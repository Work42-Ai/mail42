// MailSearch.swift — mail search without the CLI (WOR-900): `MailIndex.search`, ported from `LiveMail.search`.
//
// Everything but message text is answered from Apple's index. Words and `body:` need the text, which Apple's index doesn't
// hold: those read the newest messages that match the rest of the query (within `MailSearchLimits`) and the outcome's `note`
// says so when that wasn't all of them.
//
// What the headers settle (subject, sender, recipients, dates, state) is answered first from the index, instantly and
// completely. Only then are messages read, and only those that could still add a result: when the headers already fill
// `limit`, only messages newer than the oldest of them (an older match could never displace it).
//
// The extension cannot open `.emlx` files itself (it reads through the disk bridge), so reading is a parameter:
// `MailBodyTextSource` gives the text of the messages it is asked about, and this file owns the limits, the chunking, the
// early stop and the honesty about how much was read.

import Foundation

/// How much a text search may read.
nonisolated struct MailSearchLimits: Sendable {
    /// The most messages to read.
    var maxMessages: Int = 20_000
    /// Stop starting new messages after this long.
    var timeLimit: TimeInterval = 8
    /// How many messages are read before checking whether there are already enough results.
    var chunkSize: Int = 500

    static let standard = MailSearchLimits()
}

/// A message whose text is wanted: its id and the URL of the mailbox it is stored in (which says where its file is).
nonisolated struct MailBodyCandidate: Equatable, Sendable {
    let id: Int64
    let mailboxURL: String
}

/// What a `MailBodyTextSource` could read.
nonisolated struct MailBodyTextBatch: Sendable {
    /// The readable text of the messages it read (plain part, else the HTML turned into text). A message with no file, or
    /// with no text, may be missing: it contains no word.
    var texts: [Int64: String]
    /// Set when it stopped because the time limit passed. Messages it did not get to are then not counted as read.
    var ranOutOfTime = false
    /// Messages whose text was only partly read (a file bigger than the source reads from the start).
    var partial: Set<Int64> = []
    /// Set when a read failed for a reason other than "no file" (a refusal by macOS or the bridge): the search ends with it
    /// instead of answering from the messages that did read.
    var failure: (any Error)?

    init(texts: [Int64: String], ranOutOfTime: Bool = false, partial: Set<Int64> = [], failure: (any Error)? = nil) {
        self.texts = texts
        self.ranOutOfTime = ranOutOfTime
        self.partial = partial
        self.failure = failure
    }
}

/// Reads the text of messages (the caller implements it with the disk bridge and `MailBodyParser`).
nonisolated protocol MailBodyTextSource: Sendable {
    /// - Parameters:
    ///   - messages: the candidates, newest first.
    ///   - timeLimit: seconds left; stop starting new messages after that and set `ranOutOfTime`.
    func bodyTexts(for messages: [MailBodyCandidate], timeLimit: TimeInterval) async -> MailBodyTextBatch
}

/// A search's results, and a note when it could not cover every message.
nonisolated struct MailSearchOutcome: Sendable {
    var records: [MailEnvelope]
    /// Set when the text of some messages was not read ("Read the text of the newest 3,000…"); say so, never hide it.
    var note: String?
}

