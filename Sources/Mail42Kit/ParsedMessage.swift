// ParsedMessage.swift — a message read from its .emlx file, in the shape the CLI and the HTML renderer use.
//
// Produced by Mail42AppleMail's `MessageParser`; consumed by `HTMLSanitizer` and `HTMLText` here in Mail42Kit,
// so the model lives in Kit to keep the dependency pointing one way (AppleMail → Kit).

import Foundation

/// One leaf MIME part of a message (a text body, an inline image, an attachment).
public struct ParsedPart: Sendable, Equatable {
    /// Stable id of this part within the message: its 1-based position among the leaf parts in document
    /// order (`"1"`, `"2"`, …). This is the `<part>` that `mail42 attachment save <id> <part>` takes.
    public let part: String
    public let filename: String?
    /// Lowercased MIME type, e.g. `image/png`.
    public let mime: String
    public let size: Int
    /// `Content-ID` without the angle brackets, lowercased (what `cid:` URLs in the HTML refer to).
    public let contentID: String?
    /// True for a part the HTML refers to as `cid:…` and that isn't marked `attachment` (an inline image).
    public let isInline: Bool
    /// The decoded bytes. For a `.partial.emlx` message this comes from Mail's external attachment cache;
    /// empty when the bytes were never downloaded.
    public let data: Data

    public init(
        part: String, filename: String?, mime: String, size: Int, contentID: String?, isInline: Bool, data: Data
    ) {
        self.part = part
        self.filename = filename
        self.mime = mime
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
        self.data = data
    }

    /// Shown as an attachment: it has a filename and isn't an inline image.
    public var isAttachment: Bool { filename != nil && !isInline }
}

public struct ParsedMessage: Sendable {
    /// Top-level headers, lowercased keys, RFC 2047-decoded values (`subject`, `from`, `message-id`, …).
    public let headers: [String: String]
    public let textBody: String?
    public let htmlBody: String?
    public let parts: [ParsedPart]
    /// True when the file was a `.partial.emlx`: Mail has the headers but not (fully) the body.
    public let isPartial: Bool

    public init(
        headers: [String: String], textBody: String?, htmlBody: String?, parts: [ParsedPart], isPartial: Bool
    ) {
        self.headers = headers
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.parts = parts
        self.isPartial = isPartial
    }

    public var attachments: [ParsedPart] { parts.filter(\.isAttachment) }

    /// The RFC 5322 Message-ID with the angle brackets, when the message has one.
    public var messageID: String? {
        guard let raw = headers["message-id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }
}
