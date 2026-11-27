// MailTools.swift — what an agent can do with the user's mail, as MCP tools written in Swift (WOR-900).
//
// One MCP, `mail` (the Mail widget), whose tools call `MailCtl.Controller`, the object the tile's transport asks as well. They do not
// need a tile on screen: a tool call builds (once per session, in `MailToolSessions`) its own controller from the services of the
// call, so an agent can read mail in a session that never opened the widget.
//
//   reading   list_mailboxes, list_messages, search_messages, read_message, read_thread, list_attachments, get_message_link
//   saving    save_attachment   into `~/.work42/mail42/attachments`, the one folder the extension may write attachments in
//   acting    mark_message, move_message, archive_message, delete_message, junk_message, open_reply_draft, open_in_mail
//             Mail does the work (Apple Events). Nothing here sends mail: a reply or forward opens Mail's compose window.
//
// Answers are small `Encodable` structs whose keys are the mail42 CLI's (`message_id`, `conversation_id`, `is_read`, …), so a
// reader that knew the CLI's JSON knows these, and an iPad that asks the Mac to run a tool decodes the same shapes. A `MailFailure`
// leaves as a `PluginToolFailure` with the CLI's code and a next step an agent can take.

import CryptoKit
import Foundation
import Work42PluginKit

// MARK: - Answers (the CLI's JSON keys)

nonisolated struct MailToolPerson: Encodable, Sendable {
    var name: String?
    var addr: String?

    init(_ person: MailPerson) {
        name = person.name.flatMap { $0.isEmpty ? nil : $0 }
        addr = person.addr
    }

    private enum Keys: String, CodingKey { case name, addr }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .name)       // an absent value is an explicit null, as the CLI printed it
        try container.encode(addr, forKey: .addr)
    }
}

/// One message (or, in a conversation list, its newest message plus the conversation's size): `envelope list`'s object.
nonisolated struct MailToolEnvelope: Encodable, Sendable {
    struct Account: Encodable, Sendable {
        var id: String
        var name: String
        var email: String?

        private enum Keys: String, CodingKey { case id, name, email }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(email, forKey: .email)
        }
    }

    struct Mailbox: Encodable, Sendable {
        var id: Int64
        var name: String
        var role: String
    }

    var id: Int64
    var messageID: String?
    var conversationID: Int64?
    var account: Account
    var mailbox: Mailbox
    var from: MailToolPerson
    var to: [MailToolPerson]
    var cc: [MailToolPerson]
    var subject: String
    var date: String
    var snippet: String?
    var isRead: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
    var link: String?
    var conversationCount: Int?
    var participants: [String]?

    init(_ e: MailEnvelope) {
        id = e.id
        messageID = e.messageID
        conversationID = e.conversationID
        account = Account(id: e.account.id, name: e.account.name, email: e.account.email)
        mailbox = Mailbox(id: e.mailbox.id, name: e.mailbox.name, role: e.mailbox.role)
        from = MailToolPerson(e.from)
        to = e.to.map(MailToolPerson.init)
        cc = e.cc.map(MailToolPerson.init)
        subject = e.subject
        date = ISO8601DateFormatter().string(from: e.date)
        snippet = e.snippet
        isRead = e.isRead
        isFlagged = e.isFlagged
        hasAttachments = e.hasAttachments
        link = e.link
        conversationCount = e.conversationCount
        participants = e.participants
    }

    private enum Keys: String, CodingKey {
        case id, account, mailbox, from, to, cc, subject, date, snippet, link, participants
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case isRead = "is_read"
        case isFlagged = "is_flagged"
        case hasAttachments = "has_attachments"
        case conversationCount = "conversation_count"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(account, forKey: .account)
        try container.encode(mailbox, forKey: .mailbox)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(cc, forKey: .cc)
        try container.encode(subject, forKey: .subject)
        try container.encode(date, forKey: .date)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(isRead, forKey: .isRead)
        try container.encode(isFlagged, forKey: .isFlagged)
        try container.encode(hasAttachments, forKey: .hasAttachments)
        try container.encode(link, forKey: .link)
        // A conversation is its newest message plus the size of the conversation and who wrote in it.
        if let conversationCount {
            try container.encode(conversationCount, forKey: .conversationCount)
            try container.encode(participants ?? [], forKey: .participants)
        }
    }
}

