import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct BodyScannerTests {

    private func file(_ rfc822: String) throws -> (URL, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("1.emlx")
        try MailFixtures.emlx(rfc822).write(to: url)
        return (url, { try? FileManager.default.removeItem(at: folder) })
    }

    private func wanted(_ terms: String...) -> [(term: String, folded: String)] {
        terms.map { (term: $0, folded: BodyScanner.fold($0)) }
    }

    private func message(headers: [String] = [], body: String) -> String {
        (["From: a@example.com", "To: b@example.com", "Subject: hello", "Message-ID: <x@y>", "Date: Mon, 27 Oct 2026 10:00:00 +0000"]
            + headers + ["", body]).joined(separator: "\r\n")
    }

    @Test func aWordInPlainTextIsFoundAndAMissingOneIsNot() throws {
        let (url, cleanup) = try file(message(headers: ["Content-Type: text/plain; charset=utf-8"], body: "The Invoice is attached."))
        defer { cleanup() }
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("invoice")) == ["invoice"])        // any case
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("receipt")) == [])
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("invoice", "receipt")) == ["invoice"])
    }

    @Test func theRawBytesAreEnoughToRuleAMessageOut() throws {
        let data = MailFixtures.emlx(message(headers: ["Content-Type: text/plain"], body: "nothing relevant here"))
        #expect(BodyScanner.rawCandidates(in: data, wanted: wanted("invoice")) == [])             // no decoding needed to say no
        #expect(BodyScanner.rawCandidates(in: data, wanted: wanted("relevant")) == ["relevant"])
    }

    @Test func onlyTheStartOfAHugeFileIsLookedAt() throws {
        // A word past the first 256 KB (inside a big attachment, say) is not worth copying the whole file for.
        let padding = String(repeating: "x", count: BodyScanner.rawReadLimit + 1000)
        let late = MailFixtures.emlx(message(headers: ["Content-Type: text/plain"], body: padding + " lateword"))
        #expect(BodyScanner.rawCandidates(in: late, wanted: wanted("lateword")) == [])
        let early = MailFixtures.emlx(message(headers: ["Content-Type: text/plain"], body: "earlyword " + padding))
        #expect(BodyScanner.rawCandidates(in: early, wanted: wanted("earlyword")) == ["earlyword"])
    }

    @Test func aWordSplitByAQuotedPrintableLineBreakIsStillFound() throws {
        let body = "This is the inv=\r\noice you asked for, and a long line that Mail would have wrapped here."
        let (url, cleanup) = try file(message(headers: ["Content-Type: text/plain; charset=utf-8",
                                                        "Content-Transfer-Encoding: quoted-printable"], body: body))
        defer { cleanup() }
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("invoice")) == ["invoice"])
    }

    @Test func base64TextIsDecodedBecauseTheRawBytesHideIt() throws {
        let encoded = Data("Please pay the invoice today.".utf8).base64EncodedString()
        let (url, cleanup) = try file(message(headers: ["Content-Type: text/plain; charset=utf-8",
                                                        "Content-Transfer-Encoding: base64"], body: encoded))
        defer { cleanup() }
        let data = try Data(contentsOf: url)
        #expect(BodyScanner.rawCandidates(in: data, wanted: wanted("invoice")) == nil)            // "can't tell: decode it"
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("invoice")) == ["invoice"])
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("receipt")) == [])
    }

    @Test func aWordInMarkupOnlyDoesNotCount() throws {
        // "invoice" appears in an HTML attribute and a URL, not in what a reader sees.
        let html = "<html><body><a href=\"https://example.com/invoice\" class=\"invoice\">Click here</a></body></html>"
        let (url, cleanup) = try file(message(headers: ["Content-Type: text/html; charset=utf-8"], body: html))
        defer { cleanup() }
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("invoice")) == [])                    // raw hit, confirmed against the text
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("click")) == ["click"])
    }

    @Test func wordsWithCharactersThatEncodingsRewriteAreAlwaysDecoded() throws {
        let (url, cleanup) = try file(message(headers: ["Content-Type: text/html; charset=utf-8"],
                                              body: "<p>Terms &amp; conditions, café and r&amp;d</p>"))
        defer { cleanup() }
        let data = try Data(contentsOf: url)
        #expect(BodyScanner.rawCandidates(in: data, wanted: wanted("r&d")) == nil)                // "&" is rewritten in HTML
        #expect(BodyScanner.rawCandidates(in: data, wanted: wanted("café")) == nil)               // non-ASCII word: decode
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("r&d")) == ["r&d"])
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("CAFÉ")) == ["CAFÉ"])                 // case ignored, accent matches
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("cafe")) == [])                       // accents are significant
    }

    @Test func accentedTextIsReadFromQuotedPrintableToo() throws {
        let (url, cleanup) = try file(message(headers: ["Content-Type: text/plain; charset=utf-8",
                                                        "Content-Transfer-Encoding: quoted-printable"], body: "Un caf=C3=A9 s'il vous pla=C3=AEt."))
        defer { cleanup() }
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("café")) == ["café"])
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("plaît")) == ["plaît"])
        #expect(BodyScanner.termsFound(in: url, wanted: wanted("vous")) == ["vous"])                 // plain words still use the fast path
    }

    @Test func aMissingOrUnreadableFileMatchesNothing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).emlx")
        #expect(BodyScanner.termsFound(in: missing, wanted: wanted("invoice")) == [])
        let result = BodyScanner.scan(terms: ["invoice"], candidates: [(1, missing), (2, nil)])
        #expect(result.scanned == [1, 2] && result.matches["invoice"] == nil)                      // read, nothing found
    }

    @Test func scanningStopsAtTheLimitsAndSaysWhatItRead() throws {
        let (url, cleanup) = try file(message(headers: ["Content-Type: text/plain"], body: "invoice"))
        defer { cleanup() }
        let candidates: [(id: Int64, file: URL?)] = (1...10).map { ($0, url) }
        let few = BodyScanner.scan(terms: ["invoice"], candidates: candidates, limits: ScanLimits(maxMessages: 4))
        #expect(few.scanned == [1, 2, 3, 4] && few.matches["invoice"] == [1, 2, 3, 4])
        let none = BodyScanner.scan(terms: ["invoice"], candidates: candidates, limits: ScanLimits(maxMessages: 10, timeLimit: 0))
        #expect(none.scanned.isEmpty && none.matches.isEmpty)
    }
}
