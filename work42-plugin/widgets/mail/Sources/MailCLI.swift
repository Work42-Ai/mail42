// MailCLI.swift — runs the `mail42` command-line tool and decodes its JSON.
//
// Every call is a real subprocess with an argument ARRAY (never a shell string), so search text and file names
// can't inject commands. The widget never reads Apple Mail itself: everything goes through the CLI, and both the
// process and the JSON decoding stay off the main thread.

// On the iPad there is no `mail42` to run. The same verbs go through `services.shell`, which the paired Mac answers (the
// link allows only a built-in widget's own CLI, and nothing with a shell metacharacter in it, so a search for
// `a;b` is refused there rather than run).

import Foundation
import Work42PluginKit

/// The outcome of one CLI run.
nonisolated struct MailCLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
}

#if os(macOS)
/// Collects a pipe's bytes from a background thread.
nonisolated private final class PipeBox: @unchecked Sendable {
    var data = Data()
}
#endif

/// Full Disk Access for mail42, as `mail42 permissions` reports it.
nonisolated enum MailAccess: Sendable {
    case granted, denied, noMailData, notInstalled
}

nonisolated enum MailCLI {

    /// One word of a command line sent to the Mac's shell (the iPad's path). Plain words go as they are; anything else
    /// is single-quoted, with a quote inside it written as `'\''`.
    static func quoted(_ argument: String) -> String {
        let plain = argument.unicodeScalars.allSatisfy {
            $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || "_@%+=:,./-~".unicodeScalars.contains($0))
        }
        if plain, !argument.isEmpty { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    #if os(macOS)

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

    static func executableURL() -> URL? {
        if let installed = installedURL { return installed }
        return which("mail42").map { URL(fileURLWithPath: $0) }
    }

    /// Runs `mail42 <arguments>`. Returns nil when mail42 isn't installed or couldn't be launched.
    static func run(_ arguments: [String], timeout: TimeInterval = 60) async -> MailCLIResult? {
        guard let executable = executableURL() else { return nil }
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

    #else

    /// The Mac's shell, as `services.shell` reaches it. Set when the widget starts.
    nonisolated(unsafe) static var remoteShell: (any WidgetShellService)?

    /// A `mail42` is always reachable from here; whether the Mac has one shows when a command runs (exit 127).
    static func isInstalled() -> Bool { true }

    /// Runs `mail42 <arguments>` on the Mac. Returns nil when there is no shell to ask or the Mac didn't answer.
    static func run(_ arguments: [String], timeout: TimeInterval = 60) async -> MailCLIResult? {
        guard let shell = remoteShell else { return nil }
        let command = (["mail42"] + arguments.map(quoted)).joined(separator: " ")
        guard let result = try? await shell.run(command: command) else { return nil }
        if result.exitCode == 127 { return nil }   // the Mac has no mail42
        return MailCLIResult(status: result.exitCode, stdout: Data(result.stdout.utf8), stderr: result.stderr)
    }

    static func json<T: Decodable & Sendable>(
        _ type: T.Type, _ arguments: [String], timeout: TimeInterval = 60
    ) async throws -> T {
        guard let shell = remoteShell else { throw MailFailure.notInstalled }
        let command = (["mail42"] + (arguments + ["--json"]).map(quoted)).joined(separator: " ")
        let result: WidgetShellResult
        do {
            result = try await shell.run(command: command)
        } catch let error as WidgetServiceError {
            // A refusal names its reason (a character the link won't carry); anything else is the Mac not answering.
            throw MailFailure(
                code: error.isNotPermitted ? "not_permitted" : "mac_unreachable",
                message: error.isNotPermitted ? error.message : "Your Mac didn\u{2019}t answer: \(error.message)")
        }
        if result.exitCode == 127 { throw MailFailure.notInstalled }
        let output = MailCLIResult(status: result.exitCode, stdout: Data(result.stdout.utf8), stderr: result.stderr)
        guard output.status == 0 else { throw failure(from: output) }
        return try await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(T.self, from: output.stdout)
            } catch {
                throw MailFailure(
                    code: "bad_output",
                    message: "mail42 printed something unexpected: \(error.localizedDescription)")
            }
        }.value
    }

    #endif

    // MARK: - Decoding

    #if os(macOS)

    /// Runs a `--json` verb and decodes its output, mapping a failure to `MailFailure` (using the CLI's own
    /// `{"error":{"code","message"}}` when it printed one).
    /// The process and the JSON decoding both run on a background queue; only the finished value comes back.
    static func json<T: Decodable & Sendable>(
        _ type: T.Type, _ arguments: [String], timeout: TimeInterval = 60
    ) async throws -> T {
        guard let executable = executableURL() else { throw MailFailure.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let result = runBlocking(executable, arguments + ["--json"], timeout: timeout) else {
                    continuation.resume(throwing: MailFailure.notInstalled)
                    return
                }
                guard result.status == 0 else {
                    continuation.resume(throwing: failure(from: result))
                    return
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do {
                    continuation.resume(returning: try decoder.decode(T.self, from: result.stdout))
                } catch {
                    continuation.resume(throwing: MailFailure(
                        code: "bad_output",
                        message: "mail42 printed something unexpected: \(error.localizedDescription)"))
                }
            }
        }
    }

    #endif

    /// Full Disk Access as mail42 itself sees it (`mail42 permissions`: exit 0 when granted).
    static func access() async -> MailAccess {
        guard let result = await run(["permissions", "--json"], timeout: 20) else { return .notInstalled }
        if result.status == 0 { return .granted }
        let report = try? JSONDecoder().decode(MailPermissionsReport.self, from: result.stdout)
        return report?.fullDiskAccess == "noMailData" ? .noMailData : .denied
    }

    static func failure(from result: MailCLIResult) -> MailFailure {
        if let envelope = try? JSONDecoder().decode(MailErrorEnvelope.self, from: result.stdout) {
            return MailFailure(code: envelope.error.code, message: envelope.error.message)
        }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailFailure(code: "failed", message: text.isEmpty ? "mail42 exited with status \(result.status)." : text)
    }
}
