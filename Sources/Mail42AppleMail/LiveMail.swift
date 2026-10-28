// LiveMail.swift — reads the user's mail straight from Apple Mail's own index, with no copy of it.
//
// mail42 used to copy every message's headers and text into its own database (a multi-minute first sync and a second
// copy of the user's mail on disk). Everything the list needs is already in Apple Mail's Envelope Index, so this
// reads it directly: `LiveMail.open()` takes a private snapshot of the index (an APFS clone, so it costs next to
// nothing; Apple's files are never opened for writing) and answers questions about it.
//
// Things that are specific to how Apple stores mail, and that this layer owns:
//   · A Gmail account keeps every message in [Gmail]/All Mail; Inbox, Important and every other label are rows in the
//     `labels` table (message → mailbox). A message is "in" a mailbox when it is stored there OR labelled with it.
//     Counted that way the numbers match Apple's own counters exactly (verified on a real Gmail account).
//   · Accounts are UUIDs in the index; their names and addresses come from the system Accounts database
//     (`AccountDirectory`).
//   · `total_count` / `unread_count` on `mailboxes` are Apple's own counters for the whole mailbox.
//
// Speed: a mailbox can hold 160,000 messages, so a list is answered in two steps. First only the newest N ids are
// found (walking Apple's `(deleted, date_received)` index, or, for a small mailbox, sorting its few members); then
// the details are fetched for just those N. Joining every row's subject and sender before sorting was ~20× slower.

import Foundation
import Mail42Kit

public final class LiveMail {

    public let mailRoot: URL
    private let snapshot: EnvelopeIndexSnapshot
    private let capabilities: EnvelopeIndexSnapshot.Capabilities
    private let hasLabels: Bool
    private let accountInfo: [String: AccountDirectory.Info]
    private let mailboxRows: [MailboxRow]
    private let mailboxByID: [Int64: MailboxRow]

    /// Mailboxes with at most this many messages are listed by sorting their members; bigger ones by walking the
    /// date index and testing membership (which stops as soon as the page is full).
    private static let smallMailbox: Int64 = 20_000

    // MARK: - Opening

