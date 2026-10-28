import Foundation
import Testing
@testable import Mail42Kit

@Suite struct StoreReadTests {

    private final class Fixture {
        let store: MailStore
        private let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-read-\(UUID().uuidString)", isDirectory: true)
            store = try MailStore(path: folder.appendingPathComponent("mail.db"))
            try store.upsertAccounts([
                AccountRow(id: "A", name: "yan@example.com", email: "yan@example.com", kind: "imap"),
                AccountRow(id: "B", name: "work@corp.com", email: "work@corp.com", kind: "ews"),
            ])
            try store.upsertMailboxes([
                MailboxRow(id: 1, accountID: "A", name: "INBOX", role: "inbox", url: "imap://A/INBOX", total: 5, unread: 2),
                MailboxRow(id: 2, accountID: "A", name: "Sent", role: "sent", url: "imap://A/Sent", total: 1, unread: 0),
                MailboxRow(id: 3, accountID: "A", name: "Archive", role: "archive", url: "imap://A/Archive", total: 0, unread: 0),
                MailboxRow(id: 4, accountID: "B", name: "Inbox", role: "inbox", url: "ews://B/Inbox", total: 1, unread: 1),
            ])
        }

        func add(_ id: Int64, date: Int64, mailbox: Int64 = 1, read: Bool = false, flagged: Bool = false,
                 conversation: Int64 = 0, subject: String? = nil) throws {
            try store.upsertEnvelope(
                EnvelopeRow(id: id, messageID: "<m\(id)@x>", conversationID: conversation, mailboxID: mailbox,
                            subject: subject ?? "Message \(id)", fromName: "F\(id)", fromAddr: "f\(id)@x.com", dateReceived: date,
                            dateSent: date, snippet: "snippet \(id)", isRead: read, isFlagged: flagged, hasAttachments: false,
                            size: 1, emlxPath: nil),
                recipients: [], attachments: [], bodyText: "")
        }

        func ids(_ options: EnvelopeListOptions) throws -> [Int64] { try store.listEnvelopes(options).map(\.row.id) }
        func cleanup() { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - envelope list

    @Test func listsNewestFirstAcrossAllInboxesByDefault() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.add(1, date: 100); try f.add(2, date: 300); try f.add(3, date: 200, mailbox: 4)
        try f.add(4, date: 400, mailbox: 2)            // Sent: not an inbox
        try f.add(5, date: 500, mailbox: 3)            // Archive: not an inbox
        #expect(try f.ids(.init()) == [2, 3, 1])
    }

    @Test func filtersByMailboxStateAndFlag() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.add(1, date: 100, read: true); try f.add(2, date: 200, flagged: true)
        try f.add(3, date: 300, mailbox: 2, flagged: true); try f.add(4, date: 400, mailbox: 4)

