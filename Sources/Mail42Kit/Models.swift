// Models.swift — the plain values the read verbs print: accounts, mailboxes, messages, recipients, attachments.
//
// They describe what is in Apple Mail right now (see LiveMail); nothing here is stored by mail42.

import Foundation

public struct AccountRow: Equatable, Sendable {
    public var id: String          // Apple Mail's account UUID
    public var name: String        // the account's name as Mail shows it ("Google"), else its address, else the UUID
    public var email: String?
    public var kind: String        // URL scheme of the account's mailboxes: imap, ews, local…

    public init(id: String, name: String, email: String?, kind: String) {
        self.id = id
        self.name = name
        self.email = email
        self.kind = kind
    }
}

public struct MailboxRow: Equatable, Sendable {
    public var id: Int64           // Apple's mailboxes.ROWID
    public var accountID: String
    public var name: String        // path inside the account, e.g. "INBOX" or "[Gmail]/All Mail"
    public var role: String        // inbox · sent · drafts · archive · trash · junk · other
    public var url: String
    public var total: Int64
    public var unread: Int64

    public init(id: Int64, accountID: String, name: String, role: String, url: String, total: Int64, unread: Int64) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.role = role
        self.url = url
        self.total = total
        self.unread = unread
    }
}

public struct EnvelopeRow: Equatable, Sendable {
    public var id: Int64           // Apple's messages.ROWID
    public var messageID: String?  // RFC 5322 Message-ID, with angle brackets
    public var conversationID: Int64
    public var mailboxID: Int64
    public var subject: String
    public var fromName: String?
    public var fromAddr: String?
    public var dateReceived: Int64 // Unix seconds
    public var dateSent: Int64
    public var snippet: String?
    public var isRead: Bool
    public var isFlagged: Bool
    public var hasAttachments: Bool
    public var size: Int64
    public var emlxPath: String?

    public init(
        id: Int64, messageID: String?, conversationID: Int64, mailboxID: Int64, subject: String,
        fromName: String?, fromAddr: String?, dateReceived: Int64, dateSent: Int64, snippet: String?,
        isRead: Bool, isFlagged: Bool, hasAttachments: Bool, size: Int64, emlxPath: String?
    ) {
        self.id = id
        self.messageID = messageID
        self.conversationID = conversationID
        self.mailboxID = mailboxID
        self.subject = subject
        self.fromName = fromName
        self.fromAddr = fromAddr
        self.dateReceived = dateReceived
        self.dateSent = dateSent
        self.snippet = snippet
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
        self.size = size
        self.emlxPath = emlxPath
    }
}

public struct RecipientRow: Equatable, Sendable {
    public var kind: String        // to · cc · bcc
    public var name: String?
    public var addr: String
    public var position: Int64

    public init(kind: String, name: String?, addr: String, position: Int64) {
        self.kind = kind
        self.name = name
        self.addr = addr
        self.position = position
    }
}

public struct AttachmentRow: Equatable, Sendable {
    public var part: String
    public var filename: String
    public var mime: String
    public var size: Int64

    public init(part: String, filename: String, mime: String, size: Int64) {
        self.part = part
        self.filename = filename
        self.mime = mime
        self.size = size
    }
}

/// One message as the read verbs present it: the envelope, where it lives, and who it was sent to.
public struct EnvelopeRecord: Equatable, Sendable {
    public var row: EnvelopeRow
    public var accountID: String
    public var accountName: String
    public var accountEmail: String?
    public var mailboxName: String
    public var mailboxRole: String
    public var to: [RecipientRow]
    public var cc: [RecipientRow]

    public init(
        row: EnvelopeRow, accountID: String, accountName: String, accountEmail: String?, mailboxName: String,
        mailboxRole: String, to: [RecipientRow], cc: [RecipientRow]
    ) {
        self.row = row
        self.accountID = accountID
        self.accountName = accountName
        self.accountEmail = accountEmail
        self.mailboxName = mailboxName
        self.mailboxRole = mailboxRole
        self.to = to
        self.cc = cc
    }
}

/// Which mailbox(es) `envelope list` reads.
public enum MailboxSelector: Equatable, Sendable {
    /// Every mailbox with the `inbox` role (all accounts).
    case allInboxes
    /// Flagged messages in any mailbox.
    case flagged
    case id(Int64)
    /// A mailbox name or role, resolved like the `in:` search term.
    case named(String)
}

public struct EnvelopeListOptions: Sendable {
    public var mailbox: MailboxSelector
    public var unreadOnly: Bool
    public var flaggedOnly: Bool
    /// Return only messages older than this one (keyset pagination: pass the last id of the previous page).
    public var beforeID: Int64?
    public var limit: Int

    public init(
        mailbox: MailboxSelector = .allInboxes, unreadOnly: Bool = false, flaggedOnly: Bool = false,
        beforeID: Int64? = nil, limit: Int = 50
    ) {
        self.mailbox = mailbox
        self.unreadOnly = unreadOnly
        self.flaggedOnly = flaggedOnly
        self.beforeID = beforeID
        self.limit = limit
    }
}
