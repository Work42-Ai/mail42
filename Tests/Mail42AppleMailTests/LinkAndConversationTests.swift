import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct MessageLinkTests {

    @Test func aLinkRoundTripsEvenWithAnOddMessageID() {
        for header in ["<CAF7x9Q@mail.gmail.com>", "<a+b=c&d?e#f%g@x.y>", "<日本語@例え.jp>", "plain@example.com", "<a b@c>"] {
            let link = MessageLink(rowid: 48213, messageID: header)
            let parsed = MessageLink(string: link.string)
            #expect(parsed == link, "\(header) → \(link.string)")
            #expect(parsed?.messageID == MessageLink.stripBrackets(header))
        }
        #expect(MessageLink(rowid: 7, messageID: "<x@y>").string == "mail42://message/7?mid=x%40y")
    }

    @Test func aBareIdIsALinkWithoutAMessageID() {
        #expect(MessageLink(string: "48213") == MessageLink(rowid: 48213, messageID: nil))
        #expect(MessageLink(string: " 12 ")?.rowid == 12)
        #expect(MessageLink(rowid: 5, messageID: nil).string == "mail42://message/5")
    }

    @Test func somethingElseIsNotALink() {
        for text in ["", "abc", "mail42://message/", "mail42://message/abc", "https://example.com/1", "message://%3Cx%40y%3E"] {
            #expect(MessageLink(string: text) == nil, "\(text)")
        }
    }

    @Test func emptyBracketsGiveNoMessageID() {
        #expect(MessageLink.stripBrackets("<>") == nil)
        #expect(MessageLink(rowid: 1, messageID: "  ").messageID == nil)
    }
}

@Suite struct LinkAndConversationTests {

    private let now = Int64(Date().timeIntervalSince1970)