nonisolated struct MailToolMailboxes: Encodable, Sendable {
    var accounts: [MailAccountTree]
}

nonisolated struct MailToolMessages: Encodable, Sendable {
    var messages: [MailToolEnvelope]
    var count: Int
    /// Pass it as `before_id` to get the next page; absent when this page was not full.
    var nextBeforeID: Int64?
    /// A search that could not read every message's text says so here.
    var note: String?

    private enum CodingKeys: String, CodingKey {
        case messages, count, note
        case nextBeforeID = "next_before_id"
    }
}

nonisolated struct MailToolMessage: Encodable, Sendable {
    var envelope: MailToolEnvelope
    var headers: [String: String]
    var text: String?
    var html: String?
    var attachments: [MailAttachment]
    var bodyUnavailable: Bool
    /// The text (or HTML) was cut at `MailTools.maxBodyCharacters`.
    var truncated: Bool

    private enum Keys: String, CodingKey {
        case envelope, headers, text, html, attachments, truncated
        case bodyUnavailable = "body_unavailable"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(envelope, forKey: .envelope)
        try container.encode(headers, forKey: .headers)
        try container.encode(text, forKey: .text)
        try container.encode(html, forKey: .html)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(bodyUnavailable, forKey: .bodyUnavailable)
        try container.encode(truncated, forKey: .truncated)
    }
}

nonisolated struct MailToolThread: Encodable, Sendable {
    var messages: [MailToolEnvelope]
    var count: Int
}

nonisolated struct MailToolAttachments: Encodable, Sendable {
    var attachments: [MailAttachment]
}

nonisolated struct MailToolSaved: Encodable, Sendable {
    var path: String
    var bytes: Int
}

nonisolated struct MailToolLink: Encodable, Sendable {
    var id: Int64
    var link: String
    /// Mail's own `message://` URL for the Message-ID; nil when the message has none.
    var messageURL: String?

    private enum Keys: String, CodingKey {
        case id, link
        case messageURL = "message_url"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(link, forKey: .link)
        try container.encode(messageURL, forKey: .messageURL)
    }
}

/// What an action verb printed: `{"ok","action","id","link"}`. After a move the link is the message's new one.
nonisolated struct MailToolAction: Encodable, Sendable {
    var ok: Bool
    var action: String
    var id: Int64
    var link: String?
}

/// What `open` printed: `{"ok","url","opened"}`.
nonisolated struct MailToolOpened: Encodable, Sendable {
    var ok: Bool
    var url: String?
    var opened: Bool

    private enum Keys: String, CodingKey { case ok, url, opened }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(url, forKey: .url)
        try container.encode(opened, forKey: .opened)
    }
}

// MARK: - One controller per session

/// What a session's tools run on: the controller (shared by every call of the session, so its mirror and index are reused), and
/// where an attachment may be saved.
nonisolated struct MailToolSession: Sendable {
    var controller: MailCtl.Controller
    /// Saves an attachment through the same code (and the same allowed folders) as the tile's Save Attachment.
    var saver: MailCtlDirectTransport
    var saveDirectory: URL
    /// The controller's own working folder (the mirror of Mail's index); removed when the session's tools go idle.
    var workFolder: URL?
}

/// The controllers of the sessions whose tools were called, by session id. One is made on the first call, reused by the next ones,
/// and dropped (index closed, working folder removed) once the session's tools have been idle for `idleTimeout`.
///
/// Each session has its own working folder under the extension's, never the tile's: two controllers copying Apple's index to one
/// file would overwrite each other's mirror.
@MainActor
final class MailToolSessions {

    static let shared = MailToolSessions()

    typealias Factory = @MainActor (PluginToolContext, String) throws -> MailToolSession

