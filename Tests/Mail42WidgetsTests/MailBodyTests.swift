// MailBodyTests.swift — the body reader that replaced `mail42 message read` and `attachment save`: where the .emlx is, the
// .emlx → MIME parse, the HTML sanitiser, HTML → text and attachment decoding (WOR-900). Ports the cases that covered the
// originals (EmlxLocator, MessageParser, HTMLSanitizer, HTMLText).

import Foundation
import Mail42TestSupport
import Testing
@testable import Mail42MailWidget

private let account = EnvelopeIndexBuilder.accountUUID
private let store = EnvelopeIndexBuilder.storeUUID

private func crlf(_ lines: [String]) -> String { lines.joined(separator: "\r\n") }

private func parse(_ rfc822: String, partial: Bool = false, cache: [String: Data] = [:]) throws -> MailBodyMessage {
    try MailBodyParser.parse(
        emlx: MailFixtures.emlx(rfc822), isPartial: partial, externalAttachment: { cache[$0] })
}

// MARK: - Where the .emlx is

@Suite("Mail body path")
struct MailEmlxPathTests {

    @Test func hashDirectoryFollowsTheDigitsOfRowIdOverAThousand() {
        #expect(MailEmlxPath.hashDirectory(rowid: 5) == "")
        #expect(MailEmlxPath.hashDirectory(rowid: 218) == "")
        #expect(MailEmlxPath.hashDirectory(rowid: 999) == "")
        #expect(MailEmlxPath.hashDirectory(rowid: 1000) == "1")
        #expect(MailEmlxPath.hashDirectory(rowid: 9865) == "9")
        #expect(MailEmlxPath.hashDirectory(rowid: 19926) == "9/1")
        #expect(MailEmlxPath.hashDirectory(rowid: 123456) == "3/2/1")
        #expect(MailEmlxPath.hashDirectory(rowid: 262653) == "2/6/2")
        #expect(MailEmlxPath.hashDirectory(rowid: 1234567) == "4/3/2/1")
    }

    @Test func mapsAMailboxURLToItsFolders() throws {
        // An iCloud-style mailbox.
        let inbox = try #require(MailEmlxPath.mailbox(from: "imap://\(account)/INBOX"))
        #expect(inbox.scheme == "imap")
        #expect(inbox.accountUUID == account)
        #expect(inbox.pathComponents == ["INBOX"])
        // A Gmail-style mailbox: brackets and a space, percent-encoded, two levels.
        let gmail = try #require(MailEmlxPath.mailbox(from: "imap://\(account)/%5BGmail%5D/All%20Mail"))
        #expect(gmail.pathComponents == ["[Gmail]", "All Mail"])
        // An encoded slash stays inside its component; a literal one is a level; empty segments are kept.
        #expect(MailEmlxPath.mailbox(from: "imap://U/R%26D%2FSent")?.pathComponents == ["R&D/Sent"])
        #expect(MailEmlxPath.mailbox(from: "imap://U/R%26D/Sent")?.pathComponents == ["R&D", "Sent"])
        #expect(MailEmlxPath.mailbox(from: "imap://U/A//B")?.pathComponents == ["A", "", "B"])
        #expect(MailEmlxPath.mailbox(from: "ews://U/%E6%94%B6%E4%BB%B6%E5%8C%A3")?.pathComponents == ["收件匣"])
        // Malformed.
        #expect(MailEmlxPath.mailbox(from: "not a url") == nil)
        #expect(MailEmlxPath.mailbox(from: "imap://\(account)") == nil)
    }

