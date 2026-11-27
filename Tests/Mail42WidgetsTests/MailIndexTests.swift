// MailIndexTests.swift — the reader that replaced `mail42 mailbox list` and `mail42 envelope list`, run against a synthetic index
// built with Apple's real column names (WOR-900).

import Foundation
import Mail42TestSupport
import Testing
@testable import Mail42MailWidget

private let account = EnvelopeIndexBuilder.accountUUID
private func url(_ path: String...) -> String { EnvelopeIndexBuilder.mailboxURL(path) }

private func message(
    _ rowid: Int64, _ subject: String, mailbox: Int64 = 1, at date: Int64, from sender: String = "ana@example.com",
    name: String? = "Ana", read: Bool = false, flagged: Bool = false, conversation: Int64 = 0, summary: String? = nil,
    header: String? = nil
) -> EnvelopeIndexBuilder.Message {
    .init(rowid: rowid, subject: subject, senderAddress: sender, senderName: name, mailboxID: mailbox, dateReceived: date,
          read: read, flagged: flagged, conversationID: conversation, summary: summary, messageIDHeader: header)
}

private func open(_ builder: EnvelopeIndexBuilder, accounts: [String: MailIndexAccountInfo] = [:]) throws -> MailIndex {
    try MailIndex(database: builder.envelopeIndexURL, accounts: accounts)
}

@Suite("Mail index")
struct MailIndexTests {

