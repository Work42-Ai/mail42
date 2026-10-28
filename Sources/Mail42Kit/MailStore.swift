// MailStore.swift — mail42's own index of the user's mail: ~/.work42/mail42/mail.db.
//
// Modelled on meet42's CalendarStore: raw sqlite3, WAL mode (so the CLI's read verbs and the widget's
// background sync can use it at the same time), `schema_version` in a key/value table, additive column
// migrations. mail42 is the only writer; Apple Mail's own files are never touched.
//
// Tables: accounts · mailboxes · envelopes (one row per message: the cheap summary agents scan) · recipients ·
// attachments · bodies_fts (FTS5 over subject / sender / recipients / body text) · sync_state.

import Foundation

// MARK: - Rows

public struct AccountRow: Equatable, Sendable {
    public var id: String          // Apple Mail's account UUID
    public var name: String        // the account's email address, or its UUID when Apple doesn't expose one
    public var email: String?
    public var kind: String        // URL scheme of the account's mailboxes: imap, ews, local…

    public init(id: String, name: String, email: String?, kind: String) {
        self.id = id
        self.name = name
        self.email = email
        self.kind = kind
    }
}

public struct MailboxRow: Equatable, Sendable {
    public var id: Int64           // Apple's mailboxes.ROWID
    public var accountID: String
    public var name: String        // path inside the account, e.g. "INBOX" or "[Gmail]/All Mail"
    public var role: String        // inbox · sent · drafts · archive · trash · junk · other
    public var url: String
    public var total: Int64
    public var unread: Int64

    public init(id: Int64, accountID: String, name: String, role: String, url: String, total: Int64, unread: Int64) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.role = role
        self.url = url
        self.total = total
        self.unread = unread
    }
}

public struct EnvelopeRow: Equatable, Sendable {
    public var id: Int64           // Apple's messages.ROWID
    public var messageID: String?  // RFC 5322 Message-ID, with angle brackets
    public var conversationID: Int64
    public var mailboxID: Int64
    public var subject: String
    public var fromName: String?
    public var fromAddr: String?
    public var dateReceived: Int64 // Unix seconds
    public var dateSent: Int64
    public var snippet: String?
    public var isRead: Bool
    public var isFlagged: Bool
    public var hasAttachments: Bool
    public var size: Int64
    public var emlxPath: String?

    public init(
        id: Int64, messageID: String?, conversationID: Int64, mailboxID: Int64, subject: String,
        fromName: String?, fromAddr: String?, dateReceived: Int64, dateSent: Int64, snippet: String?,
        isRead: Bool, isFlagged: Bool, hasAttachments: Bool, size: Int64, emlxPath: String?
    ) {
        self.id = id
        self.messageID = messageID
        self.conversationID = conversationID
        self.mailboxID = mailboxID
        self.subject = subject
        self.fromName = fromName
        self.fromAddr = fromAddr
        self.dateReceived = dateReceived
        self.dateSent = dateSent
        self.snippet = snippet
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
        self.size = size
        self.emlxPath = emlxPath
    }
}

public struct RecipientRow: Equatable, Sendable {
    public var kind: String        // to · cc · bcc
    public var name: String?
    public var addr: String
    public var position: Int64

    public init(kind: String, name: String?, addr: String, position: Int64) {
        self.kind = kind
        self.name = name
        self.addr = addr
        self.position = position
    }
}

public struct AttachmentRow: Equatable, Sendable {
    public var part: String
    public var filename: String
    public var mime: String
    public var size: Int64

    public init(part: String, filename: String, mime: String, size: Int64) {
        self.part = part
        self.filename = filename
        self.mime = mime
        self.size = size
    }
}

/// What the sync compares against Apple's index to decide what changed.
public struct EnvelopeState: Equatable, Sendable {
    public var isRead: Bool
    public var isFlagged: Bool
    public var mailboxID: Int64
    public var messageID: String?

