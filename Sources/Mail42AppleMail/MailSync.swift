// MailSync.swift — copies new, changed and removed mail from Apple Mail into mail42's own index.
//
// One run: check Full Disk Access → take a private snapshot of the Envelope Index → check its schema → open
// mail.db → bring accounts, mailboxes and messages up to date → record the outcome. Apple Mail's files are only
// read (through the snapshot). Nothing in mail.db is touched when access is denied or the schema is
// unsupported: those checks all happen before the store is opened.
//
// What "up to date" means:
//   · scope: messages with `deleted = 0` received within `window_days` (default 90; 0 = all), one row per
//     Message-ID (Gmail keeps a copy in [Gmail]/All Mail plus one per label; the non-All-Mail copy wins);
//   · added: in scope but not indexed yet; their bodies are parsed from the .emlx into the full-text index;
//   · updated: indexed, but read / flagged / mailbox changed in Mail;
//   · removed: indexed, but gone from Mail, deleted, or older than the window.
// New messages are indexed in batches of 500, one transaction each, so a long first sync makes visible
// progress and an interrupted one resumes where it stopped (the next run sees those messages as indexed).

import Foundation
import Mail42Kit

public struct SyncResult: Codable, Equatable, Sendable {
    public var added: Int
    public var updated: Int
    public var removed: Int
    public var ms: Int
}

/// Classifies a mailbox by its name. Names differ by provider and language of the server, so this covers the
/// common English ones (iCloud, Gmail, Outlook/Exchange, generic IMAP); everything else is `other`.
public enum MailboxRole {
    public static func classify(name: String) -> String {
        let leaf = (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
        let full = name.lowercased()
        switch leaf {
        case "inbox": return "inbox"
        case "sent", "sent messages", "sent items", "sent mail": return "sent"
        case "drafts", "draft": return "drafts"
        case "archive", "archives", "all mail": return "archive"
        case "trash", "deleted messages", "deleted items", "bin": return "trash"
        case "junk", "junk email", "junk e-mail", "spam": return "junk"
        default: return full.hasSuffix("/all mail") ? "archive" : "other"
        }
    }

    /// Gmail's catch-all folder: it holds a copy of every message, so it loses to any other copy.
    static func isGmailAllMail(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "[gmail]/all mail" || lowered == "[google mail]/all mail"
    }
}

public final class MailSync {

    private let storeURL: URL
    private let library: URL
    private let traceFile: URL?
    private let now: () -> Date

    private static let batchSize = 500
    private static let snippetLength = 200

    /// - Parameters:
    ///   - storeURL: where mail.db lives (tests use a temp file).
    ///   - library: the `Library/Mail` folder to read (tests use a synthetic one).
    ///   - traceFile: where to append the `sync-ok` / `sync-failed` line; nil to skip tracing.
    public init(
        storeURL: URL = Mail42Paths.db,
        library: URL = Mail42Paths.appleMailLibrary,
        traceFile: URL? = Mail42Paths.trace,
        now: @escaping () -> Date = Date.init
    ) {
        self.storeURL = storeURL
        self.library = library
        self.traceFile = traceFile
        self.now = now
    }

    // MARK: - Run

    public func run(full: Bool = false) throws -> SyncResult {
        let started = Date()
        do {
            let result = try sync(full: full, started: started)
            trace("sync-ok", ["added": result.added, "updated": result.updated, "removed": result.removed, "ms": result.ms])
            return result
        } catch {
            trace("sync-failed", ["code": (error as? Mail42Error)?.code ?? "error", "message": "\(error)"])
            throw error
        }
    }

    private func trace(_ event: String, _ fields: [String: Any]) {
        guard let traceFile else { return }
        Trace.append(src: "sync", event: event, fields: fields, to: traceFile)
    }

    private func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    // MARK: - Snapshot rows

    private struct SnapshotMailbox {
        let row: MailboxRow
        let components: [String]
    }

    private struct SnapshotMessage {
        let id: Int64
        let subject: String
        let fromAddr: String?
        let fromName: String?
        let mailboxID: Int64
        let dateReceived: Int64
        let dateSent: Int64?
        let isRead: Bool
        let isFlagged: Bool
        let size: Int64
        let conversationID: Int64
        let summary: String?
        let messageID: String?
    }

