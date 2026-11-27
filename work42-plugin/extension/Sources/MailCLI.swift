// MailCLI.swift — the shape of an answer to one of the widget's requests, and how a failed one becomes a `MailFailure`.
//
// Requests are argument vectors in the vocabulary of the standalone `mail42` tool (`envelope list --conversations`, `mark <link> read`),
// answered in-process on the Mac (MailDirectTransport) or by the paired Mac's `mail` tools on the iPad (MailPluginToolsTransport).
// Nothing here starts a process.

import Foundation

/// The outcome of one request: an exit-style status, what it printed (JSON with `--json`) and its one-line stderr.
nonisolated struct MailCLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
}

/// Full Disk Access, as a request for `permissions` reports it.
nonisolated enum MailAccess: Sendable {
    case granted, denied, noMailData
    /// Access could not be checked (the service refused, did not start or timed out): what went wrong.
    case unreachable(String)
}

nonisolated enum MailCLI {

    /// One word of the command line Quick Look runs through Work 42's shell (`qlmanage -p <file>`, the one command the plugin still
    /// starts, hence the `run-commands` permission). Plain words go as they are; anything else is single-quoted, with a quote
    /// inside it written as `'\''`.
    static func quoted(_ argument: String) -> String {
        let plain = argument.unicodeScalars.allSatisfy {
            $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || "_@%+=:,./-~".unicodeScalars.contains($0))
        }
        if plain, !argument.isEmpty { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A failed answer as the `MailFailure` it describes: its own `{"error":{"code","message"}}` when it printed one, else its
    /// stderr, else its exit status.
    static func failure(from result: MailCLIResult) -> MailFailure {
        if let envelope = try? JSONDecoder().decode(MailErrorEnvelope.self, from: result.stdout) {
            return MailFailure(code: envelope.error.code, message: envelope.error.message)
        }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailFailure(code: "failed", message: text.isEmpty ? "Mail failed with status \(result.status)." : text)
    }
}