    @Test func buildsTheMailboxDirectory() {
        let root = "/Users/me/Library/Mail/V10"
        #expect(MailEmlxPath.mailboxDirectory(mailboxURL: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), mailRoot: root)
            == "\(root)/\(account)/INBOX.mbox")
        #expect(MailEmlxPath.mailboxDirectory(mailboxURL: EnvelopeIndexBuilder.mailboxURL(["[Gmail]", "All Mail"]), mailRoot: root)
            == "\(root)/\(account)/[Gmail].mbox/All Mail.mbox")
        #expect(MailEmlxPath.mailboxDirectory(mailboxURL: "garbage", mailRoot: root) == nil)
    }

    @Test func listsTheCandidatePathsOfAGmailStyleMailbox() {
        let root = "/Users/me/Library/Mail/V10"
        let url = EnvelopeIndexBuilder.mailboxURL(["[Gmail]", "All Mail"])
        let paths = MailEmlxPath.candidates(rowid: 123456, mailboxURL: url, mailRoot: root, stores: ["Info.plist", store])
        let base = "\(root)/\(account)/[Gmail].mbox/All Mail.mbox/\(store)/Data/3/2/1/Messages"
        #expect(paths == ["\(base)/123456.emlx", "\(base)/123456.partial.emlx"])
    }

    @Test func listsTheCandidatePathsOfAnICloudStyleMailbox() {
        let root = "/Users/me/Library/Mail/V10"
        let url = EnvelopeIndexBuilder.mailboxURL(["INBOX"])
        let paths = MailEmlxPath.candidates(rowid: 5, mailboxURL: url, mailRoot: root, stores: [store])
        let base = "\(root)/\(account)/INBOX.mbox/\(store)/Data/Messages"      // no hash folder under 1000
        #expect(paths == ["\(base)/5.emlx", "\(base)/5.partial.emlx"])
        let four = MailEmlxPath.candidates(rowid: 4321, mailboxURL: url, mailRoot: root, stores: [store])
        #expect(four.first == "\(root)/\(account)/INBOX.mbox/\(store)/Data/4/Messages/4321.emlx")
    }

    @Test func triesEveryStoreFolderInOrderAndIgnoresOtherNames() {
        let other = "B0B0B0B0-B1B1-4C2C-8D3D-E4E4E4E4E4E4"
        let paths = MailEmlxPath.candidates(
            rowid: 7, mailboxURL: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), mailRoot: "/m", stores: [other, ".DS_Store", store])
        #expect(paths.count == 4)
        #expect(paths[0].contains(store) && paths[2].contains(other))                 // sorted: A0… before B0…
        #expect(paths[0].hasSuffix("/7.emlx") && paths[1].hasSuffix("/7.partial.emlx"))
        #expect(MailEmlxPath.isStoreUUID(store))
        #expect(!MailEmlxPath.isStoreUUID("Info.plist"))
        #expect(!MailEmlxPath.isStoreUUID("not-a-uuid-but-with-dashes-and-36-chars!"))
    }

    @Test func noCandidatesForABadURLNoStoresOrAHostilePath() {
        let url = EnvelopeIndexBuilder.mailboxURL(["INBOX"])
        #expect(MailEmlxPath.candidates(rowid: 1, mailboxURL: "not a url", mailRoot: "/m", stores: [store]).isEmpty)
        #expect(MailEmlxPath.candidates(rowid: 1, mailboxURL: "imap://\(account)", mailRoot: "/m", stores: [store]).isEmpty)
        #expect(MailEmlxPath.candidates(rowid: 1, mailboxURL: url, mailRoot: "/m").isEmpty)
        let hostile = "imap://\(account)/x%2F..%2F..%2F..%2F..%2Fetc"
        #expect(MailEmlxPath.candidates(rowid: 1, mailboxURL: hostile, mailRoot: "/m", stores: [store]).isEmpty)
    }

    @Test func includesTheFileWhereMailKeepsIt() throws {
        // The candidates are computed without looking at disk; one of them is where the fixture put the file.
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let written = try fixture.writeEmlx(rowid: 4321, data: MailFixtures.emlx(MailFixtures.plain()))
        let paths = MailEmlxPath.candidates(
            rowid: 4321, mailboxURL: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), mailRoot: fixture.mailRoot.path, stores: [store])
        #expect(paths.map { URL(fileURLWithPath: $0).standardizedFileURL }.contains(written.standardizedFileURL))
    }

    @Test func flagsPartialFilesAndFindsTheAttachmentCache() {
        #expect(MailEmlxPath.isPartial(path: "/x/Messages/7.partial.emlx"))
        #expect(!MailEmlxPath.isPartial(path: "/x/Messages/7.emlx"))
        #expect(MailEmlxPath.attachmentsDirectory(forEmlx: "/m/\(store)/Data/4/Messages/4321.partial.emlx")
            == "/m/\(store)/Data/4/Attachments/4321")
    }
}

// MARK: - The parse

@Suite("Mail body parser")
struct MailBodyParserTests {

    @Test func parsesAPlainTextMessage() throws {
        let message = try parse(MailFixtures.plain())
        #expect(message.headers["subject"] == "mail42-qa plain zebrafish")
        #expect(message.messageID == "<plain-1@example.com>")
        #expect(message.text?.contains("quokkabody") == true)
        #expect(message.html == nil)
        #expect(message.attachments.isEmpty)
        #expect(!message.isPartial)
        #expect(!message.bodyUnavailable)
    }

    @Test func parsesHTMLWithAnInlineImageAndFlagsItInline() throws {
        let message = try parse(MailFixtures.htmlWithInlineImage())
        #expect(message.html?.contains("Roadmap headline") == true)
        let image = try #require(message.parts.first { $0.mime == "image/png" })
        #expect(image.contentID == "logo1")                 // `<Logo1>` normalised
        #expect(image.isInline)
        #expect(!image.isAttachment)                        // inline images aren't listed as attachments
        #expect(image.data == MailFixtures.png)
        #expect(image.size == MailFixtures.png.count)
        #expect(message.attachments.isEmpty)
    }