    /// Inbox (1), Sent (2) and Archive (3). Conversation 7 is a thread of three: 20 (inbox, oldest, Ana), 21 (inbox,
    /// Bo), 22 (Sent, Yan, newest). Conversation 8 is 19 (inbox, between 21 and 20 in time). 18 has no conversation.
    private func mailbox() throws -> EnvelopeIndexBuilder {
        let b = try EnvelopeIndexBuilder()
        try b.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 4, unread: 4)
        try b.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["Sent Messages"]), total: 1)
        try b.addMailbox(id: 3, url: EnvelopeIndexBuilder.mailboxURL(["Archive"]), total: 0)
        func add(_ id: Int64, _ subject: String, _ address: String, _ name: String, age: Int64, box: Int64 = 1,
                 conversation: Int64 = 0, header: String) throws {
            try b.addMessage(.init(rowid: id, subject: subject, senderAddress: address, senderName: name, mailboxID: box,
                                   dateReceived: now - age, conversationID: conversation, messageIDHeader: header))
        }
        try add(20, "Roadmap", "ana@example.com", "Ana", age: 900, conversation: 7, header: "<r1@example.com>")
        try add(21, "Re: Roadmap", "bo@example.com", "Bo", age: 100, conversation: 7, header: "<r2@example.com>")
        try add(22, "Re: Roadmap", "yan@example.com", "Yan", age: 50, box: 2, conversation: 7, header: "<r3@example.com>")
        try add(19, "Lunch", "cy@example.com", "Cy", age: 300, conversation: 8, header: "<l1@example.com>")
        try add(18, "Alone", "di@example.com", "Di", age: 400, header: "<a1@example.com>")
        return b
    }

    private func open(_ b: EnvelopeIndexBuilder) throws -> LiveMail {
        try LiveMail.open(library: b.library, accountsDatabase: b.root.appendingPathComponent("none.sqlite"))
    }

    // MARK: - Links

    @Test func everyEnvelopeCarriesItsLink() throws {
        let b = try mailbox(); defer { b.cleanup() }
        let record = try #require(try open(b).envelopeRecord(id: 21))
        #expect(record.link == MessageLink(rowid: 21, messageID: "r2@example.com"))
        #expect(record.link.string == "mail42://message/21?mid=r2%40example.com")
    }

    @Test func resolveFindsTheRowWhenItStillHoldsThatMessage() throws {
        let b = try mailbox(); defer { b.cleanup() }
        let mail = try open(b)
        #expect(try mail.resolve(MessageLink(rowid: 21, messageID: "r2@example.com")).row.id == 21)
        #expect(try mail.resolve(MessageLink(rowid: 21, messageID: nil)).row.id == 21)        // a bare id
    }

    @Test func resolveFindsAMovedMessageByItsMessageID() throws {
        let b = try mailbox(); defer { b.cleanup() }
        let link = MessageLink(rowid: 21, messageID: "r2@example.com")
        // Mail archives it: the old row goes away and the same message returns under a new id in Archive.
        try b.deleteMessage(rowid: 21)
        try b.addMessage(.init(rowid: 90, subject: "Re: Roadmap", senderAddress: "bo@example.com", senderName: "Bo",
                               mailboxID: 3, dateReceived: now - 100, conversationID: 7, messageIDHeader: "<r2@example.com>"))
        let found = try open(b).resolve(link)
        #expect(found.row.id == 90 && found.mailboxName == "Archive")
        #expect(found.link.string != link.string)
    }

    @Test func resolveDoesNotTrustAReusedRowID() throws {
        let b = try mailbox(); defer { b.cleanup() }
        // Row 18 holds "Alone" now; a link made when row 18 held another message must not open "Alone".
        #expect(throws: Mail42Error.self) {
            try self.open(b).resolve(MessageLink(rowid: 18, messageID: "someone-else@example.com"))
        }
        // …but when that other message exists elsewhere, it is found.
        let other = try mailbox(); defer { other.cleanup() }
        let found = try open(other).resolve(MessageLink(rowid: 18, messageID: "r2@example.com"))
        #expect(found.row.id == 21)
    }

    @Test func resolveSkipsDeletedCopiesAndPrefersTheRequestedMailbox() throws {
        let b = try mailbox(); defer { b.cleanup() }
        for (id, box, age) in [(30, 1, 500), (31, 3, 400), (32, 3, 10)] as [(Int64, Int64, Int64)] {
            try b.addMessage(.init(rowid: id, subject: "Copy", senderAddress: "z@example.com", mailboxID: box,
                                   dateReceived: now - age, messageIDHeader: "<copy@example.com>"))
        }
        try b.setDeleted(rowid: 32, true)                                                   // the newest is deleted
        let mail = try open(b)
        let link = MessageLink(rowid: 999, messageID: "copy@example.com")
        #expect(try mail.resolve(link).row.id == 31)                                       // newest not deleted
        #expect(try mail.resolve(link, preferMailbox: 1).row.id == 30)                     // the copy in the Inbox
        #expect(try mail.resolve(link, preferMailbox: 2).row.id == 31)                     // none there: newest
    }

    @Test func resolveReportsAMessageThatIsGone() throws {
        let b = try mailbox(); defer { b.cleanup() }
        do {
            _ = try open(b).resolve(MessageLink(rowid: 500, messageID: "nowhere@example.com"))
            Issue.record("should not resolve")
        } catch Mail42Error.notFound { }
        do {
            _ = try open(b).resolve(MessageLink(rowid: 500, messageID: nil))
            Issue.record("should not resolve")
        } catch Mail42Error.notFound { }
    }

    // MARK: - Conversations

    @Test func aConversationIsOneRowWithItsWholeSize() throws {
        let b = try mailbox(); defer { b.cleanup() }
        let rows = try open(b).listConversations(EnvelopeListOptions(limit: 10))
        #expect(rows.map(\.newest.row.id) == [21, 19, 18])             // 22 is in Sent, so the Inbox shows 21 for it
        let thread = try #require(rows.first)
        #expect(thread.count == 3)                                     // 20, 21 and the Sent reply 22
        #expect(thread.participants == ["Yan", "Bo", "Ana"])           // newest first, Sent included
        #expect(rows[1].count == 1 && rows[1].participants == ["Cy"])
        #expect(rows[2].count == 1 && rows[2].participants == ["Di"])  // no conversation id: its own thread
    }

    @Test func conversationsPageWithoutRepeatingOne() throws {
        let b = try mailbox(); defer { b.cleanup() }
        let mail = try open(b)
        let first = try mail.listConversations(EnvelopeListOptions(limit: 1))
        #expect(first.map(\.newest.row.id) == [21])
        // 20 is older than the cursor but belongs to conversation 7, which page one already showed.
        let second = try mail.listConversations(EnvelopeListOptions(beforeID: 21, limit: 1))
        #expect(second.map(\.newest.row.id) == [19])
        let rest = try mail.listConversations(EnvelopeListOptions(beforeID: 19, limit: 5))
        #expect(rest.map(\.newest.row.id) == [18])
        #expect(try mail.listConversations(EnvelopeListOptions(beforeID: 18, limit: 5)).isEmpty)
    }

    @Test func conversationsHonourTheViewAndLimit() throws {
        let b = try mailbox(); defer { b.cleanup() }
        let mail = try open(b)
        #expect(try mail.listConversations(EnvelopeListOptions(mailbox: .named("sent"), limit: 5)).map(\.newest.row.id) == [22])
        #expect(try mail.listConversations(EnvelopeListOptions(limit: 0)).isEmpty)
        #expect(try mail.listConversations(EnvelopeListOptions(unreadOnly: true, limit: 10)).count == 3)
    }

    @Test func aThreadSpansEveryMailboxIncludingSent() throws {
        let b = try mailbox(); defer { b.cleanup() }
        let thread = try open(b).thread(containing: 21)
        #expect(thread.map(\.row.id) == [20, 21, 22])
        #expect(thread.map(\.mailboxRole) == ["inbox", "inbox", "sent"])
    }
}
