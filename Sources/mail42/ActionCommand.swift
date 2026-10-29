// ActionCommand.swift — the verbs that change mail through Apple Mail: mark, move, archive, delete, junk, draft.
//
// mail42 never edits Apple Mail's files and never sends. Each verb asks Mail itself to do the one thing (Apple
// Events, see Mail42Actions); the dispatcher has already re-launched mail42 as its own permission principal, so
// macOS asks once whether *mail42* may control Mail. Replies, forwards and new messages open Mail's compose window
// pre-filled: the person presses Send there.
//
// A message is named by its id or by a `mail42://message/…` link (both accepted everywhere). `MAIL42_ACTIONS_DRY_RUN=1`
// prints the AppleScript it would run instead of running it (tests, and a way to see exactly what will be asked).

import Foundation
import Mail42Actions
import Mail42AppleMail
import Mail42Kit

/// Collects scripts instead of running them.
final class ScriptRecorder: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []

    func run(_ source: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        scripts.append(source)
        return ""
    }

    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return scripts }
}

enum ActionCommand {

    private static var dryRun: Bool { ProcessInfo.processInfo.environment["MAIL42_ACTIONS_DRY_RUN"] == "1" }

    private static let valueFlags: Set<String> = ["--color", "--to", "--cc", "--subject", "--body"]