    @Test func listsARealAttachmentWithItsBytes() throws {
        let message = try parse(MailFixtures.withAttachment())
        let attachment = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.mime == "application/pdf")
        #expect(attachment.data == MailFixtures.attachmentBytes)
        #expect(attachment.size == MailFixtures.attachmentBytes.count)
        #expect(!attachment.isInline)
        #expect(message.text?.contains("See attached report.") == true)
        let row = try #require(message.attachmentRows.first)
        #expect(row.part == "2" && row.filename == "report.pdf" && row.mime == "application/pdf")
        #expect(row.size == MailFixtures.attachmentBytes.count)
    }

    @Test func partIdsAreStablePositionsAmongAllLeafParts() throws {
        let message = try parse(MailFixtures.withAttachment())
        let ids = message.parts.map(\.part)
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        // The text body is leaf 1 (not listed), the attachment is leaf 2.
        #expect(message.attachments.first?.part == "2")
    }

    @Test func partIdsCountThroughNestedMultiparts() throws {
        let message = try parse(crlf([
            "From: a@example.com", "Subject: nested", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"OUT\"", "",
            "--OUT", "Content-Type: multipart/alternative; boundary=\"IN\"", "",
            "--IN", "Content-Type: text/plain; charset=utf-8", "", "plain version",
            "--IN", "Content-Type: text/html; charset=utf-8", "", "<p>html version</p>",
            "--IN--",
            "--OUT", "Content-Type: application/zip; name=\"a.zip\"", "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=\"a.zip\"", "", Data("zip".utf8).base64EncodedString(),
            "--OUT", "Content-Type: text/csv", "Content-Disposition: attachment; filename=\"b.csv\"", "", "x,y",
            "--OUT--", "",
        ]))
        #expect(message.text?.trimmingCharacters(in: .whitespacesAndNewlines) == "plain version")
        #expect(message.html?.trimmingCharacters(in: .whitespacesAndNewlines) == "<p>html version</p>")
        #expect(message.attachments.map(\.part) == ["3", "4"])
        #expect(message.attachments.map(\.filename) == ["a.zip", "b.csv"])
        #expect(message.attachments.last?.data == Data("x,y".utf8))
    }

    // MARK: Partial downloads

    @Test func aPartialWithoutABodyIsBodyUnavailable() throws {
        let message = try parse(MailFixtures.partialWithoutBody(), partial: true)
        #expect(message.isPartial)
        #expect(!message.hasBody)
        #expect(message.bodyUnavailable)
        #expect(message.headers["subject"] == "partial no body")
    }

    @Test func aPartialThatKeptItsTextIsNotBodyUnavailable() throws {
        let message = try parse(MailFixtures.partialWithAttachment(), partial: true)
        #expect(message.isPartial)
        #expect(message.hasBody)
        #expect(!message.bodyUnavailable)
        #expect(message.text?.contains("live in Mail's cache") == true)
    }

    @Test func aFullFileWithAnEmptyBodyIsNotBodyUnavailable() throws {
        let message = try parse(MailFixtures.partialWithoutBody(), partial: false)
        #expect(!message.bodyUnavailable)
    }

    @Test func fillsAPartialMessagesAttachmentFromMailsExternalCache() throws {
        let message = try parse(
            MailFixtures.partialWithAttachment(), partial: true, cache: ["report.pdf": MailFixtures.attachmentBytes])
        let attachment = try #require(message.attachments.first)
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.data == MailFixtures.attachmentBytes)
        #expect(attachment.size == MailFixtures.attachmentBytes.count)
        #expect(attachment.part == "2")
    }

    @Test func aPartialAttachmentWithNoCachedBytesStaysListedButEmpty() throws {
        let message = try parse(MailFixtures.partialWithAttachment(), partial: true)
        let attachment = try #require(message.attachments.first)
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.data.isEmpty)
        #expect(attachment.size == 0)
    }

    @Test func theCacheIsOnlyConsultedForPartialFiles() throws {
        let message = try parse(
            MailFixtures.partialWithAttachment(), partial: false, cache: ["report.pdf": MailFixtures.attachmentBytes])
        #expect(message.attachments.first?.data.isEmpty == true)
    }

    @Test func aHostileAttachmentFilenameCannotEscapeTheCache() throws {
        var asked: [String] = []
        let rfc822 = MailFixtures.partialWithAttachment().replacingOccurrences(
            of: "filename=\"report.pdf\"", with: "filename=\"../../../../secret.txt\"")
        let message = MailBodyParser.parse(rfc822: Data(rfc822.utf8), isPartial: true) { name in
            asked.append(name)
            return nil
        }
        #expect(asked == ["secret.txt"])                    // only the last path component ever reaches the cache
        #expect(message.attachments.allSatisfy { $0.data.isEmpty })
    }

    // MARK: Container

    @Test func aCorruptContainerThrows() {
        #expect(throws: MailBodyError.self) { try MailBodyParser.parse(emlx: Data("not a byte count\nbody".utf8)) }
        #expect(throws: MailBodyError.self) { try MailBodyParser.parse(emlx: Data("9999\nshort".utf8)) }
        #expect(throws: MailBodyError.self) { try MailBodyParser.parse(emlx: Data("no newline at all".utf8)) }
        #expect(throws: MailBodyError.self) { try MailBodyParser.parse(emlx: Data()) }
    }

    @Test func theContainerGivesExactlyTheCountedBytes() throws {
        let message = Data("Subject: x\r\n\r\nhi".utf8)
        var file = Data("\(message.count)\n".utf8)
        file.append(message)
        file.append(Data("<plist>trailer</plist>".utf8))
        #expect(try MailBodyParser.extractMessageData(from: file) == message)
    }

    // MARK: Encodings and charsets

    @Test func decodesQuotedPrintableAndSoftLineBreaks() throws {
        let message = try parse(crlf([
            "From: a@example.com", "Subject: qp", "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable", "",
            "Caf=C3=A9 au lait, a very long line that is wrapped with a soft break=", " and goes on.", "",
        ]))
        #expect(message.text?.contains("Café au lait") == true)
        #expect(message.text?.contains("soft break and goes on.") == true)
    }

    @Test func decodesABase64Body() throws {
        let body = Data("Hola, ¿qué tal? Base64 body.".utf8).base64EncodedString()
        let message = try parse(crlf([
            "From: a@example.com", "Subject: b64", "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64", "", body, "",
        ]))
        #expect(message.text?.contains("Hola, ¿qué tal? Base64 body.") == true)
    }

    @Test func readsMultipartAlternativeWithBothBodies() throws {
        let message = try parse(crlf([
            "From: a@example.com", "Subject: alt", "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"ALT\"", "",
            "preamble ignored",
            "--ALT", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable", "",
            "Plain =E2=98=95",
            "--ALT", "Content-Type: text/html; charset=utf-8", "Content-Transfer-Encoding: base64", "",
            Data("<p>Rich ☕</p>".utf8).base64EncodedString(),
            "--ALT--", "",
        ]))
        #expect(message.text?.contains("Plain ☕") == true)
        #expect(message.html == "<p>Rich ☕</p>")
        #expect(message.attachments.isEmpty)
    }

    @Test func honoursADeclaredLegacyCharset() throws {
        var file = Data(crlf([
            "From: a@example.com", "Subject: latin", "Content-Type: text/plain; charset=iso-8859-1",
            "Content-Transfer-Encoding: 8bit", "", "caf",
        ]).utf8)
        file.append(contentsOf: [0xE9])                                    // é in Latin-1
        file.append(Data("\r\n".utf8))
        let message = MailBodyParser.parse(rfc822: file, isPartial: false)
        #expect(message.text?.contains("café") == true)
    }

    @Test func readsUTF8BytesUnderAWeakCharsetLabelAsUTF8() throws {
        let message = try parse(crlf([
            "From: a@example.com", "Subject: weak", "Content-Type: text/plain; charset=us-ascii",
            "Content-Transfer-Encoding: 8bit", "", "Zażółć gęślą jaźń ☕", "",
        ]))
        #expect(message.text?.contains("Zażółć gęślą jaźń ☕") == true)
    }

    @Test func neverDropsABodyWhoseBytesFitNoCharset() {
        var file = Data(crlf([
            "From: a@example.com", "Subject: odd", "Content-Type: text/plain; charset=us-ascii",
            "Content-Transfer-Encoding: 8bit", "", "caf",
        ]).utf8)
        file.append(contentsOf: [0xE9])                                    // a lone byte: neither ASCII nor valid UTF-8
        let message = MailBodyParser.parse(rfc822: file, isPartial: false)
        #expect(message.text?.contains("caf") == true)
    }

    @Test func readsAnEastAsianCharset() throws {      // `try` is for the #require below
        let sjis = try #require("日本語のメール".data(using: .shiftJIS))
        var file = Data(crlf([
            "From: a@example.com", "Subject: jp", "Content-Type: text/plain; charset=shift_jis",
            "Content-Transfer-Encoding: 8bit", "", "",
        ]).utf8)
        file.append(sjis)
        let message = MailBodyParser.parse(rfc822: file, isPartial: false)
        #expect(message.text?.contains("日本語のメール") == true)
    }

    @Test func salvagesATextPartThatIsMislabelled7bitButQuotedPrintable() throws {
        let mislabelled = try parse(crlf([
            "From: a@example.com", "Subject: klaviyo", "Content-Type: text/plain; charset=US-ASCII",
            "Content-Transfer-Encoding: 7bit", "", "Caf=C3=A9 =E2=98=95", "",
        ]))
        #expect(mislabelled.text?.contains("Café ☕") == true)
        // Honest 7bit text ABOUT quoted-printable is left alone: `=41` would decode to ASCII only.
        let honest = try parse(crlf([
            "From: a@example.com", "Subject: about qp", "Content-Type: text/plain; charset=US-ASCII",
            "Content-Transfer-Encoding: 7bit", "", "Write =41 for A.", "",
        ]))
        #expect(honest.text?.contains("Write =41 for A.") == true)
    }

    @Test func decodesEncodedWordHeadersAndKeepsTheirRuns() throws {
        let message = try parse(crlf([
            "From: =?UTF-8?B?Sm9zw6k=?= <jose@example.com>", "Subject: =?utf-8?Q?Caf=C3=A9_ol=C3=A9?=",
            "Content-Type: text/plain; charset=utf-8", "", "x", "",
        ]))
        #expect(message.headers["from"] == "José <jose@example.com>")
        #expect(message.headers["subject"] == "Café olé")
        // A multi-byte character split across two adjacent words still decodes.
        let split = MailBodyMIME.decodeRFC2047("=?UTF-8?B?w6k=?= =?UTF-8?B?w6k=?=")
        #expect(split == "éé")
        // "é" (0xC3 0xA9) cut between two words of one charset: decoded as a run, so the halves rejoin.
        #expect(MailBodyMIME.decodeRFC2047("=?UTF-8?B?ww==?= =?UTF-8?B?qQ==?=") == "é")
        #expect(MailBodyMIME.decodeRFC2047("plain =?bogus text") == "plain =?bogus text")
    }

    @Test func resolvesFilenamesFromEveryParameterForm() throws {
        func filename(_ disposition: String, type: String = "application/octet-stream") throws -> String? {
            let message = try parse(crlf([
                "From: a@example.com", "Subject: f", "MIME-Version: 1.0",
                "Content-Type: multipart/mixed; boundary=\"B\"", "",
                "--B", "Content-Type: text/plain", "", "body",
                "--B", "Content-Type: \(type)", "Content-Disposition: \(disposition)", "", "data",
                "--B--", "",
            ]))
            return message.attachments.first?.filename
        }
        #expect(try filename("attachment; filename=\"plain.txt\"") == "plain.txt")
        #expect(try filename("attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87.pdf") == "中文.pdf")
        #expect(try filename("attachment; filename*0=\"long-\"; filename*1=\"name.pdf\"") == "long-name.pdf")
        #expect(try filename("attachment; filename*0*=UTF-8''caf%C3%A9-; filename*1*=bar.pdf") == "café-bar.pdf")
        #expect(try filename("attachment; filename=\"=?UTF-8?B?Y2Fmw6kucGRm?=\"") == "café.pdf")
        #expect(try filename("attachment", type: "application/pdf; name=\"legacy.pdf\"") == "legacy.pdf")
        #expect(try filename("attachment; filename=\"report=?bogus.pdf\"") == "report=?bogus.pdf")
    }

    @Test func stopsAtTheMultipartDepthLimitAndOnAMissingBoundary() {
        let noBoundary = MailBodyParser.parse(
            rfc822: Data(crlf(["Content-Type: multipart/mixed", "", "--x", "Content-Type: text/plain", "", "hi"]).utf8),
            isPartial: false)
        #expect(noBoundary.text == nil)
        #expect(noBoundary.parts.isEmpty)
        // Nine levels deep: the leaf is never reached, and nothing crashes.
        var lines = ["Content-Type: multipart/mixed; boundary=\"b0\"", ""]
        for level in 0..<9 {
            lines += ["--b\(level)", "Content-Type: multipart/mixed; boundary=\"b\(level + 1)\"", ""]
        }
        lines += ["--b9", "Content-Type: application/pdf", "Content-Disposition: attachment; filename=\"deep.pdf\"", "", "x"]
        let deep = MailBodyParser.parse(rfc822: Data(crlf(lines).utf8), isPartial: false)
        #expect(deep.attachments.isEmpty)
    }

    @Test func aHostilelyNestedMessageIsReadWithoutRecursingToItsEnd() {
        // 5,000 multiparts nested in one another, behind a top-level text part. Boundaries are not prefixes of each other.
        var inner = crlf(["Content-Type: text/plain", "", "deepest"])
        for level in stride(from: 5_000, to: 0, by: -1) {
            inner = crlf(["Content-Type: multipart/mixed; boundary=\"b\(level)x\"", "", "--b\(level)x", inner, "--b\(level)x--"])
        }
        let message = crlf([
            "From: a@example.com", "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"topx\"", "",
            "--topx", "Content-Type: text/plain", "", "top-level text",
            "--topx", inner, "--topx--", "",
        ])
        let parsed = MailBodyParser.parse(rfc822: Data(message.utf8), isPartial: false)
        #expect(parsed.text?.contains("top-level text") == true)
        #expect(parsed.text?.contains("deepest") != true)
    }

    @Test func aMessageWithEndlessPartsIsCappedButKeepsWhatCameFirst() {
        var lines = ["Content-Type: multipart/mixed; boundary=\"flatx\"", "",
                     "--flatx", "Content-Type: text/plain", "", "first text"]
        for _ in 0..<(MailBodyMIME.maxBodyParts + 500) { lines += ["--flatx", "Content-Type: application/x-none", "", "x"] }
        lines += ["--flatx", "Content-Type: text/html", "", "<p>too late</p>", "--flatx--", ""]
        let parsed = MailBodyParser.parse(rfc822: Data(crlf(lines).utf8), isPartial: false)
        #expect(parsed.text?.contains("first text") == true)
        #expect(parsed.html == nil, "the part budget ended the walk")
    }

    @Test func plainTextFallsBackToTheHTMLAsText() throws {
        let htmlOnly = try parse(MailFixtures.htmlWithInlineImage())
        #expect(htmlOnly.text == nil)
        #expect(htmlOnly.plainText.contains("Roadmap headline"))
        #expect(!htmlOnly.plainText.contains("SCRIPT RAN"))
        let text = try parse(MailFixtures.plain())
        #expect(text.plainText.contains("quokkabody"))
    }
}

