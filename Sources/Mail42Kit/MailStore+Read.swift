// MailStore+Read.swift — the read queries behind `mail42 envelope list / search`, `message thread` and
// `mailbox list`: envelopes joined with their mailbox and account, plus their To / Cc recipients.

import Foundation

/// One message as the read verbs present it: the envelope, where it lives, and who it was sent to.
public struct EnvelopeRecord: Equatable, Sendable {
    public var row: EnvelopeRow
    public var accountID: String
    public var accountName: String
    public var accountEmail: String?
    public var mailboxName: String
    public var mailboxRole: String
    public var to: [RecipientRow]
    public var cc: [RecipientRow]
}

/// Which mailbox(es) `envelope list` reads.
public enum MailboxSelector: Equatable, Sendable {
    /// Every mailbox with the `inbox` role (all accounts).
    case allInboxes
    /// Flagged messages in any mailbox.
    case flagged
    case id(Int64)
    /// A mailbox name or role, resolved like the `in:` search term.
    case named(String)
}

public struct EnvelopeListOptions: Sendable {
    public var mailbox: MailboxSelector
    public var unreadOnly: Bool
    public var flaggedOnly: Bool
    /// Return only messages older than this one (keyset pagination: pass the last id of the previous page).
    public var beforeID: Int64?
    public var limit: Int

    public init(
        mailbox: MailboxSelector = .allInboxes, unreadOnly: Bool = false, flaggedOnly: Bool = false,
        beforeID: Int64? = nil, limit: Int = 50
    ) {
        self.mailbox = mailbox
        self.unreadOnly = unreadOnly
        self.flaggedOnly = flaggedOnly
        self.beforeID = beforeID
        self.limit = limit
    }
}

extension MailStore {

    private static let recordColumns = """
        e.id, e.message_id, e.conversation_id, e.mailbox_id, e.subject, e.from_name, e.from_addr, \
        e.date_received, e.date_sent, e.snippet, e.is_read, e.is_flagged, e.has_attachments, e.size, e.emlx_path, \
        m.name, m.role, a.id, a.name, a.email
        """

    private static let recordFrom = """
        FROM envelopes e \
        LEFT JOIN mailboxes m ON e.mailbox_id = m.id \
        LEFT JOIN accounts a ON m.account_id = a.id
        """

    // MARK: - Queries