nonisolated extension MailIndex {

    /// The tables a search compares against: subject, sender and (when this Mail has them) the one-line preview.
    private var searchJoins: String {
        "LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender"
            + (hasSummary ? " LEFT JOIN summaries sm ON sm.ROWID = m.summary" : "")
    }

    private func compiler(_ matches: [String: Set<Int64>]?) -> MailQueryCompiler {
        MailQueryCompiler(mailboxIDs: { self.mailboxIDs(matching: $0) }, textMatches: matches, summaries: hasSummary, labels: hasLabels)
    }

    /// Messages matching a search query (`from:alice is:unread date:2w.. invoice`), newest first.
    ///
    /// - Parameter headersOnly: stop after the first step: what the headers alone find (the tile shows this at once, then
    ///   replaces it with the full answer). Empty for a query that can't be settled by headers (a word under `not`).
    /// - Throws: `MailFailure` with code `bad_query` when the query is not valid.
    func search(
        _ query: String, limit: Int, scan: MailSearchLimits = .standard, headersOnly: Bool = false, before: Int64? = nil,
        textScanner: any MailBodyTextSource
    ) async throws -> MailSearchOutcome {
        do {
            return try await runSearch(query, limit: limit, scan: scan, headersOnly: headersOnly, before: before, textScanner: textScanner)
        } catch let error as MailQueryError {
            throw error.failure
        }
    }

    private func runSearch(
        _ query: String, limit: Int, scan: MailSearchLimits, headersOnly: Bool, before: Int64?, textScanner: any MailBodyTextSource
    ) async throws -> MailSearchOutcome {
        let order = "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(max(limit, 0))"
        func outcome(_ records: [Record], note: String? = nil) -> MailSearchOutcome {
            MailSearchOutcome(records: records.map { Self.envelope($0, conversationCount: nil, participants: nil) }, note: note)
        }

        // Keyset paging, as `listEnvelopes`: only messages after `before` in the newest-first order (date, then id), ties included.
        // It is in every query below that picks messages, so a page never repeats or skips one across the seam.
        var cursorClauses: [String] = []
        var cursorParams: [MailSQLValue] = []
        if let before {
            guard let date = try dateReceived(of: before) else { throw MailIndexError.notFound("message \(before) (the paging cursor)") }
            cursorClauses = ["(m.date_received < ? OR (m.date_received = ? AND m.ROWID < ?))"]
            cursorParams = [.int(date), .int(date), .int(before)]
        }

        let relaxed = try compiler(nil).compile(query)
        guard !relaxed.textTerms.isEmpty else {
            return outcome(try searchRecords(
                clauses: ["m.deleted = 0", relaxed.whereSQL] + cursorClauses, params: relaxed.params + cursorParams, order: order))
        }

        // 1. What the headers alone settle: exact (for a query with no word under `not`) and instant.
        var headerRecords: [Record] = []
        var cutoff: (date: Int64, id: Int64)?
        if !relaxed.hasNegatedText {
            let headers = try compiler([:]).compile(query)            // every text test false: a subset of the answer
            headerRecords = try searchRecords(
                clauses: ["m.deleted = 0", headers.whereSQL] + cursorClauses, params: headers.params + cursorParams, order: order)
            if headersOnly || limit <= 0 { return outcome(headerRecords) }
            if headerRecords.count >= limit, let last = headerRecords.last {
                cutoff = (last.dateReceived, last.id)                 // an older text match can't displace these
            }
        } else if headersOnly {
            return outcome([])
        }
        let known = Set(headerRecords.map(\.id))

        // 2. The newest other messages that pass everything that doesn't need their text, to read.
        var candidateClauses = ["m.deleted = 0", relaxed.whereSQL] + cursorClauses
        var candidateParams = relaxed.params + cursorParams
        if let cutoff {
            candidateClauses.append("(m.date_received > ? OR (m.date_received = ? AND m.ROWID > ?))")
            candidateParams += [.int(cutoff.date), .int(cutoff.date), .int(cutoff.id)]
        }
        let found = try searchIDs(
            clauses: candidateClauses, params: candidateParams,
            order: "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(max(scan.maxMessages, 0) + known.count + 1)"
        ).filter { !known.contains($0) }
        let moreExist = found.count > scan.maxMessages
        let candidates = Array(found.prefix(max(scan.maxMessages, 0)))
        let mailboxURLs = try mailboxURLs(of: candidates)

        // Read them newest first, a chunk at a time, and after each chunk ask the real question over everything read so
        // far. Whether a message qualifies depends only on that message, so once there are `limit` results the older,
        // unread candidates cannot displace them: stop there instead of reading the rest.
        func results(_ matches: [String: Set<Int64>], _ scanned: Set<Int64>) throws -> [Record] {
            guard !scanned.isEmpty else { return [] }
            let final = try compiler(matches).compile(query)
            let read = scanned.map(String.init).joined(separator: ",")
            return try searchRecords(
                clauses: ["m.deleted = 0", "m.ROWID IN (\(read))", final.whereSQL], params: final.params, order: order)
        }

        let wanted = relaxed.textTerms.map { (term: $0, folded: Self.fold($0)) }
        let deadline = Date().addingTimeInterval(scan.timeLimit)
        let chunkSize = max(scan.chunkSize, 1)
        var matches: [String: Set<Int64>] = [:]
        var scanned = Set<Int64>()
        var partlyRead = Set<Int64>()
        var records = headerRecords
        var satisfied = false, outOfTime = false
        var start = 0
        while start < candidates.count, limit > 0 {
            let chunk = Array(candidates[start..<min(start + chunkSize, candidates.count)])
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { outOfTime = true; break }
            let batch = await textScanner.bodyTexts(
                for: chunk.map { MailBodyCandidate(id: $0, mailboxURL: mailboxURLs[$0] ?? "") }, timeLimit: remaining)
            // A refusal is not "no text": an answer built without those messages would be wrong, not partial.
            if let failure = batch.failure { throw failure }
            // A message the source has no text for was read and contains no word, unless it ran out of time first.
            let read = batch.ranOutOfTime ? Set(chunk.filter { batch.texts[$0] != nil }) : Set(chunk)
            scanned.formUnion(read)
            partlyRead.formUnion(batch.partial.intersection(read))
            for id in read {
                guard let text = batch.texts[id] else { continue }
                let folded = Self.fold(text)
                for item in wanted where folded.contains(item.folded) { matches[item.term, default: []].insert(id) }
            }
            start += chunk.count
            if batch.ranOutOfTime || read.count < chunk.count { outOfTime = true; break }
            records = Self.merge(headerRecords, try results(matches, scanned), limit: limit)
            // Candidates are read newest first, so nothing left can be newer than the next one: once `limit` results
            // are all newer than it, reading more cannot change the answer.
            if records.count >= limit, start < found.count,
               let next = try dateReceived(of: found[start]), let worst = records.last?.dateReceived,
               worst > next {
                satisfied = true
                break
            }
        }
        if !satisfied { records = Self.merge(headerRecords, try results(matches, scanned), limit: limit) }

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
        // A message bigger than what is read of each file: its start was searched, and a word further in may be missed (or, under
        // `not`, wrongly let the message through).
        if !partlyRead.isEmpty {
            let count = partlyRead.count
            let partly = "The text of \(count.formatted()) large message\(count == 1 ? " was" : "s was") only partly searched "
                + "(the start of each); a word later in \(count == 1 ? "it" : "them") may be missed."
            note = [note, partly].compactMap { $0 }.joined(separator: " ")
        }
        return outcome(records, note: note)
    }

    // MARK: Helpers

    /// The ids of the messages matching `clauses`, in `order` (which carries the LIMIT), with the search joins.
    private func searchIDs(clauses: [String], params: [MailSQLValue], order: String) throws -> [Int64] {
        let sql = "SELECT m.ROWID FROM messages m \(searchJoins) WHERE \(clauses.joined(separator: " AND ")) \(order)"
        var ids: [Int64] = []
        try db.query(sql, params) { ids.append($0.int(0)) }
        return ids
    }

    /// The records of the messages matching `clauses`. The ids are found with the search joins; `fetchRecords` then only
    /// needs to read their details.
    private func searchRecords(clauses: [String], params: [MailSQLValue], order: String) throws -> [Record] {
        let ids = try searchIDs(clauses: clauses, params: params, order: order)
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        return try fetchRecords(
            mailboxes: nil, clauses: ["m.deleted = 0", "m.ROWID IN (\(list))"], params: [],
            order: "ORDER BY m.date_received DESC, m.ROWID DESC")
    }

    private func dateReceived(of id: Int64) throws -> Int64? {
        try db.scalarInt("SELECT date_received FROM messages WHERE ROWID = ?", [.int(id)])
    }

    /// The URL of the mailbox each message is stored in (a message whose mailbox is unknown is missing).
    private func mailboxURLs(of ids: [Int64]) throws -> [Int64: String] {
        let urlByMailbox = Dictionary(mailboxRows.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        var result: [Int64: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.query(
                "SELECT ROWID, mailbox FROM messages WHERE ROWID IN (\(marks))", chunk.map(MailSQLValue.int)
            ) { row in
                if let url = urlByMailbox[row.int(1)] { result[row.int(0)] = url }
            }
        }
        return result
    }

    /// The newest `limit` of two result sets, each message once.
    private static func merge(_ first: [Record], _ second: [Record], limit: Int) -> [Record] {
        var seen = Set<Int64>()
        let all = (first + second).sorted {
            $0.dateReceived != $1.dateReceived ? $0.dateReceived > $1.dateReceived : $0.id > $1.id
        }
        return Array(all.filter { seen.insert($0.id).inserted }.prefix(max(limit, 0)))
    }

    /// The form used for comparing: case-insensitive, accents significant (as the header searches' `LIKE` is).
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: nil)
    }
}