// MARK: - Attachments

@Suite("Mail body attachment")
struct MailBodyAttachmentTests {

    @Test func extractsAnAttachmentByItsPartID() throws {
        let emlx = MailFixtures.emlx(MailFixtures.withAttachment())
        let saved = try #require(MailBodyAttachment.extract(emlx: emlx, part: "2"))
        #expect(saved.filename == "report.pdf")
        #expect(saved.data == MailFixtures.attachmentBytes)
    }

    @Test func returnsNilForTheTextPartAnUnknownPartOrAnUnreadableFile() {
        let emlx = MailFixtures.emlx(MailFixtures.withAttachment())
        #expect(MailBodyAttachment.extract(emlx: emlx, part: "1") == nil)      // the text body has no filename
        #expect(MailBodyAttachment.extract(emlx: emlx, part: "9") == nil)
        #expect(MailBodyAttachment.extract(emlx: Data("garbage".utf8), part: "2") == nil)
    }

    @Test func extractsAnInlineImageThatHasAFilename() throws {
        let saved = try #require(
            MailBodyAttachment.extract(emlx: MailFixtures.emlx(MailFixtures.htmlWithInlineImage()), part: "2"))
        #expect(saved.filename == "logo.png")
        #expect(saved.data == MailFixtures.png)
    }

    @Test func aPartialAttachmentNeedsTheCacheAndIsNilWithoutIt() throws {
        let emlx = MailFixtures.emlx(MailFixtures.partialWithAttachment())
        #expect(MailBodyAttachment.extract(emlx: emlx, part: "2", isPartial: true) == nil)      // never downloaded
        let saved = try #require(MailBodyAttachment.extract(
            emlx: emlx, part: "2", isPartial: true, externalAttachment: { _ in MailFixtures.attachmentBytes }))
        #expect(saved.filename == "report.pdf")
        #expect(saved.data == MailFixtures.attachmentBytes)
    }

    @Test func theNameIsMadeSafeToUseAsAFile() throws {
        let hostile = MailFixtures.withAttachment().replacingOccurrences(
            of: "filename=\"report.pdf\"", with: "filename=\"../../.ssh/authorized_keys\"")
        let saved = try #require(MailBodyAttachment.extract(emlx: MailFixtures.emlx(hostile), part: "2"))
        #expect(saved.filename == "authorized_keys")
    }

    @Test func safeNameKeepsOneComponentAndNeverHidesOrEmpties() {
        #expect(MailBodyAttachment.safeName("report.pdf", fallback: "f") == "report.pdf")
        #expect(MailBodyAttachment.safeName("../../etc/passwd", fallback: "f") == "passwd")
        #expect(MailBodyAttachment.safeName("/abs/path/x.txt", fallback: "f") == "x.txt")
        #expect(MailBodyAttachment.safeName(".hidden", fallback: "f") == "_hidden")
        #expect(MailBodyAttachment.safeName("a:b\u{0007}c", fallback: "f") == "a_bc")
        #expect(MailBodyAttachment.safeName("..", fallback: "attachment-2") == "attachment-2")
        #expect(MailBodyAttachment.safeName("   ", fallback: "attachment-2") == "attachment-2")
        #expect(MailBodyAttachment.safeName(nil, fallback: "attachment-2") == "attachment-2")
    }

    @Test func numberedNamesKeepTheExtension() {
        #expect(MailBodyAttachment.numberedName("report.pdf", attempt: 0) == "report.pdf")
        #expect(MailBodyAttachment.numberedName("report.pdf", attempt: 2) == "report (2).pdf")
        #expect(MailBodyAttachment.numberedName("README", attempt: 1) == "README (1)")
    }
}

