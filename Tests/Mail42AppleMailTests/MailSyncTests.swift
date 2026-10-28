import CryptoKit
import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct MailSyncTests {

    // 2026-10-28 12:00:00 UTC: the clock every test sync runs at.
    private static let now = Date(timeIntervalSince1970: 1_793_188_800)
    private static let day: Int64 = 86_400
    private var nowSeconds: Int64 { Int64(Self.now.timeIntervalSince1970) }

    /// A synthetic Apple Mail store plus a place for mail.db and the trace file.
    private final class Harness {
        let mail: EnvelopeIndexBuilder
        let storeURL: URL
        let traceURL: URL
        private let folder: URL

        init(schemaOmitting: Set<String> = [], wal: Bool = false) throws {
            mail = try EnvelopeIndexBuilder(schemaOmitting: schemaOmitting, wal: wal)
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("mail42-sync-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            storeURL = folder.appendingPathComponent("mail.db")
            traceURL = folder.appendingPathComponent("trace.jsonl")
        }

        func sync(full: Bool = false) throws -> SyncResult {
            try MailSync(storeURL: storeURL, library: mail.library, traceFile: traceURL, now: { MailSyncTests.now })
                .run(full: full)
        }

        func store() throws -> MailStore { try MailStore(path: storeURL) }

        func cleanup() {
            mail.cleanup()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func inbox(_ h: Harness) throws {
        try h.mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 3, unread: 2)
        try h.mail.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["Sent Messages"]), total: 0, unread: 0)
    }

    /// Three real messages: plain (10), hostile HTML with an inline image (11), one with an attachment (12).
    private func seedThree(_ h: Harness) throws {
        try inbox(h)
        let recent = nowSeconds - 3_600
        try h.mail.addMessage(.init(rowid: 10, subject: "mail42-qa plain zebrafish", senderAddress: "qa-plain@example.com",
                                    senderName: "QA Plain", mailboxID: 1, dateReceived: recent, messageIDHeader: "<plain-1@example.com>"))
        try h.mail.addMessage(.init(rowid: 11, subject: "mail42-qa html hostile", senderAddress: "qa-html@example.com",
                                    senderName: "QA Html", mailboxID: 1, dateReceived: recent - 60, read: true,
                                    messageIDHeader: "<html-1@example.com>"))
        try h.mail.addMessage(.init(rowid: 12, subject: "mail42-qa attachment", senderAddress: "qa-attach@example.com",
                                    senderName: "QA Attach", mailboxID: 1, dateReceived: recent - 120, flagged: true,
                                    messageIDHeader: "<attach-1@example.com>"))
        try h.mail.addRecipient(messageRowid: 10, address: "yan@example.com", name: "Yan", type: 0, position: 0)
        try h.mail.addRecipient(messageRowid: 11, address: "yan@example.com", name: "Yan", type: 0, position: 0)
        try h.mail.addRecipient(messageRowid: 11, address: "bo@example.com", name: "Bo", type: 1, position: 0)
        try h.mail.writeEmlx(rowid: 10, data: MailFixtures.emlx(MailFixtures.plain()))
        try h.mail.writeEmlx(rowid: 11, data: MailFixtures.emlx(MailFixtures.htmlWithInlineImage()))
        try h.mail.writeEmlx(rowid: 12, data: MailFixtures.emlx(MailFixtures.withAttachment()))
    }

    private func sha(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: - First and repeated syncs

    @Test func theFirstSyncIndexesEveryMessage() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        try h.mail.writeAccountsMap(email: "yan@example.com")

        let result = try h.sync()
        #expect(result.added == 3 && result.updated == 0 && result.removed == 0)

        let store = try h.store()
        #expect(try store.envelopeCount() == 3)
        let plain = try #require(try store.envelope(id: 10))
        #expect(plain.subject == "mail42-qa plain zebrafish")
        #expect(plain.fromAddr == "qa-plain@example.com" && plain.fromName == "QA Plain")
        #expect(plain.messageID == "<plain-1@example.com>")
        #expect(plain.mailboxID == 1 && !plain.isRead && !plain.isFlagged)
        #expect(plain.emlxPath?.hasSuffix("/10.emlx") == true)
        #expect(plain.snippet?.contains("quokkabody") == true)         // from the body: no Apple summary
        #expect(plain.hasAttachments == false)

        let withAttachment = try #require(try store.envelope(id: 12))
        #expect(withAttachment.hasAttachments && withAttachment.isFlagged)
        #expect(try store.attachments(of: 12).map(\.filename) == ["report.pdf"])
        #expect(try store.attachments(of: 12).first?.mime == "application/pdf")
        #expect(try store.attachments(of: 12).first?.size == Int64(MailFixtures.attachmentBytes.count))

        #expect(try store.envelope(id: 11)?.isRead == true)
        #expect(try Set(store.recipients(of: 11).map { "\($0.kind):\($0.addr)" }) == ["to:yan@example.com", "cc:bo@example.com"])
    }

    @Test func accountsMailboxesAndStateAreRecorded() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        try h.mail.writeAccountsMap(email: "yan@example.com")
        _ = try h.sync()
        let store = try h.store()

        let account = try #require(try store.accounts().first)
        #expect(account.id == EnvelopeIndexBuilder.accountUUID)
        #expect(account.email == "yan@example.com" && account.name == "yan@example.com" && account.kind == "imap")
        let boxes = try store.mailboxes()
        #expect(boxes.map(\.name).sorted() == ["INBOX", "Sent Messages"])
        let inbox = try #require(boxes.first { $0.id == 1 })
        #expect(inbox.role == "inbox" && inbox.total == 3 && inbox.unread == 2)
        #expect(boxes.first { $0.id == 2 }?.role == "sent")

        #expect(try store.getState(MailStore.StateKey.lastRowID) == "12")
        #expect(try store.getState(MailStore.StateKey.fdaState) == "granted")
        #expect(try store.getState(MailStore.StateKey.lastSyncAt) == "2026-10-28T12:00:00Z")
    }

    @Test func anAccountWithoutAnAddressIsNamedByItsUUID() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)                            // no AccountsMap.plist written
        _ = try h.sync()
        let account = try #require(try h.store().accounts().first)
        #expect(account.email == nil && account.name == EnvelopeIndexBuilder.accountUUID)
    }

    @Test func aSecondSyncWithNothingNewChangesNothing() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        _ = try h.sync()
        let again = try h.sync()
        #expect(again.added == 0 && again.updated == 0 && again.removed == 0)
        #expect(try h.store().envelopeCount() == 3)
    }

    @Test func eachSyncWritesATraceLine() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        _ = try h.sync()
        let lines = try String(contentsOf: h.traceURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(entry["src"] as? String == "sync" && entry["event"] as? String == "sync-ok")
        #expect(entry["added"] as? Int == 3 && entry["updated"] as? Int == 0 && entry["removed"] as? Int == 0)
        #expect(entry["ms"] is Int)
    }

    // MARK: - Changes in Mail

    @Test func readFlagAndMailboxChangesAreUpdates() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        _ = try h.sync()

        try h.mail.setRead(rowid: 10, true)
        #expect(try h.sync().updated == 1)
        #expect(try h.store().envelope(id: 10)?.isRead == true)

        try h.mail.setFlagged(rowid: 10, true)
        try h.mail.moveMessage(rowid: 11, toMailbox: 2)
        let result = try h.sync()
        #expect(result.updated == 2 && result.added == 0 && result.removed == 0)
        #expect(try h.store().envelope(id: 10)?.isFlagged == true)
        #expect(try h.store().envelope(id: 11)?.mailboxID == 2)
    }

    @Test func aDeletedOrRemovedMessageLeavesTheIndex() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        _ = try h.sync()

        try h.mail.setDeleted(rowid: 12, true)       // Mail's "deleted" flag
        try h.mail.deleteMessage(rowid: 11)          // gone from the index altogether
        let result = try h.sync()
        #expect(result.removed == 2 && result.added == 0)

        let store = try h.store()
        #expect(try store.knownIDs() == [10])
        #expect(try store.recipients(of: 11).isEmpty)
        #expect(try store.attachments(of: 12).isEmpty)
        #expect(try store.searchIDs(match: "Roadmap").isEmpty)           // 11's body is gone from full-text search
    }

    @Test func aMessageThatIsUndeletedComesBack() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        try h.mail.setDeleted(rowid: 12, true)
        #expect(try h.sync().added == 2)
        try h.mail.setDeleted(rowid: 12, false)
        let result = try h.sync()
        #expect(result.added == 1)
        #expect(try h.store().envelope(id: 12) != nil)
    }

    // MARK: - Full-text index

    @Test func bodyOnlyWordsAreSearchable() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        _ = try h.sync()
        let store = try h.store()
        #expect(try store.searchIDs(match: "quokkabody") == [10])                 // plain text body
        #expect(try store.searchIDs(match: "Roadmap") == [11])                    // HTML body converted to text
        #expect(try store.searchIDs(match: "zebrafish") == [10])                  // subject
        #expect(try store.searchIDs(match: "from_text:\"qa-attach\"") == [12])      // a hyphenated term must be quoted
        #expect(try store.searchIDs(match: "alert").isEmpty)                      // script content never indexed
        #expect(try store.searchIDs(match: "SCRIPT").isEmpty)
    }

    // MARK: - Window

    @Test func messagesOlderThanTheWindowAreNotIndexed() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        try h.mail.addMessage(.init(rowid: 1, subject: "recent", senderAddress: "a@b.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 10 * Self.day))
        try h.mail.addMessage(.init(rowid: 2, subject: "89 days", senderAddress: "a@b.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 89 * Self.day))
        try h.mail.addMessage(.init(rowid: 3, subject: "91 days", senderAddress: "a@b.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 91 * Self.day))
        let result = try h.sync()
        #expect(result.added == 2)
        #expect(try h.store().knownIDs() == [1, 2])
    }

    @Test func widenAndShrinkTheWindow() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        try h.mail.addMessage(.init(rowid: 1, subject: "recent", senderAddress: "a@b.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 5 * Self.day))
        try h.mail.addMessage(.init(rowid: 2, subject: "old", senderAddress: "a@b.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 200 * Self.day))
        _ = try h.sync()
        #expect(try h.store().knownIDs() == [1])

        try h.store().setState(MailStore.StateKey.windowDays, "0")               // all mail
        #expect(try h.sync(full: true).added == 1)
        #expect(try h.store().knownIDs() == [1, 2])

        try h.store().setState(MailStore.StateKey.windowDays, "30")              // back to a month
        let result = try h.sync()
        #expect(result.removed == 1)
        #expect(try h.store().knownIDs() == [1])
    }

    // MARK: - Gmail duplicates

    @Test func gmailLabelCopiesCollapseToTheNonAllMailCopy() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]))
        try h.mail.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["[Gmail]", "All Mail"]))
        let recent = nowSeconds - 100
        try h.mail.addMessage(.init(rowid: 21, subject: "Dup", senderAddress: "a@b.com", mailboxID: 2,
                                    dateReceived: recent, messageIDHeader: "<dup@gmail.com>"))   // lower ROWID, but All Mail
        try h.mail.addMessage(.init(rowid: 30, subject: "Dup", senderAddress: "a@b.com", mailboxID: 1,
                                    dateReceived: recent, messageIDHeader: "<dup@gmail.com>"))
        let result = try h.sync()
        #expect(result.added == 1)
        let store = try h.store()
        #expect(try store.knownIDs() == [30])
        #expect(try store.envelope(id: 30)?.mailboxID == 1)
        #expect(try store.mailboxes().first { $0.id == 2 }?.role == "archive")

        // When the label copy goes away, the All Mail copy takes over.
        try h.mail.deleteMessage(rowid: 30)
        let after = try h.sync()
        #expect(after.removed == 1 && after.added == 1)
        #expect(try store.knownIDs() == [21])
    }

    @Test func aMessageOnlyInAllMailIsKept() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.mail.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["[Gmail]", "All Mail"]))
        try h.mail.addMessage(.init(rowid: 5, subject: "Only", senderAddress: "a@b.com", mailboxID: 2,
                                    dateReceived: nowSeconds - 100, messageIDHeader: "<only@gmail.com>"))
        #expect(try h.sync().added == 1)
    }

    @Test func twoUnrelatedMessagesWithoutAMessageIDAreBothKept() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        for rowid in [Int64(1), 2] {
            try h.mail.addMessage(.init(rowid: rowid, subject: "same", senderAddress: "a@b.com", mailboxID: 1,
                                        dateReceived: nowSeconds - 100))
        }
        #expect(try h.sync().added == 2)
    }

    // MARK: - Bodies that aren't on disk, and optional columns

    @Test func aMessageWithoutAFileIsIndexedFromItsMetadata() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        try h.mail.addMessage(.init(rowid: 9, subject: "Exchange only xylophone", senderAddress: "ex@example.com",
                                    mailboxID: 1, dateReceived: nowSeconds - 100, summary: "Apple's summary line"))
        #expect(try h.sync().added == 1)
        let store = try h.store()
        let row = try #require(try store.envelope(id: 9))
        #expect(row.emlxPath == nil)
        #expect(row.snippet == "Apple's summary line")
        #expect(try store.searchIDs(match: "xylophone") == [9])
    }

    @Test func aCorruptFileDoesNotStopTheSync() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        try h.mail.writeEmlx(rowid: 10, data: Data("garbage\nnot an emlx".utf8))
        let result = try h.sync()
        #expect(result.added == 3)
        #expect(try h.store().envelope(id: 10)?.emlxPath == nil)
    }

    @Test func aPartialMessageGetsItsAttachmentFromMailsCache() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        try h.mail.addMessage(.init(rowid: 40, subject: "Partial", senderAddress: "p@example.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 100))
        try h.mail.writeEmlx(rowid: 40, data: MailFixtures.emlx(MailFixtures.partialWithAttachment()), partial: true)
        try h.mail.writeAttachmentCache(rowid: 40, partID: "2", filename: "report.pdf", data: MailFixtures.attachmentBytes)
        _ = try h.sync()
        let store = try h.store()
        #expect(try store.envelope(id: 40)?.hasAttachments == true)
        #expect(try store.attachments(of: 40).first?.size == Int64(MailFixtures.attachmentBytes.count))
    }

    @Test func worksWhenTheOptionalColumnsAreAbsent() throws {
        let h = try Harness(schemaOmitting: ["messages.summary", "messages.date_sent", "messages.global_message_id"])
        defer { h.cleanup() }
        try seedThree(h)
        #expect(try h.sync().added == 3)
        let store = try h.store()
        let plain = try #require(try store.envelope(id: 10))
        #expect(plain.messageID == "<plain-1@example.com>")             // from the .emlx header
        #expect(plain.dateSent == plain.dateReceived)                   // no date_sent: falls back
        #expect(plain.snippet?.contains("quokkabody") == true)          // no summary: from the body
    }

    // MARK: - Resilience

    @Test func reusedRowIdsTriggerAFullResync() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        try h.mail.addMessage(.init(rowid: 10, subject: "Before", senderAddress: "a@b.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 100, messageIDHeader: "<one@x>"))
        _ = try h.sync()

        // Mail rebuilt its index: ROWID 10 now holds a different message.
        try h.mail.deleteMessage(rowid: 10)
        try h.mail.addMessage(.init(rowid: 10, subject: "After", senderAddress: "c@d.com", mailboxID: 1,
                                    dateReceived: nowSeconds - 50, messageIDHeader: "<two@x>"))
        _ = try h.sync()
        let row = try #require(try h.store().envelope(id: 10))
        #expect(row.subject == "After" && row.messageID == "<two@x>" && row.fromAddr == "c@d.com")
    }

    @Test func aFullSyncReindexesWithoutDoubleCounting() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        _ = try h.sync()
        let full = try h.sync(full: true)
        #expect(full.added == 0 && full.updated == 0 && full.removed == 0)
        #expect(try h.store().envelopeCount() == 3)
        #expect(try h.store().searchIDs(match: "quokkabody") == [10])
    }

    @Test func largeMailboxesAreIndexedInBatches() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        let base = nowSeconds - 1_000
        try h.mail.inTransaction {
            for rowid in Int64(1)...1_250 {
                try h.mail.addMessage(.init(rowid: rowid, subject: "Message \(rowid)", senderAddress: "a@b.com",
                                            mailboxID: 1, dateReceived: base + rowid))
            }
        }
        let result = try h.sync()
        #expect(result.added == 1_250)
        #expect(try h.store().envelopeCount() == 1_250)
        #expect(try h.store().getState(MailStore.StateKey.lastRowID) == "1250")
    }

    // MARK: - Progress for the Mail widget

    @Test func aSyncPublishesItsProgressAndEndsIdle() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try inbox(h)
        let base = nowSeconds - 1_000
        try h.mail.inTransaction {
            for rowid in Int64(1)...1_250 {
                try h.mail.addMessage(.init(rowid: rowid, subject: "Message \(rowid)", senderAddress: "a@b.com",
                                            mailboxID: 1, dateReceived: base + rowid))
            }
        }
        let statusURL = h.storeURL.deletingLastPathComponent().appendingPathComponent("sync-status.json")
        let sync = MailSync(storeURL: h.storeURL, library: h.mail.library, traceFile: nil, statusFile: statusURL,
                            now: { MailSyncTests.now })
        var seen: [SyncStatus] = []
        sync.onStatus = { seen.append($0) }

        _ = try sync.run()

        // reading, then the total, then one update per 500-message batch.
        #expect(seen.map(\.phase) == ["reading", "indexing", "indexing", "indexing", "indexing"])
        #expect(seen.map(\.processed) == [0, 0, 500, 1_000, 1_250])
        #expect(seen.last?.total == 1_250)
        #expect(seen.allSatisfy { $0.state == .running && $0.pid == getpid() })
        #expect(seen.last?.fraction == 1)
        // And the file ends as idle, so the widget stops showing "loading".
        let final = try #require(SyncStatus.read(from: statusURL))
        #expect(final.state == .idle)
        #expect(final.finished == MailSyncTests.now)
        #expect(!final.isRunning())
    }

    @Test func aFailedSyncLeavesTheStatusIdle() throws {
        let h = try Harness(schemaOmitting: ["messages.size"])
        defer { h.cleanup() }
        let statusURL = h.storeURL.deletingLastPathComponent().appendingPathComponent("sync-status.json")
        let sync = MailSync(storeURL: h.storeURL, library: h.mail.library, traceFile: nil, statusFile: statusURL,
                            now: { MailSyncTests.now })

        #expect(throws: Mail42Error.self) { try sync.run() }

        #expect(SyncStatus.read(from: statusURL)?.state == .idle)
    }

    @Test func seesMailThatSitsOnlyInTheWAL() throws {
        let h = try Harness(wal: true)
        defer { h.cleanup() }
        try seedThree(h)
        #expect(try h.sync().added == 3)
    }

    // MARK: - Failure leaves mail.db alone

    @Test func anUnsupportedIndexFailsWithoutTouchingTheStore() throws {
        let h = try Harness(schemaOmitting: ["messages.size"])
        defer { h.cleanup() }
        let store = try h.store()                                  // an existing store with data
        try store.upsertEnvelope(
            EnvelopeRow(id: 1, messageID: nil, conversationID: 0, mailboxID: 1, subject: "keep me", fromName: nil,
                        fromAddr: nil, dateReceived: 1, dateSent: 1, snippet: nil, isRead: false, isFlagged: false,
                        hasAttachments: false, size: 0, emlxPath: nil), recipients: [], attachments: [], bodyText: "")
        let before = (sha(h.storeURL), sha(URL(fileURLWithPath: h.storeURL.path + "-wal")))

        #expect(throws: Mail42Error.schemaUnsupported(table: "messages", column: "size")) { try h.sync() }

        #expect((sha(h.storeURL), sha(URL(fileURLWithPath: h.storeURL.path + "-wal"))) == before)
        #expect(try store.knownIDs() == [1])
        let trace = try String(contentsOf: h.traceURL, encoding: .utf8)
        #expect(trace.contains("sync-failed") && trace.contains("schema_unsupported"))
    }

    @Test func deniedAccessFailsWithoutCreatingTheStore() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try seedThree(h)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.mail.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.mail.library.path) }
        guard getuid() != 0 else { return }

        #expect(throws: Mail42Error.fdaDenied) { try h.sync() }
        #expect(!FileManager.default.fileExists(atPath: h.storeURL.path))        // a first run leaves no database behind
        #expect(try String(contentsOf: h.traceURL, encoding: .utf8).contains("fda_denied"))
    }

    @Test func noMailAtAllIsReported() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-none-\(UUID().uuidString)")
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-s-\(UUID().uuidString)/mail.db")
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let sync = MailSync(storeURL: storeURL, library: missing, traceFile: nil, now: { MailSyncTests.now })
        #expect(throws: Mail42Error.noMailData) { try sync.run() }
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test func neverWritesToAppleMailsFiles() throws {
        let h = try Harness(wal: true)
        defer { h.cleanup() }
        try seedThree(h)
        let index = h.mail.envelopeIndexURL
        let wal = URL(fileURLWithPath: index.path + "-wal")
        let before = (sha(index), sha(wal))
        let emlx = try #require(EmlxLocator.emlxURL(
            rowid: 10, mailboxURL: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), mailRoot: h.mail.mailRoot))
        let emlxBefore = sha(emlx)

        _ = try h.sync()
        _ = try h.sync(full: true)

        #expect((sha(index), sha(wal)) == before)
        #expect(sha(emlx) == emlxBefore)
    }

    // MARK: - Roles

    @Test(arguments: [
        ("INBOX", "inbox"), ("Inbox", "inbox"), ("Sent Messages", "sent"), ("Sent Items", "sent"),
        ("[Gmail]/Sent Mail", "sent"), ("Drafts", "drafts"), ("[Gmail]/Drafts", "drafts"), ("Archive", "archive"),
        ("[Gmail]/All Mail", "archive"), ("Trash", "trash"), ("Deleted Messages", "trash"), ("[Gmail]/Trash", "trash"),
        ("Junk", "junk"), ("[Gmail]/Spam", "junk"), ("Work42", "other"), ("Clients/Acme", "other"),
    ])
    func classifiesMailboxRoles(name: String, role: String) {
        #expect(MailboxRole.classify(name: name) == role)
    }
}
