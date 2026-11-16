import CryptoKit
import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct EnvelopeIndexSnapshotTests {

    private func seed(_ fixture: EnvelopeIndexBuilder) throws {
        try fixture.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 2, unread: 1)
        try fixture.addMessage(.init(
            rowid: 10, subject: "Q4 roadmap", senderAddress: "alice@acme.com", senderName: "Alice Chen",
            mailboxID: 1, dateReceived: 1_761_000_000, summary: "Here's the doc", messageIDHeader: "<a@x>"))
        try fixture.addMessage(.init(
            rowid: 11, subject: "Invoice", senderAddress: "billing@stripe.com", mailboxID: 1,
            dateReceived: 1_761_000_100, read: true, flagged: true))
        try fixture.addRecipient(messageRowid: 10, address: "yan@example.com", name: "Yan", type: 0, position: 0)
        try fixture.addAttachment(messageRowid: 11, attachmentID: "2", name: "invoice.pdf")
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func readsMessagesThroughTheCopy() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try seed(fixture)
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }

        var rows: [(Int64, String, String?)] = []
        try snapshot.connection.query(
            """
            SELECT m.ROWID, s.subject, a.comment FROM messages m
            JOIN subjects s ON m.subject = s.ROWID JOIN addresses a ON m.sender = a.ROWID ORDER BY m.ROWID
            """
        ) { row in rows.append((row.int(0), row.text(1) ?? "", row.text(2))) }
        #expect(rows.count == 2)
        #expect(rows[0].0 == 10 && rows[0].1 == "Q4 roadmap" && rows[0].2 == "Alice Chen")
        #expect(rows[1].1 == "Invoice")
    }

    @Test func seesChangesThatSitOnlyInTheWAL() throws {
        // Mail keeps recent writes in the -wal file until it checkpoints. A reader that ignores the WAL
        // (`immutable=1`, or copying only the main file) would see an empty database here.
        let fixture = try EnvelopeIndexBuilder(wal: true)
        defer { fixture.cleanup() }
        try seed(fixture)
        let walFile = URL(fileURLWithPath: fixture.envelopeIndexURL.path + "-wal")
        #expect(FileManager.default.fileExists(atPath: walFile.path))

        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        let count = try snapshot.connection.scalarInt("SELECT count(*) FROM messages")
        #expect(count == 2)
    }

    @Test func neverWritesToAppleMailsFiles() throws {
        let fixture = try EnvelopeIndexBuilder(wal: true)
        defer { fixture.cleanup() }
        try seed(fixture)
        let index = fixture.envelopeIndexURL
        let wal = URL(fileURLWithPath: index.path + "-wal")
        let before = (try sha256(of: index), try sha256(of: wal))

        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        try snapshot.validateSchema()
        _ = try snapshot.capabilities()
        _ = try snapshot.connection.scalarInt("SELECT count(*) FROM messages")
        snapshot.close()

        #expect((try sha256(of: index), try sha256(of: wal)) == before)
        // No stray files next to Apple's index either (the copy lives in a private temp folder).
        let siblings = try FileManager.default.contentsOfDirectory(atPath: index.deletingLastPathComponent().path)
        #expect(Set(siblings) == Set(["Envelope Index", "Envelope Index-wal", "Envelope Index-shm"]).intersection(siblings))
    }

    @Test func theConnectionIsReadOnly() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try seed(fixture)
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        #expect(throws: Mail42Error.self) { try snapshot.connection.execute("CREATE TABLE intruder (a)") }
        #expect(throws: Mail42Error.self) { try snapshot.connection.execute("DELETE FROM messages") }
    }

    // MARK: - In place, and the fallback copy (WOR-827)

    @Test func readsAppleMailsOwnFileWithoutCopyingIt() throws {
        let fixture = try EnvelopeIndexBuilder(wal: true)
        defer { fixture.cleanup() }
        try seed(fixture)
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        #expect(snapshot.readsInPlace)
        #expect(snapshot.connection.path == fixture.envelopeIndexURL.path)
        #expect(try snapshot.connection.scalarInt("SELECT count(*) FROM messages") == 2)
    }

    @Test func closingNeverRemovesAppleMailsFile() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try seed(fixture)
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        #expect(snapshot.readsInPlace)
        snapshot.close()
        #expect(FileManager.default.fileExists(atPath: fixture.envelopeIndexURL.path))
        snapshot.close()   // idempotent
        #expect(FileManager.default.fileExists(atPath: fixture.envelopeIndexURL.path))
    }

    @Test func anOpenConnectionSeesMailThatArrivesAfterItOpened() throws {
        // The reason a long-lived reader (the serve daemon) can't read a copy: Mail keeps writing.
        let fixture = try EnvelopeIndexBuilder(wal: true)
        defer { fixture.cleanup() }
        try seed(fixture)
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        guard snapshot.readsInPlace else { return }   // the fixture's WAL can't be shared on this machine: nothing to prove
        #expect(try snapshot.connection.scalarInt("SELECT count(*) FROM messages") == 2)

        try fixture.addMessage(.init(
            rowid: 12, subject: "Arrived later", senderAddress: "late@acme.com", mailboxID: 1, dateReceived: 1_761_000_200))
        #expect(try snapshot.connection.scalarInt("SELECT count(*) FROM messages") == 3)
    }

    @Test func theFallbackCopyIsRemovedOnClose() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try seed(fixture)
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot, inPlace: false)
        #expect(!snapshot.readsInPlace)
        let copyPath = snapshot.connection.path
        #expect(copyPath != fixture.envelopeIndexURL.path)
        #expect(FileManager.default.fileExists(atPath: copyPath))
        #expect(try snapshot.connection.scalarInt("SELECT count(*) FROM messages") == 2)
        snapshot.close()
        #expect(!FileManager.default.fileExists(atPath: copyPath))
        #expect(FileManager.default.fileExists(atPath: fixture.envelopeIndexURL.path))   // Apple's file stays
        snapshot.close()   // idempotent
    }

    @Test func staleCopiesOfDeadProcessesAreSweptAndLiveOnesKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String) throws {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let live = "mail42-\(getpid())-AAAA", dead = "mail42-2147480000-BBBB", deadToo = "mail42-2147480001-CCCC"
        for name in [live, dead, deadToo, "mail42-cli-DDDD", "mail42-0-EEEE", "other-2147480000-FFFF"] { try make(name) }

        let removed = EnvelopeIndexSnapshot.removeStaleCopies(in: root, isRunning: { $0 == getpid() })
        #expect(removed == 2)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        // Only the two dead processes' copies went: ours, names that aren't `mail42-<pid>-…`, and other folders stay.
        #expect(left == [live, "mail42-cli-DDDD", "mail42-0-EEEE", "other-2147480000-FFFF"])
    }

    @Test func sweepingAFolderThatDoesNotExistIsHarmless() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-nope-\(UUID().uuidString)")
        #expect(EnvelopeIndexSnapshot.removeStaleCopies(in: missing) == 0)
    }

    @Test func gmailLabelDuplicatesShareOneMessageID() throws {
        // Gmail keeps one copy in [Gmail]/All Mail and a labelled copy in INBOX: two rows, one Message-ID.
        // The sync (WOR-441) collapses them on that id, so the snapshot must expose it on both rows.
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try fixture.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]))
        try fixture.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["[Gmail]", "All Mail"]))
        for (rowid, mailbox) in [(Int64(20), Int64(1)), (21, 2)] {
            try fixture.addMessage(.init(
                rowid: rowid, subject: "Dup", senderAddress: "a@b.com", mailboxID: mailbox,
                dateReceived: 1_761_000_000, messageIDHeader: "<dup@gmail.com>"))
        }
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        var rows: [(Int64, Int64, String)] = []
        try snapshot.connection.query(
            """
            SELECT m.ROWID, m.mailbox, g.message_id_header FROM messages m
            JOIN message_global_data g ON m.global_message_id = g.ROWID ORDER BY m.ROWID
            """
        ) { row in rows.append((row.int(0), row.int(1), row.text(2) ?? "")) }
        #expect(rows.count == 2)
        #expect(rows.map(\.2) == ["<dup@gmail.com>", "<dup@gmail.com>"])
        #expect(rows.map(\.1) == [1, 2])
    }

    // MARK: - Schema

    @Test func acceptsTheFullSchema() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        try snapshot.validateSchema()
        #expect(try snapshot.capabilities() == .init(hasSummary: true, hasDateSent: true, hasMessageIDHeader: true))
    }

    @Test(arguments: [
        ("messages", "size"), ("messages", "date_received"), ("messages", "conversation_id"),
        ("subjects", "subject"), ("addresses", "comment"), ("recipients", "position"),
        ("mailboxes", "unread_count"), ("attachments", "attachment_id"),
    ])
    func refusesAnIndexMissingARequiredColumn(table: String, column: String) throws {
        let fixture = try EnvelopeIndexBuilder(schemaOmitting: ["\(table).\(column)"])
        defer { fixture.cleanup() }
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        #expect(throws: Mail42Error.schemaUnsupported(table: table, column: column)) {
            try snapshot.validateSchema()
        }
    }

    @Test func optionalColumnsAreNotRequired() throws {
        let fixture = try EnvelopeIndexBuilder(schemaOmitting: [
            "messages.summary", "messages.date_sent", "messages.global_message_id",
        ])
        defer { fixture.cleanup() }
        try seed(fixture)
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        try snapshot.validateSchema()          // does not throw
        #expect(try snapshot.capabilities() == .init(hasSummary: false, hasDateSent: false, hasMessageIDHeader: false))
    }

    @Test func aMissingTableIsReportedAsItsFirstMissingColumn() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.envelopeIndexURL)
        let db = try SQLiteConnection(path: fixture.envelopeIndexURL.path, readOnly: false)
        try db.execute("CREATE TABLE messages (subject INTEGER)")
        db.close()
        let snapshot = try EnvelopeIndexSnapshot.open(mailRoot: fixture.mailRoot)
        defer { snapshot.close() }
        #expect(throws: Mail42Error.schemaUnsupported(table: "messages", column: "sender")) {
            try snapshot.validateSchema()
        }
    }

    // MARK: - Opening

    @Test func noIndexMeansNoMailData() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-none-\(UUID().uuidString)")
        #expect(throws: Mail42Error.noMailData) { try EnvelopeIndexSnapshot.open(mailRoot: missing) }
    }
}
