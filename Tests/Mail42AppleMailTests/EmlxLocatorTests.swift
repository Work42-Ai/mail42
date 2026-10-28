import Foundation
import Testing
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct EmlxLocatorTests {

    @Test func hashDirectoryFollowsTheDigitsOfRowIdOverAThousand() {
        // Literal expectations, from che-apple-mail-mcp's verified examples and the plan (rowid 5, 123456).
        #expect(EmlxLocator.hashDirectory(rowId: 5) == "")
        #expect(EmlxLocator.hashDirectory(rowId: 218) == "")
        #expect(EmlxLocator.hashDirectory(rowId: 999) == "")
        #expect(EmlxLocator.hashDirectory(rowId: 1000) == "1")
        #expect(EmlxLocator.hashDirectory(rowId: 9865) == "9")
        #expect(EmlxLocator.hashDirectory(rowId: 19926) == "9/1")
        #expect(EmlxLocator.hashDirectory(rowId: 123456) == "3/2/1")
        #expect(EmlxLocator.hashDirectory(rowId: 262653) == "2/6/2")
        #expect(EmlxLocator.hashDirectory(rowId: 1234567) == "4/3/2/1")
    }

    @Test func findsEmlxFilesAtEveryDepth() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let url = EnvelopeIndexBuilder.mailboxURL(["INBOX"])
        for rowid: Int64 in [5, 4321, 123456] {
            let written = try fixture.writeEmlx(rowid: rowid, data: MailFixtures.emlx(MailFixtures.plain()))
            let found = EmlxLocator.emlxURL(rowid: rowid, mailboxURL: url, mailRoot: fixture.mailRoot)
            #expect(found?.standardizedFileURL == written.standardizedFileURL)
        }
    }

    @Test func prefersTheFullFileAndFlagsPartialOnes() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let url = EnvelopeIndexBuilder.mailboxURL(["INBOX"])
        try fixture.writeEmlx(rowid: 7, data: MailFixtures.emlx(MailFixtures.plain()), partial: true)
        let partial = try #require(EmlxLocator.emlxURL(rowid: 7, mailboxURL: url, mailRoot: fixture.mailRoot))
        #expect(EmlxLocator.isPartial(partial))

        try fixture.writeEmlx(rowid: 7, data: MailFixtures.emlx(MailFixtures.plain()))
        let full = try #require(EmlxLocator.emlxURL(rowid: 7, mailboxURL: url, mailRoot: fixture.mailRoot))
        #expect(!EmlxLocator.isPartial(full))
    }

    @Test func resolvesNestedAndPercentEncodedMailboxes() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let path = ["[Gmail]", "All Mail"]
        let written = try fixture.writeEmlx(
            rowid: 42, mailboxPath: path, data: MailFixtures.emlx(MailFixtures.plain()))
        let url = EnvelopeIndexBuilder.mailboxURL(path)
        #expect(url.contains("%5BGmail%5D") || url.contains("[Gmail]"))
        let found = EmlxLocator.emlxURL(rowid: 42, mailboxURL: url, mailRoot: fixture.mailRoot)
        #expect(found?.standardizedFileURL == written.standardizedFileURL)
    }

    @Test func returnsNilWhenThereIsNoFileOrTheURLIsMalformed() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try fixture.writeEmlx(rowid: 1, data: MailFixtures.emlx(MailFixtures.plain()))
        let url = EnvelopeIndexBuilder.mailboxURL(["INBOX"])
        #expect(EmlxLocator.emlxURL(rowid: 2, mailboxURL: url, mailRoot: fixture.mailRoot) == nil)
        #expect(EmlxLocator.emlxURL(rowid: 1, mailboxURL: "not a url", mailRoot: fixture.mailRoot) == nil)
        #expect(EmlxLocator.emlxURL(
            rowid: 1, mailboxURL: "imap://\(EnvelopeIndexBuilder.accountUUID)", mailRoot: fixture.mailRoot) == nil)
        #expect(EmlxLocator.emlxURL(
            rowid: 1, mailboxURL: "imap://\(EnvelopeIndexBuilder.accountUUID)/Other", mailRoot: fixture.mailRoot) == nil)
    }

    @Test func refusesAMailboxPathThatClimbsOutOfTheMailRoot() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let hostile = "imap://\(EnvelopeIndexBuilder.accountUUID)/x%2F..%2F..%2F..%2F..%2Fetc"
        #expect(EmlxLocator.emlxURL(rowid: 1, mailboxURL: hostile, mailRoot: fixture.mailRoot) == nil)
    }

    @Test func fallsBackToABoundedSearchWhenTheHashRuleDoesNotHold() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        // A file placed one level deeper than the rule says (as if Apple changed the layout).
        let store = fixture.mailRoot
            .appendingPathComponent(EnvelopeIndexBuilder.accountUUID)
            .appendingPathComponent("INBOX.mbox")
            .appendingPathComponent(EnvelopeIndexBuilder.storeUUID)
            .appendingPathComponent("Data/7/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let odd = store.appendingPathComponent("55.emlx")
        try MailFixtures.emlx(MailFixtures.plain()).write(to: odd)
        let found = EmlxLocator.emlxURL(
            rowid: 55, mailboxURL: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), mailRoot: fixture.mailRoot)
        #expect(found?.standardizedFileURL == odd.standardizedFileURL)
    }

    @Test func attachmentsDirectoryIsASiblingOfMessages() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let emlx = try fixture.writeEmlx(rowid: 4321, data: MailFixtures.emlx(MailFixtures.plain()), partial: true)
        let dir = EmlxLocator.attachmentsDirectory(forEmlx: emlx)
        #expect(dir.path.hasSuffix("/Data/4/Attachments/4321"))   // 4321 / 1000 = 4
        #expect(dir.deletingLastPathComponent().deletingLastPathComponent()
            == emlx.deletingLastPathComponent().deletingLastPathComponent())
    }
}
