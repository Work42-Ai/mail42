import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct LiveSearchTests {

    /// 10 plain text, "quokkabody" in the text    11 HTML-only, "Roadmap headline"     12 attachment (flagged, report.pdf)
    /// 13 no file on disk, "xylophone" in subject   16 in Sent Messages (read)
    private func mailbox() throws -> EnvelopeIndexBuilder {
        let b = try EnvelopeIndexBuilder()
        let now = Int64(Date().timeIntervalSince1970)
        try b.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 4, unread: 3)
        try b.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["Sent Messages"]), total: 1)
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
        try b.writeEmlx(rowid: 10, data: MailFixtures.emlx(MailFixtures.plain()))
        try b.writeEmlx(rowid: 11, data: MailFixtures.emlx(MailFixtures.htmlWithInlineImage()))
        try b.writeEmlx(rowid: 12, data: MailFixtures.emlx(MailFixtures.withAttachment()))
        try b.writeEmlx(rowid: 16, mailboxPath: ["Sent Messages"],
                        data: MailFixtures.emlx(MailFixtures.plain(subject: "sent note", messageID: "<sent-1@example.com>")))
        return b
    }

    private func outcome(_ query: String, limit: Int = 50, scan: ScanLimits = .standard) throws -> LiveMail.SearchOutcome {
        let b = try mailbox(); defer { b.cleanup() }
        let mail = try LiveMail.open(library: b.library, accountsDatabase: b.root.appendingPathComponent("none.sqlite"))
        return try mail.search(query, limit: limit, scan: scan)
    }

    private func ids(_ query: String, limit: Int = 50, scan: ScanLimits = .standard) throws -> [Int64] {
        try outcome(query, limit: limit, scan: scan).records.map(\.row.id)
    }

    // MARK: - Fields

    @Test func fromMatchesPartOfTheAddressOrTheName() throws {
        #expect(try ids("from:qa-attach") == [12])
        #expect(try ids("from:PLAIN") == [10])                 // the display name, any case
        #expect(try ids("from:example.com") == [10, 11, 12, 13, 16])
    }

    @Test func toMatchesToAndCcButNotBcc() throws {
        #expect(try ids("to:bo") == [11])                      // Cc
        #expect(try ids("to:yan") == [10, 11])
        #expect(try ids("to:hidden") == [])                    // Bcc is never shown
    }

    @Test func subjectMatchesPartOfTheSubject() throws {
        #expect(try ids("subject:hostile") == [11])
        #expect(try ids("subject:zebra") == [10])
    }

    @Test func stateAttachmentAndMailboxTerms() throws {
        #expect(try ids("is:unread") == [10, 12, 13])
        #expect(try ids("is:read") == [11, 16])
        #expect(try ids("is:flagged") == [12])
        #expect(try ids("has:attachment") == [12])
        #expect(try ids("in:sent") == [16])
        #expect(try ids("in:inbox") == [10, 11, 12, 13])
        #expect(try ids("in:2") == [16])
        #expect(try ids("in:nowhere") == [])
        #expect(try ids("from:qa-attach has:attachment is:flagged") == [12])
    }

    // MARK: - Words and message text

    @Test func aPlainWordMatchesHeadersAndMessageText() throws {
        #expect(try ids("xylophone") == [13])                 // subject
        #expect(try ids("quokkabody") == [10, 16])            // text only (the Sent message uses the same text)
        #expect(try ids("Roadmap") == [11])                   // HTML-only message, read as text, any case
        #expect(try ids("qa-attach") == [12])                 // sender
        #expect(try ids("nothingmatchesthis") == [])
        #expect(try ids("zebrafish") == [10])                 // subject (and not twice)
    }

    @Test func bodyOnlyLooksInsideMessages() throws {
        #expect(try ids("body:quokkabody") == [10, 16])
        #expect(try ids("body:quokkabody in:inbox") == [10])
        #expect(try ids("body:xylophone") == [])              // that word is only in a subject, and message 13 has no file
        #expect(try ids("body:roadmap from:qa-html") == [11])
        #expect(try ids("body:quokkabody from:qa-html") == [])
        #expect(try ids("body:quokkabody or body:roadmap") == [10, 11, 16])
    }

    @Test func textMatchingIgnoresCaseButNotAccents() {
        #expect(BodyScanner.fold("Café ROADMAP") == BodyScanner.fold("café roadmap"))
        #expect(BodyScanner.fold("Café") != BodyScanner.fold("cafe"))
    }

    @Test func aMessageWithoutAFileNeverMatchesOnItsText() throws {
        #expect(try ids("body:hidden") == [])
        #expect(try ids("not body:quokkabody in:inbox") == [11, 12, 13])      // 13 has no text, so it doesn't contain the word
    }

    // MARK: - Logic, dates, limits

    @Test func andOrNotAndParenthesesCombineTerms() throws {
        #expect(try ids("from:qa-plain or from:qa-html") == [10, 11])         // newest first
        #expect(try ids("is:unread not is:flagged") == [10, 13])
        #expect(try ids("not is:unread") == [11, 16])
        #expect(try ids("(from:qa-attach or from:exchange) is:unread") == [12, 13])
        #expect(try ids("is:unread and is:flagged") == [12])
        #expect(try ids("not body:quokkabody from:qa-") == [11, 12])
    }

    @Test func datesAreRelativeOrAbsoluteRanges() throws {
        #expect(try ids("date:1d..") == [10, 11, 12, 13, 16])                 // all within a day
        #expect(try ids("date:2w") == [10, 11, 12, 13, 16])                   // "2w" = "2w.."
        #expect(try ids("date:..2000-01-01") == [])
        #expect(try ids("date:2000-01-01..2000-01-31") == [])
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let tomorrow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400)).prefix(10)
        #expect(try ids("date:\(today)..\(tomorrow) is:flagged") == [12])
    }

    @Test func resultsAreNewestFirstAndRespectTheLimit() throws {
        #expect(try ids("from:example.com", limit: 2) == [10, 11])
        #expect(try ids("from:example.com", limit: 0) == [])
        #expect(try ids("example", limit: 2) == [10, 11])                     // a word too
    }

    @Test func badQueriesAreReportedWithAPosition() throws {
        for query in ["from:", "(is:unread", "is:unread)", "is:maybe", "has:photo", "date:yesterday", "date:..", "not", "a or"] {
            do {
                _ = try ids(query)
                Issue.record("`\(query)` should not parse")
            } catch Mail42Error.badQuery(_, let position) {
                #expect(position >= 0)
            }
        }
    }

    @Test func userTextIsNeverSQL() throws {
        #expect(try ids("from:\"x' OR 1=1 --\"") == [])
        #expect(try ids("subject:\"'; DROP TABLE messages; --\"") == [])
        #expect(try ids("from:%") == [])                       // LIKE wildcards are literal
        #expect(try ids("subject:_") == [])
        #expect(try ids("\"x') OR 1=1 --\"") == [])            // a word, through the text scan
        #expect(try ids("is:unread") == [10, 12, 13])          // the store is untouched
    }

    // MARK: - Honesty about how much was read

    @Test func aCompleteSearchHasNoNote() throws {
        #expect(try outcome("quokkabody").note == nil)
        #expect(try outcome("from:qa-plain is:unread").note == nil)            // no message text involved
    }

    @Test func whenThereAreMoreCandidatesThanItMayReadItSaysSo() throws {
        let narrow = ScanLimits(maxMessages: 1)
        let found = try outcome("quokkabody", scan: narrow)
        #expect(found.records.map(\.row.id) == [10])                           // the newest candidate was read
        #expect(found.note?.contains("newest 1") == true && found.note?.contains("narrow") == false)
        #expect(found.note?.contains("from:, in: or date:") == true)

        let missed = try outcome("roadmap", scan: narrow)                      // 11 is older than the one message read
        #expect(missed.records.isEmpty)
        #expect(missed.note != nil)                                            // an empty answer is flagged as partial
    }

    @Test func itStopsReadingOnceItHasEnoughResultsAndThenNeedsNoNote() throws {
        // Many candidates, a tiny read budget per search, but the first message already satisfies `limit`.
        let b = try mailbox(); defer { b.cleanup() }
        let mail = try LiveMail.open(library: b.library, accountsDatabase: b.root.appendingPathComponent("none.sqlite"))
        let quick = try mail.search("quokkabody", limit: 1, scan: ScanLimits(maxMessages: 2))
        #expect(quick.records.map(\.row.id) == [10])
        #expect(quick.note == nil)                             // the newest hit is the newest hit, however far back there is
    }

    @Test func whenTimeRunsOutItSaysSoAndNeverReturnsAGuess() throws {
        let none = try outcome("quokkabody", scan: ScanLimits(maxMessages: 100, timeLimit: 0))
        #expect(none.records.isEmpty)
        #expect(none.note?.contains("Stopped after 0 s") == true && none.note?.contains("0 of") == true)
    }
}
