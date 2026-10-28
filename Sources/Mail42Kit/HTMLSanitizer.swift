// HTMLSanitizer.swift — turns a ParsedMessage into a standalone HTML document the Work42 widget can load.
//
// The widget shows the sender's own HTML, as any mail client does, so this keeps layout, styles and images.
// What it takes out is anything that can run code or navigate on its own:
//   · <script>, <iframe>, <object>, <embed>, <applet>, <frame>, <base>, <meta> (refresh / charset)
//   · every on*= event-handler attribute, srcdoc, and form action / formaction
//   · javascript: / vbscript: / data: (non-image) URLs, including entity- and whitespace-obfuscated ones
//   · HTML comments (also drops Outlook conditional comments)
// It rewrites cid: image references to data: URIs from the message's own parts, and leaves remote http(s)
// images alone (they load, as in Mail). It is a tokenizer that rebuilds every tag from a filtered attribute
// list, not a regex over the raw string, so malformed or hostile markup can't slip a tag through untouched.

import Foundation

public enum HTMLSanitizer {

    // MARK: - Public API

    /// A complete HTML document for the message: its sanitised HTML (or its text part, escaped, in a `<pre>`)
    /// inside `<body data-mail42-id="<id>">`. The `data-mail42-id` attribute is how the widget's
    /// highlight-to-comment resolver learns which message a selection came from.
    public static func render(message: ParsedMessage, id: Int64) -> String {
        var bodyAttributes = ""
        let inner: String
        if let html = message.htmlBody, !html.isEmpty {
            let result = sanitize(html, cids: cidMap(message.parts))
            inner = result.body
            bodyAttributes = result.bodyAttributes
        } else if let text = message.textBody, !text.isEmpty {
            inner = "<pre style=\"white-space:pre-wrap;font:-apple-system-body\">\(escapeText(text))</pre>"
        } else {
            inner = ""
        }
        // The CSP is a second wall behind the sanitiser: no script of any kind can run (default-src 'none' covers
        // script-src), while remote images, inline styles and fonts still load as they do in Mail.
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src * data: blob:; "
            + "style-src 'unsafe-inline' *; font-src * data:; media-src *; form-action 'none'\">"
            + "<meta name=\"color-scheme\" content=\"light dark\"></head>"
            + "<body data-mail42-id=\"\(id)\"\(bodyAttributes)>\(inner)</body></html>\n"
    }

    /// Sanitises an HTML string. Returns the markup for inside `<body>` and the sender's `<body>` attributes
    /// (bgcolor, style, class…) so the caller can put them on its own body element.
    public static func sanitize(
        _ html: String, cids: [String: ParsedPart]
    ) -> (body: String, bodyAttributes: String) {
        let bytes = Array(html.utf8)
        let n = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(n)
        var bodyAttributes = ""
        var i = 0

        func emit(_ s: String) { out.append(contentsOf: Array(s.utf8)) }

        while i < n {
            // Plain text up to the next '<'.
            if bytes[i] != 0x3C {
                var j = i
                while j < n, bytes[j] != 0x3C { j += 1 }
                out.append(contentsOf: bytes[i..<j])
                i = j
                continue
            }

            // Comment: drop it entirely (also Outlook conditional comments).
            if HTMLScanner.hasPrefix(bytes, at: i, "<!--") {
                if let close = HTMLScanner.find("-->", in: bytes, from: i + 4) { i = close + 3 } else { i = n }
                continue
            }
            // <!DOCTYPE …>, <![if …]>, <![endif]>, <?xml …?>: markers only, drop the tag.
            if i + 1 < n, bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F {
                i = HTMLScanner.endOfTag(bytes, from: i + 1) ?? n
                continue
            }

            // End tag.
            if i + 2 < n, bytes[i + 1] == 0x2F, HTMLScanner.isLetter(bytes[i + 2]) {
                var j = i + 2
                while j < n, !HTMLScanner.isSpace(bytes[j]), bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
                let name = String(decoding: bytes[(i + 2)..<j], as: UTF8.self).lowercased()
                i = HTMLScanner.endOfTag(bytes, from: j) ?? n
                if name == "html" || name == "head" || name == "body" { continue }
                emit("</\(name)>")
                continue
            }

            // Start tag.
            if i + 1 < n, HTMLScanner.isLetter(bytes[i + 1]), let tag = HTMLScanner.parseStartTag(bytes, at: i) {
                switch tag.name {
                case "script":
                    i = skipElement(bytes, named: "script", after: tag.end)
                case "iframe", "object", "applet", "frameset", "noembed":
                    i = skipElement(bytes, named: tag.name, after: tag.end)
                case "embed", "frame", "base", "meta", "html", "head":
                    i = tag.end
                case "body":
                    bodyAttributes = renderAttributes(tag, cids: cids)
                    i = tag.end
                case "style":
                    emit("<style\(renderAttributes(tag, cids: cids))>")
                    let close = HTMLScanner.find("</style", in: bytes, from: tag.end) ?? n
                    let css = String(decoding: bytes[tag.end..<close], as: UTF8.self)
                    emit(inlineCIDInCSS(css, cids: cids))
                    i = close
                default:
                    emit("<\(tag.name)\(renderAttributes(tag, cids: cids))>")
                    i = tag.end
                }
                continue
            }

            // A '<' that doesn't open markup: show it as text.
            emit("&lt;")
            i += 1
        }

        return (String(decoding: out, as: UTF8.self), bodyAttributes)
    }

