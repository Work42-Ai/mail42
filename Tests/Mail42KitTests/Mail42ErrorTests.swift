import Foundation
import Testing
@testable import Mail42Kit

@Suite struct Mail42ErrorTests {

    @Test func everyCaseHasAStableMachineCode() {
        #expect(Mail42Error.fdaDenied.code == "fda_denied")
        #expect(Mail42Error.noMailData.code == "no_mail_data")
        #expect(Mail42Error.schemaUnsupported(table: "messages", column: "size").code == "schema_unsupported")
        #expect(Mail42Error.databaseNotAccessible("x").code == "database_not_accessible")
        #expect(Mail42Error.queryFailed("x").code == "query_failed")
        #expect(Mail42Error.emlxParseFailed("x").code == "emlx_parse_failed")
        #expect(Mail42Error.emlxNotFound(messageId: 1, path: "/p").code == "emlx_not_found")
    }

    @Test func messagesNameTheProblemAndTheFix() {
        #expect(Mail42Error.fdaDenied.errorDescription?.contains("mail42 permissions open") == true)
        let schema = Mail42Error.schemaUnsupported(table: "messages", column: "size").errorDescription
        #expect(schema?.contains("messages") == true && schema?.contains("size") == true)
    }

    @Test func parsedMessageExposesTheMessageIdAndAttachments() {
        let inline = ParsedPart(part: "1", filename: "logo.png", mime: "image/png", size: 1, contentID: "l",
                                isInline: true, data: Data([1]))
        let file = ParsedPart(part: "2", filename: "r.pdf", mime: "application/pdf", size: 1, contentID: nil,
                              isInline: false, data: Data([1]))
        let message = ParsedMessage(headers: ["message-id": " <a@b> "], textBody: nil, htmlBody: nil,
                                    parts: [inline, file], isPartial: false)
        #expect(message.messageID == "<a@b>")
        #expect(message.attachments.map(\.part) == ["2"])
        #expect(ParsedMessage(headers: [:], textBody: nil, htmlBody: nil, parts: [], isPartial: false).messageID == nil)
    }
}
