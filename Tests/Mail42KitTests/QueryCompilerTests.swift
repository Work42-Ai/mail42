import Foundation
import Testing
@testable import Mail42Kit

/// Runs real queries against a real MailStore: the compiler's output is only meaningful as SQL that returns the
/// right rows.
@Suite struct QueryCompilerTests {

    // 2026-10-28 12:00:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_793_188_800)
    private static let day: Int64 = 86_400
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private final class Fixture {
        let store: MailStore
        private let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-q-\(UUID().uuidString)", isDirectory: true)
            store = try MailStore(path: folder.appendingPathComponent("mail.db"))
            let t = Int64(QueryCompilerTests.now.timeIntervalSince1970)
            let d = QueryCompilerTests.day
            try store.upsertAccounts([AccountRow(id: "A", name: "yan@example.com", email: "yan@example.com", kind: "imap")])
            try store.upsertMailboxes([
                MailboxRow(id: 1, accountID: "A", name: "INBOX", role: "inbox", url: "imap://A/INBOX", total: 0, unread: 0),
                MailboxRow(id: 2, accountID: "A", name: "Sent Messages", role: "sent", url: "imap://A/Sent", total: 0, unread: 0),
                MailboxRow(id: 3, accountID: "A", name: "Clients/Acme", role: "other", url: "imap://A/Clients/Acme", total: 0, unread: 0),
            ])
            try add(1, "Q4 roadmap review", "Alice Chen", "alice@acme.com", mailbox: 1, date: t - 3_600, read: false, flagged: false,
                    body: "timeline for the mail42 launch", to: [("Yan", "yan@example.com")], cc: [("Bo", "bo@example.com")])
            try add(2, "Your October invoice", "Stripe", "billing@stripe.com", mailbox: 1, date: t - 2 * d, read: true, flagged: true,
                    body: "invoice 4821 is attached", attachments: true)
            try add(3, "dinner Friday?", "Marco", "marco@friends.org", mailbox: 2, date: t - 10 * d, read: true, flagged: false,
                    body: "8pm at the usual place", to: [("Alice", "alice@acme.com")])
            try add(4, "[work42] PR 812 approved", "GitHub", "notifications@github.com", mailbox: 3, date: t - 40 * d,
                    read: false, flagged: false, body: "dnorris approved these changes")
            try add(5, "re: foo-bar baz", "Zed", "zed@example.org", mailbox: 1, date: t - 5 * d, read: true, flagged: false,
                    body: "nothing to see")
            try add(6, "invoice invoice invoice", "Billing Bot", "bot@example.com", mailbox: 1, date: t - 6 * d, read: true,
                    flagged: false, body: "invoice invoice invoice invoice")
        }

        func add(
            _ id: Int64, _ subject: String, _ name: String, _ addr: String, mailbox: Int64, date: Int64, read: Bool,
            flagged: Bool, body: String, to: [(String, String)] = [], cc: [(String, String)] = [], attachments: Bool = false
        ) throws {
            var recipients: [RecipientRow] = []
            for (i, p) in to.enumerated() { recipients.append(RecipientRow(kind: "to", name: p.0, addr: p.1, position: Int64(i))) }
            for (i, p) in cc.enumerated() { recipients.append(RecipientRow(kind: "cc", name: p.0, addr: p.1, position: Int64(i))) }
            try store.upsertEnvelope(
                EnvelopeRow(id: id, messageID: "<m\(id)@x>", conversationID: 0, mailboxID: mailbox, subject: subject,
                            fromName: name, fromAddr: addr, dateReceived: date, dateSent: date, snippet: nil, isRead: read,
                            isFlagged: flagged, hasAttachments: attachments, size: 1, emlxPath: nil),
                recipients: recipients, attachments: [], bodyText: body)
        }

        func ids(_ query: String, limit: Int = 50) throws -> [Int64] {
            let compiled = try QueryCompiler(now: QueryCompilerTests.now, calendar: QueryCompilerTests.calendar).compile(query)
            return try store.searchEnvelopes(compiled, limit: limit).map(\.row.id)
        }

