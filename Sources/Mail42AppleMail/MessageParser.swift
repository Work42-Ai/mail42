// MessageParser.swift — reads one message from its .emlx file into a `ParsedMessage`.
//
// A thin layer over the vendored parsers (EmlxFormat → RFC822Parser → MIMEParser). It adds what mail42 needs
// on top: stable part ids, `cid:` content ids and inline flags, and — for `.partial.emlx` messages, whose
// attachment bytes Mail stripped out — the attachment bytes from Mail's external cache.

import Foundation
import Mail42Kit

public enum MessageParser {

    /// Reads and parses an `.emlx` or `.partial.emlx` file.
    public static func parse(emlx url: URL) throws -> ParsedMessage {
        let file: Data
        do {
            file = try Data(contentsOf: url)
        } catch {
            let code = (error as NSError).code
            // NSFileReadNoPermission: macOS refused the read (Full Disk Access); NSFileReadNoSuchFile: not there.
            if code == NSFileReadNoPermissionError { throw Mail42Error.fdaDenied }
            throw Mail42Error.emlxNotFound(messageId: Int(url.lastPathComponent.prefix { $0.isNumber }) ?? 0, path: url.path)
        }
        let message = try EmlxFormat.extractMessageData(from: file)
        let partial = EmlxLocator.isPartial(url)
        return parse(
            rfc822: message,
            isPartial: partial,
            attachmentsDirectory: partial ? EmlxLocator.attachmentsDirectory(forEmlx: url) : nil
        )
    }

    /// Parses raw RFC 822 bytes. `attachmentsDirectory` is Mail's external attachment cache for the message,
    /// used to fill attachment bytes a `.partial.emlx` no longer carries.
    public static func parse(rfc822 data: Data, isPartial: Bool, attachmentsDirectory: URL? = nil) -> ParsedMessage {
        let headers = RFC822Parser.parseHeaders(from: data)
        // Re-base the slice so the parsers see a zero-indexed buffer.
        let body = RFC822Parser.headerBodySplitOffset(in: data).map { Data(data[$0...]) } ?? Data()

        let content = MIMEParser.parseBody(body, headers: headers)
        let leaves = MIMEParser.parseAllParts(body, headers: headers)

        var parts: [ParsedPart] = []
        for (index, leaf) in leaves.enumerated() {
            let mime = leaf.contentType.lowercased()
            let disposition = leaf.contentDisposition?.lowercased()
            // The message's own text bodies aren't attachments or inline resources: skip them, but keep
            // counting so a part's id stays its position among all leaves.
            if (mime == "text/plain" || mime == "text/html"), leaf.filename == nil, disposition != "attachment" {
                continue
            }
            let contentID = normalizedContentID(leaf.headers["content-id"])
            var bytes = leaf.decodedData
            if bytes.isEmpty, isPartial, let name = leaf.filename, let dir = attachmentsDirectory {
                bytes = externalAttachmentData(named: name, in: dir) ?? Data()
            }
            parts.append(ParsedPart(
                part: String(index + 1),
                filename: leaf.filename,
                mime: mime,
                size: bytes.count,
                contentID: contentID,
                isInline: contentID != nil && disposition != "attachment",
                data: bytes
            ))
        }

        return ParsedMessage(
            headers: headers,
            textBody: content.textBody,
            htmlBody: content.htmlBody,
            parts: parts,
            isPartial: isPartial
        )
    }

    // MARK: - Private

    /// `<abc@x>` → `abc@x`, lowercased; nil when absent or empty.
    private static func normalizedContentID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `<attachments dir>/<part-id>/<filename>`, whichever part folder holds a file with this name.
    private static func externalAttachmentData(named filename: String, in directory: URL) -> Data? {
        let fm = FileManager.default
        // Only the last path component: a hostile filename must not point outside the cache.
        let leaf = (filename as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..",
              let partFolders = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        for folder in partFolders.sorted() {
            let candidate = directory.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(leaf)
            if fm.fileExists(atPath: candidate.path), let data = try? Data(contentsOf: candidate) { return data }
        }
        return nil
    }
}
