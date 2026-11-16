// AttachmentCommand.swift — `mail42 attachment list <id>` and `mail42 attachment save <id> <part> [--to <dir>]`.
//
// `list` reads the message's file (or, if Mail has none, the names in Apple's index). `save` copies one attachment
// out of the message's .emlx into a folder (default ~/Downloads) without overwriting anything.

import Foundation
import Mail42AppleMail
import Mail42Kit

enum AttachmentCommand {

    static func run(args: [String]) throws {
        let json = CLI.wantsJSON(args)
        let words = CLI.positionals(args, valueFlags: ["--to"])
        switch words.first {
        case "list":
            try list(words: words, json: json)
        case "save":
            try save(args: args, words: words, json: json)
        default:
            try CLI.usageError("usage: attachment list <id> | attachment save <id> <part> [--to <dir>]", json: json)
        }
    }

    private static func list(words: [String], json: Bool) throws {
        let id = try CLI.messageID(words.dropFirst().first, json: json)
        do {
            let mail = try LiveMail.open()
            guard let record = try mail.envelopeRecord(id: id) else { throw Mail42Error.notFound("message \(id)") }
            let attachments = try mail.attachments(of: record)
            if json {
                try CLI.emitJSONObject(attachments.map(Presentation.attachment))
            } else if attachments.isEmpty {
                print("No attachments.")
            } else {
                for a in attachments {
                    print(Presentation.fit("part \(a.part)", 9) + Presentation.fit(a.filename, 40)
                          + Presentation.fit(a.mime, 26) + Presentation.humanSize(a.size))
                }
            }
        } catch {
            try CLI.fail(error: error, json: json)
        }
    }

    private static func save(args: [String], words: [String], json: Bool) throws {
        let id = try CLI.messageID(words.dropFirst().first, json: json)
        guard words.count >= 3 else { try CLI.usageError("usage: attachment save <id> <part> [--to <dir>]", json: json) }
        let part = words[2]
        let directory = CLI.argValue(args, "--to").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        do {
            let mail = try LiveMail.open()
            guard let record = try mail.envelopeRecord(id: id) else { throw Mail42Error.notFound("message \(id)") }
            guard let file = mail.emlxURL(for: record) else {
                throw Mail42Error.emlxNotFound(messageId: Int(id), path: "(this message has no file on disk)")
            }
            let parsed: ParsedMessage
            do {
                parsed = try MessageParser.parse(emlx: file)
            } catch Mail42Error.emlxNotFound where AppleMailAccess.fullDiskAccess() == .denied {
                throw Mail42Error.fdaDenied
            }
            guard let attachment = parsed.parts.first(where: { $0.part == part && $0.filename != nil }) else {
                throw Mail42Error.notFound("attachment part `\(part)` of message \(id) (see `mail42 attachment list \(id)`)")
            }
            guard !attachment.data.isEmpty else {
                throw Mail42Error.attachmentNotDownloaded(attachment.filename ?? "part \(part)")
            }
            let saved = try AttachmentSaver.save(
                attachment.data, suggestedName: attachment.filename, fallbackName: "attachment-\(part)", into: directory)
            if json {
                try CLI.emitJSONObject(["path": saved.path, "bytes": attachment.data.count] as [String: Any])
            } else {
                print(saved.path)
            }
        } catch {
            try CLI.fail(error: error, json: json)
        }
    }
}