        func cleanup() { try? FileManager.default.removeItem(at: folder) }
    }

    private func check(_ query: String, _ expected: Set<Int64>, in f: Fixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(Set(try f.ids(query)) == expected, "query: \(query)", sourceLocation: sourceLocation)
    }

    // MARK: - Fields

    @Test func fullTextWordsSearchSubjectSenderRecipientsAndBody() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("roadmap", [1], in: f)                  // subject
        try check("timeline", [1], in: f)                 // body
        try check("stripe", [2], in: f)                   // sender name
        try check("marco", [3], in: f)
        try check("yan@example.com", [1], in: f)          // recipient
        try check("\"mail42 launch\"", [1], in: f)        // phrase
        try check("launch mail42", [1], in: f)            // both words, any order
        try check("roadmap nothingmatches", [], in: f)
        try check("ROADMAP", [1], in: f)                  // case-insensitive
    }

    @Test func fromAndToUseSubstringMatchesOnNameAndAddress() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("from:alice", [1], in: f)
        try check("from:\"Alice Chen\"", [1], in: f)
        try check("from:ACME", [1], in: f)
        try check("from:stripe.com", [2], in: f)
        try check("to:yan", [1], in: f)
        try check("to:bo", [1], in: f)                    // Cc counts
        try check("to:alice", [3], in: f)
        try check("to:nobody", [], in: f)
    }

    @Test func subjectAndBodyAreLimitedToTheirColumns() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("subject:invoice", [2, 6], in: f)
        try check("body:invoice", [2, 6], in: f)
        try check("subject:timeline", [], in: f)          // only in the body
        try check("body:roadmap", [], in: f)              // only in the subject
        try check("subject:roadmap body:timeline", [1], in: f)
    }

    @Test func stateAndAttachmentTerms() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("is:unread", [1, 4], in: f)
        try check("is:read", [2, 3, 5, 6], in: f)
        try check("is:flagged", [2], in: f)
        try check("IS:Unread", [1, 4], in: f)
        try check("has:attachment", [2], in: f)
    }

    @Test func mailboxTermAcceptsRoleNameLeafAndId() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("in:inbox", [1, 2, 5, 6], in: f)        // role
        try check("in:INBOX", [1, 2, 5, 6], in: f)
        try check("in:sent", [3], in: f)                  // role
        try check("in:\"Sent Messages\"", [3], in: f)     // name
        try check("in:Acme", [4], in: f)                  // leaf of Clients/Acme
        try check("in:\"clients/acme\"", [4], in: f)      // full name
        try check("in:3", [4], in: f)                     // id
        try check("in:nope", [], in: f)
    }

    // MARK: - Boolean logic

    @Test func booleanOperatorsCombineTerms() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("not is:unread", [2, 3, 5, 6], in: f)
        try check("roadmap or dinner", [1, 3], in: f)
        try check("(roadmap or invoice) is:unread", [1], in: f)
        try check("roadmap or dinner is:read", [1, 3], in: f)        // or(roadmap, and(dinner, is:read))
        try check("in:inbox not has:attachment is:read", [5, 6], in: f)
        try check("not (is:read or is:flagged)", [1, 4], in: f)
        try check("not not is:flagged", [2], in: f)
        try check("is:unread and in:inbox", [1], in: f)
        try check("invoice not \"invoice invoice\"", [2], in: f)     // a negated full-text term
    }

    // MARK: - Dates

    @Test func relativeDates() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("date:3d..", [1, 2], in: f)             // since Oct 25 12:00
        try check("date:3d", [1, 2], in: f)               // same, without the dots
        try check("date:1w..", [1, 2, 5, 6], in: f)       // since Oct 21 12:00: 5 and 6 are 5 and 6 days old
        try check("date:2w..", [1, 2, 3, 5, 6], in: f)
        try check("date:1m..", [1, 2, 3, 5, 6], in: f)    // since Sep 28: env 4 is 40 days old
        try check("date:2m..", [1, 2, 3, 4, 5, 6], in: f)
        try check("date:0d..", [], in: f)                 // nothing is newer than right now
    }

    @Test func absoluteDatesIncludeTheWholeLastDay() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // env 2 is Oct 26 12:00 UTC.
        try check("date:2026-10-26", [2], in: f)                          // one whole day
        try check("date:2026-10-26..2026-10-26", [2], in: f)
        try check("date:2026-10-26..2026-10-28", [1, 2], in: f)           // the 28th is included
        try check("date:2026-10-27..", [1], in: f)
        try check("date:..2026-10-20", [3, 4], in: f)                     // up to and including the 20th (env 3 is Oct 18)
        try check("date:..2026-10-18", [3, 4], in: f)                     // env 3 is Oct 18 12:00: inside the 18th
        try check("date:..2026-10-17", [4], in: f)
        try check("date:2026-10-01..2026-10-31 is:flagged", [2], in: f)
    }

    @Test func invalidDatesAreBadQueriesWithAPosition() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        for query in ["date:2026-02-31", "date:yesterday", "date:..", "date:2026-1-5", "date:2w..x", "date:-3d..", "is:read date:13/13/2026"] {
            do {
                _ = try f.ids(query)
                Issue.record("expected \(query) to fail")
            } catch Mail42Error.badQuery(let message, let position) {
                #expect(position >= 0 && message.contains("date") || message.contains("`"), "\(query): \(message)")
            }
        }
        do { _ = try f.ids("is:read date:bogus") } catch Mail42Error.badQuery(_, let position) { #expect(position == 8) }
    }

    @Test func badStateAndAttachmentValuesAreBadQueries() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        for query in ["is:maybe", "has:cat", "is:", "has:Attachments"] {
            #expect(throws: Mail42Error.self) { try f.ids(query) }
        }
    }

    // MARK: - Hostile and tricky input

    @Test func userTextIsNeverInterpretedAsSQL() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        for query in [
            "from:\"x%' OR 1=1 --\"", "subject:\"); DROP TABLE envelopes; --\"", "\"'; DELETE FROM envelopes; --\"",
            "to:\"' UNION SELECT * FROM sync_state --\"", "in:\"1 OR 1=1\"", "from:\"\\\"; --\"",
        ] {
            #expect(try f.ids(query).isEmpty, "query: \(query)")
        }
        #expect(try f.store.envelopeCount() == 6)         // nothing was dropped or deleted
    }

    @Test func likeWildcardsAreEscaped() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("from:%", [], in: f)                    // not "match everything"
        try check("from:_", [], in: f)
        try check("to:%", [], in: f)
        try check("in:%", [], in: f)
        try check("from:\\", [], in: f)
    }

    @Test func fullTextPunctuationDoesNotBreakTheQuery() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try check("foo-bar", [5], in: f)                  // an unquoted hyphen must not become an FTS operator
        try check("\"foo-bar baz\"", [5], in: f)
        try check("subject:foo-bar", [5], in: f)
        try check("body:\"nothing to see\"", [5], in: f)
        try check("NEAR", [], in: f)                      // FTS5 keywords are just words here
        try check("\"AND\"", [], in: f)                   // the quoted word; a bare AND is the operator
        #expect(throws: Mail42Error.self) { try f.ids("AND") }
        try check("foo*", [5], in: f)                     // the `*` is punctuation: it searches the word "foo"
        try check("fo*", [], in: f)                       // …and there is no prefix expansion ("fo" is not "foo")
        try check("\"say \\\"hi\\\"\"", [], in: f)        // embedded quotes
        try check("col:umn", [], in: f)
        try check("---", [], in: f)                       // no tokens at all: matches nothing
        try check("not \"---\"", [1, 2, 3, 4, 5, 6], in: f)
    }

    // MARK: - Ranking and limits

    @Test func betterFullTextMatchesComeFirst() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // 6 repeats "invoice" in subject and body; 2 mentions it once each.
        #expect(try f.ids("invoice").first == 6)
        #expect(try f.ids("invoice") == [6, 2])
    }

    @Test func withoutFullTextTermsResultsAreNewestFirst() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(try f.ids("is:read") == [2, 5, 6, 3])     // dates: 2d, 5d, 6d, 10d ago
        #expect(try f.ids("not is:flagged") == [1, 5, 6, 3, 4])
    }

    @Test func nonTextMatchesRankAfterTextMatches() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // "roadmap" matches 1 by text; is:flagged matches 2 without any text term.
        let result = try f.ids("roadmap or is:flagged")
        #expect(Set(result) == [1, 2])
        #expect(result.first == 1)
    }

    @Test func limitCapsTheResults() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(try f.ids("is:read", limit: 2) == [2, 5])
        #expect(try f.ids("is:read", limit: 1).count == 1)
        #expect(try f.ids("is:read", limit: 0).isEmpty)
    }

    @Test func recipientsComeBackWithResults() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let compiled = try QueryCompiler(now: Self.now, calendar: Self.calendar).compile("roadmap")
        let record = try #require(try f.store.searchEnvelopes(compiled, limit: 5).first)
        #expect(record.to.map(\.addr) == ["yan@example.com"])
        #expect(record.cc.map(\.addr) == ["bo@example.com"])
        #expect(record.accountEmail == "yan@example.com" && record.mailboxName == "INBOX" && record.mailboxRole == "inbox")
    }
}
