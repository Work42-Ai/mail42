// MessageLink.swift — a link that points at one message: `mail42://message/<rowid>?mid=<Message-ID>`.
//
// Mail's row id is quick to look up but changes when a message is moved (archive, move to a folder) or downloaded
// again. The Message-ID header is stamped by the sender's server and never changes. A link carries both: the row id
// first, and the Message-ID to find the message again when the row id no longer points at it.

import Foundation

public struct MessageLink: Equatable, Sendable {
    public var rowid: Int64
    /// The RFC 5322 Message-ID without its angle brackets.
    public var messageID: String?

    public init(rowid: Int64, messageID: String?) {
        self.rowid = rowid
        self.messageID = messageID.flatMap { Self.stripBrackets($0) }
    }

    /// `mail42://message/48213?mid=CAF7x9Q%40mail.gmail.com`
    public var string: String {
        var text = "mail42://message/\(rowid)"
        if let messageID { text += "?mid=" + Self.encode(messageID) }
        return text
    }

    /// Reads a link, or a bare row id (`48213`).
    public init?(string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int64(text) {
            self.init(rowid: id, messageID: nil)
            return
        }
        let prefix = "mail42://message/"
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let id = Int64(first) else { return nil }
        var mid: String?
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2, kv[0] == "mid" { mid = String(kv[1]).removingPercentEncoding }
            }
        }
        self.init(rowid: id, messageID: mid)
    }

    /// `<abc@host>` → `abc@host`; an empty result is nil.
    public static func stripBrackets(_ header: String) -> String? {
        var value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<") { value.removeFirst() }
        if value.hasSuffix(">") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    // Only letters, digits and `-._~` stay as they are, so `@ + < > & = ? # %` can never be misread.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}

extension EnvelopeRecord {
    /// The link to this message.
    public var link: MessageLink { MessageLink(rowid: row.id, messageID: row.messageID) }
}

/// One conversation as a list shows it: its newest message in the view, how big it is, and who wrote in it.
public struct ConversationRecord: Equatable, Sendable {
    public var newest: EnvelopeRecord
    /// Messages in the whole conversation, in every mailbox (the user's own replies from Sent included).
    public var count: Int
    /// Distinct sender names, newest first, at most three.
    public var participants: [String]

    public init(newest: EnvelopeRecord, count: Int, participants: [String]) {
        self.newest = newest
        self.count = count
        self.participants = participants
    }
}
