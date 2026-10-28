// MailModels.swift — local mirrors of the JSON the `mail42` CLI prints (`--json`).
//
// The widget links only Work42UI and Work42PluginKit, so it can't import mail42's own types: these structs
// decode just the fields the UI shows (JSONDecoder ignores the rest). Keys and shapes follow the CLI's documented
// output: `mail42 envelope list`, `mailbox list`, `message read --out`, `attachment list`, `permissions`.

import Foundation

nonisolated struct MailPerson: Codable, Equatable, Sendable {
    let name: String?
    let addr: String?

    /// The name when there is one, else the address.
    var display: String {
        if let name, !name.isEmpty { return name }
        return addr ?? "(unknown)"
    }

    /// Up to two letters for the avatar.
    var initials: String {
        let source = display.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = source.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    /// `Name <addr>` or just the address.
    var full: String {
        if let name, !name.isEmpty, let addr { return "\(name) <\(addr)>" }
        return display
    }
}

nonisolated struct MailAccountRef: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String?

    var label: String { email ?? name }
}

nonisolated struct MailMailboxRef: Codable, Equatable, Sendable {
    let id: Int64
    let name: String
    let role: String
}

/// One message summary: `mail42 envelope list --json` / `envelope search --json`.
nonisolated struct MailEnvelope: Codable, Identifiable, Equatable, Sendable {
    let id: Int64
    let messageID: String?
    let conversationID: Int64?
    let account: MailAccountRef
    let mailbox: MailMailboxRef
    let from: MailPerson
    let to: [MailPerson]
    let cc: [MailPerson]
    let subject: String
    let date: Date
    let snippet: String?
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachments: Bool

    enum CodingKeys: String, CodingKey {
        case id, account, mailbox, from, to, cc, subject, date, snippet
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case isRead = "is_read"
        case isFlagged = "is_flagged"
        case hasAttachments = "has_attachments"
    }
}

/// `mail42 mailbox list --json`: one account with its mailboxes.
nonisolated struct MailAccountTree: Codable, Equatable, Identifiable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let email: String?
        let kind: String
    }

    let account: Account
    let mailboxes: [MailMailbox]

    var id: String { account.id }
    var label: String { account.email ?? account.name }
}

nonisolated struct MailMailbox: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let role: String
    let total: Int64
    let unread: Int64
}

nonisolated struct MailAttachment: Codable, Equatable, Identifiable, Sendable {
    let part: String
    let filename: String
    let mime: String
    let size: Int64

    var id: String { part }
}

/// `mail42 message read <id> --html --out <file> --json`.
nonisolated struct MailReadResult: Codable, Equatable, Sendable {
    let path: String?
    let bodyUnavailable: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case bodyUnavailable = "body_unavailable"
    }
}

/// `mail42 permissions --json` (the exit code carries granted / not granted; this is for the details).
nonisolated struct MailPermissionsReport: Codable, Equatable, Sendable {
    let fullDiskAccess: String
}

/// `{"error":{"code","message"}}`, which the CLI prints to stdout with `--json`.
nonisolated struct MailErrorEnvelope: Codable {
    struct Body: Codable {
        let code: String
        let message: String
    }
    let error: Body
}

/// A failed CLI call, with the machine code the CLI reported (`fda_denied`, `not_found`, `bad_query`, …).
nonisolated struct MailFailure: Error, Equatable {
    let code: String
    let message: String

    static let notInstalled = MailFailure(code: "not_installed", message: "mail42 isn't installed.")
}
