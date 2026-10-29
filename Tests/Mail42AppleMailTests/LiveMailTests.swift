import CryptoKit
import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct LiveMailTests {

    private static let now: Int64 = 1_793_188_800          // 2026-10-28 12:00:00 UTC
    private static let gmail = "061726AC-CB5D-4E41-83D9-759780CEF744"
    private static let icloud = "1643034B-AA9D-401B-BFB8-E84A3527720C"
    private static let local = "96E9CCA7-6F03-4C16-A9BA-1229D4707956"

    private func url(_ uuid: String, _ path: String...) -> String {
        "imap://\(uuid)/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }.joined(separator: "/")
    }

    /// A Gmail account (everything stored in All Mail, Inbox and Important are labels) and an iCloud account
    /// (messages stored in the Inbox directly), with the real-world numbering of two accounts side by side.
    /// - Parameter huge: pretend the inboxes hold 100,000 messages (Apple's counters), which makes LiveMail list them
    ///   by walking the date index instead of sorting their few members: same answers, different code path.
    private func twoAccounts(_ b: EnvelopeIndexBuilder, huge: Bool = false) throws {
        try b.addMailbox(id: 1, url: "imap://\(Self.gmail)/INBOX", total: huge ? 100_000 : 3, unread: 2)
        try b.addMailbox(id: 12, url: "imap://\(Self.gmail)/%5BGmail%5D/All%20Mail", total: 4, unread: 2)
        try b.addMailbox(id: 16, url: "imap://\(Self.gmail)/%5BGmail%5D/Important", total: 1, unread: 1)
        try b.addMailbox(id: 2, url: "imap://\(Self.icloud)/INBOX", total: huge ? 100_000 : 2, unread: 1)
        try b.addMailbox(id: 3, url: "local://\(Self.local)/Outbox")
        let t = Self.now
        // Gmail: all four live in All Mail (12); 100, 101, 102 are labelled Inbox; 101 is also Important; 103 is archived.
        for (id, subject, age, read) in [(100, "gmail newest", 10, false), (101, "gmail middle", 20, true),
                                         (102, "gmail oldest inbox", 30, false), (103, "gmail archived", 40, false)] as [(Int64, String, Int64, Bool)] {
            try b.addMessage(.init(rowid: id, subject: subject, senderAddress: "g\(id)@example.com", senderName: "G \(id)",
                                   mailboxID: 12, dateReceived: t - age, read: read, conversationID: id == 102 ? 7 : 0,
                                   summary: "summary of \(subject)", messageIDHeader: "<g\(id)@x>"))
        }
        for id: Int64 in [100, 101, 102] { try b.addLabel(messageRowid: id, mailboxID: 1) }
        try b.addLabel(messageRowid: 101, mailboxID: 16)
        // iCloud: stored in the Inbox directly, no labels.
        try b.addMessage(.init(rowid: 200, subject: "icloud one", senderAddress: "i1@example.com", mailboxID: 2,
                               dateReceived: t - 15, read: false))
        try b.addMessage(.init(rowid: 201, subject: "icloud two", senderAddress: "i2@example.com", mailboxID: 2,
                               dateReceived: t - 25, read: true, flagged: true))
    }

    private func live(_ b: EnvelopeIndexBuilder, accounts: URL? = nil) throws -> LiveMail {
        try LiveMail.open(
            library: b.library,
            accountsDatabase: accounts ?? b.root.appendingPathComponent("Library/Accounts/missing.sqlite"))
    }

    // MARK: - Mailbox membership

    @Test func aGmailInboxHoldsTheMessagesLabelledInboxEvenThoughTheyLiveInAllMail() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let mail = try live(b)

        let inbox = try mail.listEnvelopes(.init(mailbox: .id(1)))
        #expect(inbox.map(\.row.id) == [100, 101, 102])                       // not 103 (archived), newest first
        #expect(inbox.allSatisfy { $0.mailboxName == "INBOX" && $0.mailboxRole == "inbox" })
        #expect(inbox.first?.row.snippet == "summary of gmail newest")
        #expect(inbox.first?.row.messageID == "<g100@x>")
    }

    @Test func allInboxesSpansEveryAccountsInboxNewestFirst() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let all = try live(b).listEnvelopes(.init(mailbox: .allInboxes))
        #expect(all.map(\.row.id) == [100, 200, 101, 201, 102])               // by date: 10, 15, 20, 25, 30 s ago
    }

    @Test func aMessageInTwoSelectedMailboxesAppearsOnce() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let both = try live(b).listEnvelopes(.init(mailbox: .named("inbox")))          // matches both inboxes
        #expect(both.count == Set(both.map(\.row.id)).count)
        let important = try live(b).listEnvelopes(.init(mailbox: .named("Important")))
        #expect(important.map(\.row.id) == [101])
    }

    @Test func aMessageStoredDirectlyInAMailboxIsInIt() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        #expect(try live(b).listEnvelopes(.init(mailbox: .id(2))).map(\.row.id) == [200, 201])
    }

    @Test func withoutALabelsTableMembershipFallsBackToWhereTheMessageIsStored() throws {
        let b = try EnvelopeIndexBuilder(schemaOmitting: ["labels.message_id"]); defer { b.cleanup() }
        try b.addMailbox(id: 1, url: "imap://\(Self.icloud)/INBOX")
        try b.addMessage(.init(rowid: 1, subject: "direct", senderAddress: "a@b.com", mailboxID: 1, dateReceived: Self.now))
        #expect(try live(b).listEnvelopes(.init(mailbox: .allInboxes)).map(\.row.id) == [1])
    }

    @Test func unreadFlaggedAndDeletedAreFilteredCorrectly() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        try b.setDeleted(rowid: 102, true)
        let mail = try live(b)
        #expect(try mail.listEnvelopes(.init(mailbox: .id(1), unreadOnly: true)).map(\.row.id) == [100])   // 101 read, 102 deleted
        #expect(try mail.listEnvelopes(.init(mailbox: .flagged)).map(\.row.id) == [201])
        #expect(try mail.listEnvelopes(.init(mailbox: .allInboxes, flaggedOnly: true)).map(\.row.id) == [201])
    }

    @Test func anUnknownMailboxNameIsNotFoundButAnEmptyOneIsEmpty() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let mail = try live(b)
        #expect(throws: Mail42Error.notFound("a mailbox matching `nope`")) { try mail.listEnvelopes(.init(mailbox: .named("nope"))) }
        #expect(try mail.listEnvelopes(.init(mailbox: .id(3))).isEmpty)
    }

    @Test func aHugeMailboxGivesTheSameAnswersAsASmallOne() throws {
        let small = try EnvelopeIndexBuilder(); defer { small.cleanup() }
        let huge = try EnvelopeIndexBuilder(); defer { huge.cleanup() }
        try twoAccounts(small)
        try twoAccounts(huge, huge: true)
        let (a, b) = (try live(small), try live(huge))

        let cases: [EnvelopeListOptions] = [
            .init(mailbox: .id(1)), .init(mailbox: .allInboxes), .init(mailbox: .id(1), unreadOnly: true),
            .init(mailbox: .allInboxes, limit: 2), .init(mailbox: .allInboxes, beforeID: 100, limit: 2),
            .init(mailbox: .named("inbox"), flaggedOnly: true),
        ]
        for options in cases {
            let expected = try a.listEnvelopes(options)
            let actual = try b.listEnvelopes(options)
            #expect(actual.map(\.row.id) == expected.map(\.row.id))
            #expect(actual.map(\.mailboxName) == expected.map(\.mailboxName))        // still shown under "INBOX"
        }
        #expect(try b.listEnvelopes(.init(mailbox: .id(1))).map(\.row.id) == [100, 101, 102])
    }

    @Test func flaggedMailIsNewestFirstAndRespectsLimitAndMailbox() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        try b.setFlagged(rowid: 102, true)           // Gmail inbox, 30 s ago
        try b.setFlagged(rowid: 100, true)           // Gmail inbox, 10 s ago
        try b.setDeleted(rowid: 103, true); try b.setFlagged(rowid: 103, true)      // deleted: never listed
        let mail = try live(b)

        #expect(try mail.listEnvelopes(.init(mailbox: .flagged)).map(\.row.id) == [100, 201, 102])
        #expect(try mail.listEnvelopes(.init(mailbox: .flagged, limit: 2)).map(\.row.id) == [100, 201])
        #expect(try mail.listEnvelopes(.init(mailbox: .id(1), flaggedOnly: true)).map(\.row.id) == [100, 102])
        #expect(try mail.listEnvelopes(.init(mailbox: .flagged, unreadOnly: true)).map(\.row.id) == [100, 102])
    }

    @Test func aGmailMessageListedUnderInboxIsFoundWhereItIsStored() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        // Message 100 is stored in All Mail (12) and labelled Inbox (1): its file is under All Mail, not INBOX.
        try b.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]))
        try b.addMailbox(id: 12, url: EnvelopeIndexBuilder.mailboxURL(["[Gmail]", "All Mail"]))
        try b.addMessage(.init(rowid: 100, subject: "labelled", senderAddress: "a@b.com", mailboxID: 12, dateReceived: Self.now))
        try b.addLabel(messageRowid: 100, mailboxID: 1)
        let file = try b.writeEmlx(rowid: 100, mailboxPath: ["[Gmail]", "All Mail"], data: MailFixtures.emlx(MailFixtures.plain()))
        let mail = try live(b)

        let listed = try #require(try mail.listEnvelopes(.init(mailbox: .id(1))).first)
        #expect(listed.row.id == 100 && listed.mailboxName == "INBOX")             // shown under Inbox…
        #expect(mail.emlxURL(for: listed)?.path == file.path)                      // …read from where it is stored
        let direct = try #require(try mail.envelopeRecord(id: 100))
        #expect(mail.emlxURL(for: direct)?.path == file.path)
        #expect(try mail.attachments(of: listed).isEmpty)
    }

    // MARK: - Paging

    @Test func pagesDoNotOverlapAndEndCleanly() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try b.addMailbox(id: 1, url: "imap://\(Self.icloud)/INBOX")
        try b.inTransaction {
            for id in Int64(1)...25 {
                // Several share a date, so the cursor must break ties by id.
                try b.addMessage(.init(rowid: id, subject: "m\(id)", senderAddress: "a@b.com", mailboxID: 1,
                                       dateReceived: Self.now - (id / 5)))
            }
        }
        let mail = try live(b)
        var seen: [Int64] = []
        var cursor: Int64?
        while true {
            let page = try mail.listEnvelopes(.init(mailbox: .id(1), beforeID: cursor, limit: 7))
            if page.isEmpty { break }
            seen += page.map(\.row.id)
            cursor = page.last?.row.id
        }
        #expect(seen.count == 25 && Set(seen).count == 25)
        #expect(seen == seen.sorted { lhs, rhs in
            // date descending (id/5 ascending), then id descending
            lhs / 5 != rhs / 5 ? lhs / 5 < rhs / 5 : lhs > rhs
        })
        #expect(throws: Mail42Error.self) { try mail.listEnvelopes(.init(mailbox: .id(1), beforeID: 9_999)) }
    }

    // MARK: - Single messages

    @Test func aRecordCarriesRecipientsAttachmentsAndItsThread() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        try b.addMessage(.init(rowid: 104, subject: "re: gmail oldest inbox", senderAddress: "x@y.com", mailboxID: 12,
                               dateReceived: Self.now - 5, conversationID: 7))
        try b.addRecipient(messageRowid: 102, address: "yan@example.com", name: "Yan", type: 0, position: 0)
        try b.addRecipient(messageRowid: 102, address: "bo@example.com", name: "Bo", type: 1, position: 0)
        try b.addRecipient(messageRowid: 102, address: "hidden@example.com", type: 2, position: 0)
        try b.addAttachment(messageRowid: 102, attachmentID: "1.2", name: "report.pdf")
        let mail = try live(b)

        let record = try #require(try mail.envelopeRecord(id: 102))
        #expect(record.to.map(\.addr) == ["yan@example.com"])
        #expect(record.cc.map(\.addr) == ["bo@example.com"])               // Bcc is not shown
        #expect(record.row.hasAttachments)
        #expect(try #require(try mail.envelopeRecord(id: 100)).row.hasAttachments == false)
        #expect(try mail.envelopeRecord(id: 4_242) == nil)

        #expect(try mail.thread(containing: 102).map(\.row.id) == [102, 104])        // oldest first
        #expect(try mail.thread(containing: 100).map(\.row.id) == [100])             // no conversation: itself
        #expect(throws: Mail42Error.notFound("message 4242")) { try mail.thread(containing: 4_242) }
    }

    // MARK: - Accounts and mailboxes

    @Test func accountsAreNamedAsMailNamesThemThroughTheirParentAccount() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let db = try b.writeAccountsDatabase([
            .init(pk: 18, identifier: "PARENT-1", username: "yansaro@gmail.com", description: "Google", type: "Gmail"),
            .init(pk: 19, identifier: Self.gmail, parent: 18),                       // the IMAP account has no name of its own
            .init(pk: 24, identifier: "PARENT-2", username: "yan@web42.ai", description: "yan@web42.ai", type: "Gmail"),
            .init(pk: 25, identifier: Self.icloud.lowercased(), parent: 24),         // identifiers compare case-insensitively
            .init(pk: 14, identifier: Self.local, description: "On My Mac", type: "Local"),
        ])
        let accounts = try live(b, accounts: db).accounts()

        #expect(accounts.map(\.name) == ["Google", "On My Mac", "yan@web42.ai"])             // sorted by name
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        #expect(byID[Self.gmail]?.name == "Google")
        #expect(byID[Self.gmail]?.email == "yansaro@gmail.com")
        #expect(byID[Self.icloud]?.name == "yan@web42.ai")
        #expect(byID[Self.icloud]?.email == "yan@web42.ai")
        #expect(try live(b, accounts: db).listEnvelopes(.init(mailbox: .id(1))).first?.accountName == "Google")
    }

    @Test func anAccountNobodyNamesFallsBackToItsUUID() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let accounts = try live(b).accounts()                                         // no Accounts database at all
        #expect(Set(accounts.map(\.name)) == [Self.gmail, Self.icloud, Self.local])
        #expect(accounts.allSatisfy { $0.email == nil })
    }

    @Test func aBrokenAccountsDatabaseIsIgnored() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let bad = b.root.appendingPathComponent("not-a-database.sqlite")
        try Data("garbage".utf8).write(to: bad)
        let accounts = try live(b, accounts: bad).accounts()
        #expect(Set(accounts.map(\.name)) == [Self.gmail, Self.icloud, Self.local])         // all fall back to the UUID
    }

    @Test func mailboxesCarryAppleCountersAndTheInboxComesFirst() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        let mail = try live(b)
        let gmail = try #require(mail.accountsWithMailboxes().first { $0.account.id == Self.gmail })
        #expect(gmail.mailboxes.map(\.name) == ["INBOX", "[Gmail]/All Mail", "[Gmail]/Important"])
        #expect(gmail.mailboxes.first?.total == 3 && gmail.mailboxes.first?.unread == 2)
        #expect(mail.mailboxIDs(matching: "important") == [16])
        #expect(mail.mailboxIDs(matching: "inbox").sorted() == [1, 2])
        #expect(mail.mailboxIDs(matching: "12") == [12])
    }

    // MARK: - Safety

    @Test func readingNeverChangesApplesFiles() throws {
        let b = try EnvelopeIndexBuilder(); defer { b.cleanup() }
        try twoAccounts(b)
        func sha() -> String? {
            (try? Data(contentsOf: b.envelopeIndexURL)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        }
        let before = sha()
        let mail = try live(b)
        _ = try mail.listEnvelopes(.init(mailbox: .allInboxes))
        _ = mail.accounts()
        mail.close()
        #expect(sha() == before)
    }

    @Test func seesMailThatSitsOnlyInTheWAL() throws {
        let b = try EnvelopeIndexBuilder(wal: true); defer { b.cleanup() }
        try twoAccounts(b)
        #expect(try live(b).listEnvelopes(.init(mailbox: .id(1))).count == 3)
    }

    @Test func aMissingStoreAndADeniedOneAreReportedAsSuch() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-none-\(UUID().uuidString)")
        #expect(throws: Mail42Error.noMailData) { try LiveMail.open(library: missing) }

        let b = try EnvelopeIndexBuilder(schemaOmitting: ["messages.size"]); defer { b.cleanup() }
        #expect(throws: Mail42Error.schemaUnsupported(table: "messages", column: "size")) { try self.live(b) }
    }
}