    /// One controller of one session, from its making to its disposal. It has a working folder of its own (named for the session and
    /// this generation), so a disposal that runs late can only remove its own.
    private final class Generation {
        let session: MailToolSession
        /// The calls running on it. While there is one, the controller is never expired or disposed.
        var leases = 0
        /// Counts down the idle time; only while `leases` is 0.
        var sweep: Task<Void, Never>?
        /// No longer in the registry (expired or released): it is disposed when its last call ends.
        var retired = false

        init(session: MailToolSession) { self.session = session }
    }

    private let idleTimeout: Duration
    /// How long a disposal waits before it closes the controller and removes its folder (a test makes it long).
    private let disposalDelay: Duration
    private let factory: Factory
    private var entries: [String: Generation] = [:]
    private var generations = 0
    /// How many controllers were made (a test and a diagnostic).
    private(set) var madeCount = 0

    init(
        idleTimeout: Duration = .seconds(600), disposalDelay: Duration = .zero,
        factory: @escaping Factory = { try MailToolSessions.live($0, folderName: $1) }
    ) {
        self.idleTimeout = idleTimeout
        self.disposalDelay = disposalDelay
        self.factory = factory
    }

    /// The session ids that have a controller now.
    var activeSessions: Set<String> { Set(entries.keys) }

    /// Runs `body` on the session's controller, holding a lease on it for as long as it runs: the idle time starts only when the
    /// session's last call ends, and a controller with a call running is never expired or disposed, however long the call takes.
    func withSession<T>(for context: PluginToolContext, _ body: (MailToolSession) async throws -> T) async throws -> T {
        let id = context.sessionId
        let generation = try lease(id, context)
        defer { endLease(of: generation, session: id) }
        return try await body(generation.session)
    }

    private func lease(_ id: String, _ context: PluginToolContext) throws -> Generation {
        let generation: Generation
        if let existing = entries[id] {
            generation = existing
        } else {
            generations += 1
            generation = Generation(session: try factory(context, Self.folderName(forSession: id, generation: generations)))
            entries[id] = generation
            madeCount += 1
        }
        generation.sweep?.cancel()
        generation.sweep = nil
        generation.leases += 1
        return generation
    }

    private func endLease(of generation: Generation, session id: String) {
        generation.leases -= 1
        guard generation.leases == 0 else { return }
        if generation.retired {
            dispose(generation.session)
        } else {
            let idleTimeout = idleTimeout
            generation.sweep = Task { [weak self] in
                try? await Task.sleep(for: idleTimeout)
                guard !Task.isCancelled else { return }
                self?.expire(id, generation)
            }
        }
    }

    /// Lets go of a session's controller now (its tools were closed), or as soon as the call running on it ends.
    func release(sessionId: String) {
        guard let generation = entries.removeValue(forKey: sessionId) else { return }
        retire(generation)
    }

    private func expire(_ id: String, _ generation: Generation) {
        guard entries[id] === generation, generation.leases == 0 else { return }
        entries[id] = nil
        retire(generation)
    }

    private func retire(_ generation: Generation) {
        generation.sweep?.cancel()
        generation.sweep = nil
        generation.retired = true
        if generation.leases == 0 { dispose(generation.session) }
    }

