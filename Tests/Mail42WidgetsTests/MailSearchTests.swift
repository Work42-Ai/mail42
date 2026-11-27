// MailSearchTests.swift — `MailIndex.search`, ported from Mail42AppleMailTests/LiveSearchTests (WOR-900).
// Message text comes from a fake `MailBodyTextSource`: nothing here touches the disk.

import Foundation
import SQLite3
import Mail42TestSupport
import Testing
@testable import Mail42MailWidget

/// A text source with the text of some messages, recording what it was asked for.
private final class FakeTextSource: MailBodyTextSource, @unchecked Sendable {
    private let lock = NSLock()
    private let texts: [Int64: String]
    private let readLimit: Int?
    private var asked: [[MailBodyCandidate]] = []

    /// - Parameter readLimit: read only this many messages of each batch, then report that time ran out.
    init(_ texts: [Int64: String], readLimit: Int? = nil) {
        self.texts = texts
        self.readLimit = readLimit
    }

    var batches: [[Int64]] { lock.withLock { asked.map { $0.map(\.id) } } }
    var requested: [MailBodyCandidate] { lock.withLock { asked.flatMap { $0 } } }

    func bodyTexts(for messages: [MailBodyCandidate], timeLimit: TimeInterval) async -> MailBodyTextBatch {
        lock.withLock { asked.append(messages) }
        let taken = readLimit.map { Array(messages.prefix($0)) } ?? messages
        var found: [Int64: String] = [:]
        for message in taken { if let text = texts[message.id] { found[message.id] = text } }
        return MailBodyTextBatch(texts: found, ranOutOfTime: taken.count < messages.count)
    }
}

@Suite("Mail search")
struct MailSearchTests {

    private static let sentURL = EnvelopeIndexBuilder.mailboxURL(["Sent Messages"])

