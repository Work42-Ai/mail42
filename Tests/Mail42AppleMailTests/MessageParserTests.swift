import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct MessageParserTests {

    private func parse(_ rfc822: String, rowid: Int64 = 1, partial: Bool = false, cache: Bool = false) throws -> (ParsedMessage, EnvelopeIndexBuilder) {
        let fixture = try EnvelopeIndexBuilder()
        let url = try fixture.writeEmlx(rowid: rowid, data: MailFixtures.emlx(rfc822), partial: partial)
        if cache {
            try fixture.writeAttachmentCache(
                rowid: rowid, partID: "2", filename: "report.pdf", data: MailFixtures.attachmentBytes)
        }
        return (try MessageParser.parse(emlx: url), fixture)
    }

    @Test func parsesAPlainTextMessage() throws {
        let (message, fixture) = try parse(MailFixtures.plain())
        defer { fixture.cleanup() }
        #expect(message.headers["subject"] == "mail42-qa plain zebrafish")
        #expect(message.messageID == "<plain-1@example.com>")
        #expect(message.textBody?.contains("quokkabody") == true)
        #expect(message.htmlBody == nil)
        #expect(message.attachments.isEmpty)
        #expect(!message.isPartial)
    }

    @Test func parsesHTMLWithAnInlineImageAndFlagsItInline() throws {
        let (message, fixture) = try parse(MailFixtures.htmlWithInlineImage())
        defer { fixture.cleanup() }
        #expect(message.htmlBody?.contains("Roadmap headline") == true)
        let image = try #require(message.parts.first { $0.mime == "image/png" })
        #expect(image.contentID == "logo1")                 // `<Logo1>` normalised
        #expect(image.isInline)
        #expect(!image.isAttachment)                        // inline images aren't listed as attachments
        #expect(image.data == MailFixtures.png)
        #expect(image.size == MailFixtures.png.count)
        #expect(message.attachments.isEmpty)
    }

    @Test func listsARealAttachmentWithItsBytes() throws {
        let (message, fixture) = try parse(MailFixtures.withAttachment())
        defer { fixture.cleanup() }
        let attachment = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.mime == "application/pdf")
        #expect(attachment.data == MailFixtures.attachmentBytes)
        #expect(attachment.size == MailFixtures.attachmentBytes.count)
        #expect(!attachment.isInline)
        #expect(message.textBody?.contains("See attached report.") == true)
    }

    @Test func fillsAPartialMessagesAttachmentFromMailsExternalCache() throws {
        let (message, fixture) = try parse(MailFixtures.partialWithAttachment(), rowid: 9, partial: true, cache: true)
        defer { fixture.cleanup() }
        #expect(message.isPartial)
        let attachment = try #require(message.attachments.first)
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.data == MailFixtures.attachmentBytes)
    }

    @Test func aPartialAttachmentWithNoCachedBytesStaysListedButEmpty() throws {
        let (message, fixture) = try parse(MailFixtures.partialWithAttachment(), rowid: 9, partial: true, cache: false)
        defer { fixture.cleanup() }
        let attachment = try #require(message.attachments.first)
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.data.isEmpty)
        #expect(attachment.size == 0)
    }

    @Test func partIdsAreStablePositionsAmongAllLeafParts() throws {
        let (message, fixture) = try parse(MailFixtures.withAttachment())
        defer { fixture.cleanup() }
        let ids = message.parts.map(\.part)
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        // The text body is leaf 1 (not listed), the attachment is leaf 2.
        #expect(message.attachments.first?.part == "2")
    }

    @Test func aMissingFileIsEmlxNotFound() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope/77.emlx")
        #expect(throws: Mail42Error.emlxNotFound(messageId: 77, path: missing.path)) {
            try MessageParser.parse(emlx: missing)
        }
    }

    @Test func aCorruptContainerIsEmlxParseFailed() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let url = try fixture.writeEmlx(rowid: 3, data: Data("not a byte count\nbody".utf8))
        #expect(throws: Mail42Error.self) { try MessageParser.parse(emlx: url) }
        let truncated = try fixture.writeEmlx(rowid: 4, data: Data("9999\nshort".utf8))
        #expect(throws: Mail42Error.self) { try MessageParser.parse(emlx: truncated) }
    }

    @Test func aHostileAttachmentFilenameCannotEscapeTheCache() throws {
        // The filename points at a file outside the cache; the parser must only look inside it.
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        let message = MessageParser.parse(
            rfc822: Data(MailFixtures.partialWithAttachment().replacingOccurrences(
                of: "filename=\"report.pdf\"", with: "filename=\"../../../../secret.txt\"").utf8),
            isPartial: true,
            attachmentsDirectory: fixture.root.appendingPathComponent("Attachments/1"))
        #expect(message.attachments.allSatisfy { $0.data.isEmpty })
    }
}