// MARK: - Sanitiser

@Suite("Mail body sanitiser")
struct MailBodySanitizerTests {

    private func logoPart(contentID: String = "logo1") -> MailBodyPart {
        MailBodyPart(part: "2", filename: "logo.png", mime: "image/png", size: MailFixtures.png.count,
                     contentID: contentID, isInline: true, data: MailFixtures.png)
    }

    private func sanitize(_ html: String, parts: [MailBodyPart] = []) -> String {
        MailBodySanitizer.sanitize(html: html, parts: parts)
    }

    private func message(html: String? = nil, text: String? = nil) -> MailBodyMessage {
        MailBodyMessage(headers: [:], text: text, html: html, parts: [], isPartial: false)
    }

    // MARK: Things that must be removed

    @Test func removesScriptsEventHandlersAndJavascriptLinks() {
        let out = sanitize("""
        <p onclick="document.title='pwned'" onMouseOver=x>Hi</p><script>alert(1)</script>
        <a href="javascript:alert(1)">js</a><a href="https://example.com/">safe</a>
        """)
        #expect(!out.lowercased().contains("<script"))
        #expect(!out.contains("alert(1)"))
        #expect(!out.lowercased().contains("onclick"))
        #expect(!out.lowercased().contains("onmouseover"))
        #expect(!out.lowercased().contains("javascript:"))
        #expect(out.contains("<p>Hi</p>"))
        #expect(out.contains("href=\"https://example.com/\""))
    }