    /// 10 "plain zebrafish"       text "…QUOKKABODY…"      11 "html hostile"  text "Roadmap headline" (read)
    /// 12 "attachment" (flagged, report.pdf, no text)         13 "metadata only xylophone" (no file)
    /// 16 in Sent Messages (read), text "quokkabody"
    private func mailbox() throws -> EnvelopeIndexBuilder {
        let b = try EnvelopeIndexBuilder()
        let now = Int64(Date().timeIntervalSince1970)
        try b.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 4, unread: 3)
        try b.addMailbox(id: 2, url: Self.sentURL, total: 1)
        func add(_ id: Int64, _ subject: String, _ from: String, _ name: String, age: Int64, box: Int64 = 1,
                 read: Bool = false, flagged: Bool = false) throws {
            try b.addMessage(.init(rowid: id, subject: subject, senderAddress: from, senderName: name, mailboxID: box,
                                   dateReceived: now - age, read: read, flagged: flagged))
        }
        try add(10, "plain zebrafish", "qa-plain@example.com", "QA Plain", age: 300)
        try add(11, "html hostile", "qa-html@example.com", "QA Html", age: 400, read: true)
        try add(12, "attachment", "qa-attach@example.com", "QA Attach", age: 500, flagged: true)
        try add(13, "metadata only xylophone", "ex@example.com", "Exchange", age: 600)
        try add(16, "sent note", "yan@example.com", "Yan", age: 900, box: 2, read: true)
        try b.addRecipient(messageRowid: 10, address: "yan@example.com", name: "Yan", type: 0, position: 0)
        try b.addRecipient(messageRowid: 11, address: "yan@example.com", name: "Yan", type: 0, position: 0)
        try b.addRecipient(messageRowid: 11, address: "bo@example.com", name: "Bo", type: 1, position: 0)
        try b.addRecipient(messageRowid: 13, address: "hidden@example.com", type: 2, position: 0)         // Bcc
        try b.addAttachment(messageRowid: 12, attachmentID: "2", name: "report.pdf")
        return b
    }

    private static let texts: [Int64: String] = [
        10: "Hello, this one has the word QuokkaBody in it.", 11: "Roadmap headline for the quarter",
        16: "a note that also says quokkabody",
    ]

    private func source(readLimit: Int? = nil) -> FakeTextSource { FakeTextSource(Self.texts, readLimit: readLimit) }

    private func run(
        _ query: String, limit: Int = 50, scan: MailSearchLimits = .standard, headersOnly: Bool = false,
        source: FakeTextSource? = nil, configure: (EnvelopeIndexBuilder) throws -> Void = { _ in }
    ) async throws -> MailSearchOutcome {
        let b = try mailbox(); defer { b.cleanup() }
        try configure(b)
        let index = try MailIndex(database: b.envelopeIndexURL)
        defer { index.close() }
        return try await index.search(query, limit: limit, scan: scan, headersOnly: headersOnly, textScanner: source ?? self.source())
    }

    private func ids(
        _ query: String, limit: Int = 50, scan: MailSearchLimits = .standard, headersOnly: Bool = false
    ) async throws -> [Int64] {
        try await run(query, limit: limit, scan: scan, headersOnly: headersOnly).records.map(\.id)
    }

    // MARK: Fields

    @Test("from matches part of the address or the name, in any case")
    func from() async throws {
        #expect(try await ids("from:qa-attach") == [12])
        #expect(try await ids("from:PLAIN") == [10])
        #expect(try await ids("from:example.com") == [10, 11, 12, 13, 16])
    }

    @Test("to matches To and Cc but not Bcc")
    func to() async throws {
        #expect(try await ids("to:bo") == [11])
        #expect(try await ids("to:yan") == [10, 11])
        #expect(try await ids("to:hidden") == [])
    }

    @Test("subject matches part of the subject")
    func subject() async throws {
        #expect(try await ids("subject:hostile") == [11])
        #expect(try await ids("subject:zebra") == [10])
    }

    @Test("state, attachment and mailbox terms")
    func stateAndMailbox() async throws {
        #expect(try await ids("is:unread") == [10, 12, 13])
        #expect(try await ids("is:read") == [11, 16])
        #expect(try await ids("is:flagged") == [12])
        #expect(try await ids("has:attachment") == [12])
        #expect(try await ids("in:sent") == [16])
        #expect(try await ids("in:inbox") == [10, 11, 12, 13])
        #expect(try await ids("in:2") == [16])
        #expect(try await ids("in:nowhere") == [])
        #expect(try await ids("from:qa-attach has:attachment is:flagged") == [12])
    }

    @Test("a message labelled with a mailbox (Gmail) is in it")
    func labelledMailbox() async throws {
        let out = try await run("in:inbox from:ex@") { b in
            try b.addMailbox(id: 3, url: EnvelopeIndexBuilder.mailboxURL(["[Gmail]", "All Mail"]), total: 1)
            try b.addMessage(.init(rowid: 20, subject: "labelled", senderAddress: "ex@gmail.com", mailboxID: 3,
                                   dateReceived: Int64(Date().timeIntervalSince1970) - 10))
            try b.addLabel(messageRowid: 20, mailboxID: 1)
        }
        #expect(out.records.map(\.id) == [20, 13])
    }

    @Test("`in:` works on an index with no usable labels table")
    func inWithoutLabels() async throws {
        let b = try EnvelopeIndexBuilder(schemaOmitting: ["labels.mailbox_id"])
        defer { b.cleanup() }
        try b.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 1)
        try b.addMessage(.init(rowid: 1, subject: "plain", senderAddress: "a@example.com", mailboxID: 1,
                               dateReceived: Int64(Date().timeIntervalSince1970) - 10))
        let index = try MailIndex(database: b.envelopeIndexURL)
        defer { index.close() }
        #expect(index.hasLabels == false)
        let out = try await index.search("in:inbox", limit: 50, textScanner: FakeTextSource([:]))
        #expect(out.records.map(\.id) == [1])
    }

    @Test("not keeps messages whose sender name, subject or preview is NULL")
    func negationKeepsMessagesWithNullColumns() async throws {
        func search(_ query: String) async throws -> [Int64] {
            try await run(query) { b in
                try b.addMailbox(id: 5, url: EnvelopeIndexBuilder.mailboxURL(["Work"]), total: 3)
                let now = Int64(Date().timeIntervalSince1970)
                // 30: no sender name (comment NULL) · 31: "Boss" · 32: subject made NULL below. None has a preview (summary NULL).
                try b.addMessage(.init(rowid: 30, subject: "hello", senderAddress: "carol@x.com", mailboxID: 5, dateReceived: now - 20))
                try b.addMessage(.init(rowid: 31, subject: "hello", senderAddress: "boss@x.com", senderName: "Boss", mailboxID: 5,
                                       dateReceived: now - 30))
                try b.addMessage(.init(rowid: 32, subject: "temp", senderAddress: "dave@x.com", senderName: "Dave", mailboxID: 5,
                                       dateReceived: now - 40))
                var db: OpaquePointer?
                #expect(sqlite3_open(b.envelopeIndexURL.path, &db) == SQLITE_OK)
                #expect(sqlite3_exec(db, "UPDATE messages SET subject = NULL WHERE ROWID = 32", nil, nil, nil) == SQLITE_OK)
                sqlite3_close(db)
            }.records.map(\.id)
        }
        #expect(try await search("in:5 from:boss") == [31])
        #expect(try await search("in:5 not from:boss") == [30, 32], "a NULL name must not hide the message")
        #expect(try await search("in:5 not subject:hello") == [32], "a NULL subject must not hide the message")
        #expect(try await search("in:5 not zzz") == [30, 31, 32], "NULL name, subject and preview under a plain word")
    }

    @Test("deleted messages never appear")
    func deleted() async throws {
        let out = try await run("from:qa-plain or quokkabody") { try $0.setDeleted(rowid: 10, true) }
        #expect(out.records.map(\.id) == [16])
    }

    // MARK: Words and message text

    @Test("a plain word matches headers and message text")
    func plainWord() async throws {
        #expect(try await ids("xylophone") == [13])                 // subject
        #expect(try await ids("quokkabody") == [10, 16])            // text only, any case
        #expect(try await ids("Roadmap") == [11])
        #expect(try await ids("qa-attach") == [12])                 // sender
        #expect(try await ids("nothingmatchesthis") == [])
        #expect(try await ids("zebrafish") == [10])                 // subject (and not twice)
    }

    @Test("body: only looks inside messages")
    func bodyOnly() async throws {
        #expect(try await ids("body:quokkabody") == [10, 16])
        #expect(try await ids("body:quokkabody in:inbox") == [10])
        #expect(try await ids("body:xylophone") == [])              // that word is only in a subject
        #expect(try await ids("body:roadmap from:qa-html") == [11])
        #expect(try await ids("body:quokkabody from:qa-html") == [])
        #expect(try await ids("body:quokkabody or body:roadmap") == [10, 11, 16])
        #expect(try await ids("\"word quokkabody\"") == [10])       // a phrase
    }

    @Test("text matching ignores case but not accents")
    func accents() async throws {
        let cafe = FakeTextSource([10: "Un CAFÉ noir", 11: "un cafe"])
        let b = try mailbox(); defer { b.cleanup() }
        let index = try MailIndex(database: b.envelopeIndexURL); defer { index.close() }
        func found(_ word: String) async throws -> [Int64] {
            try await index.search(word, limit: 10, textScanner: cafe).records.map(\.id)
        }
        #expect(try await found("café") == [10])
        #expect(try await found("cafe") == [11])
    }

    @Test("a message with no text never matches on its text")
    func noText() async throws {
        #expect(try await ids("body:hidden") == [])
        #expect(try await ids("not body:quokkabody in:inbox") == [11, 12, 13])     // 12 and 13 have no text
    }

    @Test("the source is asked for the candidates newest first, with the mailbox each is stored in")
    func candidatesAsked() async throws {
        let fake = source()
        _ = try await run("body:quokkabody", source: fake)
        #expect(fake.batches == [[10, 11, 12, 13, 16]])
        #expect(fake.requested.first { $0.id == 16 }?.mailboxURL == Self.sentURL)
        #expect(fake.requested.first { $0.id == 10 }?.mailboxURL == EnvelopeIndexBuilder.mailboxURL(["INBOX"]))
    }

    @Test("what the rest of the query rules out is never read")
    func narrowedCandidates() async throws {
        let fake = source()
        _ = try await run("body:quokkabody in:inbox is:read", source: fake)
        #expect(fake.requested.map(\.id) == [11])
    }

    // MARK: Logic, dates, limits

    @Test("and, or, not and parentheses combine terms")
    func logic() async throws {
        #expect(try await ids("from:qa-plain or from:qa-html") == [10, 11])         // newest first
        #expect(try await ids("is:unread not is:flagged") == [10, 13])
        #expect(try await ids("not is:unread") == [11, 16])
        #expect(try await ids("(from:qa-attach or from:exchange) is:unread") == [12, 13])
        #expect(try await ids("is:unread and is:flagged") == [12])
        #expect(try await ids("not body:quokkabody from:qa-") == [11, 12])
    }

    @Test("dates are relative or absolute ranges")
    func dates() async throws {
        #expect(try await ids("date:1d..") == [10, 11, 12, 13, 16])                 // all within a day
        #expect(try await ids("date:2w") == [10, 11, 12, 13, 16])                   // "2w" = "2w.."
        #expect(try await ids("date:..2000-01-01") == [])
        #expect(try await ids("date:2000-01-01..2000-01-31") == [])
        // Dates in a query are the user's local days, so name them in local time too.
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd"
        let today = local.string(from: Date())
        let tomorrow = local.string(from: Date().addingTimeInterval(86_400))
        #expect(try await ids("date:\(today)..\(tomorrow) is:flagged") == [12])
    }

    @Test("results are newest first and respect the limit")
    func limit() async throws {
        #expect(try await ids("from:example.com", limit: 2) == [10, 11])
        #expect(try await ids("from:example.com", limit: 0) == [])
        #expect(try await ids("example", limit: 2) == [10, 11])                     // a word too
        #expect(try await ids("quokkabody", limit: 0) == [])
    }

    @Test("a bad query is a bad_query failure with the position in its message")
    func badQueries() async throws {
        for query in ["from:", "(is:unread", "is:unread)", "is:maybe", "has:photo", "date:yesterday", "date:..", "not", "a or"] {
            do {
                _ = try await ids(query)
                Issue.record("`\(query)` should not parse")
            } catch let failure as MailFailure {
                #expect(failure.code == "bad_query" && failure.message.hasPrefix("Bad query at position "), "\(query): \(failure)")
            }
        }
        do {
            _ = try await ids("is:unread to:")
            Issue.record("should not parse")
        } catch let failure as MailFailure {
            #expect(failure == MailFailure(code: "bad_query", message: "Bad query at position 10: expected a value after `to:`"))
        }
    }

    @Test("user text is never SQL")
    func userTextIsNeverSQL() async throws {
        #expect(try await ids("from:\"x' OR 1=1 --\"") == [])
        #expect(try await ids("subject:\"'; DROP TABLE messages; --\"") == [])
        #expect(try await ids("from:%") == [])                       // LIKE wildcards are literal
        #expect(try await ids("subject:_") == [])
        #expect(try await ids("\"x') OR 1=1 --\"") == [])            // a word, through the text scan
        #expect(try await ids("is:unread") == [10, 12, 13])          // the store is untouched
    }

    // MARK: Honesty about how much was read

    @Test("a complete search has no note")
    func completeSearch() async throws {
        #expect(try await run("quokkabody").note == nil)
        #expect(try await run("from:qa-plain is:unread").note == nil)            // no message text involved
    }

    @Test("when there are more candidates than it may read, it says so")
    func capNote() async throws {
        let narrow = MailSearchLimits(maxMessages: 1)
        let found = try await run("quokkabody", scan: narrow)
        #expect(found.records.map(\.id) == [10])                                 // the newest candidate was read
        #expect(found.note?.contains("newest 1") == true && found.note?.contains("narrow") == false)
        #expect(found.note?.contains("from:, in: or date:") == true)
        #expect(found.note == "Read the text of the newest 1 messages that match the rest of your query; "
                + "older ones weren't searched. Add from:, in: or date: to reach further back.")

        let missed = try await run("roadmap", scan: narrow)                      // 11 is older than the one message read
        #expect(missed.records.isEmpty)
        #expect(missed.note != nil)                                              // an empty answer is flagged as partial
    }

    @Test("a limit of messages that is not reached leaves no note")
    func roomToSpare() async throws {
        #expect(try await run("quokkabody", scan: MailSearchLimits(maxMessages: 5)).note == nil)
    }

    // MARK: Headers first

    @Test("what the headers settle is found without reading any message")
    func headersWithoutReading() async throws {
        let none = MailSearchLimits(maxMessages: 0)
        let fake = source()
        let out = try await run("zebrafish", scan: none, source: fake)
        #expect(out.records.map(\.id) == [10] && fake.batches.isEmpty)
        #expect(try await ids("qa-attach", scan: none) == [12])                         // sender
        #expect(try await ids("example", limit: 3, scan: none) == [10, 11, 12])          // sender/recipient domain, newest first
        #expect(try await ids("zebrafish or xylophone", scan: none) == [10, 13])
    }

    @Test("a header match is never dropped because the scan ran out of time")
    func headerMatchSurvivesTimeout() async throws {
        let out = try await run("zebrafish", scan: MailSearchLimits(maxMessages: 100, timeLimit: 0))
        #expect(out.records.map(\.id) == [10])
    }

    @Test("a word also matches Apple Mail's preview line of a message")
    func previewLine() async throws {
        let configure: (EnvelopeIndexBuilder) throws -> Void = { b in
            try b.addMessage(.init(rowid: 17, subject: "hello", senderAddress: "pat@example.org", senderName: "Pat", mailboxID: 1,
                                   dateReceived: Int64(Date().timeIntervalSince1970) - 50, summary: "Quarterly lunch invitation for Friday"))
        }
        func found(_ query: String) async throws -> [Int64] {
            try await run(query, limit: 10, headersOnly: true, configure: configure).records.map(\.id)
        }
        #expect(try await found("lunch") == [17])                    // instant: no message file is read
        #expect(try await found("lunch friday") == [17])
        #expect(try await found("pat") == [17])                      // the sender's name
        #expect(try await found("example.org").contains(17))         // the address
        #expect(try await found("lunch nosuchword").isEmpty)
    }

    @Test("headersOnly stops before the text search")
    func headersOnly() async throws {
        let fake = source()
        #expect(try await run("zebrafish", headersOnly: true, source: fake).records.map(\.id) == [10])
        #expect(try await run("quokkabody", headersOnly: true, source: fake).records.isEmpty)       // text only: not yet
        #expect(try await run("not quokkabody in:inbox", headersOnly: true, source: fake).records.isEmpty)   // can't be settled early
        #expect(fake.batches.isEmpty)
        #expect(try await ids("quokkabody") == [10, 16])                                           // the full search finds it
    }

    @Test("header matches and text matches are merged newest first")
    func merged() async throws {
        // 10 matches "zebrafish" in its subject; 11 matches only in its text ("roadmap"), and is older than 10.
        #expect(try await ids("zebrafish or roadmap") == [10, 11])
        #expect(try await ids("roadmap or zebrafish", limit: 1) == [10])
    }

    @Test("a text hit newer than the header hits is merged in front")
    func textHitFirst() async throws {
        // 11 (text "Roadmap") is newer than 13 (subject "xylophone").
        #expect(try await ids("roadmap or xylophone") == [11, 13])
    }

    @Test("when the headers already fill the limit, only newer messages are read")
    func cutoff() async throws {
        let fake = source()
        let out = try await run("example or quokkabody", limit: 2, source: fake)
        #expect(out.records.map(\.id) == [10, 11])
        #expect(fake.requested.isEmpty)                              // nothing is newer than the 2nd header hit
    }

    // MARK: Stopping early, and time

    @Test("it stops reading once it has enough results, and then needs no note")
    func earlyStop() async throws {
        let fake = source()
        let quick = try await run("quokkabody", limit: 1, scan: MailSearchLimits(maxMessages: 2, chunkSize: 1), source: fake)
        #expect(quick.records.map(\.id) == [10])
        #expect(quick.note == nil)                                   // the newest hit is the newest hit, however far back
        #expect(fake.batches == [[10]])                              // the second candidate was never read
    }

    @Test("without enough results it keeps reading, chunk by chunk")
    func chunks() async throws {
        let fake = source()
        let out = try await run("body:quokkabody", limit: 5, scan: MailSearchLimits(chunkSize: 2), source: fake)
        #expect(out.records.map(\.id) == [10, 16] && out.note == nil)
        #expect(fake.batches == [[10, 11], [12, 13], [16]])
    }

    @Test("when time runs out it says so and never returns a guess")
    func timeLimit() async throws {
        let none = try await run("quokkabody", scan: MailSearchLimits(maxMessages: 100, timeLimit: 0))
        #expect(none.records.isEmpty)
        #expect(none.note?.contains("Stopped after 0 s") == true && none.note?.contains("0 of") == true)
    }

    @Test("a source that runs out of time mid-batch counts only what it read")
    func sourceRanOutOfTime() async throws {
        let out = try await run("body:quokkabody", source: source(readLimit: 1))
        #expect(out.records.map(\.id) == [10])                       // 16 was never read, so it is not a guess
        #expect(out.note == "Stopped after 8 s: read the text of the newest 1 of 5 messages that match the rest of your "
                + "query. Add from:, in: or date: to narrow it.")
    }
}