    private func sync(full: Bool, started: Date) throws -> SyncResult {
        // 1. Access and snapshot. Nothing here writes to mail.db.
        switch AppleMailAccess.fullDiskAccess(library: library) {
        case .granted: break
        case .denied: throw Mail42Error.fdaDenied
        case .noMailData: throw Mail42Error.noMailData
        }
        guard let mailRoot = Mail42Paths.appleMailRoot(in: library) else { throw Mail42Error.noMailData }
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: mailRoot)
        defer { snapshot.close() }
        try snapshot.validateSchema()
        let capabilities = try snapshot.capabilities()

        // 2. Now the store may be opened (and created, on a first run).
        let store = try MailStore(path: storeURL)
        let windowDays = try store.windowDays()
        let cutoff: Int64? = windowDays > 0
            ? Int64(now().timeIntervalSince1970) - Int64(windowDays) * 86_400
            : nil

        // 3. Accounts and mailboxes.
        let mailboxes = try readMailboxes(snapshot, mailRoot: mailRoot)
        let mailboxByID = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.row.id, $0) })
        try store.transaction {
            try store.upsertAccounts(accounts(for: mailboxes, mailRoot: mailRoot))
            try store.upsertMailboxes(mailboxes.map(\.row))
            try store.pruneAccountsAndMailboxes(
                keepingMailboxes: Set(mailboxes.map(\.row.id)),
                accounts: Set(mailboxes.map(\.row.accountID)))
        }

        // 4. Messages in scope, one per Message-ID.
        let inScope = try readMessages(snapshot, capabilities: capabilities, cutoff: cutoff, mailboxes: mailboxByID)
        let winners = deduplicate(inScope, mailboxes: mailboxByID)

        // 5. What changed since the last sync.
        let known = try store.knownEnvelopeStates()
        var toIndex: [(message: SnapshotMessage, isNew: Bool)] = []
        var flagChanges: [(id: Int64, isRead: Bool, isFlagged: Bool, mailboxID: Int64)] = []
        var present = Set<Int64>()
        var updated = 0
        for message in winners {
            present.insert(message.id)
            guard let state = known[message.id] else {
                toIndex.append((message, true))
                continue
            }
            // A known id whose Message-ID changed means Mail rebuilt its index and reused ROWIDs: the
            // incremental picture can't be trusted, so start over.
            if !full, let old = state.messageID, let new = message.messageID, old != new {
                return try sync(full: true, started: started)
            }
            let changed = state.isRead != message.isRead || state.isFlagged != message.isFlagged
                || state.mailboxID != message.mailboxID
            if changed {
                updated += 1
                flagChanges.append((message.id, message.isRead, message.isFlagged, message.mailboxID))
            }
            if full { toIndex.append((message, false)) }
        }
        let removedIDs = known.keys.filter { !present.contains($0) }

        // 6. New (and, under --full, re-indexed) messages, in batches.
        var added = 0
        for start in stride(from: 0, to: toIndex.count, by: Self.batchSize) {
            let batch = Array(toIndex[start..<min(start + Self.batchSize, toIndex.count)])
            let ids = batch.map(\.message.id)
            let recipients = try readRecipients(snapshot, ids: ids)
            let appleAttachments = try readAttachments(snapshot, ids: ids)
            let prepared = batch.map {
                prepare($0.message, mailbox: mailboxByID[$0.message.mailboxID], mailRoot: mailRoot,
                        recipients: recipients[$0.message.id] ?? [], appleAttachments: appleAttachments[$0.message.id] ?? [])
            }
            try store.transaction {
                for item in prepared {
                    try store.upsertEnvelope(item.envelope, recipients: item.recipients,
                                             attachments: item.attachments, bodyText: item.bodyText)
                }
            }
            added += batch.filter(\.isNew).count
        }

        // 7. Flag changes, removals and the sync state, together.
        try store.transaction {
            try store.updateFlags(flagChanges)
            try store.deleteEnvelopes(ids: removedIDs)
            try store.setState(MailStore.StateKey.lastRowID, String(winners.map(\.id).max() ?? 0))
            try store.setState(MailStore.StateKey.lastSyncAt, ISO8601DateFormatter().string(from: now()))
            try store.setState(MailStore.StateKey.fdaState, FDAState.granted.rawValue)
        }

        return SyncResult(added: added, updated: updated, removed: removedIDs.count, ms: milliseconds(since: started))
    }

    // MARK: - Reading the snapshot

    private func readMailboxes(_ snapshot: EnvelopeIndexSnapshot, mailRoot: URL) throws -> [SnapshotMailbox] {
        var result: [SnapshotMailbox] = []
        try snapshot.connection.query("SELECT ROWID, url, total_count, unread_count FROM mailboxes") { row in
            guard let url = row.text(1), let parsed = MailboxURL.decode(url) else { return }
            let name = parsed.pathComponents.joined(separator: "/")
            result.append(SnapshotMailbox(
                row: MailboxRow(
                    id: row.int(0), accountID: parsed.accountUUID, name: name,
                    role: MailboxRole.classify(name: name), url: url, total: row.int(2), unread: row.int(3)),
                components: parsed.pathComponents))
        }
        return result
    }

    private func accounts(for mailboxes: [SnapshotMailbox], mailRoot: URL) -> [AccountRow] {
        let map = AccountMapper.buildMapping(
            path: mailRoot.appendingPathComponent("MailData/Signatures/AccountsMap.plist").path)
        var seen: [String: AccountRow] = [:]
        for mailbox in mailboxes where seen[mailbox.row.accountID] == nil {
            let uuid = mailbox.row.accountID
            let email = map[uuid].flatMap { $0.contains("@") ? $0 : nil }
            let scheme = mailbox.row.url.components(separatedBy: "://").first ?? "imap"
            seen[uuid] = AccountRow(id: uuid, name: email ?? uuid, email: email, kind: scheme)
        }
        return Array(seen.values)
    }

    private func readMessages(
        _ snapshot: EnvelopeIndexSnapshot, capabilities: EnvelopeIndexSnapshot.Capabilities,
        cutoff: Int64?, mailboxes: [Int64: SnapshotMailbox]
    ) throws -> [SnapshotMessage] {
        let sql = """
        SELECT m.ROWID, s.subject, a.address, a.comment, m.mailbox, m.date_received,
               \(capabilities.hasDateSent ? "m.date_sent" : "NULL"),
               m.read, m.flagged, m.size, m.conversation_id,
               \(capabilities.hasSummary ? "sm.summary" : "NULL"),
               \(capabilities.hasMessageIDHeader ? "g.message_id_header" : "NULL")
        FROM messages m
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        \(capabilities.hasSummary ? "LEFT JOIN summaries sm ON m.summary = sm.ROWID" : "")
        \(capabilities.hasMessageIDHeader ? "LEFT JOIN message_global_data g ON m.global_message_id = g.ROWID" : "")
        WHERE m.deleted = 0 \(cutoff != nil ? "AND m.date_received >= ?" : "")
        ORDER BY m.ROWID
        """
        var messages: [SnapshotMessage] = []
        try snapshot.connection.query(sql, cutoff.map { [SQLiteValue.int($0)] } ?? []) { row in
            let mailboxID = row.int(4)
            guard mailboxes[mailboxID] != nil else { return }      // a message whose mailbox Mail no longer lists
            let header = row.text(12)?.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(SnapshotMessage(
                id: row.int(0), subject: row.text(1) ?? "", fromAddr: row.text(2), fromName: row.text(3),
                mailboxID: mailboxID, dateReceived: row.int(5), dateSent: row.isNull(6) ? nil : row.int(6),
                isRead: row.int(7) != 0, isFlagged: row.int(8) != 0, size: row.int(9), conversationID: row.int(10),
                summary: row.text(11), messageID: (header?.isEmpty == false) ? header : nil))
        }
        return messages
    }

    /// One message per Message-ID: the copy outside Gmail's All Mail, then the lowest ROWID.
    private func deduplicate(_ messages: [SnapshotMessage], mailboxes: [Int64: SnapshotMailbox]) -> [SnapshotMessage] {
        var best: [String: SnapshotMessage] = [:]
        var unkeyed: [SnapshotMessage] = []
        func rank(_ m: SnapshotMessage) -> (Int, Int64) {
            let allMail = mailboxes[m.mailboxID].map { MailboxRole.isGmailAllMail($0.row.name) } ?? false
            return (allMail ? 1 : 0, m.id)
        }
        for message in messages {
            guard let key = message.messageID else { unkeyed.append(message); continue }
            if let current = best[key], rank(current) <= rank(message) { continue }
            best[key] = message
        }
        return (Array(best.values) + unkeyed).sorted { $0.id < $1.id }
    }

    /// Recipients per message. Type 0 = To is confirmed by che-apple-mail-mcp's production queries; 1 = Cc and
    /// 2 = Bcc follow the commonly documented values but could not be verified against a real index, so they
    /// are kept in this one place.
    private func readRecipients(_ snapshot: EnvelopeIndexSnapshot, ids: [Int64]) throws -> [Int64: [RecipientRow]] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var result: [Int64: [RecipientRow]] = [:]
        try snapshot.connection.query(
            """
            SELECT r.message, r.type, a.address, a.comment, r.position FROM recipients r
            JOIN addresses a ON r.address = a.ROWID WHERE r.message IN (\(marks)) ORDER BY r.message, r.position
            """, ids.map(SQLiteValue.int)
        ) { row in
            let kind: String
            switch row.int(1) {
            case 0: kind = "to"
            case 1: kind = "cc"
            case 2: kind = "bcc"
            default: return
            }
            guard let address = row.text(2), !address.isEmpty else { return }
            result[row.int(0), default: []].append(
                RecipientRow(kind: kind, name: row.text(3), addr: address, position: row.int(4)))
        }
        return result
    }

    private func readAttachments(_ snapshot: EnvelopeIndexSnapshot, ids: [Int64]) throws -> [Int64: [AttachmentRow]] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var result: [Int64: [AttachmentRow]] = [:]
        try snapshot.connection.query(
            "SELECT message, name, attachment_id FROM attachments WHERE message IN (\(marks)) ORDER BY message, attachment_id",
            ids.map(SQLiteValue.int)
        ) { row in
            guard let name = row.text(1), !name.isEmpty else { return }
            result[row.int(0), default: []].append(
                AttachmentRow(part: row.text(2) ?? "", filename: name, mime: "", size: 0))
        }
        return result
    }

    // MARK: - Building rows

    private struct Prepared {
        let envelope: EnvelopeRow
        let recipients: [RecipientRow]
        let attachments: [AttachmentRow]
        let bodyText: String
    }

    /// Parses the message's .emlx (when it's on disk) for its body text, Message-ID and attachments. A message
    /// whose file is missing (Exchange accounts, bodies Mail never downloaded) or unreadable is still indexed
    /// from its metadata.
    private func prepare(
        _ message: SnapshotMessage, mailbox: SnapshotMailbox?, mailRoot: URL,
        recipients: [RecipientRow], appleAttachments: [AttachmentRow]
    ) -> Prepared {
        var bodyText = ""
        var emlxPath: String?
        var messageID = message.messageID
        var attachments = appleAttachments

        if let mailbox,
           let file = EmlxLocator.emlxURL(rowid: message.id, mailboxURL: mailbox.row.url, mailRoot: mailRoot),
           let parsed = try? MessageParser.parse(emlx: file) {
            emlxPath = file.path
            bodyText = parsed.textBody ?? parsed.htmlBody.map(HTMLText.convert) ?? ""
            messageID = messageID ?? parsed.messageID
            attachments = parsed.attachments.map {
                AttachmentRow(part: $0.part, filename: $0.filename ?? "", mime: $0.mime, size: Int64($0.size))
            }
        }

        let envelope = EnvelopeRow(
            id: message.id, messageID: messageID, conversationID: message.conversationID,
            mailboxID: message.mailboxID, subject: message.subject, fromName: message.fromName,
            fromAddr: message.fromAddr, dateReceived: message.dateReceived,
            dateSent: message.dateSent ?? message.dateReceived,
            snippet: snippet(summary: message.summary, body: bodyText), isRead: message.isRead,
            isFlagged: message.isFlagged, hasAttachments: !attachments.isEmpty, size: message.size,
            emlxPath: emlxPath)
        return Prepared(envelope: envelope, recipients: recipients, attachments: attachments, bodyText: bodyText)
    }

    /// Apple's own summary when it has one, else the start of the body; one line, at most 200 characters.
    private func snippet(summary: String?, body: String) -> String? {
        let source = (summary?.isEmpty == false) ? summary! : body
        let line = source.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return String(line.prefix(Self.snippetLength))
    }
}