    @Test(arguments: [
        #"<a href="java&#x09;script:alert(1)">x</a>"#,
        #"<a href="jav&#97;script:alert(1)">x</a>"#,
        #"<a href=" javascript:alert(1)">x</a>"#,
        #"<a href="JaVaScRiPt:alert(1)">x</a>"#,
        "<a href=\"java\nscript:alert(1)\">x</a>",
        #"<a href='vbscript:msgbox(1)'>x</a>"#,
        #"<a href=javascript:alert(1)>x</a>"#,
        #"<a href="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==">x</a>"#,
        #"<svg><a xlink:href="javascript:alert(1)"><text>x</text></a></svg>"#,
        #"<form action="https://evil.example/post"><button formaction="https://evil.example/2">go</button></form>"#,
        #"<iframe src="https://evil.example/"></iframe>"#,
        #"<object data="x.swf"><param name=x></object>"#,
        #"<embed src="x.swf">"#,
        #"<img src=x onerror="alert(1)">"#,
        #"<body onload="alert(1)">x</body>"#,
        #"<base href="https://evil.example/">"#,
        #"<meta http-equiv="refresh" content="0;url=https://evil.example/">"#,
        #"<iframe srcdoc="<script>alert(1)</script>"></iframe>"#,
    ])
    func neutralisesActiveContent(_ hostile: String) {
        let out = sanitize(hostile).lowercased()
        #expect(!out.contains("javascript:"))
        #expect(!out.contains("vbscript:"))
        #expect(!out.contains("alert(1)"))
        #expect(!out.contains("<iframe"))
        #expect(!out.contains("<object"))
        #expect(!out.contains("<embed"))
        #expect(!out.contains("<base"))
        #expect(!out.contains("<meta"))
        #expect(!out.contains("onerror"))
        #expect(!out.contains("onload"))
        #expect(!out.contains("action="))
        #expect(!out.contains("formaction"))
        #expect(!out.contains("data:text/html"))
        #expect(!out.contains("srcdoc"))
    }

    @Test func anUnclosedScriptSwallowsTheRestInsteadOfLeakingIt() {
        let out = sanitize("<p>before</p><script>var x = '</p><p>after</p>'")
        #expect(out.contains("before"))
        #expect(!out.contains("var x"))
        #expect(!out.contains("after"))
    }

    @Test func removesCommentsIncludingOutlookConditionals() {
        let out = sanitize("a<!-- secret -->b<!--[if mso]><table><tr><td>mso only</td></tr></table><![endif]-->c")
        #expect(out == "abc")
        #expect(!out.contains("secret"))
        #expect(!out.contains("mso only"))
    }

    @Test func aLoneAngleBracketBecomesText() {
        let out = sanitize("if 1 < 2 and a<b then <3")
        #expect(out.contains("1 &lt; 2"))
        #expect(!out.contains("<b"))
    }

    // MARK: Things that must survive

    @Test func keepsLayoutStylesTablesAndRemoteImages() {
        let html = """
        <table width="600" bgcolor="#fff" style="margin:0 auto"><tr><td class="x" style="color:#333">Cell</td></tr></table>
        <img src="https://img.example.com/p.png?a=1&amp;b=2" alt="remote" width=10>
        <a href="https://example.com/a?b=c" target="_blank">link</a>
        """
        let out = sanitize(html)
        #expect(out.contains("<table width=\"600\" bgcolor=\"#fff\" style=\"margin:0 auto\">"))
        #expect(out.contains("<td class=\"x\" style=\"color:#333\">Cell</td>"))
        #expect(out.contains("src=\"https://img.example.com/p.png?a=1&amp;b=2\""))
        #expect(out.contains("width=\"10\""))
        #expect(out.contains("target=\"_blank\""))
    }

