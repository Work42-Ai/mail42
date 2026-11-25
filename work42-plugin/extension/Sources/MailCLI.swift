// MailCLI.swift — what the widget needs to know about the `mail42` command-line tool, apart from talking to it.
//
// Talking to it is `MailStore` over a `MailTransport` (the `mail42 serve` daemon on the Mac, shell calls through the Mac
// on the iPad). This file keeps the shape of an answer, how a command word is quoted for the Mac's shell, and how a
// failed answer becomes a `MailFailure`. Where the tool lives is the host shell's business: `mail42` is run by name and Work42's
// shell finds it (`~/.work42/bin/mail42`).

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
