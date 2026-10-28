import CryptoKit
import Foundation
import Testing
@testable import Mail42Kit

@Suite struct MailStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mail42-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mail.db")
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    private func envelope(_ id: Int64, subject: String = "Hello", mailbox: Int64 = 1, read: Bool = false,
                          messageID: String? = nil) -> EnvelopeRow {
        EnvelopeRow(id: id, messageID: messageID, conversationID: 0, mailboxID: mailbox, subject: subject,
                    fromName: "Alice Chen", fromAddr: "alice@acme.com", dateReceived: 1_761_000_000,
                    dateSent: 1_760_999_000, snippet: "snippet", isRead: read, isFlagged: false,
                    hasAttachments: false, size: 10, emlxPath: nil)
    }

    // MARK: - Schema

    @Test func createsTheSchemaAndRecordsItsVersion() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        for table in ["accounts", "mailboxes", "envelopes", "recipients", "attachments", "sync_state"] {
            #expect(try !store.columns(of: table).isEmpty, "missing table \(table)")
        }
        #expect(try store.columns(of: "envelopes").isSuperset(of: [
            "id", "message_id", "conversation_id", "mailbox_id", "subject", "from_name", "from_addr",
            "date_received", "date_sent", "snippet", "is_read", "is_flagged", "has_attachments", "size", "emlx_path",
        ]))
        #expect(try store.getState(MailStore.StateKey.schemaVersion) == "1")
    }

    @Test func usesWALSoReadersAndTheWriterCoexist() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.upsertEnvelope(envelope(1), recipients: [], attachments: [], bodyText: "x")
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        // A second connection reads while the first is still open.
        let reader = try MailStore(path: url)
        #expect(try reader.envelopeCount() == 1)
    }

    @Test func addsMissingColumnsToAnOlderDatabaseWithoutLosingRows() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = try SQLiteConnection(path: url.path, readOnly: false)
        try old.execute("""
        CREATE TABLE envelopes (id INTEGER PRIMARY KEY, mailbox_id INTEGER NOT NULL, subject TEXT NOT NULL DEFAULT '',
            date_received INTEGER NOT NULL);
        INSERT INTO envelopes (id, mailbox_id, subject, date_received) VALUES (7, 1, 'kept', 1761000000);
        """)
        old.close()

        let store = try MailStore(path: url)
        #expect(try store.columns(of: "envelopes").isSuperset(of: ["snippet", "emlx_path", "is_read", "has_attachments"]))
        let row = try #require(try store.envelope(id: 7))
        #expect(row.subject == "kept")
        #expect(row.isRead == false)
        #expect(row.snippet == nil)
    }

    @Test func refusesADatabaseFromANewerMail42() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.setState(MailStore.StateKey.schemaVersion, "99")
        #expect(throws: Mail42Error.self) { try MailStore(path: url) }
    }

    // MARK: - State and window

    @Test func windowDefaultsTo90AndPersists() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        #expect(try store.windowDays() == 90)
        try store.setState(MailStore.StateKey.windowDays, "30")
        #expect(try MailStore(path: url).windowDays() == 30)
        try store.setState(MailStore.StateKey.windowDays, "0")
        #expect(try store.windowDays() == 0)
        try store.setState(MailStore.StateKey.windowDays, "junk")
        #expect(try store.windowDays() == 90)
        try store.setState(MailStore.StateKey.windowDays, "-5")
        #expect(try store.windowDays() == 90)
    }

    // MARK: - Envelopes

    @Test func upsertReplacesAMessageAndItsChildren() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        let to = RecipientRow(kind: "to", name: "Yan", addr: "yan@example.com", position: 0)
        let cc = RecipientRow(kind: "cc", name: nil, addr: "bo@example.com", position: 0)
        let pdf = AttachmentRow(part: "2", filename: "report.pdf", mime: "application/pdf", size: 31)
        try store.upsertEnvelope(envelope(1, subject: "First"), recipients: [to, cc], attachments: [pdf], bodyText: "alpha")
        #expect(try Set(store.recipients(of: 1).map(\.addr)) == ["yan@example.com", "bo@example.com"])
        #expect(try store.recipients(of: 1).count == 2)
        #expect(try store.attachments(of: 1) == [pdf])

        try store.upsertEnvelope(envelope(1, subject: "Second"), recipients: [to], attachments: [], bodyText: "beta")
        #expect(try store.envelopeCount() == 1)
        #expect(try store.envelope(id: 1)?.subject == "Second")
        #expect(try store.recipients(of: 1).map(\.kind) == ["to"])
        #expect(try store.attachments(of: 1).isEmpty)
        #expect(try store.searchIDs(match: "alpha").isEmpty)        // the old full-text row is gone
        #expect(try store.searchIDs(match: "beta") == [1])
    }

    @Test func roundTripsEveryEnvelopeField() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        let original = EnvelopeRow(
            id: 42, messageID: "<id@x>", conversationID: 9, mailboxID: 3, subject: "Q4 roadmap",
            fromName: "Alice Chen", fromAddr: "alice@acme.com", dateReceived: 1_761_000_000,
            dateSent: 1_760_990_000, snippet: "Here's the doc", isRead: true, isFlagged: true,
            hasAttachments: true, size: 123, emlxPath: "/x/42.emlx")
        try store.upsertEnvelope(original, recipients: [], attachments: [], bodyText: "")
        #expect(try store.envelope(id: 42) == original)
        #expect(try store.envelope(id: 43) == nil)
    }

    @Test func updateFlagsChangesOnlyThoseFields() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.upsertEnvelope(envelope(1, mailbox: 1), recipients: [], attachments: [], bodyText: "")
        try store.updateFlags([(id: 1, isRead: true, isFlagged: true, mailboxID: 2)])
        let row = try #require(try store.envelope(id: 1))
        #expect(row.isRead && row.isFlagged && row.mailboxID == 2)
        #expect(row.subject == "Hello")
        #expect(try store.knownEnvelopeStates()[1] == EnvelopeState(isRead: true, isFlagged: true, mailboxID: 2, messageID: nil))
    }

    @Test func deleteRemovesEnvelopesRecipientsAttachmentsAndSearchRows() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        for id in Int64(1)...3 {
            try store.upsertEnvelope(
                envelope(id), recipients: [RecipientRow(kind: "to", name: nil, addr: "a\(id)@x.com", position: 0)],
                attachments: [AttachmentRow(part: "1", filename: "f\(id)", mime: "", size: 1)], bodyText: "needle\(id)")
        }
        try store.deleteEnvelopes(ids: [1, 3])
        #expect(try store.knownIDs() == [2])
        #expect(try store.recipients(of: 1).isEmpty && store.recipients(of: 3).isEmpty)
        #expect(try store.attachments(of: 3).isEmpty)
        #expect(try store.searchIDs(match: "needle1").isEmpty)
        #expect(try store.searchIDs(match: "needle2") == [2])
        try store.deleteEnvelopes(ids: [])           // no-op
    }

    @Test func deletesInChunksForLargeSets() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.transaction {
            for id in Int64(1)...1200 { try store.upsertEnvelope(envelope(id), recipients: [], attachments: [], bodyText: "") }
        }
        try store.deleteEnvelopes(ids: Array(Int64(1)...1100))
        #expect(try store.envelopeCount() == 100)
    }

    // MARK: - Full-text search

    @Test func findsAWordThatOnlyAppearsInTheBody() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.upsertEnvelope(envelope(1, subject: "Plain"), recipients: [], attachments: [],
                                 bodyText: "The secret word is quokkabody.")
        try store.upsertEnvelope(envelope(2, subject: "Other"), recipients: [], attachments: [], bodyText: "nothing here")
        #expect(try store.searchIDs(match: "quokkabody") == [1])
        #expect(try store.searchIDs(match: "body_text:quokkabody") == [1])
        #expect(try store.searchIDs(match: "subject:quokkabody").isEmpty)
    }

    @Test func searchCoversSenderAndRecipientsAndIgnoresDiacritics() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.upsertEnvelope(
            EnvelopeRow(id: 1, messageID: nil, conversationID: 0, mailboxID: 1, subject: "Dîner", fromName: "José Núñez",
                        fromAddr: "jose@example.com", dateReceived: 1, dateSent: 1, snippet: nil, isRead: false,
                        isFlagged: false, hasAttachments: false, size: 0, emlxPath: nil),
            recipients: [RecipientRow(kind: "to", name: "Zoë", addr: "zoe@example.org", position: 0)],
            attachments: [], bodyText: "café au lait")
        #expect(try store.searchIDs(match: "from_text:jose") == [1])
        #expect(try store.searchIDs(match: "nunez") == [1])          // Núñez
        #expect(try store.searchIDs(match: "to_text:zoe") == [1])    // Zoë
        #expect(try store.searchIDs(match: "cafe") == [1])           // café
        #expect(try store.searchIDs(match: "diner") == [1])          // Dîner
    }

    @Test func ranksTheBetterMatchFirst() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.upsertEnvelope(envelope(1, subject: "misc"), recipients: [], attachments: [],
                                 bodyText: "invoice " + String(repeating: "filler ", count: 200))
        try store.upsertEnvelope(envelope(2, subject: "invoice"), recipients: [], attachments: [], bodyText: "invoice invoice invoice")
        #expect(try store.searchIDs(match: "invoice").first == 2)
    }

    // MARK: - Accounts and mailboxes

    @Test func upsertsAndPrunesAccountsAndMailboxes() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        try store.upsertAccounts([
            AccountRow(id: "A", name: "alice@x.com", email: "alice@x.com", kind: "imap"),
            AccountRow(id: "B", name: "B", email: nil, kind: "ews"),
        ])
        try store.upsertMailboxes([
            MailboxRow(id: 1, accountID: "A", name: "INBOX", role: "inbox", url: "imap://A/INBOX", total: 10, unread: 2),
            MailboxRow(id: 2, accountID: "B", name: "Inbox", role: "inbox", url: "ews://B/Inbox", total: 5, unread: 0),
        ])
        try store.upsertMailboxes([
            MailboxRow(id: 1, accountID: "A", name: "INBOX", role: "inbox", url: "imap://A/INBOX", total: 11, unread: 3),
        ])
        #expect(try store.mailboxes().first { $0.id == 1 }?.unread == 3)
        try store.pruneAccountsAndMailboxes(keepingMailboxes: [1], accounts: ["A"])
        #expect(try store.mailboxes().map(\.id) == [1])
        #expect(try store.accounts().map(\.id) == ["A"])
    }

    // MARK: - Transactions

    @Test func aFailedTransactionRollsBackEverything() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = try MailStore(path: url)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try store.transaction {
                try store.upsertEnvelope(envelope(1), recipients: [], attachments: [], bodyText: "x")
                throw Boom()
            }
        }
        #expect(try store.envelopeCount() == 0)
        #expect(try store.searchIDs(match: "x").isEmpty)
        // …and the store is still usable afterwards.
        try store.transaction { try store.upsertEnvelope(envelope(2), recipients: [], attachments: [], bodyText: "y") }
        #expect(try store.envelopeCount() == 1)
    }
}