    @Test func keepsStyleElementsAndImageDataURIs() {
        let out = sanitize("<style>.a{color:red}</style><img src=\"data:image/png;base64,AAAA\">")
        #expect(out.contains("<style>.a{color:red}</style>"))
        #expect(out.contains("src=\"data:image/png;base64,AAAA\""))
    }

    @Test(arguments: [
        #"<a href="jav&#97script:alert(1)">x</a>"#,              // numeric reference without the `;`
        #"<a href="&#x6A;avascript:alert(1)">x</a>"#,
        #"<a href="&#106avascript:alert(1)">x</a>"#,
        #"<a href="&#0000000106;avascript:alert(1)">x</a>"#,     // leading zeros past any fixed window
        #"<a href="javascript&colon;alert(1)">x</a>"#,
        #"<a href="java&Tab;script:alert(1)">x</a>"#,
        #"<a href="java&#9script:alert(1)">x</a>"#,              // an embedded tab, no `;`
        #"<a href="java&#10script:alert(1)">x</a>"#,
        #"<a href="&#x1;javascript:alert(1)">x</a>"#,            // a leading control character
    ])
    func decodesCharacterReferencesLikeABrowserBeforeTheSchemeCheck(_ hostile: String) {
        let out = sanitize(hostile).lowercased()
        #expect(!out.contains("href"), "kept: \(out)")
    }

    @Test func dataURIsSurviveOnlyInImageSources() {
        let png = "data:image/png;base64,AAAA"
        #expect(sanitize("<img src=\"\(png)\">").contains("src=\"\(png)\""))
        for kind in ["jpeg", "gif", "webp"] {
            #expect(sanitize("<img src=\"data:image/\(kind);base64,AAAA\">").contains("data:image/\(kind)"))
        }
        // Links and every other URL attribute: no data: at all.
        for html in [
            "<a href=\"\(png)\">x</a>", "<area href=\"\(png)\">", "<a href=\"&#100;ata:image/png;base64,AAAA\">x</a>",
            "<a href=\"data:image/png,AAAA\">x</a>", "<link href=\"\(png)\">", "<video poster=\"\(png)\"></video>",
            "<img longdesc=\"\(png)\">",
        ] {
            let out = sanitize(html)
            #expect(!out.contains("data:"), "kept: \(out)")
        }
        // Never SVG (it can carry script), even as an image source.
        for html in [
            "<img src=\"data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=\">", "<img src=\"data:image/svg+xml,<svg/>\">",
            "<img src=\"data:image/pngx;base64,AAAA\">", "<img src=\"data:text/html,<b>\">",
        ] {
            let out = sanitize(html)
            #expect(!out.contains("data:"), "kept: \(out)")
        }
    }

    @Test func keepsBareAttributesAndUnicodeText() {
        let out = sanitize("<input disabled value=\"café ☕\"><p>日本語 emoji 🎉</p>")
        #expect(out.contains("<input disabled value=\"café ☕\">"))
        #expect(out.contains("日本語 emoji 🎉"))
    }

    // MARK: cid: images

    @Test func inlinesCIDImagesAsDataURIsCaseInsensitively() {
        let out = sanitize("<img src=\"cid:LOGO1\" alt=\"x\">", parts: [logoPart()])
        #expect(out.contains("src=\"data:image/png;base64,\(MailFixtures.png.base64EncodedString())\""))
        #expect(!out.contains("cid:"))
    }

    @Test func inlinesCIDsInStyleAttributesAndStyleElements() {
        let parts = [logoPart()]
        let attribute = sanitize("<div style=\"background:url('cid:logo1')\">x</div>", parts: parts)
        #expect(attribute.contains("url(data:image/png;base64,"))
        let element = sanitize("<style>.l{background:url(cid:logo1)}</style>", parts: parts)
        #expect(element.contains("url(data:image/png;base64,"))
    }

    @Test func leavesAnUnknownCIDAlone() {
        let out = sanitize("<img src=\"cid:missing\">", parts: [logoPart()])
        #expect(out.contains("src=\"cid:missing\""))
    }

    @Test func onlyImagePartsAreEverInlined() {
        let html = MailBodyPart(part: "2", filename: nil, mime: "text/html", size: 3, contentID: "evil",
                                isInline: true, data: Data("<b>".utf8))
        let out = sanitize("<img src=\"cid:evil\"><a href=\"cid:evil\">x</a>", parts: [html])
        #expect(!out.contains("data:text/html"))
    }