    @Test("mailboxes come with Apple's counters, grouped by account, the Inbox first")
    func mailboxTree() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 3, url: url("Sent Messages"), total: 5, unread: 0)
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 40, unread: 7)
        try builder.addMailbox(id: 2, url: url("Archive"), total: 900, unread: 0)
        let index = try open(builder, accounts: [account.uppercased(): MailIndexAccountInfo(name: "Work", email: "me@work.com")])

        let trees = index.accountTrees()
        #expect(trees.count == 1)
        let tree = try #require(trees.first)
        #expect(tree.account.name == "Work" && tree.account.email == "me@work.com" && tree.account.kind == "imap")
        #expect(tree.mailboxes.map(\.name) == ["INBOX", "Archive", "Sent Messages"])
        #expect(tree.mailboxes.first?.unread == 7 && tree.mailboxes.first?.total == 40 && tree.mailboxes.first?.role == "inbox")
        #expect(index.mailboxIDs(matching: "inbox") == [1] && index.mailboxIDs(matching: "Sent Messages") == [3])
        #expect(try index.mailboxSignature() == "1:40:7,2:900:0,3:5:0")
    }

    @Test("an account with no known name is shown by its id")
    func unknownAccount() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"))
        let tree = try #require(try open(builder).accountTrees().first)
        #expect(tree.account.name == account && tree.account.email == nil)
    }

    @Test("all inboxes list newest first, with sender, recipients, attachments and a link that carries the Message-ID")
    func listAllInboxes() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 3, unread: 2)
        try builder.addMailbox(id: 2, url: url("Archive"), total: 1)
        try builder.addMessage(message(10, "Old", at: 100))
        try builder.addMessage(message(11, "Newest", at: 300, summary: "  Hello\n there  ", header: "<abc@host>"))
        try builder.addMessage(message(12, "Middle", at: 200, read: true))
        try builder.addMessage(message(13, "Not in an inbox", mailbox: 2, at: 400))
        try builder.addRecipient(messageRowid: 11, address: "me@work.com", name: "Me", type: 0, position: 0)
        try builder.addRecipient(messageRowid: 11, address: "bo@example.com", name: nil, type: 1, position: 1)
        try builder.addAttachment(messageRowid: 11, attachmentID: "1.2", name: "plan.pdf")

        let list = try open(builder).listEnvelopes(MailIndexListOptions())
        #expect(list.map(\.subject) == ["Newest", "Middle", "Old"])
        let newest = try #require(list.first)
        #expect(newest.from.display == "Ana" && newest.from.addr == "ana@example.com")
        #expect(newest.to.map(\.addr) == ["me@work.com"] && newest.cc.map(\.addr) == ["bo@example.com"])
        #expect(newest.hasAttachments && !list[1].hasAttachments)
        #expect(newest.snippet == "Hello there")
        #expect(newest.link == "mail42://message/11?mid=abc%40host")
        #expect(newest.messageID == "<abc@host>" && newest.date == Date(timeIntervalSince1970: 300))
        #expect(newest.isRead == false && list[1].isRead == true)
        #expect(newest.mailbox.role == "inbox" && newest.conversationID == nil)
    }

    @Test("deleted messages and other mailboxes stay out; unread and flagged filters apply")
    func filters() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 4, unread: 2)
        try builder.addMessage(message(1, "Unread", at: 400))
        try builder.addMessage(message(2, "Read", at: 300, read: true))
        try builder.addMessage(message(3, "Flagged", at: 200, read: true, flagged: true))
        try builder.addMessage(message(4, "Deleted", at: 500))
        try builder.setDeleted(rowid: 4, true)
        let index = try open(builder)

        #expect(try index.listEnvelopes(.init()).map(\.subject) == ["Unread", "Read", "Flagged"])
        #expect(try index.listEnvelopes(.init(unreadOnly: true)).map(\.subject) == ["Unread"])
        #expect(try index.listEnvelopes(.init(mailbox: .flagged)).map(\.subject) == ["Flagged"])
        #expect(try index.listEnvelopes(.init(mailbox: .id(1), flaggedOnly: true)).map(\.subject) == ["Flagged"])
        #expect(try index.listEnvelopes(.init(limit: 2)).count == 2)
    }

    @Test("a Gmail inbox is the messages labelled Inbox, shown under Inbox though stored in All Mail")
    func gmailLabels() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 1)
        try builder.addMailbox(id: 2, url: url("[Gmail]", "All Mail"), total: 2)
        try builder.addMessage(message(1, "Labelled", mailbox: 2, at: 200))
        try builder.addMessage(message(2, "Archived only", mailbox: 2, at: 300))
        try builder.addLabel(messageRowid: 1, mailboxID: 1)
        let list = try open(builder).listEnvelopes(.init())
        #expect(list.map(\.subject) == ["Labelled"])
        #expect(list.first?.mailbox.name == "INBOX", "shown under its Inbox label, not All Mail")
        #expect(try open(builder).listEnvelopes(.init(mailbox: .named("All Mail"))).map(\.subject) == ["Archived only", "Labelled"])
    }

    @Test("paging by the last id of a page gives the next, older page without repeats, ties included")
    func paging() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 5)
        for (rowid, date) in [(1, 100), (2, 200), (3, 300), (4, 300), (5, 400)] as [(Int64, Int64)] {
            try builder.addMessage(message(rowid, "m\(rowid)", at: date))
        }
        let index = try open(builder)
        let first = try index.listEnvelopes(.init(limit: 2))
        #expect(first.map(\.id) == [5, 4])
        let second = try index.listEnvelopes(.init(beforeID: first.last?.id, limit: 2))
        #expect(second.map(\.id) == [3, 2])
        let third = try index.listEnvelopes(.init(beforeID: second.last?.id, limit: 2))
        #expect(third.map(\.id) == [1])
        #expect(throws: MailIndexError.self) { _ = try index.listEnvelopes(.init(beforeID: 999)) }
    }

    @Test("conversations list one entry each, with the size of the whole conversation and who wrote in it")
    func conversations() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 4)
        try builder.addMessage(message(1, "Plan", at: 100, from: "ana@example.com", name: "Ana", conversation: 7))
        try builder.addMessage(message(2, "Re: Plan", at: 200, from: "bo@example.com", name: "Bo", conversation: 7))
        try builder.addMessage(message(3, "Re: Plan", at: 300, from: "ana@example.com", name: "Ana", conversation: 7))
        try builder.addMessage(message(4, "Alone", at: 250, from: "cy@example.com", name: nil))
        let index = try open(builder)

        let list = try index.listConversations(.init())
        #expect(list.map(\.id) == [3, 4])
        #expect(list[0].conversationCount == 3 && list[0].participants == ["Ana", "Bo"])
        #expect(list[1].conversationCount == 1 && list[1].participants == ["cy@example.com"])

        let next = try index.listConversations(.init(beforeID: 3))
        #expect(next.map(\.id) == [4], "the Plan conversation was shown above the cursor, so it is not repeated")
    }

    @Test("a page of conversations skips ones already shown, however many of their messages lie below the cursor")
    func conversationPagingPastAShownConversation() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 200)
        // 1000: the cursor, newest message of conversation 7 (already shown). 1…70: more of conversation 7 below it, more than one
        // scan batch (60). 100: conversation 9, the next thing to show.
        try builder.inTransaction {
            try builder.addMessage(message(1000, "Plan", at: 10_000, conversation: 7))
            for id in 1...70 { try builder.addMessage(message(Int64(id), "Re: Plan", at: 1_000 + Int64(id), conversation: 7)) }
            try builder.addMessage(message(100, "Other", at: 50, from: "cy@example.com", name: "Cy", conversation: 9))
        }
        let index = try open(builder)
        #expect(try index.listConversations(.init(limit: 1)).map(\.id) == [1000])
        let next = try index.listConversations(.init(beforeID: 1000, limit: 1))
        #expect(next.map(\.id) == [100], "scanning goes on past the shown conversation until an unseen one turns up")
        #expect(try index.listConversations(.init(beforeID: 100, limit: 1)).isEmpty)
    }

    @Test("many queries in flight while the connection is closed never crash; after the close they throw")
    func closingWhileQuerying() async throws {
        let builder = try EnvelopeIndexBuilder()
        defer { builder.cleanup() }
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 1)
        try builder.addMessage(message(1, "x", at: 100))
        let db = try MailSQLite(path: builder.envelopeIndexURL.path)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<300 {
                        do { _ = try db.scalarInt("SELECT COUNT(*) FROM messages") } catch let error as MailIndexError {
                            guard case .database = error else { Issue.record("unexpected \(error)"); return }
                        } catch { Issue.record("unexpected \(error)"); return }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000)
                db.close()
            }
        }
        db.close()
        #expect(throws: MailIndexError.self) { _ = try db.scalarInt("SELECT COUNT(*) FROM messages") }
        do { _ = try db.scalarInt("SELECT 1") } catch let error as MailIndexError {
            guard case .database = error else { Issue.record("was \(error)"); return }
        }
    }

    @Test("a thread is the whole conversation, oldest first, and a message with no conversation is its own thread")
    func threads() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"), total: 3)
        try builder.addMessage(message(1, "A", at: 100, conversation: 5))
        try builder.addMessage(message(2, "B", at: 200, conversation: 5))
        try builder.addMessage(message(3, "C", at: 300))
        let index = try open(builder)
        #expect(try index.thread(containing: 2).map(\.id) == [1, 2])
        #expect(try index.thread(containing: 3).map(\.id) == [3])
        #expect(try index.envelope(id: 1)?.subject == "A")
        #expect(try index.envelope(id: 99) == nil)
        #expect(throws: MailIndexError.self) { _ = try index.thread(containing: 99) }
    }

    @Test("an index missing a required column is refused, naming it; a missing optional column falls back")
    func schema() throws {
        let broken = try EnvelopeIndexBuilder(schemaOmitting: ["messages.conversation_id"])
        do {
            _ = try MailIndex(database: broken.envelopeIndexURL)
            Issue.record("a schema with no conversation_id opened")
        } catch let error as MailIndexError {
            #expect(error == .schemaUnsupported(table: "messages", column: "conversation_id"))
        }

        let plain = try EnvelopeIndexBuilder(schemaOmitting: ["messages.summary", "messages.global_message_id", "messages.date_sent"])
        try plain.addMailbox(id: 1, url: url("INBOX"), total: 1)
        try plain.addMessage(message(1, "No extras", at: 100))
        let list = try open(plain).listEnvelopes(.init())
        #expect(list.first?.subject == "No extras" && list.first?.snippet == nil && list.first?.messageID == nil)
    }

    @Test("a mailbox name that matches nothing is not found")
    func unknownMailbox() throws {
        let builder = try EnvelopeIndexBuilder()
        try builder.addMailbox(id: 1, url: url("INBOX"))
        #expect(throws: MailIndexError.self) { _ = try open(builder).listEnvelopes(.init(mailbox: .named("Nope"))) }
        #expect(try open(builder).listEnvelopes(.init(mailbox: .id(1))).isEmpty)
    }

    @Test("a mailbox url splits before it decodes, so an encoded slash stays in its name")
    func mailboxURL() {
        #expect(MailIndexMailboxURL.decode("imap://U1/R%26D%2FSent")?.pathComponents == ["R&D/Sent"])
        #expect(MailIndexMailboxURL.decode("imap://U1/R%26D/Sent")?.pathComponents == ["R&D", "Sent"])
        #expect(MailIndexMailboxURL.decode("imap://U1") == nil && MailIndexMailboxURL.decode("nonsense") == nil)
        #expect(MailIndexRole.classify(name: "[Gmail]/All Mail") == "archive" && MailIndexRole.classify(name: "Deleted Items") == "trash")
    }
}