    /// - Throws: `.fdaDenied` when macOS refuses the read, `.noMailData` when there's no Apple Mail store,
    ///   `.schemaUnsupported` when Apple's private schema isn't what mail42 expects.
    public static func open(
        library: URL = Mail42Paths.appleMailLibrary,
        accountsDatabase: URL = Mail42Paths.accountsDatabase
    ) throws -> LiveMail {
        switch AppleMailAccess.fullDiskAccess(library: library) {
        case .granted: break
        case .denied: throw Mail42Error.fdaDenied
        case .noMailData: throw Mail42Error.noMailData
        }
        guard let mailRoot = Mail42Paths.appleMailRoot(in: library) else { throw Mail42Error.noMailData }
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: mailRoot)
        do {
            try snapshot.validateSchema()
            return try LiveMail(
                snapshot: snapshot, mailRoot: mailRoot,
                accountInfo: AccountDirectory.load(database: accountsDatabase))
        } catch {
            snapshot.close()
            throw error
        }
    }

    private init(snapshot: EnvelopeIndexSnapshot, mailRoot: URL, accountInfo: [String: AccountDirectory.Info]) throws {
        self.snapshot = snapshot
        self.mailRoot = mailRoot
        self.accountInfo = accountInfo
        self.capabilities = try snapshot.capabilities()
        let labelColumns = try snapshot.connection.columns(of: "labels")
        self.hasLabels = labelColumns.contains("message_id") && labelColumns.contains("mailbox_id")

        var rows: [MailboxRow] = []
        try snapshot.connection.query("SELECT ROWID, url, total_count, unread_count FROM mailboxes") { row in
            guard let url = row.text(1), let parsed = MailboxURL.decode(url) else { return }
            let name = parsed.pathComponents.joined(separator: "/")
            rows.append(MailboxRow(
                id: row.int(0), accountID: parsed.accountUUID, name: name, role: MailboxRole.classify(name: name),
                url: url, total: row.int(2), unread: row.int(3)))
        }
        self.mailboxRows = rows
        self.mailboxByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    deinit { snapshot.close() }

    /// Releases the snapshot early (it is also released when this object goes away).
    public func close() { snapshot.close() }

    // MARK: - Accounts and mailboxes

    /// Every account that owns a mailbox, named as Mail names it. The UUID is only used when nothing else is known.
    public func accounts() -> [AccountRow] {
        var seen: [String: AccountRow] = [:]
        for mailbox in mailboxRows where seen[mailbox.accountID] == nil {
            seen[mailbox.accountID] = accountRow(for: mailbox)
        }
        return seen.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Every mailbox with Apple's own total and unread counters.
    public func mailboxes() -> [MailboxRow] { mailboxRows }

    /// Every account with its mailboxes: the Inbox first, then the rest alphabetically.
    public func accountsWithMailboxes() -> [(account: AccountRow, mailboxes: [MailboxRow])] {
        accounts().map { account in
            (account, mailboxRows.filter { $0.accountID == account.id }.sorted { lhs, rhs in
                if (lhs.role == "inbox") != (rhs.role == "inbox") { return lhs.role == "inbox" }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            })
        }
    }

    /// Ids of the mailboxes a name, id or role refers to (`INBOX`, `Jarvis/VIP`, `VIP`, `inbox`, `12`).
    public func mailboxIDs(matching value: String) -> [Int64] {
        let wanted = value.lowercased()
        let numeric = Int64(value)
        return mailboxRows.filter { mailbox in
            let name = mailbox.name.lowercased()
            return mailbox.id == numeric || name == wanted || name.hasSuffix("/" + wanted) || mailbox.role == wanted
        }.map(\.id)
    }

    private func accountRow(for mailbox: MailboxRow) -> AccountRow {
        let info = accountInfo[mailbox.accountID.uppercased()]
        let scheme = mailbox.url.components(separatedBy: "://").first ?? "imap"
        return AccountRow(
            id: mailbox.accountID, name: info?.name ?? info?.email ?? mailbox.accountID, email: info?.email, kind: scheme)
    }

    // MARK: - Messages

    public func listEnvelopes(_ options: EnvelopeListOptions) throws -> [EnvelopeRecord] {
        var clauses = ["m.deleted = 0"]
        var params: [SQLiteValue] = []
        let mailboxes: [Int64]?

        switch options.mailbox {
        case .allInboxes:
            let ids = mailboxRows.filter { $0.role == "inbox" }.map(\.id)
            guard !ids.isEmpty else { return [] }
            mailboxes = ids
        case .flagged:
            mailboxes = nil
            clauses.append("m.flagged = 1")
        case .id(let id):
            mailboxes = [id]
        case .named(let name):
            let ids = mailboxIDs(matching: name)
            guard !ids.isEmpty else { throw Mail42Error.notFound("a mailbox matching `\(name)`") }
            mailboxes = ids
        }
        if options.unreadOnly { clauses.append("m.read = 0") }
        if options.flaggedOnly { clauses.append("m.flagged = 1") }

        if let before = options.beforeID {
            guard let date = try snapshot.connection.scalarInt(
                "SELECT date_received FROM messages WHERE ROWID = ?", [.int(before)]
            ) else { throw Mail42Error.notFound("message \(before) (the `--before` cursor)") }
            // `<= date` first, so the date index can bound the scan; the second test only trims the ties.
            clauses.append("m.date_received <= ? AND (m.date_received < ? OR m.ROWID < ?)")
            params += [.int(date), .int(date), .int(before)]
        }

        return try fetchRecords(
            mailboxes: mailboxes, clauses: clauses, params: params,
            order: "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(max(options.limit, 0))",
            newestFirstLimit: max(options.limit, 0))
    }

    public func envelopeRecord(id: Int64) throws -> EnvelopeRecord? {
        try fetchRecords(mailboxes: nil, clauses: ["m.deleted = 0", "m.ROWID = ?"], params: [.int(id)], order: "").first
    }

    /// The conversation a message belongs to, oldest first. A message with no conversation id is its own thread.
    public func thread(containing id: Int64) throws -> [EnvelopeRecord] {
        guard let message = try envelopeRecord(id: id) else { throw Mail42Error.notFound("message \(id)") }
        let conversation = message.row.conversationID
        guard conversation != 0 else { return [message] }
        return try fetchRecords(
            // `+` keeps SQLite on the selective conversation index (see `orderedIDs`).
            mailboxes: nil, clauses: ["+m.deleted = 0", "m.conversation_id = ?"], params: [.int(conversation)],
            order: "ORDER BY m.date_received ASC, m.ROWID ASC")
    }

    /// The path of a message's .emlx, if Mail has its file on disk.
    public func emlxURL(for record: EnvelopeRecord) -> URL? {
        guard let mailbox = mailboxByID[record.row.mailboxID] else { return nil }
        return EmlxLocator.emlxURL(rowid: record.row.id, mailboxURL: mailbox.url, mailRoot: mailRoot)
    }

    // MARK: - Building records

    /// - Parameter mailboxes: restrict to messages stored in or labelled with these mailboxes; nil = any message.
    /// - Parameter newestFirstLimit: set by `listEnvelopes`; it lets a flagged-only list sort its few rows itself.
    private func fetchRecords(
        mailboxes: [Int64]?, clauses: [String], params: [SQLiteValue], order: String, newestFirstLimit: Int? = nil
    ) throws -> [EnvelopeRecord] {
        // Step 1: just the ids, in order.
        let ids = try orderedIDs(
            mailboxes: mailboxes, clauses: clauses, params: params, order: order, newestFirstLimit: newestFirstLimit)
        guard !ids.isEmpty else { return [] }

        // Step 2: the details of those ids only.
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT m.ROWID, \(capabilities.hasMessageIDHeader ? "g.message_id_header" : "NULL"), m.conversation_id,
                   m.mailbox, s.subject, a.comment, a.address, m.date_received,
                   \(capabilities.hasDateSent ? "m.date_sent" : "NULL"),
                   \(capabilities.hasSummary ? "sm.summary" : "NULL"), m.read, m.flagged, m.size
            FROM messages m
            LEFT JOIN subjects s ON m.subject = s.ROWID
            LEFT JOIN addresses a ON m.sender = a.ROWID
            \(capabilities.hasSummary ? "LEFT JOIN summaries sm ON m.summary = sm.ROWID" : "")
            \(capabilities.hasMessageIDHeader ? "LEFT JOIN message_global_data g ON m.global_message_id = g.ROWID" : "")
            WHERE m.ROWID IN (\(marks))
            """
        let shown = try shownMailboxes(for: ids, among: mailboxes)
        var byID: [Int64: EnvelopeRecord] = [:]
        try snapshot.connection.query(sql, ids.map(SQLiteValue.int)) { row in
            let id = row.int(0)
            let mailboxID = shown[id] ?? row.int(3)
            let mailbox = mailboxByID[mailboxID]
            let account = mailbox.map(accountRow(for:))
            let header = row.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines)
            byID[id] = EnvelopeRecord(
                row: EnvelopeRow(
                    id: id, messageID: (header?.isEmpty == false) ? header : nil, conversationID: row.int(2),
                    mailboxID: mailboxID, subject: row.text(4) ?? "", fromName: row.text(5), fromAddr: row.text(6),
                    dateReceived: row.int(7), dateSent: row.isNull(8) ? row.int(7) : row.int(8),
                    snippet: Self.snippet(row.text(9)), isRead: row.int(10) != 0, isFlagged: row.int(11) != 0,
                    hasAttachments: false, size: row.int(12), emlxPath: nil),
                accountID: mailbox?.accountID ?? "", accountName: account?.name ?? "", accountEmail: account?.email,
                mailboxName: mailbox?.name ?? "", mailboxRole: mailbox?.role ?? "other", to: [], cc: [])
        }

        var records = ids.compactMap { byID[$0] }
        let recipients = try readRecipients(ids: ids)
        let withAttachments = try readAttachmentFlags(ids: ids)
        for index in records.indices {
            let id = records[index].row.id
            records[index].to = recipients[id]?.filter { $0.kind == "to" } ?? []
            records[index].cc = recipients[id]?.filter { $0.kind == "cc" } ?? []
            records[index].row.hasAttachments = withAttachments.contains(id)
        }
        return records
    }

    /// The ids, in `order`, of the messages matching `clauses` that belong to `mailboxes`.
    private func orderedIDs(
        mailboxes: [Int64]?, clauses: [String], params: [SQLiteValue], order: String, newestFirstLimit: Int?
    ) throws -> [Int64] {
        let whereSQL = clauses.joined(separator: " AND ")
        let sql: String
        let flaggedOnly = clauses.contains("m.flagged = 1")

        // Flagged mail is rare, and Apple indexes it. Asking for it with an ORDER BY makes SQLite walk every message
        // by date instead (~0.6 s on 170,000 messages), so fetch the few flagged rows unordered and sort them here.
        if flaggedOnly, let limit = newestFirstLimit {
            var member = ""
            if let mailboxes {
                let list = mailboxes.map(String.init).joined(separator: ",")
                member = hasLabels
                    ? " AND (m.mailbox IN (\(list)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(list))))"
                    : " AND m.mailbox IN (\(list))"
            }
            // Apple's index has no statistics, so without the `+` SQLite prefers the `deleted` index (every message)
            // over the selective `flagged` one; the unary plus makes `deleted = 0` a plain filter.
            let selective = clauses.map { $0 == "m.deleted = 0" ? "+m.deleted = 0" : $0 }.joined(separator: " AND ")
            var rows: [(id: Int64, date: Int64)] = []
            try snapshot.connection.query(
                "SELECT m.ROWID, m.date_received FROM messages m WHERE \(selective)\(member)", params
            ) { rows.append(($0.int(0), $0.int(1))) }
            rows.sort { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
            return rows.prefix(limit).map(\.id)
        }

        if let mailboxes {
            // Ids are integers from Apple's own table, so they are safe to write into the statement.
            let list = mailboxes.map(String.init).joined(separator: ",")
            let expected = mailboxes.reduce(Int64(0)) { $0 + (mailboxByID[$1]?.total ?? 0) }
            let labelled = hasLabels ? " UNION SELECT message_id FROM labels WHERE mailbox_id IN (\(list))" : ""
            if expected <= Self.smallMailbox {
                // Few members: collect them, then sort.
                sql = """
                    SELECT m.ROWID FROM (SELECT ROWID AS mid FROM messages WHERE mailbox IN (\(list))\(labelled)) mb \
                    JOIN messages m ON m.ROWID = mb.mid WHERE \(whereSQL) \(order)
                    """
            } else {
                // Many members: walk the messages newest first and keep those that belong; stops at the limit.
                let member = hasLabels
                    ? "(m.mailbox IN (\(list)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(list))))"
                    : "m.mailbox IN (\(list))"
                sql = "SELECT m.ROWID FROM messages m WHERE \(whereSQL) AND \(member) \(order)"
            }
        } else {
            sql = "SELECT m.ROWID FROM messages m WHERE \(whereSQL) \(order)"
        }
        var ids: [Int64] = []
        try snapshot.connection.query(sql, params) { ids.append($0.int(0)) }
        return ids
    }

    /// For a Gmail message that lives in All Mail: which of the requested mailboxes it is shown under (its Inbox,
    /// not "All Mail"). Messages stored directly in one of them keep that mailbox.
    private func shownMailboxes(for ids: [Int64], among mailboxes: [Int64]?) throws -> [Int64: Int64] {
        guard let mailboxes, hasLabels else { return [:] }
        let list = mailboxes.map(String.init).joined(separator: ",")
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var stored: [Int64: Int64] = [:]
        try snapshot.connection.query(
            "SELECT ROWID, mailbox FROM messages WHERE ROWID IN (\(marks)) AND mailbox IN (\(list))",
            ids.map(SQLiteValue.int)
        ) { stored[$0.int(0)] = $0.int(1) }
        var shown = stored
        try snapshot.connection.query(
            "SELECT message_id, mailbox_id FROM labels WHERE message_id IN (\(marks)) AND mailbox_id IN (\(list)) ORDER BY mailbox_id DESC",
            ids.map(SQLiteValue.int)
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
    private func readRecipients(ids: [Int64]) throws -> [Int64: [RecipientRow]] {
        var result: [Int64: [RecipientRow]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try snapshot.connection.query(
                """
                SELECT r.message, r.type, a.address, a.comment, r.position FROM recipients r
                JOIN addresses a ON r.address = a.ROWID WHERE r.message IN (\(marks)) ORDER BY r.message, r.position
                """, chunk.map(SQLiteValue.int)
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
        }
        return result
    }

    private func readAttachmentFlags(ids: [Int64]) throws -> Set<Int64> {
        var result = Set<Int64>()
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try snapshot.connection.query(
                "SELECT DISTINCT message FROM attachments WHERE message IN (\(marks)) AND name IS NOT NULL AND name != ''",
                chunk.map(SQLiteValue.int)
            ) { result.insert($0.int(0)) }
        }
        return result
    }
}
