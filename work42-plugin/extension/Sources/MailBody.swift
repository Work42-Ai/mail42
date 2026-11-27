// MailBody.swift — reads one message's body from Apple Mail's .emlx file, as plain Foundation code (WOR-900).
//
// This is the "read one message" half of the `mail42` command line, moved into the extension so the widget needs no CLI:
// where the .emlx lives (`MailEmlxPath`), the .emlx → RFC 822 → MIME parse (`MailBodyParser`), the sanitiser that makes a
// sender's HTML safe to show (`MailBodySanitizer`), HTML → plain text (`MailBodyHTMLText`) and attachment decoding
// (`MailBodyAttachment`). Ported from Mail42AppleMail (EmlxLocator, MessageParser and the vendored EmlxFormat /
// RFC822Parser / MIMEParser, from che-apple-mail-mcp, MIT) and Mail42Kit (HTMLSanitizer, HTMLScanner, HTMLText,
// AttachmentSaver), keeping their behaviour.
//
// Nothing here touches the file system or the network: every function takes bytes or strings and returns values. The caller
// reads files through its own disk service (the widget may be sandboxed, or on an iPad), so `MailEmlxPath` only says which
// paths to try, and the Mail attachment cache for a `.partial.emlx` comes in through a closure.

import Foundation

// MARK: - Where the .emlx is

