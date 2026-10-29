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
        Self.mailboxIDs(matching: value, in: mailboxRows)
    }

    private static func mailboxIDs(matching value: String, in rows: [MailboxRow]) -> [Int64] {
        let wanted = value.lowercased()
        let numeric = Int64(value)
        return rows.filter { mailbox in
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

    /// The mailboxes and filters a list of `options` selects (without the paging cursor); nil when nothing can match.
    private func listPlan(_ options: EnvelopeListOptions) throws -> (mailboxes: [Int64]?, clauses: [String])? {
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
            guard !ids.isEmpty else { throw Mail42Error.notFound("a mailbox matching `\(name)`") }
            mailboxes = ids
        }
        if options.unreadOnly { clauses.append("m.read = 0") }
        if options.flaggedOnly { clauses.append("m.flagged = 1") }
        return (mailboxes, clauses)
    }

    /// The date of the message a `--before` cursor names.
    private func cursorDate(_ before: Int64) throws -> Int64 {
        guard let date = try snapshot.connection.scalarInt(
            "SELECT date_received FROM messages WHERE ROWID = ?", [.int(before)]
        ) else { throw Mail42Error.notFound("message \(before) (the `--before` cursor)") }
        return date
    }

    public func listEnvelopes(_ options: EnvelopeListOptions) throws -> [EnvelopeRecord] {
        guard var plan = try listPlan(options) else { return [] }
        var params: [SQLiteValue] = []
        if let before = options.beforeID {
            let date = try cursorDate(before)
            // `<= date` first, so the date index can bound the scan; the second test only trims the ties.
            plan.clauses.append("m.date_received <= ? AND (m.date_received < ? OR m.ROWID < ?)")
            params += [.int(date), .int(date), .int(before)]
        }
        return try fetchRecords(
            mailboxes: plan.mailboxes, clauses: plan.clauses, params: params,
            order: "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(max(options.limit, 0))",
            newestFirstLimit: max(options.limit, 0))
    }

    // MARK: - Conversations

    /// One entry per conversation that has a message in the selected view, newest first: that message, the size of
    /// the whole conversation and who wrote in it. Paging works like `listEnvelopes`: pass the newest message id of
    /// the last conversation as `beforeID`. A conversation already shown on an earlier page (it has a message in the
    /// view newer than the cursor) is not repeated.
    public func listConversations(_ options: EnvelopeListOptions) throws -> [ConversationRecord] {
        let wanted = max(options.limit, 0)
        guard wanted > 0, let plan = try listPlan(options) else { return [] }
        let cursor = try options.beforeID.map { (id: $0, date: try cursorDate($0)) }

        var newest: [EnvelopeRecord] = []
        var seen = Set<Int64>()
        var from = options.beforeID
        let batch = max(wanted * 3, 60)
        while newest.count < wanted {
            var page = options
            page.limit = batch
            page.beforeID = from
            let records = try listEnvelopes(page)
            for record in records {
                let key = record.row.conversationID == 0 ? -record.row.id : record.row.conversationID
                if seen.insert(key).inserted { newest.append(record) }
            }
            guard records.count == batch, let last = records.last else { break }
            from = last.row.id
        }

        // Conversations already listed on an earlier page: a message of theirs in the view lies above the cursor.
        var shownBefore = Set<Int64>()
        if let cursor {
            let conversations = Set(newest.map(\.row.conversationID).filter { $0 != 0 })
            if !conversations.isEmpty {
                let list = conversations.map(String.init).joined(separator: ",")
                let above = try orderedIDs(
                    mailboxes: plan.mailboxes,
                    clauses: plan.clauses + [
                        "m.conversation_id IN (\(list))",
                        "(m.date_received > ? OR (m.date_received = ? AND m.ROWID >= ?))",
                    ],
                    params: [.int(cursor.date), .int(cursor.date), .int(cursor.id)],
                    order: "", newestFirstLimit: nil, joins: "")
                if !above.isEmpty {
                    let marks = Array(repeating: "?", count: above.count).joined(separator: ",")
                    try snapshot.connection.query(
                        "SELECT DISTINCT conversation_id FROM messages WHERE ROWID IN (\(marks))",
                        above.map(SQLiteValue.int)
                    ) { shownBefore.insert($0.int(0)) }
                }
            }
        }
        let candidates = newest.filter { !shownBefore.contains($0.row.conversationID) }.prefix(wanted)
        guard !candidates.isEmpty else { return [] }

        let conversations = candidates.map(\.row.conversationID).filter { $0 != 0 }
        var counts: [Int64: Int] = [:]
        var people: [Int64: [String]] = [:]
        if !conversations.isEmpty {
            let list = conversations.map(String.init).joined(separator: ",")
            try snapshot.connection.query(
                "SELECT conversation_id, COUNT(*) FROM messages WHERE conversation_id IN (\(list)) AND +deleted = 0 GROUP BY conversation_id"
            ) { counts[$0.int(0)] = Int($0.int(1)) }
            try snapshot.connection.query("""
                SELECT m.conversation_id, a.comment, a.address FROM messages m
                LEFT JOIN addresses a ON m.sender = a.ROWID
                WHERE m.conversation_id IN (\(list)) AND +m.deleted = 0
                ORDER BY m.date_received DESC, m.ROWID DESC
                """
            ) { row in
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
            let id = record.row.conversationID
            if id == 0 {
                return ConversationRecord(
                    newest: record, count: 1,
                    participants: [Self.personName(name: record.row.fromName, address: record.row.fromAddr)])
            }
            return ConversationRecord(
                newest: record, count: counts[id] ?? 1,
                participants: people[id] ?? [Self.personName(name: record.row.fromName, address: record.row.fromAddr)])
        }
    }

    private static func personName(name: String?, address: String?) -> String {
        if let name, !name.isEmpty { return name }
        return address ?? "(unknown)"
    }

    // MARK: - Links

    /// The message a link points at: the row id when it still holds that message, else the message with the same
    /// Message-ID (a copy under `preferMailbox` first, else the newest that isn't deleted).
    public func resolve(_ link: MessageLink, preferMailbox: Int64? = nil) throws -> EnvelopeRecord {
        if let record = try envelopeRecord(id: link.rowid) {
            guard let mid = link.messageID else { return record }
            if record.row.messageID.flatMap(MessageLink.stripBrackets) == mid { return record }
        }
        guard let mid = link.messageID, capabilities.hasMessageIDHeader else {
            throw Mail42Error.notFound("message \(link.rowid)")
        }
        var ids: [Int64] = []
        try snapshot.connection.query("""
            SELECT m.ROWID FROM message_global_data g JOIN messages m ON m.global_message_id = g.ROWID
            WHERE g.message_id_header IN (?, ?) AND m.deleted = 0 ORDER BY m.date_received DESC, m.ROWID DESC
            """, [.text(mid), .text("<\(mid)>")]
        ) { ids.append($0.int(0)) }
        guard !ids.isEmpty else { throw Mail42Error.notFound("message \(link.rowid) (Message-ID \(mid))") }

        var chosen = ids[0]
        if let preferMailbox, ids.count > 1 {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var inMailbox = Set<Int64>()
            try snapshot.connection.query(
                "SELECT ROWID FROM messages WHERE ROWID IN (\(marks)) AND mailbox = ?",
                ids.map(SQLiteValue.int) + [.int(preferMailbox)]
            ) { inMailbox.insert($0.int(0)) }
            if hasLabels {
                try snapshot.connection.query(
                    "SELECT message_id FROM labels WHERE message_id IN (\(marks)) AND mailbox_id = ?",
                    ids.map(SQLiteValue.int) + [.int(preferMailbox)]
                ) { inMailbox.insert($0.int(0)) }
            }
            if let first = ids.first(where: inMailbox.contains) { chosen = first }
        }
        guard let record = try envelopeRecord(id: chosen) else { throw Mail42Error.notFound("message \(chosen)") }
        return record
    }

    /// A search's results, and a note when it could not cover every message.
    public struct SearchOutcome: Sendable {
        public var records: [EnvelopeRecord]
        /// Set when the text of some messages was not read ("searched the newest 3,000…"); say so, never hide it.
        public var note: String?
    }

    private static let searchJoins = "LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender"

    /// Messages matching a search query (`from:alice is:unread date:2w.. invoice`), newest first.
    ///
    /// Everything but message text is answered from Apple's index. Words and `body:` need the text, which Apple's
    /// index doesn't hold: those read the newest messages that match the rest of the query (within `scan`'s limits)
    /// and the outcome's `note` says so when that wasn't all of them.
    public func search(_ query: String, limit: Int, scan: ScanLimits = .standard) throws -> SearchOutcome {
        let rows = mailboxRows
        func compiler(_ matches: [String: Set<Int64>]?) -> QueryCompiler {
            QueryCompiler(mailboxIDs: { Self.mailboxIDs(matching: $0, in: rows) }, textMatches: matches)
        }
        let order = "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(max(limit, 0))"

        let relaxed = try compiler(nil).compile(query)
        guard !relaxed.textTerms.isEmpty else {
            let records = try fetchRecords(
                mailboxes: nil, clauses: ["m.deleted = 0", relaxed.whereSQL], params: relaxed.params,
                order: order, joins: Self.searchJoins)
            return SearchOutcome(records: records, note: nil)
        }

        // 1. The newest messages that pass everything that doesn't need their text.
        let found = try orderedIDs(
            mailboxes: nil, clauses: ["m.deleted = 0", relaxed.whereSQL], params: relaxed.params,
            order: "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(scan.maxMessages + 1)",
            newestFirstLimit: nil, joins: Self.searchJoins)
        let moreExist = found.count > scan.maxMessages
        let candidates = Array(found.prefix(scan.maxMessages))

        // 2. Read them newest first, a chunk at a time, and after each chunk ask the real question over everything read
        //    so far. Whether a message qualifies depends only on that message, so once there are `limit` results the
        //    older, unread candidates cannot displace them: stop there instead of reading the rest.
        func results(_ matches: [String: Set<Int64>], _ scanned: Set<Int64>) throws -> [EnvelopeRecord] {
            guard !scanned.isEmpty else { return [] }
            let final = try compiler(matches).compile(query)
            let read = scanned.map(String.init).joined(separator: ",")
            return try fetchRecords(
                mailboxes: nil, clauses: ["m.deleted = 0", "m.ROWID IN (\(read))", final.whereSQL], params: final.params,
                order: order, joins: Self.searchJoins)
        }

        let deadline = Date().addingTimeInterval(scan.timeLimit)
        var matches: [String: Set<Int64>] = [:]
        var scanned = Set<Int64>()
        var records: [EnvelopeRecord] = []
        var satisfied = false, outOfTime = false
        var start = 0
        while start < candidates.count, limit > 0 {
            let chunk = Array(candidates[start..<min(start + Self.scanChunk, candidates.count)])
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { outOfTime = true; break }
            let read = BodyScanner.scan(
                terms: relaxed.textTerms, candidates: try emlxFiles(for: chunk),
                limits: ScanLimits(maxMessages: chunk.count, timeLimit: remaining))
            scanned.formUnion(read.scanned)
            for (term, ids) in read.matches { matches[term, default: []].formUnion(ids) }
            start += chunk.count
            if read.scanned.count < chunk.count { outOfTime = true; break }
            records = try results(matches, scanned)
            if records.count >= limit { satisfied = true; break }
        }
        if !satisfied { records = try results(matches, scanned) }

        // 3. Say so when the answer might be missing older messages.
        var note: String?
        if satisfied {
            note = nil
        } else if outOfTime {
            note = "Stopped after \(Int(scan.timeLimit)) s: read the text of the newest \(scanned.count.formatted()) "
                + "of \(candidates.count.formatted()) messages that match the rest of your query. "
                + "Add from:, in: or date: to narrow it."
        } else if moreExist {
            note = "Read the text of the newest \(candidates.count.formatted()) messages that match the rest of your "
                + "query; older ones weren't searched. Add from:, in: or date: to reach further back."
        }
        return SearchOutcome(records: records, note: note)
    }

    /// How many messages a text search reads before checking whether it already has enough results.
    private static let scanChunk = 500

    /// Where Mail keeps each message's file (nil when it has none), in the order of `ids`.
    private func emlxFiles(for ids: [Int64]) throws -> [(id: Int64, file: URL?)] {
        var mailboxOf: [Int64: Int64] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try snapshot.connection.query(
                "SELECT ROWID, mailbox FROM messages WHERE ROWID IN (\(marks))", chunk.map(SQLiteValue.int)
            ) { mailboxOf[$0.int(0)] = $0.int(1) }
        }
        return ids.map { id in
            (id, mailboxOf[id].flatMap { mailboxByID[$0] }.flatMap {
                EmlxLocator.emlxURL(rowid: id, mailboxURL: $0.url, mailRoot: mailRoot)
            })
        }
    }

    /// A message's attachments: from its file when Mail has it (names, types and sizes), else the names in Apple's
    /// index (no type or size).
    public func attachments(of record: EnvelopeRecord) throws -> [AttachmentRow] {
        if let file = emlxURL(for: record), let parsed = try? MessageParser.parse(emlx: file) {
            return parsed.attachments.map {
                AttachmentRow(part: $0.part, filename: $0.filename ?? "", mime: $0.mime, size: Int64($0.size))
            }
        }
        var rows: [AttachmentRow] = []
        try snapshot.connection.query(
            "SELECT attachment_id, name FROM attachments WHERE message = ? AND name IS NOT NULL AND name != '' ORDER BY attachment_id",
            [.int(record.row.id)]
        ) { rows.append(AttachmentRow(part: $0.text(0) ?? "", filename: $0.text(1) ?? "", mime: "", size: 0)) }
        return rows
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
        // A record carries the mailbox it is listed under (a Gmail Inbox label), but the file is in the mailbox the
        // message is stored in (All Mail), so ask the index where that is.
        let stored = ((try? snapshot.connection.scalarInt(
            "SELECT mailbox FROM messages WHERE ROWID = ?", [.int(record.row.id)])) ?? nil) ?? record.row.mailboxID
        guard let mailbox = mailboxByID[stored] else { return nil }
        return EmlxLocator.emlxURL(rowid: record.row.id, mailboxURL: mailbox.url, mailRoot: mailRoot)
    }

    // MARK: - Building records

    /// - Parameter mailboxes: restrict to messages stored in or labelled with these mailboxes; nil = any message.
    /// - Parameter newestFirstLimit: set by `listEnvelopes`; it lets a flagged-only list sort its few rows itself.
    private func fetchRecords(
        mailboxes: [Int64]?, clauses: [String], params: [SQLiteValue], order: String, newestFirstLimit: Int? = nil,
        joins: String = ""
    ) throws -> [EnvelopeRecord] {
        // Step 1: just the ids, in order.
        let ids = try orderedIDs(
            mailboxes: mailboxes, clauses: clauses, params: params, order: order, newestFirstLimit: newestFirstLimit,
            joins: joins)
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
        mailboxes: [Int64]?, clauses: [String], params: [SQLiteValue], order: String, newestFirstLimit: Int?,
        joins: String
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
            sql = "SELECT m.ROWID FROM messages m \(joins) WHERE \(whereSQL) \(order)"
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