        #expect(try f.ids(.init(mailbox: .id(1))) == [2, 1])
        #expect(try f.ids(.init(mailbox: .id(2))) == [3])
        #expect(try f.ids(.init(mailbox: .id(999))) == [])
        #expect(try f.ids(.init(mailbox: .flagged)) == [3, 2])                    // any mailbox
        #expect(try f.ids(.init(mailbox: .allInboxes, unreadOnly: true)) == [4, 2])
        #expect(try f.ids(.init(mailbox: .allInboxes, flaggedOnly: true)) == [2])
        #expect(try f.ids(.init(mailbox: .named("sent"))) == [3])                 // role
        #expect(try f.ids(.init(mailbox: .named("Archive"))) == [])               // exists, empty
        #expect(try f.ids(.init(mailbox: .named("inbox"))) == [4, 2, 1])          // role: both accounts
    }

    @Test func anUnknownMailboxNameIsNotFound() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(throws: Mail42Error.notFound("a mailbox matching `nope`")) { try f.ids(.init(mailbox: .named("nope"))) }
    }

    @Test func pagesWithAKeysetCursorWithoutGapsOrRepeats() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // Ids 1…9, three of them sharing one timestamp: the cursor must tie-break on id.
        for id in Int64(1)...9 { try f.add(id, date: id <= 6 ? id * 100 : 600) }
        var seen: [Int64] = []
        var cursor: Int64?
        for _ in 0..<10 {
            let page = try f.ids(.init(beforeID: cursor, limit: 2))
            if page.isEmpty { break }
            seen += page
            cursor = page.last
        }
        #expect(seen == [9, 8, 7, 6, 5, 4, 3, 2, 1].sorted { a, b in
            // newest first, ties newest id first
            let da = a <= 6 ? a * 100 : 600, db = b <= 6 ? b * 100 : 600
            return da != db ? da > db : a > b
        })
        #expect(Set(seen).count == 9)
    }

    @Test func aBeforeCursorThatIsNotIndexedIsNotFound() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(throws: Mail42Error.self) { try f.ids(.init(beforeID: 12345)) }
    }

    @Test func limitIsRespected() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        for id in Int64(1)...5 { try f.add(id, date: id) }
        #expect(try f.ids(.init(limit: 3)).count == 3)
        #expect(try f.ids(.init(limit: 100)).count == 5)
    }

    @Test func recordsCarryAccountMailboxAndRecipients() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.upsertEnvelope(
            EnvelopeRow(id: 7, messageID: "<7@x>", conversationID: 0, mailboxID: 4, subject: "Hi", fromName: nil, fromAddr: "a@b.com",
                        dateReceived: 1, dateSent: 1, snippet: nil, isRead: false, isFlagged: false, hasAttachments: false,
                        size: 1, emlxPath: nil),
            recipients: [
                RecipientRow(kind: "cc", name: "Cee", addr: "c@x.com", position: 0),
                RecipientRow(kind: "to", name: "Tee", addr: "t2@x.com", position: 1),
                RecipientRow(kind: "to", name: nil, addr: "t1@x.com", position: 0),
                RecipientRow(kind: "bcc", name: nil, addr: "hidden@x.com", position: 0),
            ], attachments: [], bodyText: "")
        let record = try #require(try f.store.envelopeRecord(id: 7))
        #expect(record.accountID == "B" && record.accountName == "work@corp.com" && record.accountEmail == "work@corp.com")
        #expect(record.mailboxName == "Inbox" && record.mailboxRole == "inbox")
        #expect(record.to.map(\.addr) == ["t1@x.com", "t2@x.com"])            // by position
        #expect(record.cc.map(\.addr) == ["c@x.com"])
        #expect(record.row.fromName == nil)                                    // bcc is never shown
        #expect(try f.store.envelopeRecord(id: 8) == nil)
    }

    // MARK: - threads

    @Test func aThreadIsTheConversationOldestFirst() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.add(1, date: 300, conversation: 42); try f.add(2, date: 100, conversation: 42)
        try f.add(3, date: 200, conversation: 42); try f.add(4, date: 150, conversation: 7)
        #expect(try f.store.thread(containing: 3).map(\.row.id) == [2, 3, 1])
        #expect(try f.store.thread(containing: 4).map(\.row.id) == [4])
    }

    @Test func aMessageWithoutAConversationIsItsOwnThread() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.add(1, date: 100); try f.add(2, date: 200)             // both conversation 0
        #expect(try f.store.thread(containing: 1).map(\.row.id) == [1])
    }

    @Test func threadOfAnUnknownMessageIsNotFound() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(throws: Mail42Error.notFound("message 99")) { try f.store.thread(containing: 99) }
    }

    // MARK: - mailbox list

    @Test func accountsWithMailboxesPutTheInboxFirst() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let tree = try f.store.accountsWithMailboxes()
        #expect(tree.map(\.account.id) == ["B", "A"] || tree.map(\.account.id) == ["A", "B"])
        let a = try #require(tree.first { $0.account.id == "A" })
        #expect(a.mailboxes.map(\.name) == ["INBOX", "Archive", "Sent"])
        #expect(a.mailboxes.first?.unread == 2)
    }

    @Test func resolvesMailboxNamesRolesAndIds() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(Set(try f.store.mailboxIDs(matching: "inbox")) == [1, 4])
        #expect(try f.store.mailboxIDs(matching: "SENT") == [2])
        #expect(try f.store.mailboxIDs(matching: "3") == [3])
        #expect(try f.store.mailboxIDs(matching: "nothing").isEmpty)
    }
}
