// Presentation.swift — how the read verbs show mail: the JSON shapes agents rely on, and the readable tables
// for people. JSON is built from dictionaries so an absent value is an explicit `null` (stable keys).
//
//   Envelope  {id, message_id, conversation_id, account{id,name,email}, mailbox{id,name,role}, from{name,addr},
//              to[{name,addr}], cc[…], subject, date (ISO-8601), snippet, is_read, is_flagged, has_attachments}
//   Message   {envelope, headers{}, text, html, attachments[{part,filename,mime,size}], body_unavailable}

import Foundation
import Mail42Kit

enum Presentation {

    // MARK: - JSON

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    static func iso(_ seconds: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func person(name: String?, addr: String?) -> [String: Any] {
        ["name": orNull(name.flatMap { $0.isEmpty ? nil : $0 }), "addr": orNull(addr)]
    }

    static func envelope(_ r: EnvelopeRecord) -> [String: Any] {
        let row = r.row
        return [
            "id": row.id,
            "message_id": orNull(row.messageID),
            "conversation_id": row.conversationID == 0 ? NSNull() : row.conversationID,
            "account": ["id": r.accountID, "name": r.accountName, "email": orNull(r.accountEmail)],
            "mailbox": ["id": row.mailboxID, "name": r.mailboxName, "role": r.mailboxRole],
            "from": person(name: row.fromName, addr: row.fromAddr),
            "to": r.to.map { person(name: $0.name, addr: $0.addr) },
            "cc": r.cc.map { person(name: $0.name, addr: $0.addr) },
            "subject": row.subject,
            "date": iso(row.dateReceived),
            "snippet": orNull(row.snippet),
            "is_read": row.isRead,
            "is_flagged": row.isFlagged,
            "has_attachments": row.hasAttachments,
        ]
    }

    static func attachment(_ a: AttachmentRow) -> [String: Any] {
        ["part": a.part, "filename": a.filename, "mime": a.mime, "size": a.size]
    }

    // MARK: - Tables and text

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func localDate(_ seconds: Int64) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Pads or cuts `text` to exactly `width` characters (cut with an ellipsis).
    static func fit(_ text: String, _ width: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        if single.count > width { return String(single.prefix(max(width - 1, 0))) + "…" }
        return single + String(repeating: " ", count: width - single.count)
    }

    static func displayName(name: String?, addr: String?) -> String {
        if let name, !name.isEmpty { return name }
        return addr ?? "(unknown)"
    }

    static func printEnvelopeTable(_ records: [EnvelopeRecord]) {
        guard !records.isEmpty else {
            print("No messages.")
            return
        }
        print(fit("ID", 9) + fit("", 3) + fit("DATE", 17) + fit("FROM", 24) + fit("SUBJECT", 46) + "MAILBOX")
        for r in records {
            let row = r.row
            let marks = (row.isRead ? " " : "●") + (row.isFlagged ? "⚑" : " ") + (row.hasAttachments ? "+" : " ")
            let mailbox = r.accountEmail.map { "\($0) · \(r.mailboxName)" } ?? "\(r.accountName) · \(r.mailboxName)"
            print(fit(String(row.id), 9) + marks + " " + fit(localDate(row.dateReceived), 17)
                  + fit(displayName(name: row.fromName, addr: row.fromAddr), 24)
                  + fit(row.subject, 46) + mailbox)
        }
        print("\n● unread  ⚑ flagged  + attachments")
    }

    static func formatPeople(_ people: [RecipientRow]) -> String {
        people.map { p in
            if let name = p.name, !name.isEmpty { return "\(name) <\(p.addr)>" }
            return p.addr
        }.joined(separator: ", ")
    }

    static func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
