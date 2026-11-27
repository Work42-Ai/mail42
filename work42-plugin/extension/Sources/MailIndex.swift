// MailIndex.swift — reads Apple Mail's Envelope Index (the local copy `MailMirror` made) and answers what the widget shows (WOR-900).
//
// This is the reading half of the `mail42` command line, moved into the extension so there is no CLI and no daemon: the same
// questions (mailboxes with Apple's counters, a mailbox or all inboxes newest first, conversations) asked of the same private
// schema, and answered with the widget's own models (`MailAccountTree`, `MailEnvelope`) instead of JSON on stdout.
//
// Things that are specific to how Apple stores mail, and that this owns (ported from `LiveMail`):
//   · A Gmail account keeps every message in [Gmail]/All Mail; Inbox, Important and every other label are rows in the `labels`
//     table (message → mailbox). A message is "in" a mailbox when it is stored there OR labelled with it.
//   · `total_count` / `unread_count` on `mailboxes` are Apple's own counters for the whole mailbox.
//   · A list is answered in two steps: the newest N ids first (walking the `(deleted, date_received)` index, or sorting a small
//     mailbox's members), then the details of just those N.
//
// It only ever opens the copy read-only; nothing here can write Apple Mail's files.

import Foundation
import SQLite3

// MARK: - SQLite

nonisolated enum MailIndexError: Error, Equatable {
    /// The index cannot be opened or queried (the text is SQLite's).
    case database(String)
    /// Apple's private schema is not what this expects: a required column is missing.
    case schemaUnsupported(table: String, column: String)
    /// A message or mailbox that is not there.
    case notFound(String)

    var message: String {
        switch self {
        case .database(let text): return text
        case .schemaUnsupported(let table, let column):
            return "This version of macOS keeps Mail's index differently (no \(table).\(column)). Update Work 42."
        case .notFound(let what): return "Couldn\u{2019}t find \(what)."
        }
    }
}

nonisolated enum MailSQLValue: Sendable {
    case null
    case int(Int64)
    case text(String)
}

/// One result row, valid only inside the `query` callback (it wraps the live statement).
nonisolated struct MailSQLRow {
    fileprivate let stmt: OpaquePointer
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
}

/// A read-only SQLite connection (`SQLITE_OPEN_READONLY`, never `immutable=1`, which would ignore the `-wal`).
nonisolated final class MailSQLite: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw MailIndexError.database("\(path): \(message)")
        }
        db = handle
    }

    deinit { close() }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// Callers hold `lock`.
    private var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed" }

    func query(_ sql: String, _ params: [MailSQLValue] = [], _ onRow: (MailSQLRow) throws -> Void) throws {
        // `FULLMUTEX` guards SQLite, not the `db` property: the connection is used and closed under one lock. Recursive,
        // because a row callback may run another query.
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw MailIndexError.database("database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MailIndexError.database("prepare failed: \(lastError)")
        }
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, index)
            case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            }
            guard rc == SQLITE_OK else { throw MailIndexError.database("bind failed: \(lastError)") }
        }
        let row = MailSQLRow(stmt: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try onRow(row) } else if rc == SQLITE_DONE { return } else {
                throw MailIndexError.database("step failed: \(lastError)")
            }
        }
    }

    /// The lowercase column names of `table` (empty when it does not exist).
    func columns(of table: String) throws -> Set<String> {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var names = Set<String>()
        try query("PRAGMA table_info(\(quoted))") { row in
            if let name = row.text(1) { names.insert(name.lowercased()) }
        }
        return names
    }

    func scalarInt(_ sql: String, _ params: [MailSQLValue] = []) throws -> Int64? {
        var result: Int64?
        try query(sql, params) { row in
            if result == nil, !row.isNull(0) { result = row.int(0) }
        }
        return result
    }
}

// MARK: - Mailboxes

