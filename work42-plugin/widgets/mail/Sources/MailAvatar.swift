// MailAvatar.swift — people look the same in Mail42 as in Meet42: a liquid-glass circle (Work42UI's `GlassAvatar`,
// shared with the chat) tinted with one colour per person.
//
// KEEP IN STEP WITH meet42: `MailAvatarStyle` is a copy of `MeetAvatar` in meet42/work42-plugin/shared/MeetEvent.swift
// (plugins can't share code). The palette, the hash and the initials rule must stay identical, so that a person has
// the same colour in a guest list, a transcript and a mail.

import SwiftUI
import Work42UI

enum MailAvatarStyle {

    /// One plain colour per slot: the glass is tinted with it and the initials are drawn in it.
    static let palette: [Color] = [
        Color(red: 1.00, green: 0.24, blue: 0.43),
        Color(red: 0.15, green: 0.39, blue: 0.92),
        Color(red: 0.05, green: 0.65, blue: 0.42),
        Color(red: 0.43, green: 0.16, blue: 0.85),
        Color(red: 0.91, green: 0.47, blue: 0.06),
        Color(red: 0.36, green: 0.40, blue: 0.44),
    ]

    /// The colour of the user's own messages ("You" in Meet42's transcripts).
    static let me = palette[4]

    /// FNV-1a over the lowercased key, mod the palette size: stable across launches (unlike `hashValue`).
    static func paletteIndex(for key: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(palette.count))
    }

    static func key(name: String?, email: String?) -> String {
        if let email, !email.isEmpty { return email }
        return name ?? "?"
    }

    /// First letters of the first and last name words; else the first two letters of the email's local part.
    static func initials(name: String?, email: String?) -> String {
        let words = (name ?? "").split(whereSeparator: { $0 == " " || $0 == "." }).filter { !$0.isEmpty }
        if words.count >= 2, let a = words.first?.first, let b = words.last?.first { return "\(a)\(b)".uppercased() }
        if let first = words.first { return String(first.prefix(2)).uppercased() }
        if let local = email?.split(separator: "@").first { return String(local.prefix(2)).uppercased() }
        return "?"
    }
}

struct MailAvatar: View {
    let person: MailPerson
    var size: CGFloat = 28
    /// The user's own message: drawn in Meet42's "You" colour.
    var isMe = false

    var body: some View {
        let key = MailAvatarStyle.key(name: person.name, email: person.addr)
        GlassAvatar(
            initials: MailAvatarStyle.initials(name: person.name, email: person.addr),
            color: isMe ? MailAvatarStyle.me : MailAvatarStyle.palette[MailAvatarStyle.paletteIndex(for: key)],
            size: size)
    }
}
