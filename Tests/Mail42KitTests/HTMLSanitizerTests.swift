import Foundation
import Testing
@testable import Mail42Kit

@Suite struct HTMLSanitizerTests {

    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func logoPart(contentID: String = "logo1") -> ParsedPart {
        ParsedPart(part: "2", filename: "logo.png", mime: "image/png", size: png.count,
                   contentID: contentID, isInline: true, data: png)
    }

    private func sanitize(_ html: String, parts: [ParsedPart] = []) -> String {
        HTMLSanitizer.sanitize(html, cids: HTMLSanitizer.cidMap(parts)).body
    }

    private func message(html: String? = nil, text: String? = nil, parts: [ParsedPart] = []) -> ParsedMessage {
        ParsedMessage(headers: [:], textBody: text, htmlBody: html, parts: parts, isPartial: false)
    }

    // MARK: - Things that must be removed

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
        #expect(out.contains("abc") || (out.contains("a") && out.contains("b") && out.contains("c")))
        #expect(!out.contains("secret"))
        #expect(!out.contains("mso only"))
        #expect(!out.contains("<!--"))
    }

    @Test func aLoneAngleBracketBecomesText() {
        let out = sanitize("if 1 < 2 and a<b then <3")
        #expect(out.contains("1 &lt; 2"))
        #expect(!out.contains("<b"))
    }

    // MARK: - Things that must survive

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

    @Test func keepsBareAttributesAndUnicodeText() {
        let out = sanitize("<input disabled value=\"café ☕\"><p>日本語 emoji 🎉</p>")
        #expect(out.contains("<input disabled value=\"café ☕\">"))
        #expect(out.contains("日本語 emoji 🎉"))
    }

    // MARK: - cid: images

    @Test func inlinesCIDImagesAsDataURIsCaseInsensitively() {
        let out = sanitize("<img src=\"cid:LOGO1\" alt=\"x\">", parts: [logoPart()])
        #expect(out.contains("src=\"data:image/png;base64,\(png.base64EncodedString())\""))
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
        let html = ParsedPart(part: "2", filename: nil, mime: "text/html", size: 3, contentID: "evil",
                              isInline: true, data: Data("<b>".utf8))
        let out = sanitize("<img src=\"cid:evil\"><a href=\"cid:evil\">x</a>", parts: [html])
        #expect(!out.contains("data:text/html"))
    }

    // MARK: - render

    @Test func rendersAFullDocumentWithTheMessageId() {
        let out = HTMLSanitizer.render(
            message: message(html: "<p>hi</p><script>x()</script>"), id: 4211)
        #expect(out.hasPrefix("<!DOCTYPE html>"))
        #expect(out.contains("<meta charset=\"utf-8\">"))
        #expect(out.contains("<meta name=\"color-scheme\" content=\"light dark\">"))
        #expect(out.contains("<body data-mail42-id=\"4211\">"))
        #expect(out.contains("<p>hi</p>"))
        #expect(!out.contains("<script"))
        #expect(out.components(separatedBy: "data-mail42-id").count == 2)
    }

    @Test func carriesTheSendersBodyAttributesOntoOurBody() {
        let out = HTMLSanitizer.render(
            message: message(html: "<html><head><title>T</title></head><body bgcolor=\"#eee\" class=\"m\" onload=\"x()\"><p>hi</p></body></html>"),
            id: 1)
        #expect(out.contains("<body data-mail42-id=\"1\" bgcolor=\"#eee\" class=\"m\">"))
        #expect(!out.contains("onload"))
        #expect(out.components(separatedBy: "<body").count == 2)        // exactly one <body>
        #expect(out.components(separatedBy: "<html").count == 2)
    }

    @Test func rendersATextOnlyMessageEscapedInAPre() {
        let out = HTMLSanitizer.render(message: message(text: "a < b & <script>x</script>"), id: 9)
        #expect(out.contains("<pre style=\"white-space:pre-wrap;font:-apple-system-body\">a &lt; b &amp; &lt;script&gt;x&lt;/script&gt;</pre>"))
        #expect(!out.contains("<script"))
    }

    @Test func rendersAnEmptyMessageWithoutCrashing() {
        let out = HTMLSanitizer.render(message: message(), id: 2)
        #expect(out.contains("<body data-mail42-id=\"2\"></body>"))
    }

    @Test func dangerousURLDetectionIsPreciseAboutSafeSchemes() {
        #expect(!HTMLSanitizer.isDangerousURL("https://example.com/javascript:foo"))
        #expect(!HTMLSanitizer.isDangerousURL("mailto:a@b.com"))
        #expect(!HTMLSanitizer.isDangerousURL("cid:logo"))
        #expect(!HTMLSanitizer.isDangerousURL("data:image/gif;base64,R0lG"))
        #expect(!HTMLSanitizer.isDangerousURL("#anchor"))
        #expect(HTMLSanitizer.isDangerousURL("  JAVASCRIPT:alert(1)"))
        #expect(HTMLSanitizer.isDangerousURL("data:text/html,<b>"))
    }
}
