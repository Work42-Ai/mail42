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
    var isRead: Bool
    var isFlagged: Bool
    let hasAttachments: Bool
    /// `mail42://message/<id>?mid=<Message-ID>`: finds the message again after Mail moves it.
    let link: String?
    /// Messages in the whole conversation (`envelope list --conversations`); nil for a plain list or a search.
    let conversationCount: Int?
    /// Who wrote in the conversation, newest first (at most three names).
    let participants: [String]?

    enum CodingKeys: String, CodingKey {
        case id, account, mailbox, from, to, cc, subject, date, snippet, link, participants
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case isRead = "is_read"
        case isFlagged = "is_flagged"
        case hasAttachments = "has_attachments"
        case conversationCount = "conversation_count"
    }

    /// What the CLI is given to name this message: its link when it has one, else the bare id.
    var reference: String { link ?? String(id) }

    /// The row's heading: the people of a conversation, or the sender of a single message.
    var heading: String {
        if let participants, (conversationCount ?? 1) > 1, !participants.isEmpty { return participants.joined(separator: ", ") }
        return from.display
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
    var mailboxes: [MailMailbox]

    var id: String { account.id }
    var label: String { account.email ?? account.name }
}

nonisolated struct MailMailbox: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let role: String
    var total: Int64
    var unread: Int64
}

/// What an action verb (`mark`, `move`, `archive`, …) prints: `{"ok":true,"link":…}`.
nonisolated struct MailActionResult: Decodable, Sendable {
    let ok: Bool
    let link: String?
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
