// MailURL.swift — the `message://` link Mail.app opens a specific message from.
//
// Mail registers the `message:` scheme: `message://%3C<Message-ID>%3E` (the RFC 5322 Message-ID in angle
// brackets, percent-encoded) shows that message. Opening the URL needs no Apple Events and no extra
// permission, which is why `mail42 open` uses it instead of scripting Mail.

import Foundation

public enum MailURL {

    /// Everything but unreserved characters is percent-encoded, so `<`, `>` and `@` become `%3C`, `%3E`, `%40`.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// `message://%3Cabc%40example.com%3E` for a Message-ID (with or without its angle brackets).
    public static func messageURL(messageID: String) -> URL? {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bracketed = trimmed.hasPrefix("<") && trimmed.hasSuffix(">") ? trimmed : "<\(trimmed)>"
        guard let encoded = bracketed.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "message://\(encoded)")
    }
}
