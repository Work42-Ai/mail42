// HTMLText.swift — HTML to plain text, with no dependencies, for the full-text index and for `message read`'s
// default text output when a message has only an HTML part.
//
// Not a renderer: it drops tags and the contents of <script>/<style>/<head>, turns block-level tags and <br>
// into line breaks, decodes entities, and collapses whitespace. Good enough for search and for an agent
// reading a newsletter; the widget shows the real HTML through `HTMLSanitizer`.

import Foundation

public enum HTMLText {

    /// Tags whose boundaries (open or close) start a new line.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "tr", "li", "ul", "ol", "table", "blockquote", "hr", "section", "article",
        "header", "footer", "nav", "aside", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "dl", "dt", "dd",
        "form", "fieldset", "figure", "figcaption", "address", "main",
    ]
    /// Elements whose contents are not text.
    private static let skippedElements: Set<String> = ["script", "style", "head", "title", "template"]

    public static func convert(_ html: String) -> String {
        let bytes = Array(html.utf8)
        let n = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(n / 2)
        var preDepth = 0
        var i = 0

        while i < n {
            if bytes[i] != 0x3C {
                var j = i
                while j < n, bytes[j] != 0x3C { j += 1 }
                // Source line breaks are just whitespace in HTML, except inside <pre>.
                if preDepth > 0 {
                    out.append(contentsOf: bytes[i..<j])
                } else {
                    for b in bytes[i..<j] { out.append(b == 0x0A || b == 0x0D ? 0x20 : b) }
                }
                i = j
                continue
            }
            if HTMLScanner.hasPrefix(bytes, at: i, "<!--") {
                if let close = HTMLScanner.find("-->", in: bytes, from: i + 4) { i = close + 3 } else { i = n }
                continue
            }
            if i + 1 < n, bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F {
                i = HTMLScanner.endOfTag(bytes, from: i + 1) ?? n
                continue
            }
            // End tag.
            if i + 2 < n, bytes[i + 1] == 0x2F, HTMLScanner.isLetter(bytes[i + 2]) {
                var j = i + 2
                while j < n, !HTMLScanner.isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                let name = String(decoding: bytes[(i + 2)..<j], as: UTF8.self).lowercased()
                i = HTMLScanner.endOfTag(bytes, from: j) ?? n
                if name == "pre", preDepth > 0 { preDepth -= 1 }
                if blockTags.contains(name) { out.append(0x0A) } else if name == "td" || name == "th" { out.append(0x20) }
                continue
            }
            // Start tag.
            if i + 1 < n, HTMLScanner.isLetter(bytes[i + 1]), let tag = HTMLScanner.parseStartTag(bytes, at: i) {
                if skippedElements.contains(tag.name) {
                    i = HTMLScanner.find("</\(tag.name)", in: bytes, from: tag.end)
                        .flatMap { HTMLScanner.endOfTag(bytes, from: $0) } ?? n
                    continue
                }
                if tag.name == "pre" { preDepth += 1 }
                if blockTags.contains(tag.name) { out.append(0x0A) } else if tag.name == "td" || tag.name == "th" { out.append(0x20) }
                i = tag.end
                continue
            }
            // A '<' that isn't markup.
            out.append(0x3C)
            i += 1
        }
        return normalize(HTMLEntities.decode(String(decoding: out, as: UTF8.self)))
    }

    /// Collapses runs of spaces, trims each line, and limits blank lines to one.
    static func normalize(_ text: String) -> String {
        var lines: [String] = []
        var blank = 0
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            var lastWasSpace = true
            for ch in rawLine {
                if ch == " " || ch == "\t" || ch == "\u{00A0}" || ch == "\u{200B}" || ch == "\u{000C}" {
                    if !lastWasSpace { line.append(" ") }
                    lastWasSpace = true
                } else {
                    line.append(ch)
                    lastWasSpace = false
                }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            if line.isEmpty {
                blank += 1
                if blank <= 1, !lines.isEmpty { lines.append("") }
            } else {
                blank = 0
                lines.append(line)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