    public init(isRead: Bool, isFlagged: Bool, mailboxID: Int64, messageID: String?) {
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.mailboxID = mailboxID
        self.messageID = messageID
    }
}

// MARK: - Store

public final class MailStore {

    public static let currentSchemaVersion = 1

    /// Keys of the `sync_state` table.
    public enum StateKey {
        public static let schemaVersion = "schema_version"
        public static let lastRowID = "last_rowid"
        public static let lastSyncAt = "last_sync_at"
        public static let fdaState = "fda_state"
        public static let windowDays = "window_days"
    }

    public static let defaultWindowDays = 90

    /// The connection. Internal so the read queries in `MailStore+Read.swift` can share it.
    let db: SQLiteConnection

    /// Opens (creating if needed) the store at `path`, switches it to WAL mode and migrates the schema.
    public init(path: URL = Mail42Paths.db) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: path.path, readOnly: false)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    // MARK: - Schema

    /// Columns added after the first release must be listed here with a default so existing databases gain
    /// them (`ALTER TABLE … ADD COLUMN`). Mirrors how CalendarStore migrates.
    private static let additiveColumns: [(table: String, column: String, declaration: String)] = [
        ("accounts", "email", "TEXT"),
        ("accounts", "kind", "TEXT NOT NULL DEFAULT 'imap'"),
        ("mailboxes", "role", "TEXT NOT NULL DEFAULT 'other'"),
        ("mailboxes", "total", "INTEGER NOT NULL DEFAULT 0"),
        ("mailboxes", "unread", "INTEGER NOT NULL DEFAULT 0"),
        ("envelopes", "message_id", "TEXT"),
        ("envelopes", "conversation_id", "INTEGER NOT NULL DEFAULT 0"),
        ("envelopes", "from_name", "TEXT"),
        ("envelopes", "from_addr", "TEXT"),
        ("envelopes", "date_sent", "INTEGER NOT NULL DEFAULT 0"),
        ("envelopes", "snippet", "TEXT"),
        ("envelopes", "is_read", "INTEGER NOT NULL DEFAULT 0"),
        ("envelopes", "is_flagged", "INTEGER NOT NULL DEFAULT 0"),
        ("envelopes", "has_attachments", "INTEGER NOT NULL DEFAULT 0"),
        ("envelopes", "size", "INTEGER NOT NULL DEFAULT 0"),
        ("envelopes", "emlx_path", "TEXT"),
        ("recipients", "name", "TEXT"),
        ("recipients", "position", "INTEGER NOT NULL DEFAULT 0"),
        ("attachments", "mime", "TEXT NOT NULL DEFAULT ''"),
        ("attachments", "size", "INTEGER NOT NULL DEFAULT 0"),
    ]

    private func migrate() throws {
        let stored = try? getState(StateKey.schemaVersion).flatMap { Int($0) }
        if let stored, stored > Self.currentSchemaVersion {
            throw Mail42Error.databaseNotAccessible(
                "mail.db was written by a newer mail42 (schema \(stored)); update mail42")
        }

        try db.execute("""
        CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT, kind TEXT NOT NULL DEFAULT 'imap');
        CREATE TABLE IF NOT EXISTS mailboxes (
            id INTEGER PRIMARY KEY, account_id TEXT NOT NULL, name TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'other', url TEXT NOT NULL,
            total INTEGER NOT NULL DEFAULT 0, unread INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS envelopes (
            id INTEGER PRIMARY KEY, message_id TEXT, conversation_id INTEGER NOT NULL DEFAULT 0,
            mailbox_id INTEGER NOT NULL, subject TEXT NOT NULL DEFAULT '', from_name TEXT, from_addr TEXT,
            date_received INTEGER NOT NULL, date_sent INTEGER NOT NULL DEFAULT 0, snippet TEXT,
            is_read INTEGER NOT NULL DEFAULT 0, is_flagged INTEGER NOT NULL DEFAULT 0,
            has_attachments INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0, emlx_path TEXT);
        CREATE TABLE IF NOT EXISTS recipients (
            envelope_id INTEGER NOT NULL, kind TEXT NOT NULL, name TEXT, addr TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS attachments (
            envelope_id INTEGER NOT NULL, part TEXT NOT NULL, filename TEXT NOT NULL,
            mime TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0);
        CREATE VIRTUAL TABLE IF NOT EXISTS bodies_fts USING fts5(
            subject, from_text, to_text, body_text, tokenize='unicode61 remove_diacritics 2');
        """)

        // Additive migrations for tables created by an earlier build.
        for (table, column, declaration) in Self.additiveColumns {
            if try !db.columns(of: table).contains(column) {
                try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
            }
        }

        // Indexes (after the column migrations, since they reference columns an old table may lack).
        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_envelopes_date ON envelopes(date_received DESC);
        CREATE INDEX IF NOT EXISTS idx_envelopes_mailbox_date ON envelopes(mailbox_id, date_received DESC);
        CREATE INDEX IF NOT EXISTS idx_envelopes_conversation ON envelopes(conversation_id);
        CREATE INDEX IF NOT EXISTS idx_envelopes_message_id ON envelopes(message_id);
        CREATE INDEX IF NOT EXISTS idx_recipients_envelope ON recipients(envelope_id);
        CREATE INDEX IF NOT EXISTS idx_attachments_envelope ON attachments(envelope_id);
        """)

        try setState(StateKey.schemaVersion, String(Self.currentSchemaVersion))
    }

    // MARK: - Transactions

    /// Runs `body` in one write transaction (`BEGIN IMMEDIATE`: it takes the write lock up front, so two
    /// syncs can't deadlock halfway through). Rolls back if `body` throws. Not re-entrant.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try db.execute("COMMIT")
            return result
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - State

    public func getState(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM sync_state WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    public func setState(_ key: String, _ value: String) throws {
        try db.query(
            "INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]) { _ in }
    }

    /// The sync window in days (0 = all mail).
    public func windowDays() throws -> Int {
        if let raw = try getState(StateKey.windowDays), let days = Int(raw), days >= 0 { return days }
        return Self.defaultWindowDays
    }

    // MARK: - Accounts and mailboxes

    public func upsertAccounts(_ accounts: [AccountRow]) throws {
        for a in accounts {
            try db.query(
                """
                INSERT INTO accounts (id, name, email, kind) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, email = excluded.email, kind = excluded.kind
                """,
                [.text(a.id), .text(a.name), a.email.map(SQLiteValue.text) ?? .null, .text(a.kind)]) { _ in }
        }
    }

    public func upsertMailboxes(_ mailboxes: [MailboxRow]) throws {
        for m in mailboxes {
            try db.query(
                """
                INSERT INTO mailboxes (id, account_id, name, role, url, total, unread) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET account_id = excluded.account_id, name = excluded.name,
                    role = excluded.role, url = excluded.url, total = excluded.total, unread = excluded.unread
                """,
                [.int(m.id), .text(m.accountID), .text(m.name), .text(m.role), .text(m.url),
                 .int(m.total), .int(m.unread)]) { _ in }
        }
    }

    /// Drops accounts and mailboxes that no longer exist in Apple Mail.
    public func pruneAccountsAndMailboxes(keepingMailboxes mailboxIDs: Set<Int64>, accounts accountIDs: Set<String>) throws {
        for existing in try mailboxes() where !mailboxIDs.contains(existing.id) {
            try db.query("DELETE FROM mailboxes WHERE id = ?", [.int(existing.id)]) { _ in }
        }
        for existing in try accounts() where !accountIDs.contains(existing.id) {
            try db.query("DELETE FROM accounts WHERE id = ?", [.text(existing.id)]) { _ in }
        }
    }

    public func accounts() throws -> [AccountRow] {
        var rows: [AccountRow] = []
        try db.query("SELECT id, name, email, kind FROM accounts ORDER BY name") {
            rows.append(AccountRow(id: $0.text(0) ?? "", name: $0.text(1) ?? "", email: $0.text(2), kind: $0.text(3) ?? "imap"))
        }
        return rows
    }

    public func mailboxes() throws -> [MailboxRow] {
        var rows: [MailboxRow] = []
        try db.query("SELECT id, account_id, name, role, url, total, unread FROM mailboxes ORDER BY account_id, name") {
            rows.append(MailboxRow(
                id: $0.int(0), accountID: $0.text(1) ?? "", name: $0.text(2) ?? "", role: $0.text(3) ?? "other",
                url: $0.text(4) ?? "", total: $0.int(5), unread: $0.int(6)))
        }
        return rows
    }

    // MARK: - Envelopes

    /// Inserts or replaces one message with its recipients, attachments and full-text row.
    public func upsertEnvelope(
        _ e: EnvelopeRow, recipients: [RecipientRow], attachments: [AttachmentRow], bodyText: String
    ) throws {
        try db.query(
            """
            INSERT OR REPLACE INTO envelopes (id, message_id, conversation_id, mailbox_id, subject, from_name,
                from_addr, date_received, date_sent, snippet, is_read, is_flagged, has_attachments, size, emlx_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.int(e.id), e.messageID.map(SQLiteValue.text) ?? .null, .int(e.conversationID), .int(e.mailboxID),
             .text(e.subject), e.fromName.map(SQLiteValue.text) ?? .null, e.fromAddr.map(SQLiteValue.text) ?? .null,
             .int(e.dateReceived), .int(e.dateSent), e.snippet.map(SQLiteValue.text) ?? .null,
             .int(e.isRead ? 1 : 0), .int(e.isFlagged ? 1 : 0), .int(e.hasAttachments ? 1 : 0), .int(e.size),
             e.emlxPath.map(SQLiteValue.text) ?? .null]) { _ in }

        try db.query("DELETE FROM recipients WHERE envelope_id = ?", [.int(e.id)]) { _ in }
        for r in recipients {
            try db.query(
                "INSERT INTO recipients (envelope_id, kind, name, addr, position) VALUES (?, ?, ?, ?, ?)",
                [.int(e.id), .text(r.kind), r.name.map(SQLiteValue.text) ?? .null, .text(r.addr), .int(r.position)]) { _ in }
        }
        try db.query("DELETE FROM attachments WHERE envelope_id = ?", [.int(e.id)]) { _ in }
        for a in attachments {
            try db.query(
                "INSERT INTO attachments (envelope_id, part, filename, mime, size) VALUES (?, ?, ?, ?, ?)",
                [.int(e.id), .text(a.part), .text(a.filename), .text(a.mime), .int(a.size)]) { _ in }
        }

        // Full-text row: rowid = the envelope id, so a match maps straight back to an envelope.
        try db.query("DELETE FROM bodies_fts WHERE rowid = ?", [.int(e.id)]) { _ in }
        let sender = [e.fromName, e.fromAddr].compactMap { $0 }.joined(separator: " ")
        let to = recipients.flatMap { [$0.name, $0.addr] }.compactMap { $0 }.joined(separator: " ")
        try db.query(
            "INSERT INTO bodies_fts (rowid, subject, from_text, to_text, body_text) VALUES (?, ?, ?, ?, ?)",
            [.int(e.id), .text(e.subject), .text(sender), .text(to), .text(bodyText)]) { _ in }
    }

    public func updateFlags(_ changes: [(id: Int64, isRead: Bool, isFlagged: Bool, mailboxID: Int64)]) throws {
        for c in changes {
            try db.query(
                "UPDATE envelopes SET is_read = ?, is_flagged = ?, mailbox_id = ? WHERE id = ?",
                [.int(c.isRead ? 1 : 0), .int(c.isFlagged ? 1 : 0), .int(c.mailboxID), .int(c.id)]) { _ in }
        }
    }

    /// Removes messages and everything that belongs to them.
    public func deleteEnvelopes(ids: [Int64]) throws {
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let params = chunk.map(SQLiteValue.int)
            try db.query("DELETE FROM envelopes WHERE id IN (\(marks))", params) { _ in }
            try db.query("DELETE FROM recipients WHERE envelope_id IN (\(marks))", params) { _ in }
            try db.query("DELETE FROM attachments WHERE envelope_id IN (\(marks))", params) { _ in }
            try db.query("DELETE FROM bodies_fts WHERE rowid IN (\(marks))", params) { _ in }
        }
    }

    /// Every indexed message with the fields the sync compares against Apple's index.
    public func knownEnvelopeStates() throws -> [Int64: EnvelopeState] {
        var states: [Int64: EnvelopeState] = [:]
        try db.query("SELECT id, is_read, is_flagged, mailbox_id, message_id FROM envelopes") {
            states[$0.int(0)] = EnvelopeState(
                isRead: $0.int(1) != 0, isFlagged: $0.int(2) != 0, mailboxID: $0.int(3), messageID: $0.text(4))
        }
        return states
    }

    public func knownIDs() throws -> Set<Int64> { Set(try knownEnvelopeStates().keys) }

    public func envelopeCount() throws -> Int { Int(try db.scalarInt("SELECT count(*) FROM envelopes") ?? 0) }

    public func envelope(id: Int64) throws -> EnvelopeRow? {
        var found: EnvelopeRow?
        try db.query(
            """
            SELECT id, message_id, conversation_id, mailbox_id, subject, from_name, from_addr, date_received,
                   date_sent, snippet, is_read, is_flagged, has_attachments, size, emlx_path
            FROM envelopes WHERE id = ?
            """, [.int(id)]
        ) { r in
            found = EnvelopeRow(
                id: r.int(0), messageID: r.text(1), conversationID: r.int(2), mailboxID: r.int(3),
                subject: r.text(4) ?? "", fromName: r.text(5), fromAddr: r.text(6), dateReceived: r.int(7),
                dateSent: r.int(8), snippet: r.text(9), isRead: r.int(10) != 0, isFlagged: r.int(11) != 0,
                hasAttachments: r.int(12) != 0, size: r.int(13), emlxPath: r.text(14))
        }
        return found
    }

    public func recipients(of id: Int64) throws -> [RecipientRow] {
        var rows: [RecipientRow] = []
        try db.query("SELECT kind, name, addr, position FROM recipients WHERE envelope_id = ? ORDER BY kind, position", [.int(id)]) {
            rows.append(RecipientRow(kind: $0.text(0) ?? "to", name: $0.text(1), addr: $0.text(2) ?? "", position: $0.int(3)))
        }
        return rows
    }

    public func attachments(of id: Int64) throws -> [AttachmentRow] {
        var rows: [AttachmentRow] = []
        try db.query("SELECT part, filename, mime, size FROM attachments WHERE envelope_id = ? ORDER BY part", [.int(id)]) {
            rows.append(AttachmentRow(part: $0.text(0) ?? "", filename: $0.text(1) ?? "", mime: $0.text(2) ?? "", size: $0.int(3)))
        }
        return rows
    }

    /// Envelope ids whose subject, sender, recipients or body match an FTS5 `MATCH` expression, best first.
    ///
    /// `expression` is raw FTS5 syntax. Anything that came from a user must be quoted as a phrase
    /// (`"qa-attach"`): unquoted, a hyphen reads as a column-exclusion operator and punctuation such as `:`
    /// or `*` changes the query's meaning.
    public func searchIDs(match expression: String, limit: Int = 100) throws -> [Int64] {
        var ids: [Int64] = []
        try db.query(
            "SELECT rowid FROM bodies_fts WHERE bodies_fts MATCH ? ORDER BY bm25(bodies_fts) LIMIT ?",
            [.text(expression), .int(Int64(limit))]
        ) { ids.append($0.int(0)) }
        return ids
    }

    /// The store's columns for a table, lowercased (tests and diagnostics).
    public func columns(of table: String) throws -> Set<String> { try db.columns(of: table) }
}