    /// Newest first. Throws `.notFound` when `beforeID` isn't an indexed message or a named mailbox matches
    /// nothing.
    public func listEnvelopes(_ options: EnvelopeListOptions) throws -> [EnvelopeRecord] {
        var clauses: [String] = []
        var params: [SQLiteValue] = []

        switch options.mailbox {
        case .allInboxes:
            clauses.append("e.mailbox_id IN (SELECT id FROM mailboxes WHERE role = 'inbox')")
        case .flagged:
            clauses.append("e.is_flagged = 1")
        case .id(let id):
            clauses.append("e.mailbox_id = ?")
            params.append(.int(id))
        case .named(let name):
            guard !(try mailboxIDs(matching: name)).isEmpty else {
                throw Mail42Error.notFound("a mailbox matching `\(name)`")
            }
            let clause = QueryCompiler.mailboxClause(matching: name)
            clauses.append(clause.sql)
            params += clause.params
        }
        if options.unreadOnly { clauses.append("e.is_read = 0") }
        if options.flaggedOnly { clauses.append("e.is_flagged = 1") }

        if let before = options.beforeID {
            guard let date = try db.scalarInt("SELECT date_received FROM envelopes WHERE id = ?", [.int(before)]) else {
                throw Mail42Error.notFound("message \(before) (the `--before` cursor)")
            }
            clauses.append("(e.date_received < ? OR (e.date_received = ? AND e.id < ?))")
            params += [.int(date), .int(date), .int(before)]
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try fetchRecords(
            "SELECT \(Self.recordColumns) \(Self.recordFrom) \(whereSQL) "
                + "ORDER BY e.date_received DESC, e.id DESC LIMIT ?",
            params + [.int(Int64(max(options.limit, 0)))])
    }

    /// Messages matching a compiled search query. Ranked by BM25 when the query has full-text terms, otherwise
    /// newest first; ties go to the newer message.
    public func searchEnvelopes(_ query: CompiledQuery, limit: Int) throws -> [EnvelopeRecord] {
        var params: [SQLiteValue] = []
        var rankJoin = ""
        var order = "ORDER BY e.date_received DESC, e.id DESC"
        if let rank = query.rankExpression {
            rankJoin = " LEFT JOIN (SELECT rowid AS rid, bm25(bodies_fts) AS score FROM bodies_fts "
                + "WHERE bodies_fts MATCH ?) rk ON rk.rid = e.id"
            params.append(.text(rank))
            // bm25() is lower for better matches; rows that matched only through non-text terms (NULL) go last.
            order = "ORDER BY (rk.score IS NULL), rk.score, e.date_received DESC, e.id DESC"
        }
        params += query.params
        params.append(.int(Int64(max(limit, 0))))
        return try fetchRecords(
            "SELECT \(Self.recordColumns) \(Self.recordFrom)\(rankJoin) WHERE \(query.whereSQL) \(order) LIMIT ?",
            params)
    }

    public func envelopeRecord(id: Int64) throws -> EnvelopeRecord? {
        try fetchRecords("SELECT \(Self.recordColumns) \(Self.recordFrom) WHERE e.id = ?", [.int(id)]).first
    }

    /// The conversation a message belongs to, oldest first. A message with no conversation id is its own thread.
    public func thread(containing id: Int64) throws -> [EnvelopeRecord] {
        guard let message = try envelopeRecord(id: id) else { throw Mail42Error.notFound("message \(id)") }
        let conversation = message.row.conversationID
        guard conversation != 0 else { return [message] }
        return try fetchRecords(
            "SELECT \(Self.recordColumns) \(Self.recordFrom) WHERE e.conversation_id = ? "
                + "ORDER BY e.date_received ASC, e.id ASC",
            [.int(conversation)])
    }

    /// Ids of the mailboxes a name, id or role refers to.
    public func mailboxIDs(matching value: String) throws -> [Int64] {
        let clause = QueryCompiler.mailboxClause(matching: value)
        // The clause is written over `envelopes e`; here we want the mailbox ids themselves.
        var ids: [Int64] = []
        try db.query(
            """
            SELECT id FROM mailboxes WHERE id = ? OR lower(name) = lower(?) \
            OR lower(name) LIKE '%/' || lower(?) ESCAPE '\\' OR role = lower(?)
            """, clause.params
        ) { ids.append($0.int(0)) }
        return ids
    }

    /// Every account with its mailboxes, for `mailbox list`.
    public func accountsWithMailboxes() throws -> [(account: AccountRow, mailboxes: [MailboxRow])] {
        let all = try mailboxes()
        return try accounts().map { account in
            (account, all.filter { $0.accountID == account.id }.sorted { lhs, rhs in
                // Inbox first, then the rest alphabetically.
                if (lhs.role == "inbox") != (rhs.role == "inbox") { return lhs.role == "inbox" }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            })
        }
    }

    // MARK: - Building records

    private func fetchRecords(_ sql: String, _ params: [SQLiteValue]) throws -> [EnvelopeRecord] {
        var records: [EnvelopeRecord] = []
        try db.query(sql, params) { r in
            records.append(EnvelopeRecord(
                row: EnvelopeRow(
                    id: r.int(0), messageID: r.text(1), conversationID: r.int(2), mailboxID: r.int(3),
                    subject: r.text(4) ?? "", fromName: r.text(5), fromAddr: r.text(6), dateReceived: r.int(7),
                    dateSent: r.int(8), snippet: r.text(9), isRead: r.int(10) != 0, isFlagged: r.int(11) != 0,
                    hasAttachments: r.int(12) != 0, size: r.int(13), emlxPath: r.text(14)),
                accountID: r.text(17) ?? "", accountName: r.text(18) ?? "", accountEmail: r.text(19),
                mailboxName: r.text(15) ?? "", mailboxRole: r.text(16) ?? "other", to: [], cc: []))
        }
        guard !records.isEmpty else { return [] }

        // To / Cc for the whole page in as few queries as possible.
        var byEnvelope: [Int64: (to: [RecipientRow], cc: [RecipientRow])] = [:]
        let ids = records.map(\.row.id)
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.query(
                """
                SELECT envelope_id, kind, name, addr, position FROM recipients \
                WHERE envelope_id IN (\(marks)) AND kind IN ('to', 'cc') ORDER BY envelope_id, position
                """, chunk.map(SQLiteValue.int)
            ) { row in
                let recipient = RecipientRow(kind: row.text(1) ?? "to", name: row.text(2), addr: row.text(3) ?? "", position: row.int(4))
                var entry = byEnvelope[row.int(0)] ?? ([], [])
                if recipient.kind == "cc" { entry.cc.append(recipient) } else { entry.to.append(recipient) }
                byEnvelope[row.int(0)] = entry
            }
        }
        for index in records.indices {
            if let entry = byEnvelope[records[index].row.id] {
                records[index].to = entry.to
                records[index].cc = entry.cc
            }
        }
        return records
    }
}