    /// Closes the controller (and waits for it), then removes its working folder: the folder is this generation's alone, so a
    /// disposal that runs after a new call made a new controller for the same session cannot touch the new one's files.
    private func dispose(_ session: MailToolSession) {
        let delay = disposalDelay
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            await session.controller.close()
            if let folder = session.workFolder { try? FileManager.default.removeItem(at: folder) }
        }
    }

    // MARK: The live controller

    /// A path component made from a session id: the first 32 hex digits of the SHA-256 of the whole id. Nothing of the id itself is
    /// kept (no `/`, no case, no length limit), so two ids never share a folder, even on a case-insensitive filesystem.
    nonisolated static func folderName(forSession id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The folder of one controller generation of a session: the session's digest and the generation's number.
    nonisolated static func folderName(forSession id: String, generation: Int) -> String {
        "\(folderName(forSession: id))-\(generation)"
    }

    #if os(macOS)
    /// Working folders left by a process that is gone: nothing is using them when the first controller of this process is made.
    private static var sweptStaleFolders = false
    #endif

    /// The controller of the extension's real services (`services.diskRead` and `services.automation`, through Work42), over a working
    /// folder of its own.
    static func live(_ context: PluginToolContext, folderName: String) throws -> MailToolSession {
        #if os(macOS)
        guard let base = MailModel.directFolder() else {
            throw PluginToolFailure(
                code: "unavailable", message: "The Mail plugin has no folder of its own to work in.",
                suggestion: "restart Work 42 and try again")
        }
        let tools = base.appendingPathComponent("tools", isDirectory: true)
        if !sweptStaleFolders {
            sweptStaleFolders = true
            try? FileManager.default.removeItem(at: tools)
        }
        let work = tools.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw PluginToolFailure(
                code: "unavailable", message: "Couldn\u{2019}t make the Mail plugin\u{2019}s working folder: \(error.localizedDescription)",
                suggestion: "check the disk has room, then try again")
        }
        let configuration = MailModel.directConfiguration()
        let controller = MailCtl.Controller(
            disk: context.services.diskRead, automation: context.services.automation, directory: work, configuration: configuration)
        return MailToolSession(
            controller: controller, saver: MailCtlDirectTransport(controller: controller, saveFolders: configuration.saveFolders),
            saveDirectory: MailModel.attachmentsFolder, workFolder: work)
        #else
        throw PluginToolFailure(
            code: "unsupported_in_extension", message: "The Mail tools run on the Mac, where Apple Mail is.",
            suggestion: "ask the Mac\u{2019}s Work 42 to run the tool")
        #endif
    }
}

// MARK: - The mail MCP (the Mail widget)

extension MailWidget: Work42WidgetMCPs {
    var mcpTools: [PluginMCPTools] { [MailTools.mcp(sessions: .shared)] }
}

/// What the tools do, over the session's controller.
@MainActor
enum MailTools {

    /// `read_message` cuts the text (or HTML) here and says so in `truncated`.
    nonisolated static let maxBodyCharacters = 100_000
    nonisolated static let defaultLimit = 25
    nonisolated static let maxLimit = 100

    private static let idHelp = "The message's id (the `id` of a list or search result) or its mail42://message/… link. Prefer the link: it still finds the message after Mail moves it."

