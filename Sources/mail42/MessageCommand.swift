// MessageCommand.swift — `mail42 message read <id>` and `mail42 message thread <id>`.
//
// `read` opens the message's .emlx file under ~/Library/Mail (the dispatcher already re-launched mail42 as its own
// permission principal, which holds Full Disk Access). Text is the default; `--html` gives the sender's HTML,
// sanitised (no scripts, no event handlers, cid: images inlined); `--headers` gives only the headers.

import Foundation
import Mail42AppleMail
import Mail42Kit

enum MessageCommand {

    static func run(args: [String]) {
        let json = CLI.wantsJSON(args)
        let words = CLI.positionals(args, valueFlags: ["--out", "--prefer-mailbox"])
        switch words.first {
        case "read":
            read(args: args, words: words, json: json)
        case "thread":
            thread(words: words, json: json)
        case "resolve":
            resolve(args: args, words: words, json: json)
        default:
            CLI.usageError(
                "usage: message read <id> [--text|--html|--headers] [--out <file>] | message thread <id> | message resolve <link|id> [--prefer-mailbox <id>]",
                json: json)
        }
    }

    // MARK: - resolve

    /// Finds the message a `mail42://message/…` link points at, even after Mail moved it and gave it a new id.
    private static func resolve(args: [String], words: [String], json: Bool) {
        guard let text = words.dropFirst().first, let link = MessageLink(string: text) else {
            CLI.usageError("usage: message resolve <mail42://message/… link | id> [--prefer-mailbox <id>]", json: json)
        }
        var preferred: Int64?
        if let value = CLI.argValue(args, "--prefer-mailbox") {
            guard let id = Int64(value) else { CLI.usageError("--prefer-mailbox takes a mailbox id, not `\(value)`", json: json) }
            preferred = id
        }
        do {
            let record = try LiveMail.open().resolve(link, preferMailbox: preferred)
            if json {
                CLI.emitJSONObject(Presentation.envelope(record))
            } else {
                EnvelopeCommand.show([record], json: false)
                print(record.link.string)
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    // MARK: - thread

    private static func thread(words: [String], json: Bool) {
        let id = CLI.messageID(words.dropFirst().first, json: json)
        do {
            EnvelopeCommand.show(try LiveMail.open().thread(containing: id), json: json)
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    // MARK: - read

    private enum Mode { case text, html, headers }

    private static func read(args: [String], words: [String], json: Bool) {
        let id = CLI.messageID(words.dropFirst().first, json: json)
        let requested: [Mode] = [args.contains("--text") ? .text : nil,
                                 args.contains("--html") ? .html : nil,
                                 args.contains("--headers") ? .headers : nil].compactMap { $0 }
        guard requested.count <= 1 else {
            CLI.usageError("choose one of --text, --html, --headers", json: json)
        }
        let mode = requested.first ?? .text

        do {
            let mail = try LiveMail.open()
            guard let record = try mail.envelopeRecord(id: id) else { throw Mail42Error.notFound("message \(id)") }
            let body = try loadBody(mail.emlxURL(for: record))
            // From the message file when it was read (names, types, sizes), else the names Apple's index holds.
            let attachments = try body.parsed.map { parsed in
                parsed.attachments.map { AttachmentRow(part: $0.part, filename: $0.filename ?? "", mime: $0.mime, size: Int64($0.size)) }
            } ?? mail.attachments(of: record)

            let content: String?
            switch (mode, body.parsed) {
            case (_, nil), (.headers, _): content = nil
            case (.text, let parsed?): content = text(of: parsed)
            case (.html, let parsed?): content = HTMLSanitizer.render(message: parsed, id: id)
            }
            let headers = body.parsed?.headers ?? [:]

            if let out = CLI.argValue(args, "--out") {
                try writeOut(out, mode: mode, content: content, headers: headers, unavailable: body.unavailable, json: json)
                return
            }
            if json {
                CLI.emitJSONObject([
                    "envelope": Presentation.envelope(record),
                    "headers": headers,
                    "text": mode == .text ? (content as Any? ?? NSNull()) : NSNull(),
                    "html": mode == .html ? (content as Any? ?? NSNull()) : NSNull(),
                    "attachments": attachments.map(Presentation.attachment),
                    "body_unavailable": body.unavailable,
                ] as [String: Any])
            } else {
                printHuman(record, attachments: attachments, mode: mode, content: content,
                           headers: headers, unavailable: body.unavailable)
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    /// The message parsed from its file, or `nil` + `unavailable` when there is no body to show: no file
    /// (Exchange, never downloaded), an unreadable one, or a partial file whose body Mail never fetched.
    private static func loadBody(_ file: URL?) throws -> (parsed: ParsedMessage?, unavailable: Bool) {
        guard let file else { return (nil, true) }
        do {
            let parsed = try MessageParser.parse(emlx: file)
            let hasBody = !(parsed.textBody ?? "").isEmpty || !(parsed.htmlBody ?? "").isEmpty
            return (parsed, parsed.isPartial && !hasBody)
        } catch Mail42Error.fdaDenied {
            throw Mail42Error.fdaDenied
        } catch Mail42Error.emlxNotFound {
            // Without Full Disk Access a file under ~/Library/Mail looks missing: don't blame the message.
            if AppleMailAccess.fullDiskAccess() == .denied { throw Mail42Error.fdaDenied }
            return (nil, true)
        } catch {
            return (nil, true)
        }
    }

    private static func text(of parsed: ParsedMessage) -> String {
        if let text = parsed.textBody, !text.isEmpty { return text }
        return parsed.htmlBody.map(HTMLText.convert) ?? ""
    }

    private static func headerLines(_ headers: [String: String]) -> String {
        headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    // MARK: - output

    private static func writeOut(
        _ out: String, mode: Mode, content: String?, headers: [String: String], unavailable: Bool, json: Bool
    ) throws {
        let text = mode == .headers ? headerLines(headers) : content
        guard let text, !(unavailable && mode != .headers) else {
            if json {
                CLI.emitJSONObject(["path": NSNull(), "body_unavailable": true] as [String: Any])
            } else {
                print("The full message isn't available (not downloaded). Open it in Mail with `mail42 open <id>`.")
            }
            return
        }
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Mail42Error.writeFailed("\(url.path): \(error.localizedDescription)")
        }
        if json {
            CLI.emitJSONObject(["path": url.path, "body_unavailable": false] as [String: Any])
        } else {
            print(url.path)
        }
    }

    private static func printHuman(
        _ r: EnvelopeRecord, attachments: [AttachmentRow], mode: Mode, content: String?,
        headers: [String: String], unavailable: Bool
    ) {
        if mode == .headers {
            print(headerLines(headers))
            return
        }
        if mode == .html, let content {
            print(content)
            return
        }
        let row = r.row
        print("From:    \(Presentation.displayName(name: row.fromName, addr: row.fromAddr))"
              + (row.fromName.map { _ in row.fromAddr.map { " <\($0)>" } ?? "" } ?? ""))
        if !r.to.isEmpty { print("To:      \(Presentation.formatPeople(r.to))") }
        if !r.cc.isEmpty { print("Cc:      \(Presentation.formatPeople(r.cc))") }
        print("Date:    \(Presentation.localDate(row.dateReceived))")
        print("Subject: \(row.subject)")
        print("Mailbox: \(r.accountEmail ?? r.accountName) · \(r.mailboxName)    (id \(row.id))")
        if !attachments.isEmpty {
            let list = attachments.map { "\($0.filename) (\(Presentation.humanSize($0.size)))" }.joined(separator: ", ")
            print("Attached: \(list)")
        }
        print("")
        if unavailable {
            if let snippet = row.snippet { print(snippet + "\n") }
            print("(The full message isn't downloaded. Open it in Mail with `mail42 open \(row.id)`.)")
        } else {
            print(content ?? "")
        }
    }
}