    @Test func inlinesTheImageOfARealMessageAndDropsItsHostileParts() throws {
        let parsed = try parse(MailFixtures.htmlWithInlineImage())
        let out = sanitize(try #require(parsed.html), parts: parsed.parts)
        #expect(out.contains("data:image/png;base64,\(MailFixtures.png.base64EncodedString())"))
        #expect(out.contains("src=\"https://img.example.com/p.png\""))             // remote image stays
        #expect(out.contains("href=\"https://example.com/\""))
        #expect(!out.contains("SCRIPT RAN"))
        #expect(!out.lowercased().contains("onclick"))
        #expect(!out.lowercased().contains("javascript:"))
    }

    // MARK: render

    @Test func rendersAFullDocumentWithTheMessageId() {
        let out = MailBodySanitizer.render(message: message(html: "<p>hi</p><script>x()</script>"), id: 4211)
        #expect(out.hasPrefix("<!DOCTYPE html>"))
        #expect(out.contains("<meta charset=\"utf-8\">"))
        #expect(out.contains("<meta name=\"color-scheme\" content=\"light dark\">"))
        #expect(out.contains("<body data-mail42-id=\"4211\">"))
        #expect(out.contains("<p>hi</p>"))
        #expect(!out.contains("<script"))
        #expect(out.components(separatedBy: "data-mail42-id").count == 2)
    }

    @Test func documentCarriesACSPThatForbidsScriptButAllowsRemoteImages() throws {
        let out = MailBodySanitizer.render(message: message(html: "<p>hi</p>"), id: 5)
        let policy = "Content-Security-Policy"
        #expect(out.contains(policy))
        #expect(out.contains("default-src 'none'"))
        #expect(!out.contains("script-src"))                 // scripts fall under default-src 'none'
        #expect(out.contains("img-src * data: blob:"))
        #expect(out.contains("form-action 'none'"))
        // The policy sits in <head>, before any message content.
        let head = try #require(out.range(of: policy))
        let body = try #require(out.range(of: "<body"))
        #expect(head.lowerBound < body.lowerBound)
    }

    @Test func carriesTheSendersBodyAttributesOntoOurBody() {
        let out = MailBodySanitizer.render(
            message: message(html: "<html><head><title>T</title></head><body bgcolor=\"#eee\" class=\"m\" onload=\"x()\"><p>hi</p></body></html>"),
            id: 1)
        #expect(out.contains("<body data-mail42-id=\"1\" bgcolor=\"#eee\" class=\"m\">"))
        #expect(!out.contains("onload"))
        #expect(out.components(separatedBy: "<body").count == 2)        // exactly one <body>
        #expect(out.components(separatedBy: "<html").count == 2)
    }

    @Test func rendersATextOnlyMessageEscapedInAPre() {
        let out = MailBodySanitizer.render(message: message(text: "a < b & <script>x</script>"), id: 9)
        #expect(out.contains("<pre style=\"white-space:pre-wrap;font:-apple-system-body\">a &lt; b &amp; &lt;script&gt;x&lt;/script&gt;</pre>"))
        #expect(!out.contains("<script"))
    }

    @Test func rendersAnEmptyMessageWithoutCrashing() {
        let out = MailBodySanitizer.render(message: message(), id: 2)
        #expect(out.contains("<body data-mail42-id=\"2\"></body>"))
    }

    @Test func dangerousURLDetectionIsPreciseAboutSafeSchemes() {
        #expect(!MailBodySanitizer.isDangerousURL("https://example.com/javascript:foo"))
        #expect(!MailBodySanitizer.isDangerousURL("mailto:a@b.com"))
        #expect(!MailBodySanitizer.isDangerousURL("cid:logo"))
        #expect(!MailBodySanitizer.isDangerousURL("data:image/gif;base64,R0lG"))
        #expect(!MailBodySanitizer.isDangerousURL("#anchor"))
        #expect(MailBodySanitizer.isDangerousURL("  JAVASCRIPT:alert(1)"))
        #expect(MailBodySanitizer.isDangerousURL("data:text/html,<b>"))
    }
}

// MARK: - HTML → text

@Suite("Mail body HTML text")
struct MailBodyHTMLTextTests {

    private func plain(_ html: String) -> String { MailBodyHTMLText.plain(from: html) }

    @Test func dropsTagsScriptsStylesAndTheHead() {
        let text = plain("""
        <html><head><title>Title</title><style>.a{color:red}</style></head>
        <body><script>evil()</script><p>Hello <b>world</b></p></body></html>
        """)
        #expect(text == "Hello world")
    }

    @Test func turnsBlockTagsAndBreaksIntoLines() {
        let text = plain("<p>One</p><p>Two<br>Three</p><ul><li>a</li><li>b</li></ul><div>End</div>")
        #expect(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty } == ["One", "Two", "Three", "a", "b", "End"])
    }

    @Test func decodesEntities() {
        #expect(plain("Tom &amp; Jerry &lt;3 &quot;hi&quot; &#169; &#x1F600; caf&eacute;").hasPrefix("Tom & Jerry <3 \"hi\" © 😀"))
        #expect(plain("a&nbsp;&nbsp;b") == "a b")
    }

    @Test func collapsesWhitespaceAndKeepsAtMostOneBlankLine() {
        let text = plain("<p>a   \n   b</p>\n\n\n<p>c</p><p></p><p></p><p>d</p>")
        #expect(text.contains("a b"))
        #expect(!text.contains("\n\n\n"))
        #expect(text.hasSuffix("d"))
    }

    @Test func keepsLineBreaksInsidePre() {
        let text = plain("<pre>line1\nline2\n  indented</pre>")
        #expect(text.contains("line1\nline2\nindented") || text.contains("line1\nline2\n indented"))
    }

    @Test func tableCellsAreSeparatedByASpace() {
        let text = plain("<table><tr><td>Name</td><td>Qty</td></tr><tr><td>Pen</td><td>3</td></tr></table>")
        #expect(text.contains("Name Qty"))
        #expect(text.contains("Pen 3"))
    }

    @Test func survivesMalformedAndHostileInput() {
        #expect(plain("") == "")
        #expect(plain("<<<>>>").contains("<"))
        #expect(plain("<div").contains("<div"))
        #expect(plain("<script>never closed").isEmpty)
        #expect(plain("text <!-- unterminated").hasPrefix("text"))
    }

    @Test func findsWordsOnlyPresentInTheBody() {
        let text = plain("<div><span>The secret word is</span> <i>quokkabody</i>.</div>")
        #expect(text.contains("quokkabody"))
    }
}