/// Apple Mail's file layout for a message:
///
///     <mailRoot>/<account-uuid>/<mailbox>.mbox[/<child>.mbox…]/<store-uuid>/Data/<hash>/Messages/<ROWID>.emlx
///
/// `<hash>` is the decimal digits of ROWID / 1000, written right to left and joined with `/`: nothing for ROWID < 1000, `3` for
/// 3 000…3 999, `3/2/1` for 123 456. The `<store-uuid>` folder is not in the database, so it has to be listed from disk: ask
/// `mailboxDirectory`, list it, and pass the folder names as `stores`.
nonisolated enum MailEmlxPath {

    /// A mailbox URL from Apple's index (`imap://<account-uuid>/<percent-encoded path>`) taken apart.
    struct Mailbox: Equatable, Sendable {
        let scheme: String
        let accountUUID: String
        /// Each hierarchy level, percent-decoded on its own, so an encoded `/` inside a name stays inside its component.
        let pathComponents: [String]
    }

    /// The pure mailbox-url mapping: `imap://UUID/R%26D%2FSent` → one component `R&D/Sent`; `imap://UUID/R%26D/Sent` → two.
    /// Empty segments are kept (`A//B` → `A`, ``, `B`). Nil when the URL is malformed or has no path.
    static func mailbox(from mailboxURL: String) -> Mailbox? {
        guard let schemeEnd = mailboxURL.range(of: "://") else { return nil }
        let scheme = String(mailboxURL[mailboxURL.startIndex..<schemeEnd.lowerBound])
        let afterScheme = mailboxURL[schemeEnd.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let uuid = String(afterScheme[afterScheme.startIndex..<slash])
        let encodedPath = String(afterScheme[afterScheme.index(after: slash)...])
        // Split FIRST, decode each piece SECOND.
        let components = encodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard !components.isEmpty else { return nil }
        return Mailbox(scheme: scheme, accountUUID: uuid, pathComponents: components)
    }

    /// The `<hash>` path (possibly empty) for a ROWID.
    static func hashDirectory(rowid: Int64) -> String {
        var n = rowid / 1000
        if n <= 0 { return "" }
        var digits: [String] = []
        while n > 0 {
            digits.append(String(n % 10))
            n /= 10
        }
        return digits.joined(separator: "/")
    }

    /// `<mailRoot>/<account-uuid>/<mailbox>.mbox/…`: the folder whose children are the store folders. Nil for a malformed URL, or
    /// when the path climbs out of the mail root (it comes from Apple's database; it must not be trusted blindly).
    static func mailboxDirectory(mailboxURL: String, mailRoot: String) -> String? {
        guard let mailbox = mailbox(from: mailboxURL) else { return nil }
        // `isDirectory: true` so building a URL never asks the file system.
        var directory = URL(fileURLWithPath: mailRoot, isDirectory: true)
            .appendingPathComponent(mailbox.accountUUID, isDirectory: true)
        for component in mailbox.pathComponents {
            directory.appendPathComponent("\(component).mbox", isDirectory: true)
        }
        let root = URL(fileURLWithPath: mailRoot, isDirectory: true).standardizedFileURL.path
        guard directory.standardizedFileURL.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return directory.path
    }

    /// True for a store folder name: a 36-character UUID.
    static func isStoreUUID(_ name: String) -> Bool {
        name.count == 36 && name.split(separator: "-").count == 5 && name.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The store folders among the names found in a `mailboxDirectory`, in the order they are tried.
    static func storeNames(in names: [String]) -> [String] {
        names.filter(isStoreUUID).sorted()
    }

    /// `Data/<hash>/Messages/<ROWID>.emlx` then `….partial.emlx`, relative to a store folder.
    static func relativeCandidates(rowid: Int64) -> [String] {
        let hash = hashDirectory(rowid: rowid)
        let messages = (hash.isEmpty ? "Data" : "Data/\(hash)") + "/Messages"
        return ["emlx", "partial.emlx"].map { "\(messages)/\(rowid).\($0)" }
    }

    /// The absolute paths the message's file can be at, in the order to try them: for each store folder the full `.emlx`, then
    /// the `.partial.emlx`. Empty when the URL is malformed, hostile, or `stores` is empty. Touches no file.
    static func candidates(rowid: Int64, mailboxURL: String, mailRoot: String, stores: [String] = []) -> [String] {
        guard let directory = mailboxDirectory(mailboxURL: mailboxURL, mailRoot: mailRoot) else { return [] }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        var paths: [String] = []
        for store in storeNames(in: stores) {
            let storeURL = base.appendingPathComponent(store, isDirectory: true)
            for relative in relativeCandidates(rowid: rowid) {
                paths.append(storeURL.appendingPathComponent(relative).path)
            }
        }
        return paths
    }

    /// True for a `.partial.emlx`: Mail synced the headers but has not (fully) downloaded the body.
    static func isPartial(path: String) -> Bool {
        (path as NSString).lastPathComponent.hasSuffix(".partial.emlx")
    }

    /// Mail's external attachment cache for a message: `<hash>/Attachments/<ROWID>/<part-id>/<filename>`, a sibling of `Messages`.
    static func attachmentsDirectory(forEmlx path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let rowid = String(name.prefix { $0.isNumber })
        let hashDirectory = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return ((hashDirectory as NSString).appendingPathComponent("Attachments") as NSString).appendingPathComponent(rowid)
    }
}

// MARK: - Model

nonisolated enum MailBodyError: Error, Equatable, Sendable {
    /// The bytes are not an .emlx container (no byte count, or fewer bytes than it says).
    case emlxParseFailed(String)
}

/// One leaf MIME part of a message (a text body, an inline image, an attachment).
nonisolated struct MailBodyPart: Equatable, Sendable {
    /// Its 1-based position among the leaf parts in document order (`"1"`, `"2"`, …): the `<part>` the CLI's
    /// `attachment save` takes, and `MailAttachment.part`.
    let part: String
    let filename: String?
    /// Lowercased MIME type, e.g. `image/png`.
    let mime: String
    let size: Int
    /// `Content-ID` without the angle brackets, lowercased (what `cid:` URLs in the HTML refer to).
    let contentID: String?
    /// A part the HTML refers to as `cid:…` and that isn't marked `attachment` (an inline image).
    let isInline: Bool
    /// The decoded bytes; empty when they were never downloaded.
    let data: Data

    /// Shown as an attachment: it has a filename and isn't an inline image.
    var isAttachment: Bool { filename != nil && !isInline }
}

nonisolated struct MailBodyMessage: Equatable, Sendable {
    /// Top-level headers, lowercased keys, RFC 2047-decoded values.
    let headers: [String: String]
    /// The plain-text part, when the message has one.
    let text: String?
    /// The HTML part as sent (not sanitised), when the message has one.
    let html: String?
    let parts: [MailBodyPart]
    /// True when the file was a `.partial.emlx`: Mail has the headers but not (fully) the body.
    let isPartial: Bool

    /// A partial download that carries no body at all: the widget should say "open it in Mail".
    var bodyUnavailable: Bool { isPartial && !hasBody }

    var hasBody: Bool { !(text ?? "").isEmpty || !(html ?? "").isEmpty }

    var attachments: [MailBodyPart] { parts.filter(\.isAttachment) }

    /// The attachments in the widget's shape: what `mail42 message read` listed.
    var attachmentRows: [(part: String, filename: String, mime: String, size: Int)] {
        attachments.map { ($0.part, $0.filename ?? "", $0.mime, $0.size) }
    }

    /// The RFC 5322 Message-ID with the angle brackets, when the message has one.
    var messageID: String? {
        guard let raw = headers["message-id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// What `message read --text` printed: the text part, or the HTML part as text when that is all there is.
    var plainText: String {
        if let text, !text.isEmpty { return text }
        return html.map(MailBodyHTMLText.plain(from:)) ?? ""
    }
}

// MARK: - Parser

nonisolated enum MailBodyParser {

    /// Parses the bytes of an `.emlx` or `.partial.emlx` file. `isPartial` is true for a `.partial.emlx` (see
    /// `MailEmlxPath.isPartial(path:)`); `externalAttachment` returns the bytes Mail keeps in its attachment cache for a
    /// filename, to fill the attachments a partial file no longer carries.
    static func parse(
        emlx: Data, isPartial: Bool = false, externalAttachment: ((String) -> Data?)? = nil
    ) throws -> MailBodyMessage {
        parse(rfc822: try extractMessageData(from: emlx), isPartial: isPartial, externalAttachment: externalAttachment)
    }

    /// Parses raw RFC 822 bytes.
    static func parse(
        rfc822 data: Data, isPartial: Bool, externalAttachment: ((String) -> Data?)? = nil
    ) -> MailBodyMessage {
        let headers = MailBodyMIME.parseHeaders(from: data)
        // Re-base the slice so the parsers see a zero-indexed buffer.
        let body = MailBodyMIME.headerBodySplitOffset(in: data).map { Data(data[$0...]) } ?? Data()

        let content = MailBodyMIME.parseBody(body, headers: headers)
        let leaves = MailBodyMIME.parseAllParts(body, headers: headers)

        var parts: [MailBodyPart] = []
        for (index, leaf) in leaves.enumerated() {
            let mime = leaf.contentType.lowercased()
            let disposition = leaf.contentDisposition?.lowercased()
            // The message's own text bodies aren't attachments or inline resources: skip them, but keep counting so a part's
            // id stays its position among all leaves.
            if (mime == "text/plain" || mime == "text/html"), leaf.filename == nil, disposition != "attachment" {
                continue
            }
            let contentID = normalizedContentID(leaf.headers["content-id"])
            var bytes = leaf.decodedData
            if bytes.isEmpty, isPartial, let name = leaf.filename, let external = externalAttachment {
                // Only the last path component: a hostile filename must not point outside the cache.
                let leafName = (name as NSString).lastPathComponent
                if !leafName.isEmpty, leafName != ".", leafName != ".." { bytes = external(leafName) ?? Data() }
            }
            parts.append(MailBodyPart(
                part: String(index + 1),
                filename: leaf.filename,
                mime: mime,
                size: bytes.count,
                contentID: contentID,
                isInline: contentID != nil && disposition != "attachment",
                data: bytes
            ))
        }
        return MailBodyMessage(headers: headers, text: content.text, html: content.html, parts: parts, isPartial: isPartial)
    }

    /// The .emlx container: a decimal byte count, a newline, exactly that many bytes of RFC 822, then Apple's plist trailer.
    static func extractMessageData(from data: Data) throws -> Data {
        guard let newlineIndex = data.firstIndex(of: 0x0A) else {
            throw MailBodyError.emlxParseFailed("No newline found; cannot locate byte count header")
        }
        let headerBytes = data[data.startIndex..<newlineIndex]
        guard let headerString = String(bytes: headerBytes, encoding: .utf8),
              let byteCount = Int(headerString.trimmingCharacters(in: .whitespaces)),
              byteCount >= 0
        else {
            let preview = String(
                bytes: data[data.startIndex..<min(data.startIndex + 40, data.endIndex)], encoding: .utf8) ?? "<binary>"
            throw MailBodyError.emlxParseFailed("Invalid byte count header: \(preview)")
        }
        let messageStart = data.index(after: newlineIndex)
        guard let end = data.index(messageStart, offsetBy: byteCount, limitedBy: data.endIndex) else {
            throw MailBodyError.emlxParseFailed(
                "Insufficient data: expected \(byteCount) bytes after header, "
                + "but only \(data.distance(from: messageStart, to: data.endIndex)) available")
        }
        return data[messageStart..<end]
    }

    /// `<abc@x>` → `abc@x`, lowercased; nil when absent or empty.
    private static func normalizedContentID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Attachments

nonisolated enum MailBodyAttachment {

    /// The filename and decoded bytes of an attachment by its part id, or nil when the message has no such attachment or its
    /// bytes were never downloaded. The name is already safe to use as a single file name (see `safeName`). Writes nothing.
    static func extract(
        emlx: Data, part: String, isPartial: Bool = false, externalAttachment: ((String) -> Data?)? = nil
    ) -> (filename: String, data: Data)? {
        guard let message = try? MailBodyParser.parse(emlx: emlx, isPartial: isPartial, externalAttachment: externalAttachment),
              let attachment = message.parts.first(where: { $0.part == part && $0.filename != nil }),
              !attachment.data.isEmpty
        else { return nil }
        return (safeName(attachment.filename, fallback: "attachment-\(part)"), attachment.data)
    }

    /// A safe single-component filename, or `fallback` when nothing usable is left. The filename comes from an email, so it is
    /// untrusted: only its last path component is used, control characters and separators are removed, and a leading dot is
    /// replaced (no hidden files, no `../x`).
    static func safeName(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        var name = (raw as NSString).lastPathComponent
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }      // never a hidden file
        // Nothing but dots and underscores left (`.`, `..`, `/`): no real name, use the fallback.
        return (name.isEmpty || name.allSatisfy { $0 == "." || $0 == "_" }) ? fallback : name
    }

    /// The name to try on the `attempt`th collision: `report.pdf`, `report (1).pdf`, `report (2).pdf`, …
    static func numberedName(_ name: String, attempt: Int) -> String {
        guard attempt > 0 else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
    }
}

// MARK: - HTML → plain text

nonisolated enum MailBodyHTMLText {

    /// Tags whose boundaries (open or close) start a new line.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "tr", "li", "ul", "ol", "table", "blockquote", "hr", "section", "article",
        "header", "footer", "nav", "aside", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "dl", "dt", "dd",
        "form", "fieldset", "figure", "figcaption", "address", "main",
    ]
    /// Elements whose contents are not text.
    private static let skippedElements: Set<String> = ["script", "style", "head", "title", "template"]

    /// Not a renderer: drops tags and the contents of `<script>`/`<style>`/`<head>`, turns block-level tags and `<br>` into line
    /// breaks, decodes entities, and collapses whitespace.
    static func plain(from html: String) -> String {
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
            if MailBodyScanner.hasPrefix(bytes, at: i, "<!--") {
                if let close = MailBodyScanner.find("-->", in: bytes, from: i + 4) { i = close + 3 } else { i = n }
                continue
            }
            if i + 1 < n, bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F {
                i = MailBodyScanner.endOfTag(bytes, from: i + 1) ?? n
                continue
            }
            // End tag.
            if i + 2 < n, bytes[i + 1] == 0x2F, MailBodyScanner.isLetter(bytes[i + 2]) {
                var j = i + 2
                while j < n, !MailBodyScanner.isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                let name = String(decoding: bytes[(i + 2)..<j], as: UTF8.self).lowercased()
                i = MailBodyScanner.endOfTag(bytes, from: j) ?? n
                if name == "pre", preDepth > 0 { preDepth -= 1 }
                if blockTags.contains(name) { out.append(0x0A) } else if name == "td" || name == "th" { out.append(0x20) }
                continue
            }
            // Start tag.
            if i + 1 < n, MailBodyScanner.isLetter(bytes[i + 1]), let tag = MailBodyScanner.parseStartTag(bytes, at: i) {
                if skippedElements.contains(tag.name) {
                    i = MailBodyScanner.find("</\(tag.name)", in: bytes, from: tag.end)
                        .flatMap { MailBodyScanner.endOfTag(bytes, from: $0) } ?? n
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
        return normalize(MailBodyEntities.decode(String(decoding: out, as: UTF8.self)))
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

// MARK: - Sanitiser

/// Makes a sender's HTML safe for the widget to load. It keeps layout, styles and images, as any mail client does, and takes out
/// anything that can run code or navigate on its own:
///   · `<script>`, `<iframe>`, `<object>`, `<embed>`, `<applet>`, `<frame>`, `<base>`, `<meta>` (refresh / charset)
///   · every `on*=` event-handler attribute, `srcdoc`, and form `action` / `formaction`
///   · `javascript:` / `vbscript:` / `data:` (non-image) URLs, including entity- and whitespace-obfuscated ones
///   · HTML comments (also drops Outlook conditional comments)
/// It rewrites `cid:` image references to `data:` URIs from the message's own parts, and leaves remote http(s) images alone (they
/// load, as in Mail). It is a tokenizer that rebuilds every tag from a filtered attribute list, not a regex over the raw string,
/// so malformed or hostile markup can't slip a tag through untouched.
nonisolated enum MailBodySanitizer {

    /// The HTML to put inside `<body>`; `parts` are the message's parts, for `cid:` images.
    static func sanitize(html: String, parts: [MailBodyPart] = []) -> String {
        sanitizeWithBodyAttributes(html: html, parts: parts).body
    }

    /// A complete HTML document for the message: its sanitised HTML (or its text part, escaped, in a `<pre>`) inside
    /// `<body data-mail42-id="<id>">`. The attribute is how the widget's highlight-to-comment resolver learns which message a
    /// selection came from.
    static func render(message: MailBodyMessage, id: Int64) -> String {
        var bodyAttributes = ""
        let inner: String
        if let html = message.html, !html.isEmpty {
            let result = sanitizeWithBodyAttributes(html: html, parts: message.parts)
            inner = result.body
            bodyAttributes = result.bodyAttributes
        } else if let text = message.text, !text.isEmpty {
            inner = "<pre style=\"white-space:pre-wrap;font:-apple-system-body\">\(escapeText(text))</pre>"
        } else {
            inner = ""
        }
        // The CSP is a second wall behind the sanitiser: no script of any kind can run (default-src 'none' covers script-src),
        // while remote images, inline styles and fonts still load as they do in Mail.
        // Remote content (`img-src *`, `style-src *`, `@import`, CSS `url()`, remote `<img>`) is allowed DELIBERATELY, mirroring
        // the original CLI, whose tests require remote images to survive. That also lets a sender see that a message was opened
        // (tracking pixels); blocking remote loads is a product decision, not something to tighten here.
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src * data: blob:; "
            + "style-src 'unsafe-inline' *; font-src * data:; media-src *; form-action 'none'\">"
            + "<meta name=\"color-scheme\" content=\"light dark\"></head>"
            + "<body data-mail42-id=\"\(id)\"\(bodyAttributes)>\(inner)</body></html>\n"
    }

    /// The markup for inside `<body>` and the sender's `<body>` attributes (bgcolor, style, class…), so the caller can put them
    /// on its own body element.
    static func sanitizeWithBodyAttributes(html: String, parts: [MailBodyPart] = []) -> (body: String, bodyAttributes: String) {
        sanitize(html, cids: cidMap(parts))
    }

    /// `cid:` lookup table: lowercased Content-ID (no brackets) → the image part.
    static func cidMap(_ parts: [MailBodyPart]) -> [String: MailBodyPart] {
        var map: [String: MailBodyPart] = [:]
        for part in parts {
            guard part.mime.hasPrefix("image/"), let id = part.contentID, !id.isEmpty, map[id] == nil else { continue }
            map[id] = part
        }
        return map
    }

    private static func sanitize(_ html: String, cids: [String: MailBodyPart]) -> (body: String, bodyAttributes: String) {
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
            if MailBodyScanner.hasPrefix(bytes, at: i, "<!--") {
                if let close = MailBodyScanner.find("-->", in: bytes, from: i + 4) { i = close + 3 } else { i = n }
                continue
            }
            // <!DOCTYPE …>, <![if …]>, <![endif]>, <?xml …?>: markers only, drop the tag.
            if i + 1 < n, bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F {
                i = MailBodyScanner.endOfTag(bytes, from: i + 1) ?? n
                continue
            }

            // End tag.
            if i + 2 < n, bytes[i + 1] == 0x2F, MailBodyScanner.isLetter(bytes[i + 2]) {
                var j = i + 2
                while j < n, !MailBodyScanner.isSpace(bytes[j]), bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
                let name = String(decoding: bytes[(i + 2)..<j], as: UTF8.self).lowercased()
                i = MailBodyScanner.endOfTag(bytes, from: j) ?? n
                if name == "html" || name == "head" || name == "body" { continue }
                emit("</\(name)>")
                continue
            }

            // Start tag.
            if i + 1 < n, MailBodyScanner.isLetter(bytes[i + 1]), let tag = MailBodyScanner.parseStartTag(bytes, at: i) {
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
                    let close = MailBodyScanner.find("</style", in: bytes, from: tag.end) ?? n
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

    // MARK: Elements

    /// Index just past the closing tag of `name`, or the end of input when it never closes (so a hostile unclosed `<script>`
    /// swallows the rest rather than leaking it).
    private static func skipElement(_ bytes: [UInt8], named name: String, after start: Int) -> Int {
        guard let close = MailBodyScanner.find("</\(name)", in: bytes, from: start) else { return bytes.count }
        return MailBodyScanner.endOfTag(bytes, from: close) ?? bytes.count
    }

    // MARK: Attributes

    /// Attributes that hold a URL and are checked for script / non-image data schemes.
    private static let urlAttributes: Set<String> = [
        "href", "src", "xlink:href", "background", "poster", "data", "codebase", "cite", "longdesc",
        "usemap", "manifest", "ping", "dynsrc", "lowsrc", "profile",
    ]
    /// Attributes that make a form or button navigate by itself: dropped outright.
    private static let droppedAttributes: Set<String> = ["action", "formaction", "srcdoc"]
    /// URL attributes where a `cid:` reference is replaced by the inline image.
    private static let cidAttributes: Set<String> = ["src", "background", "poster"]

    private static func renderAttributes(_ tag: MailBodyStartTag, cids: [String: MailBodyPart]) -> String {
        var result = ""
        for (name, rawValue) in tag.attributes {
            if name.hasPrefix("on") || droppedAttributes.contains(name) { continue }
            guard var value = rawValue else {
                result += " \(name)"
                continue
            }
            if urlAttributes.contains(name) {
                if isDangerousURL(value, allowRasterDataImage: tag.name == "img" && name == "src") { continue }
                if cidAttributes.contains(name), let inlined = dataURI(forCID: value, cids: cids) { value = inlined }
            } else if name == "style" {
                value = inlineCIDInCSS(value, cids: cids)
            }
            result += " \(name)=\"\(escapeAttribute(value))\""
        }
        return result
    }

    /// True for URLs that can run script or load an active document. Decodes entities and strips whitespace and control
    /// characters first, because browsers ignore those inside a scheme (`java&#x09;script:`).
    ///
    /// - Parameter allowRasterDataImage: whether a `data:` URI of a raster image (png, jpeg, gif, webp) is acceptable: only in
    ///   `<img src>`. Everywhere else (a link above all) `data:` is rejected whole; SVG is never accepted, it can hold script.
    static func isDangerousURL(_ raw: String, allowRasterDataImage: Bool = true) -> Bool {
        let decoded = MailBodyEntities.decodeAttribute(raw)
        let compact = String(String.UnicodeScalarView(decoded.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
            .lowercased()
        if compact.hasPrefix("javascript:") || compact.hasPrefix("vbscript:") || compact.hasPrefix("livescript:") {
            return true
        }
        if compact.hasPrefix("data:") {
            guard allowRasterDataImage else { return true }
            return !["png", "jpeg", "gif", "webp"].contains { compact.hasPrefix("data:image/\($0)") && isEndOfMIMEType(compact, after: "data:image/\($0)") }
        }
        return false
    }

    /// `data:image/png;base64,…` / `data:image/png,…`: the type ends there, so `image/png+xml`-style suffixes don't pass.
    private static func isEndOfMIMEType(_ compact: String, after prefix: String) -> Bool {
        let rest = compact.dropFirst(prefix.count)
        return rest.first == ";" || rest.first == ","
    }

    // MARK: cid: images

    /// `data:<mime>;base64,…` for a `cid:` reference, or nil when it isn't one or no matching image part exists.
    private static func dataURI(forCID value: String, cids: [String: MailBodyPart]) -> String? {
        let trimmed = MailBodyEntities.decode(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cid:") else { return nil }
        var key = String(trimmed.dropFirst(4))
        key = (key.removingPercentEncoding ?? key).trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        guard let part = cids[key.lowercased()], !part.data.isEmpty else { return nil }
        return "data:\(part.mime);base64,\(part.data.base64EncodedString())"
    }

    /// Replaces `url(cid:…)` references inside CSS (a `style` attribute or a `<style>` element).
    private static func inlineCIDInCSS(_ css: String, cids: [String: MailBodyPart]) -> String {
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

    // MARK: Escaping

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - HTML tokenizer helpers

/// A parsed start tag: `<name attr="v" flag>`.
nonisolated struct MailBodyStartTag {
    /// Lowercased tag name.
    var name: String
    /// Attributes in source order; names lowercased; `nil` value for a bare flag like `disabled`.
    var attributes: [(name: String, value: String?)]
    /// Index just past the closing `>`.
    var end: Int
}

/// Works on UTF-8 bytes: every delimiter HTML cares about (`<`, `>`, quotes, `=`) is ASCII, and ASCII bytes never occur inside
/// a multi-byte UTF-8 sequence, so slicing and re-joining byte ranges can't split a character.
nonisolated enum MailBodyScanner {

    static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    static func lower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 32 : b
    }

    /// True when `bytes[i...]` starts with `prefix`, ignoring ASCII case.
    static func hasPrefix(_ bytes: [UInt8], at i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard i + p.count <= bytes.count else { return false }
        for k in 0..<p.count where lower(bytes[i + k]) != lower(p[k]) { return false }
        return true
    }

    /// Index of the first occurrence of `needle` (ASCII, case-insensitive) at or after `from`.
    static func find(_ needle: String, in bytes: [UInt8], from: Int) -> Int? {
        let p = Array(needle.utf8)
        guard !p.isEmpty, bytes.count >= p.count, from <= bytes.count - p.count else { return nil }
        var i = from
        let last = bytes.count - p.count
        let first = lower(p[0])
        while i <= last {
            if lower(bytes[i]) == first {
                var matched = true
                var k = 1
                while k < p.count {
                    if lower(bytes[i + k]) != lower(p[k]) { matched = false; break }
                    k += 1
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    /// Index just past the next `>` at or after `from`, or nil.
    static func endOfTag(_ bytes: [UInt8], from: Int) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == 0x3E { return i + 1 }
            i += 1
        }
        return nil
    }

    /// Parses the start tag at `i` (`bytes[i] == '<'` and a letter follows). Returns nil when the tag has no closing `>` (the
    /// caller then treats the `<` as text).
    static func parseStartTag(_ bytes: [UInt8], at i: Int) -> MailBodyStartTag? {
        let n = bytes.count
        var j = i + 1
        let nameStart = j
        while j < n, !isSpace(bytes[j]), bytes[j] != 0x2F, bytes[j] != 0x3E { j += 1 }
        let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
        var attributes: [(name: String, value: String?)] = []

        while j < n {
            while j < n, isSpace(bytes[j]) || bytes[j] == 0x2F { j += 1 }
            guard j < n else { return nil }
            if bytes[j] == 0x3E {
                return MailBodyStartTag(name: name, attributes: attributes, end: j + 1)
            }
            let attrStart = j
            while j < n, !isSpace(bytes[j]), bytes[j] != 0x3D, bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
            if j == attrStart { j += 1; continue }
            let attrName = String(decoding: bytes[attrStart..<j], as: UTF8.self).lowercased()
            while j < n, isSpace(bytes[j]) { j += 1 }
            if j < n, bytes[j] == 0x3D {
                j += 1
                while j < n, isSpace(bytes[j]) { j += 1 }
                guard j < n else { return nil }
                var value: String
                if bytes[j] == 0x22 || bytes[j] == 0x27 {
                    let quote = bytes[j]
                    j += 1
                    let valueStart = j
                    while j < n, bytes[j] != quote { j += 1 }
                    guard j < n else { return nil }
                    value = String(decoding: bytes[valueStart..<j], as: UTF8.self)
                    j += 1
                } else {
                    let valueStart = j
                    while j < n, !isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                    value = String(decoding: bytes[valueStart..<j], as: UTF8.self)
                }
                attributes.append((attrName, value))
            } else {
                attributes.append((attrName, nil))
            }
        }
        return nil
    }
}

/// Minimal HTML entity decoding: numeric references and the named entities that show up in real email.
nonisolated enum MailBodyEntities {

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "laquo": "«", "raquo": "»", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "deg": "°", "times": "×", "divide": "÷", "plusmn": "±", "sect": "§", "para": "¶",
        "colon": ":", "tab": "\t", "newline": "\n", "excl": "!", "num": "#", "dollar": "$",
        "percnt": "%", "lpar": "(", "rpar": ")", "sol": "/", "semi": ";", "equals": "=",
        "quest": "?", "commat": "@", "lbrack": "[", "rbrack": "]", "lowbar": "_", "period": ".",
        "comma": ",", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}",
        "zwj": "\u{200D}", "shy": "\u{00AD}",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                if let decoded = decodeBody(body) {
                    out.append(decoded)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    /// Named references browsers decode in an attribute even without the closing `;`.
    private static let legacyNamed: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    /// Character references as a browser decodes them in an attribute value (HTML5): numeric ones need no `;` and may have any
    /// number of leading zeros; named ones need the `;`, except the legacy few, which stop at `=` or a letter/digit. Used to
    /// see a URL the way the browser will, so `jav&#97script:` and `&#106avascript:` can't hide a scheme.
    static func decodeAttribute(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func isAlnum(_ c: Unicode.Scalar) -> Bool { c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c)) }
        while i < scalars.count {
            guard scalars[i] == "&", i + 1 < scalars.count else { out.append(scalars[i]); i += 1; continue }
            var j = i + 1
            if scalars[j] == "#" {
                j += 1
                var radix: UInt32 = 10
                if j < scalars.count, scalars[j] == "x" || scalars[j] == "X" { radix = 16; j += 1 }
                var value: UInt32 = 0
                var digits = 0
                while j < scalars.count, let digit = Character(scalars[j]).hexDigitValue, UInt32(digit) < radix {
                    value = min(value * radix + UInt32(digit), 0x110000)   // saturate: anything past U+10FFFF is the same
                    digits += 1
                    j += 1
                }
                guard digits > 0 else { out.append(scalars[i]); i += 1; continue }
                if j < scalars.count, scalars[j] == ";" { j += 1 }
                out.append(Unicode.Scalar(value).flatMap { $0.value == 0 ? nil : $0 } ?? "\u{FFFD}")
                i = j
                continue
            }
            var name = ""
            while j < scalars.count, isAlnum(scalars[j]), name.count < 32 { name.unicodeScalars.append(scalars[j]); j += 1 }
            if !name.isEmpty {
                if j < scalars.count, scalars[j] == ";", let decoded = named[name.lowercased()] {
                    out.append(contentsOf: decoded.unicodeScalars)
                    i = j + 1
                    continue
                }
                let next: Unicode.Scalar? = j < scalars.count ? scalars[j] : nil
                if legacyNamed.contains(name.lowercased()), next != "=", next.map(isAlnum) != true, let decoded = named[name.lowercased()] {
                    out.append(contentsOf: decoded.unicodeScalars)
                    i = j
                    continue
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    private static func decodeBody(_ body: Substring) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[body.lowercased()]
    }
}

// MARK: - RFC 822 / MIME

/// A fully-decoded leaf MIME part, before `MailBodyParser` numbers it.
nonisolated struct MailBodyLeaf: Equatable, Sendable {
    let headers: [String: String]
    let contentType: String
    let contentTypeParams: [String: String]
    let contentDisposition: String?
    let filename: String?
    let decodedData: Data
}

/// The header, multipart and transfer-encoding parsing the body reader is built on (the vendored RFC822Parser + MIMEParser).
nonisolated enum MailBodyMIME {

    /// Maximum depth of nested multipart recursion. Guards against maliciously-crafted messages.
    static let maxMultipartDepth = 8

    // MARK: Headers

    /// Header names are lowercased. Values are decoded (folding removed, RFC 2047 decoded; not for `content-*` headers, whose
    /// encoded-words are decoded per parameter).
    static func parseHeaders(from data: Data) -> [String: String] {
        if let splitIdx = findDoubleCRLF(in: data) {
            return parseHeaderBlock(data[data.startIndex..<splitIdx])
        }
        // No body separator found — treat entire data as headers.
        return parseHeaderBlock(data)
    }

    /// The absolute Data index where the body begins (after `\r\n\r\n` or `\n\n`), suitable for `data[returnedIndex...]`.
    static func headerBodySplitOffset(in data: Data) -> Int? {
        if data.count >= 4 {
            for i in data.startIndex..<(data.endIndex - 3) {
                if data[i] == 0x0D && data[i + 1] == 0x0A && data[i + 2] == 0x0D && data[i + 3] == 0x0A { return i + 4 }
            }
        }
        // Fallback: some messages use bare LF.
        if data.count >= 2 {
            for i in data.startIndex..<(data.endIndex - 1) {
                if data[i] == 0x0A && data[i + 1] == 0x0A { return i + 2 }
            }
        }
        return nil
    }

    /// The index of the first byte of the separator, for `data[..<returnedIndex]`.
    private static func findDoubleCRLF(in data: Data) -> Int? {
        if data.count >= 4 {
            for i in data.startIndex..<(data.endIndex - 3) {
                if data[i] == 0x0D && data[i + 1] == 0x0A && data[i + 2] == 0x0D && data[i + 3] == 0x0A { return i }
            }
        }
        if data.count >= 2 {
            for i in data.startIndex..<(data.endIndex - 1) {
                if data[i] == 0x0A && data[i + 1] == 0x0A { return i }
            }
        }
        return nil
    }

    private static func parseHeaderBlock(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return [:] }

        // Unfold continuation lines: replace line break + whitespace with a single space.
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r\n\t", with: " ")
            .replacingOccurrences(of: "\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")

        var headers: [String: String] = [:]
        for line in unfolded.components(separatedBy: .newlines) {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIdx]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            // Structured MIME headers are NOT RFC 2047-decoded here (RFC 2047 §5): a filename encoded-word is decoded per
            // parameter in `resolveFilename`; a header-level scan mangles ones split across RFC 2231 continuations.
            headers[name] = name.hasPrefix("content-") ? value : decodeRFC2047(value)
        }
        return headers
    }

    // MARK: RFC 2047 encoded words

    /// Decodes `=?charset?B|Q?text?=` words in a header value. Adjacent words sharing one charset are decoded as a run (the
    /// charset conversion applies to their concatenated bytes), because a multi-byte character can straddle a word boundary.
    static func decodeRFC2047(_ value: String) -> String {
        var result = ""
        var remaining = value[value.startIndex...]
        var lastWasEncodedWord = false

        struct RunWord { let bytes: Data; let range: Range<String.Index> }
        var runEncoding: String.Encoding?
        var runWords: [RunWord] = []
        /// Whitespace after the last run word, not yet committed either way.
        var heldSeparator: Substring?

        /// Emit the open run. Returns whether the last thing emitted counts as a decoded encoded-word, which decides (RFC 2047
        /// §6.2) whether a following separator is dropped or kept.
        func flushRun() -> Bool {
            guard let encoding = runEncoding, !runWords.isEmpty else { return lastWasEncodedWord }
            defer { runEncoding = nil; runWords = [] }

            let joined = runWords.reduce(into: Data()) { $0.append($1.bytes) }
            if let decoded = String(data: joined, encoding: encoding) {
                result += decoded
                return true
            }

            // The run does not decode as a unit: decode word by word; a word that fails alone is emitted verbatim, and a
            // separator survives exactly when the word before it failed.
            var lastOK = false
            for (i, word) in runWords.enumerated() {
                if i > 0, !lastOK {
                    result += value[runWords[i - 1].range.upperBound..<word.range.lowerBound]
                }
                if let decoded = String(data: word.bytes, encoding: encoding) {
                    result += decoded
                    lastOK = true
                } else {
                    result += value[word.range]
                    lastOK = false
                }
            }
            return lastOK
        }

        /// Close the run and settle the held separator with it.
        func closeRun() {
            let decodedLast = flushRun()
            if let separator = heldSeparator {
                if !decodedLast { result += separator }
                heldSeparator = nil
            }
            lastWasEncodedWord = decodedLast
        }

        while !remaining.isEmpty {
            guard let startRange = remaining.range(of: "=?", options: .literal) else {
                closeRun()
                result += remaining
                break
            }

            let prefix = remaining[remaining.startIndex..<startRange.lowerBound]
            // Iterates unicodeScalars because Swift treats "\r\n" as a single grapheme cluster that equals no single literal.
            let prefixIsLWS = !prefix.isEmpty && prefix.unicodeScalars.allSatisfy {
                $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
            }
            if prefix.isEmpty {
                // nothing between the words
            } else if lastWasEncodedWord && prefixIsLWS {
                // Whitespace between two encoded words is dropped, but only if what follows really is one: hold it.
                heldSeparator = prefix
            } else {
                closeRun()
                result += prefix
            }

            let afterEq = remaining[startRange.upperBound...]
            guard let parsed = parseEncodedWord(afterEq) else {
                closeRun()
                result += "=?"
                remaining = remaining[startRange.upperBound...]
                lastWasEncodedWord = false
                continue
            }

            // Transport decode only: the charset conversion belongs to the run.
            var bytes: Data?
            if parsed.encoding == "B" {
                bytes = Data(base64Encoded: parsed.text)
            } else if parsed.encoding == "Q" {
                // In encoded-words, `_` stands for space.
                bytes = decodeQuotedPrintableBytes(parsed.text.replacingOccurrences(of: "_", with: " "))
            }

            if let bytes = bytes {
                let encoding = stringEncoding(for: parsed.charset)
                // Compare the RESOLVED encoding, not the label: `utf-8` and `utf8` share a run.
                if let open = runEncoding, open != encoding { closeRun() }
                if runEncoding == nil { runEncoding = encoding }
                runWords.append(RunWord(bytes: bytes, range: startRange.lowerBound..<parsed.endIndex))
                heldSeparator = nil
                lastWasEncodedWord = true
            } else {
                // Cannot even transport-decode: this word joins no run.
                let decodedLast = flushRun()
                if let separator = heldSeparator {
                    if !decodedLast { result += separator }
                    heldSeparator = nil
                }
                result += String(remaining[startRange.lowerBound..<parsed.endIndex])
                lastWasEncodedWord = false
            }

            remaining = remaining[parsed.endIndex...]
        }

        closeRun()
        if let separator = heldSeparator { result += separator }
        return result
    }

    private struct EncodedWord {
        let charset: String
        let encoding: String
        let text: String
        let endIndex: Substring.Index
    }

    /// Parses an encoded word after the initial "=?" was consumed: `utf-8?Q?=E9=84=AD?= rest`.
    private static func parseEncodedWord(_ input: Substring) -> EncodedWord? {
        guard let q1 = input.firstIndex(of: "?") else { return nil }
        let charset = String(input[input.startIndex..<q1])

        let afterQ1 = input.index(after: q1)
        guard afterQ1 < input.endIndex else { return nil }
        let encoding = String(input[afterQ1]).uppercased()
        guard encoding == "B" || encoding == "Q" else { return nil }

        let q2 = input.index(after: afterQ1)
        guard q2 < input.endIndex, input[q2] == "?" else { return nil }

        let textStart = input.index(after: q2)
        let textRegion = input[textStart...]
        guard let endRange = textRegion.range(of: "?=", options: .literal) else { return nil }

        return EncodedWord(
            charset: charset,
            encoding: encoding,
            text: String(textRegion[textRegion.startIndex..<endRange.lowerBound]),
            endIndex: endRange.upperBound
        )
    }

    static func decodeQuotedPrintableBytes(_ text: String) -> Data? {
        var data = Data()
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "=" {
                let next1 = text.index(after: i)
                guard next1 < text.endIndex else {
                    data.append(contentsOf: "=".utf8)
                    break
                }
                let next2 = text.index(after: next1)
                guard next2 < text.endIndex else {
                    data.append(contentsOf: String(text[i...next1]).utf8)
                    break
                }
                let hex = String(text[next1]) + String(text[next2])
                if let byte = UInt8(hex, radix: 16) {
                    data.append(byte)
                    i = text.index(after: next2)
                    continue
                }
                // Soft line break (RFC 2045 §6.7): `=` at end of line, the break itself removed. Compared as scalars, because
                // Swift folds "\r\n" into one Character that equals neither "\r" nor "\n".
                let scalars = String(text[next1]).unicodeScalars
                if scalars.allSatisfy({ $0 == "\r" || $0 == "\n" }) {
                    i = text.index(after: next1)
                    continue
                }
                data.append(contentsOf: "=".utf8)
                i = next1
                continue
            }
            data.append(contentsOf: String(ch).utf8)
            i = text.index(after: i)
        }
        return data
    }

    /// Maps a charset name to a `String.Encoding` (unknown names read as UTF-8).
    static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "iso-8859-2":
            return .isoLatin2
        case "iso-2022-jp":
            return .iso2022JP
        case "euc-jp":
            return .japaneseEUC
        case "shift_jis", "shift-jis":
            return .shiftJIS
        case "big5":
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String.Encoding(rawValue: cfEnc)
        case "gb2312", "gbk", "gb18030":
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: cfEnc)
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "us-ascii", "ascii":
            return .ascii
        default:
            return .utf8
        }
    }

    // MARK: Text bodies

    /// The first `text/plain` and the first `text/html` of a body; everything else is discarded.
    static func parseBody(_ bodyData: Data, headers: [String: String]) -> (text: String?, html: String?) {
        var budget = PartBudget()
        return parsePart(
            bodyData,
            contentType: headers["content-type"] ?? "text/plain",
            encoding: headers["content-transfer-encoding"] ?? "7bit",
            depth: 0,
            budget: &budget)
    }

    /// The most parts one message's body parse will look at: a hostile message can't make it do unbounded work.
    static let maxBodyParts = 2_000

    private struct PartBudget {
        var parts = 0
    }

    private static func parsePart(
        _ data: Data, contentType: String, encoding: String, depth: Int, budget: inout PartBudget
    ) -> (text: String?, html: String?) {
        let (mimeType, params) = parseContentType(contentType)

        if mimeType.hasPrefix("multipart/") {
            // Too deep (the limit the attachment parser enforces): an opaque leaf, the rest of the message is still read.
            guard depth < maxMultipartDepth, let boundary = params["boundary"] else { return (nil, nil) }
            return parseMultipart(data, boundary: boundary, depth: depth, budget: &budget)
        }

        var decoded = decodeTransferEncoding(data, encoding: encoding)
        if mimeType.hasPrefix("text/") {
            decoded = salvageMislabelledQuotedPrintable(decoded, declaredEncoding: encoding)
        }
        let text = decodeBodyText(decoded, declaredCharset: params["charset"] ?? "utf-8")

        if mimeType == "text/html" { return (nil, text) }
        if mimeType.hasPrefix("text/") { return (text, nil) }
        // Non-text parts (attachments, images) — skip.
        return (nil, nil)
    }

    private static func parseMultipart(
        _ data: Data, boundary: String, depth: Int, budget: inout PartBudget
    ) -> (text: String?, html: String?) {
        let boundaryMarker = "--\(boundary)"

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return (nil, nil) }

        var textBody: String?
        var htmlBody: String?

        for part in text.components(separatedBy: boundaryMarker) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("--") { continue }
            budget.parts += 1
            if budget.parts > maxBodyParts { break }

            // Each part has its own headers + body.
            let partData = Data(part.utf8)
            guard let splitOffset = headerBodySplitOffset(in: partData) else { continue }

            let partHeaders = parseHeaders(from: partData)
            let partBody = partData[splitOffset...]

            let result = parsePart(
                Data(partBody),
                contentType: partHeaders["content-type"] ?? "text/plain",
                encoding: partHeaders["content-transfer-encoding"] ?? "7bit",
                depth: depth + 1,
                budget: &budget)

            if let t = result.text, textBody == nil { textBody = t }
            if let h = result.html, htmlBody == nil { htmlBody = h }
        }
        return (textBody, htmlBody)
    }

    /// Charset labels that say nothing reliable about the bytes: the ASCII labels cannot name a non-ASCII byte at all, and the
    /// Latin-1 family is what senders write when they did not think about the charset.
    private static let weakCharsetLabels: Set<String> = [
        "us-ascii", "ascii", "iso-8859-1", "latin1", "windows-1252", "cp1252",
    ]

    /// Decodes a text body's bytes to a `String`. Total: a body is never dropped.
    ///  1. Under a weak label, non-ASCII bytes that are strictly valid UTF-8 are UTF-8 (before the declared charset: a Latin-1
    ///     decode never fails, so tried first it would turn UTF-8 into mojibake).
    ///  2. Otherwise the declared charset, so a real `big5` / `shift_jis` / … body is never second-guessed.
    ///  3. If that fails, UTF-8.
    ///  4. Last resort: Latin-1, which maps every byte to a scalar.
    static func decodeBodyText(_ data: Data, declaredCharset: String) -> String {
        let label = declaredCharset.trimmingCharacters(in: .whitespaces).lowercased()
        if weakCharsetLabels.contains(label),
           data.contains(where: { $0 >= 0x80 }),
           let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return String(data: data, encoding: stringEncoding(for: label))
            ?? String(data: data, encoding: .utf8)
            ?? String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    // MARK: Content-Type

    /// Splits a Content-Type value into its lowercased MIME type and parameters.
    static func parseContentType(_ value: String) -> (String, [String: String]) {
        let parts = value.components(separatedBy: ";")
        let mimeType = parts[0].trimmingCharacters(in: .whitespaces).lowercased()

        var params: [String: String] = [:]
        for i in 1..<parts.count {
            let param = parts[i].trimmingCharacters(in: .whitespaces)
            if let eqIdx = param.firstIndex(of: "=") {
                let key = String(param[param.startIndex..<eqIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                var val = String(param[param.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes.
                if val.hasPrefix("\"") && val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
                params[key] = val
            }
        }
        return (mimeType, params)
    }

    // MARK: Transfer encoding

    /// Recovers a text part that declares `7bit`/`8bit`/`binary` but is really quoted-printable (a real newsletter does). The
    /// guess is self-validating, so honest text is never corrupted: it fires only when the part holds a `=XX` escape or soft line
    /// break, the QP decode is valid UTF-8, and it recovers at least one non-ASCII scalar (`=41` alone decodes to ASCII: refused).
    static func salvageMislabelledQuotedPrintable(_ data: Data, declaredEncoding: String) -> Data {
        switch declaredEncoding.lowercased() {
        case "7bit", "8bit", "binary", "":
            break
        default:
            return data   // already decoded by its own declaration — never second-guess
        }
        guard let text = String(data: data, encoding: .ascii),
              text.range(of: #"=[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil
                || text.range(of: #"=\r?\n"#, options: .regularExpression) != nil,
              let candidate = decodeQuotedPrintableBytes(text),
              candidate != data,
              let s = String(data: candidate, encoding: .utf8),
              s.unicodeScalars.contains(where: { !$0.isASCII })
        else { return data }
        return candidate
    }

    static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "base64":
            let cleaned = String(data: data, encoding: .ascii)?
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: " ", with: "")
                ?? ""
            return Data(base64Encoded: cleaned) ?? data

        case "quoted-printable":
            guard let text = String(data: data, encoding: .ascii) else { return data }
            return decodeQuotedPrintableBytes(text) ?? data

        default:     // 7bit / 8bit / binary, and any exotic encoding, pass through
            return data
        }
    }

    // MARK: Every leaf part

    /// Every leaf part in depth-first order, each with its bytes decoded. Empty for a malformed multipart (no boundary, depth
    /// limit exceeded).
    static func parseAllParts(_ bodyData: Data, headers: [String: String]) -> [MailBodyLeaf] {
        var parts: [MailBodyLeaf] = []
        collectParts(
            body: bodyData,
            partHeaders: headers,
            contentType: headers["content-type"] ?? "text/plain",
            encoding: headers["content-transfer-encoding"] ?? "7bit",
            depth: 0,
            out: &parts
        )
        return parts
    }

    private static func collectParts(
        body: Data, partHeaders: [String: String], contentType: String, encoding: String, depth: Int,
        out: inout [MailBodyLeaf]
    ) {
        guard depth < maxMultipartDepth else { return }

        let (mimeType, params) = parseContentType(contentType)

        if mimeType.hasPrefix("multipart/") {
            guard let boundary = params["boundary"], !boundary.isEmpty else { return }
            for childData in splitMultipart(body, boundary: boundary) {
                guard let split = headerBodySplitOffset(in: childData) else { continue }
                let childHeaders = parseHeaders(from: childData)
                collectParts(
                    body: Data(childData[split...]),
                    partHeaders: childHeaders,
                    contentType: childHeaders["content-type"] ?? "text/plain",
                    encoding: childHeaders["content-transfer-encoding"] ?? "7bit",
                    depth: depth + 1,
                    out: &out
                )
            }
            return
        }

        let (disposition, dispositionParams) = parseContentDisposition(partHeaders["content-disposition"])
        out.append(MailBodyLeaf(
            headers: partHeaders,
            contentType: mimeType,
            contentTypeParams: params,
            contentDisposition: disposition,
            filename: resolveFilename(dispositionParams: dispositionParams, contentTypeParams: params),
            decodedData: decodeTransferEncoding(body, encoding: encoding)
        ))
    }

    /// Splits a multipart body into child part bytes (each child includes its own headers + body). Scans bytes, not a String:
    /// attachment bytes aren't valid UTF-8. RFC 2046 §5.1.1.
    static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        guard !delimiter.isEmpty else { return [] }

        var children: [Data] = []
        var cursor = data.startIndex
        var inFirstPart = true  // Anything before the first delimiter is preamble.

        while cursor < data.endIndex {
            guard let delimRange = data.range(of: delimiter, in: cursor..<data.endIndex) else { break }
            // The part that ended is from `cursor` to the delimiter, minus the line break that precedes the delimiter.
            if !inFirstPart {
                var end = delimRange.lowerBound
                if end > cursor, data[data.index(before: end)] == 0x0A {
                    end = data.index(before: end)
                    if end > cursor, data[data.index(before: end)] == 0x0D {
                        end = data.index(before: end)
                    }
                }
                if end > cursor { children.append(Data(data[cursor..<end])) }
            }
            inFirstPart = false

            // Closing boundary "--boundary--".
            var afterDelim = delimRange.upperBound
            if data.distance(from: afterDelim, to: data.endIndex) >= 2 {
                let twoAhead = data[afterDelim..<data.index(afterDelim, offsetBy: 2)]
                if twoAhead == Data("--".utf8) { break }
            }
            // Skip the line break after the delimiter to position the cursor at the next part's start.
            if afterDelim < data.endIndex, data[afterDelim] == 0x0D { afterDelim = data.index(after: afterDelim) }
            if afterDelim < data.endIndex, data[afterDelim] == 0x0A { afterDelim = data.index(after: afterDelim) }
            cursor = afterDelim
        }
        return children
    }

    // MARK: Content-Disposition / filename

    /// `attachment; filename="report.pdf"` → (`attachment`, [`filename`: `report.pdf`]); `(nil, [:])` when absent.
    static func parseContentDisposition(_ value: String?) -> (String?, [String: String]) {
        guard let value = value else { return (nil, [:]) }
        let (disposition, params) = parseContentType(value)  // same grammar
        return (disposition.isEmpty ? nil : disposition, params)
    }

    /// The attachment filename: Content-Disposition `filename*=` (RFC 5987), then RFC 2231 continuation (`filename*0`, …), then
    /// `filename=`, then Content-Type `name*=`, `name*N`, `name=`. A second RFC 2047 pass decodes encoded-words nested inside.
    static func resolveFilename(
        dispositionParams: [String: String], contentTypeParams: [String: String]
    ) -> String? {
        if let extValue = dispositionParams["filename*"] {
            return decodeRFC2047IfApplicable(decodeRFC5987(extValue) ?? extValue)
        }
        if let assembled = assembleRFC2231Continuation(params: dispositionParams, paramName: "filename") {
            return assembled
        }
        if let filename = dispositionParams["filename"] {
            return decodeRFC2047IfApplicable(filename)
        }
        if let extValue = contentTypeParams["name*"] {
            return decodeRFC2047IfApplicable(decodeRFC5987(extValue) ?? extValue)
        }
        if let assembled = assembleRFC2231Continuation(params: contentTypeParams, paramName: "name") {
            return assembled
        }
        if let name = contentTypeParams["name"] {
            return decodeRFC2047IfApplicable(name)
        }
        return nil
    }

    /// Assembles `<paramName>*0`, `<paramName>*1`, … (a trailing `*` marks a percent-encoded segment), percent-decodes with the
    /// first segment's charset, and applies the RFC 2047 pass. Nil when there are no such keys.
    private static func assembleRFC2231Continuation(params: [String: String], paramName: String) -> String? {
        let prefix = "\(paramName)*"
        let continuationKeys = params.keys
            .filter { $0.hasPrefix(prefix) && $0 != prefix }
            .sorted { lhs, rhs in
                (continuationIndex(lhs, paramName: paramName) ?? 0) < (continuationIndex(rhs, paramName: paramName) ?? 0)
            }
        guard !continuationKeys.isEmpty else { return nil }

        var assembled = ""
        var firstCharset: String?
        for key in continuationKeys {
            guard let segment = params[key] else { continue }
            if key.hasSuffix("*") {
                if key == continuationKeys.first, let parsed = splitRFC5987(segment) {
                    firstCharset = parsed.charset
                    assembled += parsed.encoded
                } else {
                    assembled += segment
                }
            } else {
                assembled += segment
            }
        }
        let decoded = decodePercentEncoded(assembled, charset: firstCharset ?? "utf-8") ?? assembled
        return decodeRFC2047IfApplicable(decoded)
    }

    /// A single well-formed RFC 2047 encoded-word: `=?charset?B|Q?text?=`.
    private static let rfc2047EncodedWordPattern = #"=\?[^?\s]+\?[BQbq]\?[^?]+\?="#

    /// Applies `decodeRFC2047` only when `value` contains at least one well-formed encoded-word (a substring search, so
    /// `=?…?=.pdf` decodes and `report=?bogus.pdf` survives untouched).
    static func decodeRFC2047IfApplicable(_ value: String) -> String {
        guard value.range(of: rfc2047EncodedWordPattern, options: .regularExpression) != nil else { return value }
        return decodeRFC2047(value)
    }

    /// RFC 5987 ext-value `charset'language'percent-encoded` → (charset, percent-encoded), or nil when malformed.
    static func splitRFC5987(_ value: String) -> (charset: String, encoded: String)? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[2]))
    }

    /// A full RFC 5987 ext-value like `UTF-8''%E4%B8%AD%E6%96%87.pdf`.
    static func decodeRFC5987(_ extValue: String) -> String? {
        guard let (charset, encoded) = splitRFC5987(extValue) else { return nil }
        return decodePercentEncoded(encoded, charset: charset)
    }

    /// Decodes a percent-encoded string under the given charset.
    static func decodePercentEncoded(_ encoded: String, charset: String) -> String? {
        var bytes: [UInt8] = []
        var idx = encoded.startIndex
        while idx < encoded.endIndex {
            let ch = encoded[idx]
            if ch == "%" {
                let hexStart = encoded.index(after: idx)
                guard encoded.distance(from: hexStart, to: encoded.endIndex) >= 2 else { return nil }
                let hexEnd = encoded.index(hexStart, offsetBy: 2)
                guard let byte = UInt8(String(encoded[hexStart..<hexEnd]), radix: 16) else { return nil }
                bytes.append(byte)
                idx = hexEnd
            } else if let scalar = ch.asciiValue {
                bytes.append(scalar)
                idx = encoded.index(after: idx)
            } else {
                // Non-ASCII literal — re-encode as UTF-8 bytes.
                bytes.append(contentsOf: String(ch).utf8)
                idx = encoded.index(after: idx)
            }
        }
        return String(data: Data(bytes), encoding: stringEncoding(for: charset))
            ?? String(data: Data(bytes), encoding: .utf8)
    }

    /// The numeric index of a continuation key like `<paramName>*3*` or `<paramName>*0`; nil for the bare `<paramName>*`.
    private static func continuationIndex(_ key: String, paramName: String) -> Int? {
        let digits = key.dropFirst("\(paramName)*".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