/// What kind of mailbox a name is. Names differ by provider and language, so this covers the common English ones.
nonisolated enum MailIndexRole {
    static func classify(name: String) -> String {
        let leaf = (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
        switch leaf {
        case "inbox": return "inbox"
        case "sent", "sent messages", "sent items", "sent mail": return "sent"
        case "drafts", "draft": return "drafts"
        case "archive", "archives", "all mail": return "archive"
        case "trash", "deleted messages", "deleted items", "bin": return "trash"
        case "junk", "junk email", "junk e-mail", "spam": return "junk"
        default: return name.lowercased().hasSuffix("/all mail") ? "archive" : "other"
        }
    }
}

/// `<scheme>://<account-uuid>/<percent-encoded path>`: the account and the path components (split before decoding, so a `%2F`
/// inside a mailbox name never looks like a separator).
nonisolated struct MailIndexMailboxURL: Equatable, Sendable {
    let scheme: String
    let accountUUID: String
    let pathComponents: [String]

    static func decode(_ urlString: String) -> MailIndexMailboxURL? {
        guard let schemeEnd = urlString.range(of: "://") else { return nil }
        let scheme = String(urlString[urlString.startIndex..<schemeEnd.lowerBound])
        let afterScheme = urlString[schemeEnd.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let uuid = String(afterScheme[afterScheme.startIndex..<slash])
        let encoded = String(afterScheme[afterScheme.index(after: slash)...])
        let components = encoded.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
        return MailIndexMailboxURL(scheme: scheme, accountUUID: uuid, pathComponents: components)
    }
}

nonisolated struct MailIndexMailbox: Equatable, Sendable {
    let id: Int64
    let accountID: String
    /// Path inside the account: `INBOX`, `[Gmail]/All Mail`.
    let name: String
    let role: String
    let url: String
    let total: Int64
    let unread: Int64
}

/// What an account is called, from the system Accounts database when it is known.
nonisolated struct MailIndexAccountInfo: Equatable, Sendable {
    var name: String
    var email: String?
}

/// Which mailbox(es) a list reads.
nonisolated enum MailIndexSelector: Equatable, Sendable {
    case allInboxes
    case flagged
    case id(Int64)
    case named(String)
}

nonisolated struct MailIndexListOptions: Sendable {
    var mailbox: MailIndexSelector = .allInboxes
    var unreadOnly = false
    var flaggedOnly = false
    /// Keyset paging: only messages older than this one (pass the last id of the previous page).
    var beforeID: Int64?
    var limit = 50
}

// MARK: - The index

nonisolated final class MailIndex: @unchecked Sendable {

    /// Tables and columns this cannot work without (`ROWID` is implicit on every table).
    static let requiredColumns: [(table: String, columns: [String])] = [
        ("messages", ["subject", "sender", "mailbox", "date_received", "read", "flagged", "deleted", "size", "conversation_id"]),
        ("subjects", ["subject"]),
        ("addresses", ["address", "comment"]),
        ("recipients", ["message", "address", "type", "position"]),
        ("mailboxes", ["url", "total_count", "unread_count"]),
        ("attachments", ["message", "name", "attachment_id"]),
    ]

    /// Mailboxes with at most this many messages are listed by sorting their members; bigger ones by walking the date index.
    static let smallMailbox: Int64 = 20_000

    let db: MailSQLite
    private let accounts: [String: MailIndexAccountInfo]
    let hasSummary: Bool
    private let hasDateSent: Bool
    private let hasMessageIDHeader: Bool
    let hasLabels: Bool
    private(set) var mailboxRows: [MailIndexMailbox]
    private var mailboxByID: [Int64: MailIndexMailbox]

    /// - Parameters:
    ///   - database: the local copy of the Envelope Index (`MailMirror.refresh()`), opened read-only.
    ///   - accounts: names and addresses by account UUID (upper case); an account missing here is shown by its UUID.
    init(database: URL, accounts: [String: MailIndexAccountInfo] = [:]) throws {
        let db = try MailSQLite(path: database.path)
        self.db = db
        self.accounts = accounts
        for (table, columns) in Self.requiredColumns {
            let present = try db.columns(of: table)
            guard !present.isEmpty else { throw MailIndexError.schemaUnsupported(table: table, column: "*") }
            for column in columns where !present.contains(column) {
                throw MailIndexError.schemaUnsupported(table: table, column: column)
            }
        }
        let messages = try db.columns(of: "messages")
        let summaries = try db.columns(of: "summaries")
        let globalData = try db.columns(of: "message_global_data")
        let labels = try db.columns(of: "labels")
        hasSummary = messages.contains("summary") && summaries.contains("summary")
        hasDateSent = messages.contains("date_sent")
        hasMessageIDHeader = messages.contains("global_message_id") && globalData.contains("message_id_header")
        hasLabels = labels.contains("message_id") && labels.contains("mailbox_id")
        let rows = try Self.readMailboxRows(db)
        mailboxRows = rows
        mailboxByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func close() { db.close() }

    private static func readMailboxRows(_ db: MailSQLite) throws -> [MailIndexMailbox] {
        var rows: [MailIndexMailbox] = []
        try db.query("SELECT ROWID, url, total_count, unread_count FROM mailboxes") { row in
            guard let url = row.text(1), let parsed = MailIndexMailboxURL.decode(url) else { return }
            let name = parsed.pathComponents.joined(separator: "/")
            rows.append(MailIndexMailbox(
                id: row.int(0), accountID: parsed.accountUUID, name: name, role: MailIndexRole.classify(name: name),
                url: url, total: row.int(2), unread: row.int(3)))
        }
        return rows
    }

    /// Every mailbox's id and Apple's counters as one string (`12:830:4,13:40:0`): it changes exactly when mail arrives, is read,
    /// flagged, moved or deleted.
    func mailboxSignature() throws -> String {
        var parts: [String] = []
        try db.query("SELECT ROWID, total_count, unread_count FROM mailboxes ORDER BY ROWID") { row in
            parts.append("\(row.int(0)):\(row.int(1)):\(row.int(2))")
        }
        return parts.joined(separator: ",")
    }

    // MARK: Accounts and mailboxes

    private func info(for accountID: String) -> MailIndexAccountInfo? { accounts[accountID.uppercased()] }

    private func accountRef(_ mailbox: MailIndexMailbox?) -> MailAccountRef {
        guard let mailbox else { return MailAccountRef(id: "", name: "", email: nil) }
        let known = info(for: mailbox.accountID)
        return MailAccountRef(id: mailbox.accountID, name: known?.name ?? known?.email ?? mailbox.accountID, email: known?.email)
    }

    /// Every account with its mailboxes, as `mailbox list` printed them: accounts by name, the Inbox first, then the rest.
    func accountTrees() -> [MailAccountTree] {
        var seen: [String: MailIndexMailbox] = [:]
        for mailbox in mailboxRows where seen[mailbox.accountID] == nil { seen[mailbox.accountID] = mailbox }
        let trees = seen.values.map { first -> MailAccountTree in
            let ref = accountRef(first)
            let scheme = first.url.components(separatedBy: "://").first ?? "imap"
            let boxes = mailboxRows.filter { $0.accountID == first.accountID }.sorted { lhs, rhs in
                if (lhs.role == "inbox") != (rhs.role == "inbox") { return lhs.role == "inbox" }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }.map { MailMailbox(id: $0.id, name: $0.name, role: $0.role, total: $0.total, unread: $0.unread) }
            return MailAccountTree(account: .init(id: ref.id, name: ref.name, email: ref.email, kind: scheme), mailboxes: boxes)
        }
        return trees.sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }
    }

    /// Ids of the mailboxes a name, id or role refers to (`INBOX`, `Jarvis/VIP`, `VIP`, `inbox`, `12`).
    func mailboxIDs(matching value: String) -> [Int64] {
        let wanted = value.lowercased()
        let numeric = Int64(value)
        return mailboxRows.filter { mailbox in
            let name = mailbox.name.lowercased()
            return mailbox.id == numeric || name == wanted || name.hasSuffix("/" + wanted) || mailbox.role == wanted
        }.map(\.id)
    }

    // MARK: Lists

    private func listPlan(_ options: MailIndexListOptions) throws -> (mailboxes: [Int64]?, clauses: [String])? {
        var clauses = ["m.deleted = 0"]
        let mailboxes: [Int64]?
        switch options.mailbox {
        case .allInboxes:
            let ids = mailboxRows.filter { $0.role == "inbox" }.map(\.id)
            guard !ids.isEmpty else { return nil }
            mailboxes = ids
        case .flagged:
            mailboxes = nil
            clauses.append("m.flagged = 1")
        case .id(let id):
            mailboxes = [id]
        case .named(let name):
            let ids = mailboxIDs(matching: name)
            guard !ids.isEmpty else { throw MailIndexError.notFound("a mailbox matching \u{201C}\(name)\u{201D}") }
            mailboxes = ids
        }
        if options.unreadOnly { clauses.append("m.read = 0") }
        if options.flaggedOnly { clauses.append("m.flagged = 1") }
        return (mailboxes, clauses)
    }

    private func cursorDate(_ before: Int64) throws -> Int64 {
        guard let date = try db.scalarInt("SELECT date_received FROM messages WHERE ROWID = ?", [.int(before)]) else {
            throw MailIndexError.notFound("message \(before) (the paging cursor)")
        }
        return date
    }

    /// The newest `limit` messages of the selection, one row per message.
    func listEnvelopes(_ options: MailIndexListOptions) throws -> [MailEnvelope] {
        try listRecords(options).map { Self.envelope($0, conversationCount: nil, participants: nil) }
    }

    private func listRecords(_ options: MailIndexListOptions) throws -> [Record] {
        guard var plan = try listPlan(options) else { return [] }
        var params: [MailSQLValue] = []
        if let before = options.beforeID {
            let date = try cursorDate(before)
            // `<= date` first, so the date index can bound the scan; the second test only trims the ties.
            plan.clauses.append("m.date_received <= ? AND (m.date_received < ? OR m.ROWID < ?)")
            params += [.int(date), .int(date), .int(before)]
        }
        let limit = max(options.limit, 0)
        return try fetchRecords(
            mailboxes: plan.mailboxes, clauses: plan.clauses, params: params,
            order: "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(limit)", newestFirstLimit: limit)
    }

    /// One entry per conversation that has a message in the selection, newest first, with the size of the whole conversation and
    /// who wrote in it (`envelope list --conversations`). Paging works like `listEnvelopes`: pass the newest message id of the last
    /// conversation as `beforeID`; a conversation already shown above the cursor is not repeated.
    func listConversations(_ options: MailIndexListOptions) throws -> [MailEnvelope] {
        let wanted = max(options.limit, 0)
        guard wanted > 0, let plan = try listPlan(options) else { return [] }
        let cursor = try options.beforeID.map { (id: $0, date: try cursorDate($0)) }

        var newest: [Record] = []
        var seen = Set<Int64>()
        var shownBefore = Set<Int64>()
        var from = options.beforeID
        let batch = max(wanted * 3, 60)
        while newest.count < wanted {
            var page = options
            page.limit = batch
            page.beforeID = from
            let records = try listRecords(page)
            var fresh: [Record] = []
            for record in records {
                let key = record.conversationID == 0 ? -record.id : record.conversationID
                if seen.insert(key).inserted { fresh.append(record) }
            }
            // Conversations already listed on an earlier page are dropped here, before they count toward the page size, so a
            // run of messages from a shown conversation cannot use up the quota and leave the page empty.
            if let cursor {
                shownBefore.formUnion(try conversationsShown(among: fresh.map(\.conversationID), above: cursor, plan: plan))
            }
            newest += fresh.filter { !shownBefore.contains($0.conversationID) }
            guard records.count == batch, let last = records.last else { break }
            from = last.id
        }
        let candidates = newest.prefix(wanted)
        guard !candidates.isEmpty else { return [] }

        let conversations = candidates.map(\.conversationID).filter { $0 != 0 }
        var counts: [Int64: Int] = [:]
        var people: [Int64: [String]] = [:]
        if !conversations.isEmpty {
            let list = conversations.map(String.init).joined(separator: ",")
            try db.query(
                "SELECT conversation_id, COUNT(*) FROM messages WHERE conversation_id IN (\(list)) AND +deleted = 0 GROUP BY conversation_id"
            ) { counts[$0.int(0)] = Int($0.int(1)) }
            try db.query("""
                SELECT m.conversation_id, a.comment, a.address FROM messages m
                LEFT JOIN addresses a ON m.sender = a.ROWID
                WHERE m.conversation_id IN (\(list)) AND +m.deleted = 0
                ORDER BY m.date_received DESC, m.ROWID DESC
                """) { row in
                let name = Self.personName(name: row.text(1), address: row.text(2))
                let id = row.int(0)
                var known = people[id] ?? []
                if known.count < 3, !known.contains(name) {
                    known.append(name)
                    people[id] = known
                }
            }
        }
        return candidates.map { record in
            let id = record.conversationID
            let own = [Self.personName(name: record.fromName, address: record.fromAddr)]
            return Self.envelope(record, conversationCount: id == 0 ? 1 : (counts[id] ?? 1), participants: id == 0 ? own : (people[id] ?? own))
        }
    }

    /// Which of `ids` have a message of theirs in the view at or above the paging cursor (so an earlier page already showed them).
    private func conversationsShown(
        among ids: [Int64], above cursor: (id: Int64, date: Int64), plan: (mailboxes: [Int64]?, clauses: [String])
    ) throws -> Set<Int64> {
        var shown = Set<Int64>()
        let conversations = Set(ids.filter { $0 != 0 })
        guard !conversations.isEmpty else { return shown }
        let list = conversations.map(String.init).joined(separator: ",")
        let above = try orderedIDs(
            mailboxes: plan.mailboxes,
            clauses: plan.clauses + [
                "m.conversation_id IN (\(list))",
                "(m.date_received > ? OR (m.date_received = ? AND m.ROWID >= ?))",
            ],
            params: [.int(cursor.date), .int(cursor.date), .int(cursor.id)], order: "", newestFirstLimit: nil)
        if !above.isEmpty {
            let marks = Array(repeating: "?", count: above.count).joined(separator: ",")
            try db.query("SELECT DISTINCT conversation_id FROM messages WHERE ROWID IN (\(marks))",
                         above.map(MailSQLValue.int)) { shown.insert($0.int(0)) }
        }
        return shown
    }

    private static func personName(name: String?, address: String?) -> String {
        if let name, !name.isEmpty { return name }
        return address ?? "(unknown)"
    }

    /// One message by id, or nil when it is gone or deleted.
    func envelope(id: Int64) throws -> MailEnvelope? {
        try fetchRecords(mailboxes: nil, clauses: ["m.deleted = 0", "m.ROWID = ?"], params: [.int(id)], order: "").first
            .map { Self.envelope($0, conversationCount: nil, participants: nil) }
    }

    /// The conversation a message belongs to, oldest first (a message with no conversation id is its own thread).
    func thread(containing id: Int64) throws -> [MailEnvelope] {
        guard let message = try fetchRecords(mailboxes: nil, clauses: ["m.deleted = 0", "m.ROWID = ?"], params: [.int(id)], order: "").first
        else { throw MailIndexError.notFound("message \(id)") }
        guard message.conversationID != 0 else { return [Self.envelope(message, conversationCount: nil, participants: nil)] }
        return try fetchRecords(
            // `+` keeps SQLite on the selective conversation index.
            mailboxes: nil, clauses: ["+m.deleted = 0", "m.conversation_id = ?"], params: [.int(message.conversationID)],
            order: "ORDER BY m.date_received ASC, m.ROWID ASC"
        ).map { Self.envelope($0, conversationCount: nil, participants: nil) }
    }

    // MARK: Building records

    /// One message as the index holds it, before it becomes the widget's `MailEnvelope`.
    struct Record: Sendable {
        var id: Int64
        var messageID: String?
        var conversationID: Int64
        var mailbox: MailIndexMailbox?
        var subject: String
        var fromName: String?
        var fromAddr: String?
        var dateReceived: Int64
        var snippet: String?
        var isRead: Bool
        var isFlagged: Bool
        var hasAttachments: Bool
        var to: [MailPerson] = []
        var cc: [MailPerson] = []
        var accountName = ""
        var accountEmail: String?
    }

    static func envelope(_ record: Record, conversationCount: Int?, participants: [String]?) -> MailEnvelope {
        MailEnvelope(
            id: record.id, messageID: record.messageID, conversationID: record.conversationID == 0 ? nil : record.conversationID,
            account: accountRef(for: record), mailbox: MailMailboxRef(
                id: record.mailbox?.id ?? 0, name: record.mailbox?.name ?? "", role: record.mailbox?.role ?? "other"),
            from: MailPerson(name: record.fromName, addr: record.fromAddr), to: record.to, cc: record.cc, subject: record.subject,
            date: Date(timeIntervalSince1970: TimeInterval(record.dateReceived)), snippet: record.snippet, isRead: record.isRead,
            isFlagged: record.isFlagged, hasAttachments: record.hasAttachments, link: messageLink(record),
            conversationCount: conversationCount, participants: participants)
    }

    // `accountRef` needs the accounts map, which instance methods hold; a record carries the ref it was built with.
    private static func accountRef(for record: Record) -> MailAccountRef {
        MailAccountRef(id: record.mailbox?.accountID ?? "", name: record.accountName, email: record.accountEmail)
    }

    /// `mail42://message/<id>?mid=<Message-ID>`: finds the message again after Mail moves it.
    static func messageLink(_ record: Record) -> String {
        var text = "mail42://message/\(record.id)"
        if let mid = record.messageID.flatMap(stripBrackets) { text += "?mid=" + encode(mid) }
        return text
    }

    static func stripBrackets(_ header: String) -> String? {
        var value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<") { value.removeFirst() }
        if value.hasSuffix(">") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }

    func fetchRecords(
        mailboxes: [Int64]?, clauses: [String], params: [MailSQLValue], order: String, newestFirstLimit: Int? = nil
    ) throws -> [Record] {
        let ids = try orderedIDs(mailboxes: mailboxes, clauses: clauses, params: params, order: order, newestFirstLimit: newestFirstLimit)
        guard !ids.isEmpty else { return [] }

        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT m.ROWID, \(hasMessageIDHeader ? "g.message_id_header" : "NULL"), m.conversation_id,
                   m.mailbox, s.subject, a.comment, a.address, m.date_received,
                   \(hasDateSent ? "m.date_sent" : "NULL"),
                   \(hasSummary ? "sm.summary" : "NULL"), m.read, m.flagged, m.size
            FROM messages m
            LEFT JOIN subjects s ON m.subject = s.ROWID
            LEFT JOIN addresses a ON m.sender = a.ROWID
            \(hasSummary ? "LEFT JOIN summaries sm ON m.summary = sm.ROWID" : "")
            \(hasMessageIDHeader ? "LEFT JOIN message_global_data g ON m.global_message_id = g.ROWID" : "")
            WHERE m.ROWID IN (\(marks))
            """
        let shown = try shownMailboxes(for: ids, among: mailboxes)
        var byID: [Int64: Record] = [:]
        try db.query(sql, ids.map(MailSQLValue.int)) { row in
            let id = row.int(0)
            let mailbox = mailboxByID[shown[id] ?? row.int(3)]
            let account = accountRef(mailbox)
            let header = row.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines)
            byID[id] = Record(
                id: id, messageID: (header?.isEmpty == false) ? header : nil, conversationID: row.int(2), mailbox: mailbox,
                subject: row.text(4) ?? "", fromName: row.text(5), fromAddr: row.text(6), dateReceived: row.int(7),
                snippet: Self.snippet(row.text(9)), isRead: row.int(10) != 0, isFlagged: row.int(11) != 0, hasAttachments: false,
                accountName: account.name, accountEmail: account.email)
        }

        var records = ids.compactMap { byID[$0] }
        let recipients = try readRecipients(ids: ids)
        let withAttachments = try readAttachmentFlags(ids: ids)
        for index in records.indices {
            let id = records[index].id
            records[index].to = recipients[id]?.to ?? []
            records[index].cc = recipients[id]?.cc ?? []
            records[index].hasAttachments = withAttachments.contains(id)
        }
        return records
    }

    /// The ids, in `order`, of the messages matching `clauses` that belong to `mailboxes`.
    private func orderedIDs(
        mailboxes: [Int64]?, clauses: [String], params: [MailSQLValue], order: String, newestFirstLimit: Int?
    ) throws -> [Int64] {
        let whereSQL = clauses.joined(separator: " AND ")
        let sql: String
        let flaggedOnly = clauses.contains("m.flagged = 1")

        // Flagged mail is rare and Apple indexes it. Asking for it with an ORDER BY makes SQLite walk every message by date, so
        // fetch the few flagged rows unordered and sort them here.
        if flaggedOnly, let limit = newestFirstLimit {
            var member = ""
            if let mailboxes {
                let list = mailboxes.map(String.init).joined(separator: ",")
                member = hasLabels
                    ? " AND (m.mailbox IN (\(list)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(list))))"
                    : " AND m.mailbox IN (\(list))"
            }
            // Without statistics SQLite prefers the `deleted` index (every message) over the selective `flagged` one; the unary
            // plus makes `deleted = 0` a plain filter.
            let selective = clauses.map { $0 == "m.deleted = 0" ? "+m.deleted = 0" : $0 }.joined(separator: " AND ")
            var rows: [(id: Int64, date: Int64)] = []
            try db.query("SELECT m.ROWID, m.date_received FROM messages m WHERE \(selective)\(member)", params) {
                rows.append(($0.int(0), $0.int(1)))
            }
            rows.sort { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
            return rows.prefix(limit).map(\.id)
        }

        if let mailboxes {
            // Ids are integers from Apple's own table, so they are safe to write into the statement.
            let list = mailboxes.map(String.init).joined(separator: ",")
            let expected = mailboxes.reduce(Int64(0)) { $0 + (mailboxByID[$1]?.total ?? 0) }
            let labelled = hasLabels ? " UNION SELECT message_id FROM labels WHERE mailbox_id IN (\(list))" : ""
            if expected <= Self.smallMailbox {
                sql = """
                    SELECT m.ROWID FROM (SELECT ROWID AS mid FROM messages WHERE mailbox IN (\(list))\(labelled)) mb \
                    JOIN messages m ON m.ROWID = mb.mid WHERE \(whereSQL) \(order)
                    """
            } else {
                let member = hasLabels
                    ? "(m.mailbox IN (\(list)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(list))))"
                    : "m.mailbox IN (\(list))"
                sql = "SELECT m.ROWID FROM messages m WHERE \(whereSQL) AND \(member) \(order)"
            }
        } else {
            sql = "SELECT m.ROWID FROM messages m WHERE \(whereSQL) \(order)"
        }
        var ids: [Int64] = []
        try db.query(sql, params) { ids.append($0.int(0)) }
        return ids
    }

    /// For a Gmail message that lives in All Mail: which of the requested mailboxes it is shown under (its Inbox, not "All Mail").
    private func shownMailboxes(for ids: [Int64], among mailboxes: [Int64]?) throws -> [Int64: Int64] {
        guard let mailboxes, hasLabels else { return [:] }
        let list = mailboxes.map(String.init).joined(separator: ",")
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var stored: [Int64: Int64] = [:]
        try db.query("SELECT ROWID, mailbox FROM messages WHERE ROWID IN (\(marks)) AND mailbox IN (\(list))",
                     ids.map(MailSQLValue.int)) { stored[$0.int(0)] = $0.int(1) }
        var shown = stored
        try db.query(
            "SELECT message_id, mailbox_id FROM labels WHERE message_id IN (\(marks)) AND mailbox_id IN (\(list)) ORDER BY mailbox_id DESC",
            ids.map(MailSQLValue.int)
        ) { row in
            if stored[row.int(0)] == nil { shown[row.int(0)] = row.int(1) }
        }
        return shown
    }

    /// Apple's own summary, on one line and at most 200 characters.
    private static func snippet(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let line = summary.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(200))
    }

    /// Type 0 = To is confirmed against real mailboxes; 1 = Cc and 2 = Bcc follow the commonly documented values.
    private func readRecipients(ids: [Int64]) throws -> [Int64: (to: [MailPerson], cc: [MailPerson])] {
        var result: [Int64: (to: [MailPerson], cc: [MailPerson])] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.query(
                """
                SELECT r.message, r.type, a.address, a.comment, r.position FROM recipients r
                JOIN addresses a ON r.address = a.ROWID WHERE r.message IN (\(marks)) ORDER BY r.message, r.position
                """, chunk.map(MailSQLValue.int)
            ) { row in
                guard let address = row.text(2), !address.isEmpty else { return }
                let person = MailPerson(name: row.text(3), addr: address)
                var entry = result[row.int(0)] ?? ([], [])
                switch row.int(1) {
                case 0: entry.to.append(person)
                case 1: entry.cc.append(person)
                default: return
                }
                result[row.int(0)] = entry
            }
        }
        return result
    }

    private func readAttachmentFlags(ids: [Int64]) throws -> Set<Int64> {
        var result = Set<Int64>()
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.query("SELECT DISTINCT message FROM attachments WHERE message IN (\(marks)) AND name IS NOT NULL AND name != ''",
                         chunk.map(MailSQLValue.int)) { result.insert($0.int(0)) }
        }
        return result
    }
}