    static func run(command: String, args: [String]) {
        let json = CLI.wantsJSON(args)
        let words = CLI.positionals(args, valueFlags: valueFlags)
        let recorder = ScriptRecorder()
        let actions = MailActions(runner: dryRun ? recorder : NSAppleScriptRunner())
        do {
            switch command {
            case "mark": try mark(words, args, actions, recorder, json)
            case "move": try move(words, actions, recorder, json)
            case "archive": try archive(words, actions, recorder, json)
            case "delete": try delete(words, actions, recorder, json)
            case "junk": try junk(words, actions, recorder, json)
            case "draft": try draft(words, args, actions, recorder, json)
            default: CLI.usageError("unknown action `\(command)`", json: json)
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    // MARK: - Verbs

    private static func mark(_ words: [String], _ args: [String], _ actions: MailActions, _ recorder: ScriptRecorder, _ json: Bool) throws {
        guard words.count >= 2 else {
            CLI.usageError("usage: mark <id|link> read|unread|flagged|unflagged [--color red|orange|yellow|green|blue|purple|gray]", json: json)
        }
        let state: MarkState
        switch words[1].lowercased() {
        case "read": state = .read
        case "unread": state = .unread
        case "unflagged": state = .unflagged
        case "flagged":
            var color: FlagColor?
            if let name = CLI.argValue(args, "--color") {
                guard let known = FlagColor(rawValue: name.lowercased()) else {
                    CLI.usageError("--color is one of \(FlagColor.allCases.map(\.rawValue).joined(separator: ", ")), not `\(name)`", json: json)
                }
                color = known
            }
            state = .flagged(color)
        default:
            CLI.usageError("mark takes read, unread, flagged or unflagged, not `\(words[1])`", json: json)
        }
        let (_, record) = try target(words.first, json: json)
        try actions.mark(MessageRef(record: record), as: state)
        finish(action: "mark", record: record, link: record.link, recorder: recorder, json: json,
               text: "Marked message \(record.row.id) as \(words[1].lowercased()).")
    }

    private static func move(_ words: [String], _ actions: MailActions, _ recorder: ScriptRecorder, _ json: Bool) throws {
        guard words.count >= 2 else { CLI.usageError("usage: move <id|link> <mailbox id|name>", json: json) }
        let (mail, record) = try target(words.first, json: json)
        let box = try mailbox(matching: words[1], in: mail, for: record)
        try actions.move(MessageRef(record: record), toMailbox: path(of: box))
        finish(action: "move", record: record, link: settledLink(record, mail: mail, preferring: box.id), recorder: recorder, json: json,
               text: "Moved message \(record.row.id) to \(box.name).")
    }

    private static func archive(_ words: [String], _ actions: MailActions, _ recorder: ScriptRecorder, _ json: Bool) throws {
        let (mail, record) = try target(words.first, json: json)
        let box = accountMailboxes(of: record, in: mail).filter { $0.role == "archive" }
            .sorted { ($0.name.hasPrefix("[Gmail]") ? 0 : 1) < ($1.name.hasPrefix("[Gmail]") ? 0 : 1) }.first
        try actions.archive(MessageRef(record: record), archivePath: box.map(path(of:)))
        finish(action: "archive", record: record, link: settledLink(record, mail: mail, preferring: box?.id), recorder: recorder, json: json,
               text: "Archived message \(record.row.id).")
    }

    private static func delete(_ words: [String], _ actions: MailActions, _ recorder: ScriptRecorder, _ json: Bool) throws {
        let (mail, record) = try target(words.first, json: json)
        try actions.delete(MessageRef(record: record))
        let trash = accountMailboxes(of: record, in: mail).first { $0.role == "trash" }
        finish(action: "delete", record: record, link: settledLink(record, mail: mail, preferring: trash?.id), recorder: recorder, json: json,
               text: "Moved message \(record.row.id) to the Trash.")
    }

    private static func junk(_ words: [String], _ actions: MailActions, _ recorder: ScriptRecorder, _ json: Bool) throws {
        let (mail, record) = try target(words.first, json: json)
        let box = accountMailboxes(of: record, in: mail).first { $0.role == "junk" }
        try actions.junk(MessageRef(record: record), junkPath: box.map(path(of:)))
        finish(action: "junk", record: record, link: settledLink(record, mail: mail, preferring: box?.id), recorder: recorder, json: json,
               text: "Marked message \(record.row.id) as junk.")
    }

    private static func draft(_ words: [String], _ args: [String], _ actions: MailActions, _ recorder: ScriptRecorder, _ json: Bool) throws {
        let usage = "usage: draft reply|reply-all|forward <id|link> | draft new [--to <addr>] [--cc <addr>] [--subject <text>] [--body <text>]"
        guard let kind = words.first else { CLI.usageError(usage, json: json) }
        switch kind {
        case "new":
            try actions.draftNew(
                to: CLI.argValues(args, "--to"), cc: CLI.argValues(args, "--cc"),
                subject: CLI.argValue(args, "--subject"), body: CLI.argValue(args, "--body"))
            finish(action: "draft new", record: nil, link: nil, recorder: recorder, json: json,
                   text: "Opened a new message in Mail. Nothing is sent until you press Send there.")
        case "reply", "reply-all", "forward":
            let (_, record) = try target(words.dropFirst().first, json: json)
            let ref = MessageRef(record: record)
            if kind == "forward" { try actions.draftForward(ref) } else { try actions.draftReply(ref, all: kind == "reply-all") }
            finish(action: "draft \(kind)", record: record, link: record.link, recorder: recorder, json: json,
                   text: "Opened a \(kind) draft in Mail. Nothing is sent until you press Send there.")
        default:
            CLI.usageError(usage, json: json)
        }
    }

    // MARK: - Finding things

    /// The message an id or link names.
    private static func target(_ argument: String?, json: Bool) throws -> (LiveMail, EnvelopeRecord) {
        guard let argument, let link = MessageLink(string: argument) else {
            CLI.usageError("expected a message id or a mail42://message/… link", json: json)
        }
        let mail = try LiveMail.open()
        return (mail, try mail.resolve(link))
    }

    private static func accountMailboxes(of record: EnvelopeRecord, in mail: LiveMail) -> [MailboxRow] {
        mail.accountsWithMailboxes().first { $0.account.id == record.accountID }?.mailboxes ?? []
    }

    private static func path(of box: MailboxRow) -> [String] {
        box.name.split(separator: "/").map(String.init)
    }

    /// A mailbox of the message's own account, by id, full name, last name or role.
    private static func mailbox(matching value: String, in mail: LiveMail, for record: EnvelopeRecord) throws -> MailboxRow {
        let boxes = accountMailboxes(of: record, in: mail)
        let wanted = value.lowercased()
        let found = Int64(value).flatMap { id in boxes.first { $0.id == id } }
            ?? boxes.first { $0.name.lowercased() == wanted }
            ?? boxes.first { $0.name.lowercased().hasSuffix("/" + wanted) }
            ?? boxes.first { $0.role == wanted }
        guard let found else { throw Mail42Error.notFound("a mailbox matching `\(value)` in the account \(record.accountName)") }
        return found
    }

    /// The message's link after Mail moved it: a moved message gets a new row id once Mail's index catches up, so
    /// look for a moment; if it hasn't, the old link still works (it resolves by Message-ID).
    private static func settledLink(_ record: EnvelopeRecord, mail: LiveMail, preferring mailbox: Int64?) -> MessageLink {
        guard !dryRun else { return record.link }
        for attempt in 0..<6 {
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.3 : 0.4)
            guard let fresh = try? LiveMail.open().resolve(record.link, preferMailbox: mailbox) else { continue }
            if fresh.row.id != record.row.id || fresh.row.mailboxID != record.row.mailboxID { return fresh.link }
        }
        return record.link
    }

    // MARK: - Output

    private static func finish(
        action: String, record: EnvelopeRecord?, link: MessageLink?, recorder: ScriptRecorder, json: Bool, text: String
    ) {
        if json {
            var result: [String: Any] = ["ok": true, "action": action]
            if let record { result["id"] = record.row.id }
            if let link { result["link"] = link.string }
            if dryRun { result["dry_run"] = true; result["scripts"] = recorder.recorded }
            CLI.emitJSONObject(result)
        } else if dryRun {
            print(recorder.recorded.joined(separator: "\n\n"))
        } else {
            print(text)
        }
    }
}