    /// `cid:` lookup table for the sanitiser: lowercased Content-ID (no brackets) → the image part.
    public static func cidMap(_ parts: [ParsedPart]) -> [String: ParsedPart] {
        var map: [String: ParsedPart] = [:]
        for part in parts {
            guard part.mime.hasPrefix("image/"), let id = part.contentID, !id.isEmpty, map[id] == nil else { continue }
            map[id] = part
        }
        return map
    }

    // MARK: - Elements

    /// Index just past the closing tag of `name`, or the end of input when it never closes (so a hostile
    /// unclosed <script> swallows the rest rather than leaking it).
    private static func skipElement(_ bytes: [UInt8], named name: String, after start: Int) -> Int {
        guard let close = HTMLScanner.find("</\(name)", in: bytes, from: start) else { return bytes.count }
        return HTMLScanner.endOfTag(bytes, from: close) ?? bytes.count
    }

    // MARK: - Attributes

    /// Attributes that hold a URL and are checked for script / non-image data schemes.
    private static let urlAttributes: Set<String> = [
        "href", "src", "xlink:href", "background", "poster", "data", "codebase", "cite", "longdesc",
        "usemap", "manifest", "ping", "dynsrc", "lowsrc", "profile",
    ]
    /// Attributes that make a form or button navigate by itself: dropped outright.
    private static let droppedAttributes: Set<String> = ["action", "formaction", "srcdoc"]
    /// URL attributes where a `cid:` reference is replaced by the inline image.
    private static let cidAttributes: Set<String> = ["src", "background", "poster"]

    private static func renderAttributes(_ tag: HTMLStartTag, cids: [String: ParsedPart]) -> String {
        var result = ""
        for (name, rawValue) in tag.attributes {
            if name.hasPrefix("on") || droppedAttributes.contains(name) { continue }
            guard var value = rawValue else {
                result += " \(name)"
                continue
            }
            if urlAttributes.contains(name) {
                if isDangerousURL(value) { continue }
                if cidAttributes.contains(name), let inlined = dataURI(forCID: value, cids: cids) { value = inlined }
            } else if name == "style" {
                value = inlineCIDInCSS(value, cids: cids)
            }
            result += " \(name)=\"\(escapeAttribute(value))\""
        }
        return result
    }

    /// True for URLs that can run script or load an active document. Decodes entities and strips whitespace and
    /// control characters first, because browsers ignore those inside a scheme (`java&#x09;script:`).
    static func isDangerousURL(_ raw: String) -> Bool {
        let decoded = HTMLEntities.decode(raw)
        let compact = String(String.UnicodeScalarView(decoded.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
            .lowercased()
        if compact.hasPrefix("javascript:") || compact.hasPrefix("vbscript:") || compact.hasPrefix("livescript:") {
            return true
        }
        if compact.hasPrefix("data:") { return !compact.hasPrefix("data:image/") }
        return false
    }

    // MARK: - cid: images

    /// `data:<mime>;base64,…` for a `cid:` reference, or nil when it isn't one or no matching image part exists.
    private static func dataURI(forCID value: String, cids: [String: ParsedPart]) -> String? {
        let trimmed = HTMLEntities.decode(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cid:") else { return nil }
        var key = String(trimmed.dropFirst(4))
        key = (key.removingPercentEncoding ?? key).trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        guard let part = cids[key.lowercased()], !part.data.isEmpty else { return nil }
        return "data:\(part.mime);base64,\(part.data.base64EncodedString())"
    }

    /// Replaces `url(cid:…)` references inside CSS (a `style` attribute or a `<style>` element).
    private static func inlineCIDInCSS(_ css: String, cids: [String: ParsedPart]) -> String {
        guard !cids.isEmpty, css.range(of: "cid:", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                pattern: #"url\(\s*(['"]?)(cid:[^'")\s]+)\1\s*\)"#, options: [.caseInsensitive])
        else { return css }
        let ns = css as NSString
        var result = css
        for match in regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).reversed() {
            let reference = ns.substring(with: match.range(at: 2))
            guard let uri = dataURI(forCID: reference, cids: cids),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "url(\(uri))")
        }
        return result
    }

    // MARK: - Escaping

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "&quot;")
    }
}
