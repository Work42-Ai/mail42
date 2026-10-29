// MailboxRole.swift — what kind of mailbox a name is (inbox, sent, drafts…).
//
// Names differ by provider and language of the server, so this covers the common English ones (iCloud, Gmail,
// Outlook/Exchange, generic IMAP); everything else is `other`.

import Foundation

public enum MailboxRole {
    public static func classify(name: String) -> String {
        let leaf = (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
        let full = name.lowercased()
        switch leaf {
        case "inbox": return "inbox"
        case "sent", "sent messages", "sent items", "sent mail": return "sent"
        case "drafts", "draft": return "drafts"
        case "archive", "archives", "all mail": return "archive"
        case "trash", "deleted messages", "deleted items", "bin": return "trash"
        case "junk", "junk email", "junk e-mail", "spam": return "junk"
        default: return full.hasSuffix("/all mail") ? "archive" : "other"
        }
    }
}
