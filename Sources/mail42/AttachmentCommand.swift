// AttachmentCommand.swift — `mail42 attachment list <id>` and `mail42 attachment save <id> <part> [--to <dir>]`.
//
// `list` reads mail.db. `save` reads the message's .emlx (so it re-launches as mail42's own permission principal)
// and copies one attachment into a folder (default ~/Downloads) without overwriting anything.

import Foundation
import Mail42AppleMail
import Mail42Kit

enum AttachmentCommand {

    static func run(args: [String]) {
        let json = CLI.wantsJSON(args)
        let words = CLI.positionals(args, valueFlags: ["--to"])
        switch words.first {
        case "list":
            list(words: words, json: json)
        case "save":
            Mail42Daemon.reexecIfNeeded(arguments: ["attachment"] + args)
            save(args: args, words: words, json: json)
        default:
            CLI.usageError("usage: attachment list <id> | attachment save <id> <part> [--to <dir>]", json: json)
        }
    }

    private static func list(words: [String], json: Bool) {
        let id = CLI.messageID(words.dropFirst().first, json: json)
        do {
            let store = try MailStore()
            guard try store.envelopeRecord(id: id) != nil else { throw Mail42Error.notFound("message \(id)") }
            let attachments = try store.attachments(of: id)
            if json {
                CLI.emitJSONObject(attachments.map(Presentation.attachment))
            } else if attachments.isEmpty {
                print("No attachments.")
            } else {
                for a in attachments {
                    print(Presentation.fit("part \(a.part)", 9) + Presentation.fit(a.filename, 40)
                          + Presentation.fit(a.mime, 26) + Presentation.humanSize(a.size))
                }
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    private static func save(args: [String], words: [String], json: Bool) {
        let id = CLI.messageID(words.dropFirst().first, json: json)
        guard words.count >= 3 else { CLI.usageError("usage: attachment save <id> <part> [--to <dir>]", json: json) }
        let part = words[2]
        let directory = CLI.argValue(args, "--to").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        do {
            let store = try MailStore()
            guard let record = try store.envelopeRecord(id: id) else { throw Mail42Error.notFound("message \(id)") }
            guard let path = record.row.emlxPath else {
                throw Mail42Error.emlxNotFound(messageId: Int(id), path: "(this message has no file on disk)")
            }
            let parsed: ParsedMessage
            do {
                parsed = try MessageParser.parse(emlx: URL(fileURLWithPath: path))
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
                CLI.emitJSONObject(["path": saved.path, "bytes": attachment.data.count] as [String: Any])
            } else {
                print(saved.path)
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }
}
