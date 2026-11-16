// MailCLI.swift — what the widget needs to know about the `mail42` command-line tool, apart from talking to it.
//
// Talking to it is `MailStore` over a `MailTransport` (the `mail42 serve` daemon on the Mac, shell calls through the Mac
// on the iPad). This file keeps the shape of an answer, how a command word is quoted for the Mac's shell, where the
// installed tool lives, and how a failed answer becomes a `MailFailure`.

import Foundation

/// The outcome of one mail42 command.
nonisolated struct MailCLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
}

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

    private static func which(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
            .split(separator: ":")
        for dir in paths {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The `mail42` that can start the daemon: the installed one, else one on the PATH.
    static func executableURL() -> URL? {
        if let installed = installedURL { return installed }
        return which("mail42").map { URL(fileURLWithPath: $0) }
    }

    #endif

    /// A failed answer as the `MailFailure` it describes: the CLI's own `{"error":{"code","message"}}` when it printed
    /// one, else its stderr, else its exit status.
    static func failure(from result: MailCLIResult) -> MailFailure {
        if let envelope = try? JSONDecoder().decode(MailErrorEnvelope.self, from: result.stdout) {
            return MailFailure(code: envelope.error.code, message: envelope.error.message)
        }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailFailure(code: "failed", message: text.isEmpty ? "mail42 exited with status \(result.status)." : text)
    }
}
