// MailFixtures.swift — RFC 822 messages and the .emlx container, built in code so the tests carry no binary
// fixture files. Covers the shapes mail42 has to handle: plain text, hostile HTML with an inline image,
// a real attachment, and a `.partial.emlx` whose attachment bytes live in Mail's external cache.

import Foundation

public enum MailFixtures {

    /// A 1×1 transparent PNG.
    public static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    public static var png: Data { Data(base64Encoded: pngBase64)! }

    public static let attachmentBytes = Data("%PDF-1.4 mail42 test attachment".utf8)

    /// Wraps an RFC 822 message in the .emlx container: a byte count, a newline, exactly that many bytes of
    /// message, then Apple's plist trailer.
    public static func emlx(_ rfc822: String) -> Data {
        let message = Data(rfc822.utf8)
        var data = Data("\(message.count)\n".utf8)
        data.append(message)
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>flags</key><integer>8590195713</integer></dict></plist>

        """.utf8))
        return data
    }

    private static func crlf(_ lines: [String]) -> String { lines.joined(separator: "\r\n") }

    /// A plain-text message.
    public static func plain(
        subject: String = "mail42-qa plain zebrafish",
        from: String = "QA Plain <qa-plain@example.com>",
        messageID: String = "<plain-1@example.com>",
        body: String = "Hello from the plain test. The secret word is quokkabody."
    ) -> String {
        crlf([
            "From: \(from)", "To: Yan <yan@example.com>", "Subject: \(subject)",
            "Date: Mon, 27 Oct 2026 10:00:00 +0000", "Message-ID: \(messageID)",
            "Content-Type: text/plain; charset=utf-8", "", body, "",
        ])
    }

    /// HTML with a script, an `onclick`, a `javascript:` link, a remote image, and a `cid:` inline image
    /// (declared as `<Logo1>`, mixed case on purpose).
    public static func htmlWithInlineImage(messageID: String = "<html-1@example.com>") -> String {
        let html = "<html><head><title>t</title><style>.logo{background:url(cid:logo1)}</style></head>"
            + "<body bgcolor=\"#eeeeee\" class=\"mail\"><h1>Roadmap headline</h1>"
            + "<p onclick=\"document.title='pwned'\">Click me paragraph</p>"
            + "<script>document.body.innerHTML='SCRIPT RAN'</script>"
            + "<a href=\"javascript:alert(1)\">js link</a> <a href=\"https://example.com/\">safe link</a>"
            + "<img src=\"cid:logo1\" alt=\"inline logo\"> <img src=\"https://img.example.com/p.png\" alt=\"remote\">"
            + "</body></html>"
        return crlf([
            "From: QA Html <qa-html@example.com>", "To: Yan <yan@example.com>", "Cc: Bo <bo@example.com>",
            "Subject: mail42-qa html hostile", "Date: Mon, 27 Oct 2026 11:00:00 +0000",
            "Message-ID: \(messageID)", "MIME-Version: 1.0",
            "Content-Type: multipart/related; boundary=\"B1\"", "",
            "--B1", "Content-Type: text/html; charset=utf-8", "", html,
            "--B1", "Content-Type: image/png", "Content-Transfer-Encoding: base64",
            "Content-ID: <Logo1>", "Content-Disposition: inline; filename=\"logo.png\"", "", pngBase64,
            "--B1--", "",
        ])
    }

    /// A text body plus one real attachment, `report.pdf`.
    public static func withAttachment(messageID: String = "<attach-1@example.com>") -> String {
        crlf([
            "From: QA Attach <qa-attach@example.com>", "To: Yan <yan@example.com>",
            "Subject: mail42-qa attachment", "Date: Mon, 27 Oct 2026 12:00:00 +0000",
            "Message-ID: \(messageID)", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"B2\"", "",
            "--B2", "Content-Type: text/plain; charset=utf-8", "", "See attached report.",
            "--B2", "Content-Type: application/pdf; name=\"report.pdf\"",
            "Content-Transfer-Encoding: base64", "Content-Disposition: attachment; filename=\"report.pdf\"", "",
            attachmentBytes.base64EncodedString(),
            "--B2--", "",
        ])
    }

    /// A `.partial.emlx` for a message whose body Mail never downloaded: headers only.
    public static func partialWithoutBody(messageID: String = "<partial-2@example.com>") -> String {
        crlf([
            "From: QA Empty <qa-empty@example.com>", "To: Yan <yan@example.com>", "Subject: partial no body",
            "Date: Mon, 27 Oct 2026 14:00:00 +0000", "Message-ID: \(messageID)",
            "Content-Type: text/plain; charset=utf-8", "", "",
        ])
    }

    /// The same message as Mail stores it after externalising the attachment (a `.partial.emlx`): headers and
    /// text are there, the attachment part has no bytes.
    public static func partialWithAttachment(messageID: String = "<attach-2@example.com>") -> String {
        crlf([
            "From: QA Partial <qa-partial@example.com>", "To: Yan <yan@example.com>",
            "Subject: mail42-qa partial", "Date: Mon, 27 Oct 2026 13:00:00 +0000",
            "Message-ID: \(messageID)", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"B3\"", "",
            "--B3", "Content-Type: text/plain; charset=utf-8", "", "The attachment bytes live in Mail's cache.",
            "--B3", "Content-Type: application/pdf; name=\"report.pdf\"",
            "Content-Disposition: attachment; filename=\"report.pdf\"", "X-Apple-Content-Length: 31", "", "",
            "--B3--", "",
        ])
    }
}
