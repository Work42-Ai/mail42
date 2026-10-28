// MailCLI.swift — runs the `mail42` command-line tool and decodes its JSON.
//
// Every call is a real subprocess with an argument ARRAY (never a shell string), so search text and file names
// can't inject commands, and there is no 10-second shell timeout cutting off a long first sync. The widget
// never reads Apple Mail or mail.db itself: everything goes through the CLI.

import Foundation

/// The outcome of one CLI run.
nonisolated struct MailCLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
}

/// Collects a pipe's bytes from a background thread.
nonisolated private final class PipeBox: @unchecked Sendable {
    var data = Data()
}

nonisolated enum MailCLI {

    /// `~/.work42/bin/mail42` (where Work42's installer links the tool), if it exists.
    static var installedURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".work42/bin/mail42")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// True when a `mail42` can be run.
    static func isInstalled() -> Bool {
        if installedURL != nil { return true }
        return which("mail42") != nil
    }

    private static func which(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
            .split(separator: ":")
        for dir in paths {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs `mail42 <arguments>`. Returns nil when mail42 isn't installed or couldn't be launched.
    static func run(_ arguments: [String], timeout: TimeInterval = 60) async -> MailCLIResult? {
        let executable: URL
        if let installed = installedURL {
            executable = installed
        } else if let found = which("mail42") {
            executable = URL(fileURLWithPath: found)
        } else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> MailCLIResult? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read both pipes while the process runs, or a chatty one would block on a full pipe.
        let outBox = PipeBox(), errBox = PipeBox()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()
        return MailCLIResult(
            status: process.terminationStatus, stdout: outBox.data,
            stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    // MARK: - Decoding

    /// Runs a `--json` verb and decodes its output, mapping a failure to `MailFailure` (using the CLI's own
    /// `{"error":{"code","message"}}` when it printed one).
    @MainActor
    static func json<T: Decodable>(_ type: T.Type, _ arguments: [String], timeout: TimeInterval = 60) async throws -> T {
        guard let result = await run(arguments + ["--json"], timeout: timeout) else { throw MailFailure.notInstalled }
        guard result.status == 0 else { throw failure(from: result) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: result.stdout)
        } catch {
            throw MailFailure(code: "bad_output", message: "mail42 printed something unexpected: \(error.localizedDescription)")
        }
    }

    static func failure(from result: MailCLIResult) -> MailFailure {
        if let envelope = try? JSONDecoder().decode(MailErrorEnvelope.self, from: result.stdout) {
            return MailFailure(code: envelope.error.code, message: envelope.error.message)
        }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailFailure(code: "failed", message: text.isEmpty ? "mail42 exited with status \(result.status)." : text)
    }
}
