// MailModels.swift — local mirrors of the JSON the `mail42` CLI prints (`--json`).
//
// The widget links only Work42UI and Work42PluginKit, so it can't import mail42's own types: these structs
// decode just the fields the UI shows (JSONDecoder ignores the rest). Keys and shapes follow the CLI's documented
// output: `mail42 envelope list`, `mailbox list`, `message read --out`, `attachment list`, `permissions`.

import Foundation

nonisolated struct MailPerson: Codable, Equatable {
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

nonisolated struct MailAccountRef: Codable, Equatable {
    let id: String
    let name: String
    let email: String?

    var label: String { email ?? name }
}

nonisolated struct MailMailboxRef: Codable, Equatable {
    let id: Int64
    let name: String
    let role: String
}

/// One message summary: `mail42 envelope list --json` / `envelope search --json`.
nonisolated struct MailEnvelope: Codable, Identifiable, Equatable {
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
nonisolated struct MailAccountTree: Codable, Equatable, Identifiable {
    struct Account: Codable, Equatable {
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

nonisolated struct MailMailbox: Codable, Equatable, Identifiable {
    let id: Int64
    let name: String
    let role: String
    let total: Int64
    let unread: Int64
}

nonisolated struct MailAttachment: Codable, Equatable, Identifiable {
    let part: String
    let filename: String
    let mime: String
    let size: Int64

    var id: String { part }
}

/// `mail42 message read <id> --html --out <file> --json`.
nonisolated struct MailReadResult: Codable, Equatable {
    let path: String?
    let bodyUnavailable: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case bodyUnavailable = "body_unavailable"
    }
}

/// `mail42 sync --json`.
nonisolated struct MailSyncSummary: Codable, Equatable {
    let added: Int
    let updated: Int
    let removed: Int
}

/// The live progress of a running `mail42 sync`, which the CLI keeps in `~/.work42/mail42/sync-status.json`.
/// `current()` is nil unless a sync is really running (a crashed sync leaves a stale file behind).
nonisolated struct MailSyncProgress: Decodable, Equatable {
    let state: String
    let phase: String?
    let pid: Int32?
    let started: Date?
    let updated: Date?
    let processed: Int
    let total: Int?

    /// A "running" file nobody has touched for this long is dead.
    static let staleAfter: TimeInterval = 600

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".work42/mail42/sync-status.json")
    }

    /// 0…1 once the total is known.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(processed) / Double(total))
    }

    /// A rough time left, from how fast this run has gone so far. Nil until there is enough to go on.
    func secondsLeft(now: Date = Date()) -> Int? {
        guard let started, let total, processed >= 100, total > processed else { return nil }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed > 5 else { return nil }
        return Int((Double(total - processed) / (Double(processed) / elapsed)).rounded())
    }

    static func current(now: Date = Date()) -> MailSyncProgress? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(MailSyncProgress.self, from: data), status.state == "running"
        else { return nil }
        if let last = status.updated ?? status.started, now.timeIntervalSince(last) > staleAfter { return nil }
        if let pid = status.pid, kill(pid, 0) != 0, errno != EPERM { return nil }
        return status
    }
}

/// `mail42 permissions --json` (the exit code carries granted / not granted; this is for the details).
nonisolated struct MailPermissionsReport: Codable, Equatable {
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