    static func mcp(sessions: MailToolSessions) -> PluginMCPTools {
        PluginMCPTools(id: "mail", tools: [
            PluginTool(
                id: "list_mailboxes",
                description: "The user's Apple Mail accounts and their mailboxes, with each mailbox's id, role (inbox, sent, archive, junk, trash…), "
                    + "total and unread counts. Use the ids or names with list_messages and move_message.") { _, context in
                try await run(sessions, context) { session in
                    try .structured(MailToolMailboxes(accounts: try await session.controller.mailboxTree()))
                }
            },
            PluginTool(
                id: "list_messages",
                description: "Lists the newest messages of the user's Apple Mail, newest first: all inboxes by default, or one mailbox, or the flagged ones. "
                    + "With conversations true there is one row per conversation (its newest message, with conversation_count and participants). "
                    + "To page, pass the previous answer's next_before_id as before_id.",
                input: .object([
                    "mailbox": .string("'all' (all inboxes, the default), 'flagged', a mailbox id from list_mailboxes, or a mailbox name or role such as 'inbox'").optional,
                    "unread_only": .boolean("Only unread messages").optional,
                    "flagged_only": .boolean("Only flagged messages").optional,
                    "before_id": .integer("Only messages older than this one: the last id of the previous page").optional,
                    "limit": .integer("How many to return (default \(defaultLimit), at most \(maxLimit))").optional,
                    "conversations": .boolean("One row per conversation instead of one per message").optional,
                ])) { args, context in
                var options = MailCtl.ListOptions()
                options.limit = try limit(args)
                options.unreadOnly = try args.optionalBool("unread_only") ?? false
                options.flaggedOnly = try args.optionalBool("flagged_only") ?? false
                options.conversations = try args.optionalBool("conversations") ?? false
                if let before = try args.optionalInt("before_id") {
                    guard before > 0 else { throw invalid("'before_id' must be a message id", "pass the id of the last message you were given") }
                    options.beforeID = Int64(before)
                }
                if let mailbox = try args.optionalString("mailbox")?.trimmingCharacters(in: .whitespaces), !mailbox.isEmpty {
                    options.mailbox = MailCtl.ListOptions.selector(mailbox)
                }
                let wanted = options
                return try await run(sessions, context) { session in
                    let found = try await session.controller.list(wanted)
                    return try .structured(page(found, limit: wanted.limit, note: nil))
                }
            },
            PluginTool(
                id: "search_messages",
                description: "Searches the user's Apple Mail with the mail42 query language, newest first. Plain words match subject, sender, recipients and the message text "
                    + "(text is read from the newest messages, which takes seconds on a big mailbox: the answer's note says when it could not read them all; narrow with from:, in: or date:). "
                    + "Terms: from:x to:x subject:x body:x, in:inbox|<mailbox id>|<name>, is:unread is:read is:flagged, has:attachment, "
                    + "date:2w.. date:..3d date:2026-10-01..2026-10-15 (d days, w weeks, m months ago). Combine with and, or, not and parentheses; quote phrases.",
                input: .object([
                    "query": .string("The search, e.g. from:alice is:unread date:2w.. \"quarterly report\""),
                    "limit": .integer("How many to return (default \(defaultLimit), at most \(maxLimit))").optional,
                    "headers_only": .boolean("Match only subject, sender, recipients and Apple's preview line (instant, never reads message text)").optional,
                ])) { args, context in
                let query = try args.string("query")
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("'query' is empty", "pass a search such as: from:alice is:unread")
                }
                guard query.count <= MailQueryParser.maxLength else {
                    throw invalid(
                        "'query' is too long (\(query.count) characters; at most \(MailQueryParser.maxLength))",
                        "search for fewer words or terms, for example: from:alice is:unread")
                }
                let wanted = try limit(args)
                let headersOnly = try args.optionalBool("headers_only") ?? false
                return try await run(sessions, context) { session in
                    let outcome = try await session.controller.search(query, limit: wanted, headersOnly: headersOnly)
                    return try .structured(page(outcome.records, limit: wanted, note: outcome.note))
                }
            },
            PluginTool(
                id: "read_message",
                description: "Reads one message: its envelope, top-level headers, body and attachment list. The body is plain text unless format is 'html' (the sanitised HTML). "
                    + "Text longer than \(maxBodyCharacters) characters is cut and truncated is true. body_unavailable true means Apple Mail has not downloaded the body yet (the user can open the message in Mail).",
                input: .object([
                    "id": .string(idHelp),
                    "format": .oneOf(["text", "html"], "'text' (the default) or 'html'").optional,
                ])) { args, context in
                let html = try args.optionalString("format") == "html"
                return try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    let message = try await session.controller.message(target.id, mode: html ? .html : .text)
                    let body = capped(message.content)
                    return try .structured(MailToolMessage(
                        envelope: MailToolEnvelope(message.envelope), headers: message.headers,
                        text: html ? nil : body.text, html: html ? body.text : nil, attachments: message.attachments,
                        bodyUnavailable: message.bodyUnavailable, truncated: body.truncated))
                }
            },
            PluginTool(
                id: "read_thread",
                description: "The whole conversation a message belongs to, oldest first, from every mailbox (Sent included), as envelopes. "
                    + "Read a message's text with read_message.",
                input: .object(["id": .string(idHelp)])) { args, context in
                try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    let thread = try await session.controller.thread(target.id)
                    return try .structured(MailToolThread(messages: thread.map(MailToolEnvelope.init), count: thread.count))
                }
            },
            PluginTool(
                id: "list_attachments",
                description: "The attachments of a message: part (what save_attachment takes), filename, mime type and size in bytes.",
                input: .object(["id": .string(idHelp)])) { args, context in
                try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    return try .structured(MailToolAttachments(attachments: try await session.controller.attachments(target.id)))
                }
            },
            PluginTool(
                id: "save_attachment",
                description: "Saves one attachment of a message into the Mail plugin's attachments folder (~/.work42/mail42/attachments) and answers with the saved path and size. "
                    + "A file name that is taken gets a number (report (1).pdf). It is the only folder Mail attachments can be saved in; read the file from the returned path.",
                input: .object([
                    "id": .string(idHelp),
                    "part": .string("The attachment's part, from list_attachments"),
                ]),
                changesData: true) { args, context in
                let part = try args.string("part")
                guard !part.isEmpty else { throw invalid("'part' is empty", "pass a part from list_attachments") }
                return try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    let result = try await session.saver.run([
                        "attachment", "save", String(target.id), part, "--to", session.saveDirectory.path, "--json",
                    ])
                    return try .structured(try saved(result))
                }
            },
            PluginTool(
                id: "get_message_link",
                description: "The links to a message: the mail42://message/… link (share it with the user: clicking it opens the message in the Mail tile, and it survives Mail moving the message) "
                    + "and Mail's own message:// URL.",
                input: .object(["id": .string(idHelp)])) { args, context in
                try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    return try .structured(MailToolLink(
                        id: target.id, link: target.link ?? "mail42://message/\(target.id)",
                        messageURL: target.messageID.flatMap { MailAct.messageURL(messageID: $0) }))
                }
            },
            PluginTool(
                id: "mark_message",
                description: "Marks a message read or unread and/or flagged or unflagged, in Apple Mail. Change the user's mail only when they asked for it, and say what you did (subject and link). "
                    + "Pass read, flagged, or both; color applies to flagged true.",
                input: .object([
                    "id": .string(idHelp),
                    "read": .boolean("true marks it read, false unread").optional,
                    "flagged": .boolean("true flags it, false removes the flag").optional,
                    "color": .oneOf(MailAct.FlagColor.allCases.map(\.rawValue), "The flag's colour, with flagged true").optional,
                ]),
                changesData: true) { args, context in
                let read = try args.optionalBool("read")
                let flagged = try args.optionalBool("flagged")
                let color = try args.optionalString("color").flatMap(MailAct.FlagColor.init(rawValue:))
                guard read != nil || flagged != nil else {
                    throw invalid("nothing to change", "pass read (true or false), flagged (true or false), or both")
                }
                guard color == nil || flagged == true else {
                    throw invalid("'color' needs 'flagged' set to true", "pass flagged: true together with color")
                }
                return try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    var result: MailActionResult?
                    if let read { result = try await session.controller.mark(target.id, read: read) }
                    if let flagged {
                        if flagged {
                            result = try await session.controller.flag(target.id, color: color)
                        } else {
                            result = try await session.controller.unflag(target.id)
                        }
                    }
                    return try acted("mark", target.id, result)
                }
            },
            PluginTool(
                id: "move_message",
                description: "Moves a message to another mailbox of the same account, in Apple Mail. Change the user's mail only when they asked for it. "
                    + "The answer's link is the message's new one (Mail gives a moved message a new id).",
                input: .object([
                    "id": .string(idHelp),
                    "mailbox": .string("The destination: a mailbox id from list_mailboxes, its name, or its role (e.g. 'archive', 'junk')"),
                ]),
                changesData: true) { args, context in
                let mailbox = try args.string("mailbox")
                guard !mailbox.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw invalid("'mailbox' is empty", "pass a mailbox id or name from list_mailboxes")
                }
                return try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    return try acted("move", target.id, try await session.controller.move(target.id, to: mailbox))
                }
            },
            PluginTool(
                id: "archive_message",
                description: "Moves a message to its account's Archive mailbox, in Apple Mail (for Gmail this removes it from the Inbox). Change the user's mail only when they asked for it.",
                input: .object(["id": .string(idHelp)]), changesData: true) { args, context in
                try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    return try acted("archive", target.id, try await session.controller.archive(target.id))
                }
            },
            PluginTool(
                id: "delete_message",
                description: "Deletes a message: Apple Mail moves it to the account's Trash (move_message with the link brings it back). Change the user's mail only when they asked for it.",
                input: .object(["id": .string(idHelp)]), changesData: true) { args, context in
                try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    return try acted("delete", target.id, try await session.controller.delete(target.id))
                }
            },
            PluginTool(
                id: "junk_message",
                description: "Marks a message as junk and moves it to the account's Junk mailbox, in Apple Mail. Change the user's mail only when they asked for it.",
                input: .object(["id": .string(idHelp)]), changesData: true) { args, context in
                try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    return try acted("junk", target.id, try await session.controller.junk(target.id))
                }
            },
            PluginTool(
                id: "open_reply_draft",
                description: "Opens a reply, reply-all or forward of a message in Mail's own compose window, pre-filled (recipients, subject, the quoted original, the user's signature). "
                    + "It is never sent: the user reads it and presses Send in Mail, and nothing here can send. Tell the user the draft is open.",
                input: .object([
                    "id": .string(idHelp),
                    "mode": .oneOf(["reply", "reply_all", "forward"], "'reply' (the default), 'reply_all' or 'forward'").optional,
                ]),
                changesData: true) { args, context in
                let mode = try args.optionalString("mode") ?? "reply"
                let kind: MailAct.Draft
                let label: String
                switch mode {
                case "reply": (kind, label) = (.reply, "draft reply")
                case "reply_all": (kind, label) = (.replyAll, "draft reply-all")
                case "forward": (kind, label) = (.forward, "draft forward")
                default: throw invalid("'mode' must be reply, reply_all or forward", "pass one of reply, reply_all, forward")
                }
                return try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    return try acted(label, target.id, try await session.controller.draft(kind, of: target.id))
                }
            },
            PluginTool(
                id: "open_in_mail",
                description: "Shows a message in the Mail app (brings its window forward). It changes nothing in the mailbox.",
                input: .object(["id": .string(idHelp)]), changesData: true) { args, context in
                try await run(sessions, context) { session in
                    let target = try await session.controller.resolve(try args.string("id"))
                    _ = try await session.controller.open(target.id)
                    return try .structured(MailToolOpened(
                        ok: true, url: target.messageID.flatMap { MailAct.messageURL(messageID: $0) }, opened: true))
                }
            },
        ])
    }

    // MARK: Running a call

    /// Runs `body` on the session's controller, and turns whatever it throws into a `PluginToolFailure` (cancellation stays one).
    static func run(
        _ sessions: MailToolSessions, _ context: PluginToolContext, _ body: (MailToolSession) async throws -> PluginToolResult
    ) async throws -> PluginToolResult {
        do {
            return try await sessions.withSession(for: context, body)
        } catch {
            throw failure(from: error)
        }
    }

    // MARK: Arguments and answers

    nonisolated static func invalid(_ message: String, _ suggestion: String) -> PluginToolFailure {
        PluginToolFailure(code: "invalid_arguments", message: message, suggestion: suggestion)
    }

    /// `limit`, between 1 and `maxLimit` (the default when absent).
    nonisolated static func limit(_ args: PluginToolArguments) throws -> Int {
        guard let value = try args.optionalInt("limit") else { return defaultLimit }
        guard (1...maxLimit).contains(value) else {
            throw invalid("'limit' must be between 1 and \(maxLimit)", "pass a limit from 1 to \(maxLimit), and page with before_id for more")
        }
        return value
    }

    private static func page(_ found: [MailEnvelope], limit: Int, note: String?) -> MailToolMessages {
        MailToolMessages(
            messages: found.map(MailToolEnvelope.init), count: found.count,
            nextBeforeID: found.count >= limit ? found.last?.id : nil, note: note)
    }

    /// `text` cut at `maxBodyCharacters`, and whether it was.
    nonisolated static func capped(_ text: String?, limit: Int = maxBodyCharacters) -> (text: String?, truncated: Bool) {
        guard let text else { return (nil, false) }
        guard let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex), end < text.endIndex else { return (text, false) }
        return (String(text[..<end]), true)
    }

    private static func acted(_ action: String, _ id: Int64, _ result: MailActionResult?) throws -> PluginToolResult {
        guard let result else { throw MailFailure(code: "error", message: "Nothing was done.") }
        return try .structured(MailToolAction(ok: result.ok, action: action, id: id, link: result.link))
    }

    /// `attachment save`'s answer: `{"path","bytes"}`, or the CLI's `{"error":{"code","message"}}`.
    private static func saved(_ result: MailCLIResult) throws -> MailToolSaved {
        struct Saved: Decodable { var path: String; var bytes: Int }
        if result.status == 0, let saved = try? JSONDecoder().decode(Saved.self, from: result.stdout) {
            return MailToolSaved(path: saved.path, bytes: saved.bytes)
        }
        if let envelope = try? JSONDecoder().decode(MailErrorEnvelope.self, from: result.stdout) {
            throw MailFailure(code: envelope.error.code, message: envelope.error.message)
        }
        throw MailFailure(code: "error", message: result.stderr.isEmpty ? "The attachment was not saved." : result.stderr)
    }

    // MARK: Failures

    /// The failure an agent reads: the CLI's code and words, and what to do next.
    nonisolated static func failure(from error: any Error) -> any Error {
        if error is CancellationError || error is PluginToolFailure { return error }
        guard let failure = MailCtl.failure(from: error) as? MailFailure else { return error }
        let code = failure.code == "usage" ? "invalid_arguments" : failure.code
        return PluginToolFailure(code: code, message: failure.message, suggestion: suggestion(forCode: failure.code))
    }

    nonisolated static func suggestion(forCode code: String) -> String? {
        switch code {
        case "fda_denied":
            return "ask the person to turn on Full Disk Access for Work 42 in System Settings \u{2192} Privacy & Security \u{2192} Full Disk Access, then try again"
        case "no_mail_data":
            return "Apple Mail has no accounts on this Mac: ask the person to set up Mail first"
        case "automation_denied":
            return "ask the person to turn on Mail under Work 42 in System Settings \u{2192} Privacy & Security \u{2192} Automation, then try again"
        case "not_found":
            return "find the message again with list_messages or search_messages (a mail42:// link survives Mail moving a message; a bare id does not), or list_mailboxes for a mailbox"
        case "ambiguous_mailbox":
            return "call move_message again with the id (a number) of the mailbox you mean, from the answer or from list_mailboxes"
        case "bad_query":
            return "write the search as plain words and terms: from:alice to:bob subject:x body:x in:inbox is:unread is:flagged has:attachment date:2w.. date:2026-10-01..2026-10-15, joined by and, or, not and parentheses; quote phrases"
        case "usage":
            return "pass the message's id (a number) or its mail42://message/… link"
        case "schema_unsupported":
            return "this macOS version's Mail index is not understood yet: tell the person; nothing is wrong with their mail"
        case "database_not_accessible", "emlx_parse_failed":
            return "try again in a moment; if it keeps failing, ask the person to open Mail so it can finish updating"
        case "mail_timeout":
            return "Mail did not answer in time and the action may or may not have happened: look at the message (read_message) before trying again"
        case "mail_not_running":
            return "ask the person to open Mail, then try again"
        case "no_archive_mailbox":
            return "the account has no Archive mailbox: use move_message with a mailbox from list_mailboxes"
        case "attachment_not_downloaded":
            return "ask the person to open the message in Mail so it downloads the attachment, then try again"
        case "emlx_not_found":
            return "Mail has no copy of this message on this Mac (it may not be downloaded): read the envelope with read_thread, or ask the person to open it in Mail"
        case "message_too_large":
            return "the message is bigger than the reader opens: ask the person to open it in Mail"
        case "path_not_allowed", "write_failed":
            return "attachments can only be saved in ~/.work42/mail42/attachments; check the disk has room"
        case "unsupported_by_automation", "unsupported_in_extension", MailCtl.hostUnsupportedCode:
            return "this Work 42 cannot do that: tell the person to update Work 42"
        case "action_failed":
            return "Mail refused: its words are in the message; check the message in Mail before trying again"
        default:
            return nil
        }
    }
}
