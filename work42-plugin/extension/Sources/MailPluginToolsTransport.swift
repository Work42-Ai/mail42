// MailPluginToolsTransport.swift — the iPad's route to Mail: the plugin's own `mail` MCP tools, run by the paired Mac (WOR-900, WOR-902).
//
// `MailStore` sends the argument vectors of the mail42 command line (`envelope list --conversations --limit 50 -m all`, `mark <link> read`).
// This transport reads those same vectors and asks the Mac for the typed tool that does the same thing (`list_messages`, `mark_message`, …,
// SDK 3.5.0 `services.pluginTools`), then hands the widget the JSON the CLI printed (a list is the array the tool wrapped in
// `{messages,count}`, an action is `{ok,action,id,link}`) or its `{"error":{"code","message"}}` envelope, so the widget decodes what it always did.
// It is not under `#if os(iOS)`: it needs nothing of the iPad, so the Mac's tests run the whole route (transport → tool → controller → JSON).
//
// What a call may do on a lost connection:
//   - nothing is retried, here or by the transport: the widget refreshes on demand, and an action is never run twice.
//   - one `run` is one user action and has one request id. A tool that changes mail makes exactly one call, so a retry from below the
//     transport (the same id) is the Mac's no-replay ledger's to answer; a new `run` is a new id and a new action.
//   - `outcome_unknown` (the Mac cannot say whether it ran) and a call lost on the way to a changing tool both leave as an
//     `outcome_unknown` failure that says to look on the Mac before doing it again.
//
// Failures a call can end with: `mac_unreachable`, `outcome_unknown` and `not_permitted` are thrown (they are the link's, as the shell
// transport threw them); a failure of the tool itself (`fda_denied`, `not_found`, `bad_query`, …) comes back as the CLI printed it, a
// non-zero status and the error envelope.
//
// Not mappable (they answer `unsupported_in_extension` or `usage`, never run something else): `draft new` (no tool), `message read --out`
// and `--headers`, `permissions open|automation`. Differences that are answered, not refused: `--limit` above a tool's 100 pages a list
// with `before_id` (a search is cut at 100: it has no paging), `attachment save --to` saves where the tool does (the Mac's attachments
// folder), and `message resolve --prefer-mailbox` is not passed (the tool has no such argument).

import Foundation
import Work42PluginKit

nonisolated final class MailPluginToolsTransport: MailTransport, @unchecked Sendable {

    private static let mcp = "mail"

    /// The tools that change something (`changesData` in MailTools: the user's mail, a saved file, a window opened in Mail): a call lost on
    /// the way to one of these may have run, and is never run again.
    static let changing: Set<String> = [
        "mark_message", "move_message", "archive_message", "delete_message", "junk_message", "open_reply_draft",
        "save_attachment", "open_in_mail",
    ]

    private let tools: any WidgetPluginToolService
    private let pollInterval: Duration
    private let maxBackoff: Duration
    private let streams = Streams()

    /// - Parameters:
    ///   - tools: `services.pluginTools`.
    ///   - pollInterval: how often `changes()` asks for the mailbox counters while someone consumes it.
    ///   - maxBackoff: how far the interval doubles while the Mac does not answer.
    init(tools: any WidgetPluginToolService, pollInterval: Duration = .seconds(6), maxBackoff: Duration = .seconds(60)) {
        self.tools = tools
        self.pollInterval = pollInterval
        self.maxBackoff = maxBackoff
    }

    // MARK: MailTransport

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        try Task.checkCancellation()
        do {
            return try await dispatch(arguments, requestId: UUID())
        } catch let refusal as Refusal {
            return Self.failed(refusal.failure)
        }
    }

    /// A signal each time the mailbox counters changed. The first read is what is there now (the widget has just read it); each later
    /// different one is a change and carries the signature (`id:total:unread,…`). The Mac is asked only while the stream has a consumer,
    /// and less often (the interval doubles, up to `maxBackoff`) while it does not answer.
    func changes() -> AsyncStream<String> {
        let interval = pollInterval
        let ceiling = maxBackoff
        let streams = streams
        return AsyncStream { continuation in
            let id = UUID()
            let task = Task { [self] in
                var last: String?
                var delay = interval
                while !Task.isCancelled {
                    do {
                        let signature = try await mailboxSignature()
                        delay = interval
                        if let last, last != signature { continuation.yield(signature) }
                        last = signature
                    } catch is CancellationError {
                        break
                    } catch {
                        delay = min(delay * 2, ceiling)
                    }
                    try? await Task.sleep(for: delay)
                }
                continuation.finish()
            }
            streams.add(id, task)
            continuation.onTermination = { _ in
                task.cancel()
                streams.remove(id)
            }
        }
    }

    /// Ends every `changes()` stream. The transport can be used again.
    func close() {
        streams.cancelAll()
    }

    // MARK: Streams

    private final class Streams: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [UUID: Task<Void, Never>] = [:]

        func add(_ id: UUID, _ task: Task<Void, Never>) { lock.withLock { tasks[id] = task } }
        func remove(_ id: UUID) { lock.withLock { _ = tasks.removeValue(forKey: id) } }
        func cancelAll() {
            let all = lock.withLock { () -> [Task<Void, Never>] in
                let copy = Array(tasks.values)
                tasks = [:]
                return copy
            }
            for task in all { task.cancel() }
        }
    }

    // MARK: Calling a tool

    /// One call of a `mail` tool. Throws `CancellationError`, a `MailFailure` for what belongs to the link, or a `Refusal` for the
    /// tool's own failure.
    private func call(_ tool: String, _ arguments: [String: WidgetJSONValue] = [:], requestId: UUID = UUID()) async throws -> WidgetJSONValue {
        try Task.checkCancellation()
        let result: PluginToolResult
        do {
            result = try await tools.call(mcp: Self.mcp, tool: tool, arguments: arguments, requestId: requestId)
        } catch {
            throw Self.map(error, changing: Self.changing.contains(tool))
        }
        guard let answer = result.structured else { throw Self.badOutput }
        return answer
    }

    private static let badOutput = Refusal(failure: MailFailure(code: "bad_output", message: "Your Mac answered with something this device can\u{2019}t read."))

    static let checkOnMac = "Your Mac didn\u{2019}t confirm whether Mail did it. Check on your Mac before doing it again."

    private static func unreachable(_ text: String) -> MailFailure {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The link's own words are already "Your Mac didn’t answer.": don't say it twice.
        if trimmed.hasPrefix("Your Mac didn\u{2019}t answer") { return MailFailure(code: "mac_unreachable", message: trimmed) }
        return MailFailure(code: "mac_unreachable", message: "Your Mac didn\u{2019}t answer" + (trimmed.isEmpty ? "." : ": \(trimmed)"))
    }

    private static func map(_ error: any Error, changing: Bool) -> any Error {
        if error is CancellationError { return error }
        if let failure = error as? PluginToolFailure {
            switch failure.code {
            case PluginToolFailure.cancelled.code:
                return CancellationError()
            case PluginRemoteFailure.macUnreachable:
                return unreachable(failure.message)
            case PluginRemoteFailure.outcomeUnknown:
                return MailFailure(code: "outcome_unknown", message: changing ? checkOnMac : "Your Mac didn\u{2019}t confirm its answer.")
            case PluginRemoteFailure.notPermitted:
                return MailFailure(code: "not_permitted", message: failure.message)
            case "invalid_arguments":
                return Refusal(failure: MailFailure(code: "usage", message: failure.message))
            default:
                return Refusal(failure: MailFailure(code: failure.code, message: failure.message))
            }
        }
        // A refusal by the service before anything was sent names its reason; anything else means the answer never came back.
        if let service = error as? WidgetServiceError {
            return service.isNotPermitted ? MailFailure(code: "not_permitted", message: service.message) : unreachable(service.message)
        }
        return changing ? MailFailure(code: "outcome_unknown", message: checkOnMac) : unreachable(error.localizedDescription)
    }

    // MARK: Dispatch

    private func dispatch(_ args: [String], requestId: UUID) async throws -> MailCLIResult {
        guard let verb = args.first else { throw Self.usage("usage: mail42 <verb> …") }
        let rest = Array(args.dropFirst())
        switch verb {
        case "mailbox":
            guard Words.positionals(rest).first == "list" else { throw Self.usage("usage: mailbox list [--json]") }
            let answer = try await call("list_mailboxes")
            guard let accounts = answer.field("accounts") else { throw Self.badOutput }
            return try Self.success(accounts)
        case "envelope": return try await envelope(rest)
        case "message": return try await message(rest)
        case "attachment": return try await attachment(rest)
        case "mark", "move", "archive", "delete", "junk", "draft": return try await action(verb, rest, requestId: requestId)
        case "open":
            guard let id = Words.positionals(rest).first else { throw Self.usage("usage: open <id|link>") }
            return try Self.success(try await call("open_in_mail", ["id": .string(id)]))
        case "permissions": return try await permissions(rest)
        default: throw Self.usage("unknown command `\(verb)`")
        }
    }

    // MARK: envelope

    private static let envelopeValueFlags: Set<String> = ["-m", "--mailbox", "--limit", "--before"]

    private func envelope(_ args: [String]) async throws -> MailCLIResult {
        let words = Words.positionals(args, valueFlags: Self.envelopeValueFlags)
        switch words.first {
        case "list": return try await list(args)
        case "search":
            let query = words.dropFirst().joined(separator: " ")
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { throw Self.usage("usage: envelope search \"<query>\" [--limit N]") }
            // The tool has no paging for a search: a larger limit is cut at the tool's own.
            let limit = min(try Words.intFlag(args, "--limit", min: 1) ?? 50, MailTools.maxLimit)
            var arguments: [String: WidgetJSONValue] = ["query": .string(query), "limit": .number(Double(limit))]
            if args.contains("--headers") { arguments["headers_only"] = .bool(true) }
            let answer = try await call("search_messages", arguments)
            guard let messages = answer.field("messages") else { throw Self.badOutput }
            var result = try Self.success(messages)
            // On stderr, as the CLI printed it, so the JSON stays a plain array.
            if let note = answer.field("note")?.text { result = MailCLIResult(status: 0, stdout: result.stdout, stderr: "mail42: \(note)\n") }
            return result
        default:
            throw Self.usage("usage: envelope list [-m <mailbox>] [--conversations] … | envelope search \"<query>\" [--limit N]")
        }
    }

    /// `envelope list`: pages of the tool (it gives at most `maxLimit` at a time) until `--limit` messages are found or there are no more.
    private func list(_ args: [String]) async throws -> MailCLIResult {
        let limit = try Words.intFlag(args, "--limit", min: 1) ?? 50
        var base: [String: WidgetJSONValue] = [:]
        if args.contains("--unread") { base["unread_only"] = .bool(true) }
        if args.contains("--flagged") { base["flagged_only"] = .bool(true) }
        if args.contains("--conversations") { base["conversations"] = .bool(true) }
        if let mailbox = Words.value(args, "-m") ?? Words.value(args, "--mailbox") { base["mailbox"] = .string(mailbox) }
        var before: Int64?
        if let raw = Words.value(args, "--before") {
            guard let id = Int64(raw) else { throw Self.usage("--before takes an envelope id, not `\(raw)`") }
            before = id
        }
        var found: [WidgetJSONValue] = []
        while found.count < limit {
            let wanted = min(MailTools.maxLimit, limit - found.count)
            var page = base
            page["limit"] = .number(Double(wanted))
            if let before { page["before_id"] = .number(Double(before)) }
            let answer = try await call("list_messages", page)
            guard let messages = answer.field("messages")?.items else { throw Self.badOutput }
            found += messages
            guard !messages.isEmpty, let next = answer.field("next_before_id")?.integer else { break }
            before = Int64(next)
        }
        return try Self.success(.array(Array(found.prefix(limit))))
    }

    // MARK: message

    private func message(_ args: [String]) async throws -> MailCLIResult {
        let words = Words.positionals(args, valueFlags: ["--out", "--prefer-mailbox"])
        switch words.first {
        case "read":
            guard let id = words.dropFirst().first else { throw Self.usage("expected a message id (a number from `envelope list`)") }
            if args.contains("--out") {
                throw Refusal(failure: MailFailure(
                    code: "unsupported_in_extension", message: "This device can\u{2019}t have the message written to a file: the page comes in the answer."))
            }
            guard !args.contains("--headers") else { throw Self.usage("`message read --headers` is not available on this device") }
            let html = args.contains("--html")
            let answer = try await call("read_message", ["id": .string(id), "format": .string(html ? "html" : "text")])
            // The CLI's keys (the tool also says whether it cut the body, which the CLI does not).
            var read: [String: WidgetJSONValue] = [:]
            for key in ["envelope", "headers", "text", "html", "attachments", "body_unavailable"] { read[key] = answer.field(key) ?? .null }
            return try Self.success(.object(read))
        case "thread":
            guard let id = words.dropFirst().first else { throw Self.usage("expected a message id (a number from `envelope list`)") }
            let answer = try await call("read_thread", ["id": .string(id)])
            guard let messages = answer.field("messages") else { throw Self.badOutput }
            return try Self.success(messages)
        case "resolve":
            guard let text = words.dropFirst().first else {
                throw Self.usage("usage: message resolve <mail42://message/\u{2026} link | id> [--prefer-mailbox <id>]")
            }
            // No tool answers one envelope: the link tool finds the message wherever Mail has put it, its conversation holds its envelope.
            let link = try await call("get_message_link", ["id": .string(text)])
            guard let id = link.field("id")?.integer else { throw Self.badOutput }
            let thread = try await call("read_thread", ["id": .string(String(id))])
            guard let found = thread.field("messages")?.items?.first(where: { $0.field("id")?.integer == id }) else {
                throw Refusal(failure: MailFailure(code: "not_found", message: "No message \(id) in Mail."))
            }
            return try Self.success(found)
        default:
            throw Self.usage("usage: message read <id> [--text|--html] | message thread <id> | message resolve <link|id>")
        }
    }

    // MARK: attachment

    private func attachment(_ args: [String]) async throws -> MailCLIResult {
        let words = Words.positionals(args, valueFlags: ["--to"])
        switch words.first {
        case "list":
            guard let id = words.dropFirst().first else { throw Self.usage("expected a message id (a number from `envelope list`)") }
            let answer = try await call("list_attachments", ["id": .string(id)])
            guard let attachments = answer.field("attachments") else { throw Self.badOutput }
            return try Self.success(attachments)
        case "save":
            guard words.count >= 3 else { throw Self.usage("usage: attachment save <id> <part> --to <dir>") }
            // Saved on the Mac, in the Mail plugin's attachments folder: `--to` is the CLI's, the tool has one folder.
            return try Self.success(try await call("save_attachment", ["id": .string(words[1]), "part": .string(words[2])]))
        default:
            throw Self.usage("usage: attachment list <id> | attachment save <id> <part> --to <dir>")
        }
    }

    // MARK: Actions

    private func action(_ verb: String, _ args: [String], requestId: UUID) async throws -> MailCLIResult {
        let words = Words.positionals(args, valueFlags: ["--color", "--to", "--cc", "--subject", "--body"])
        let tool: String
        var arguments: [String: WidgetJSONValue] = [:]
        switch verb {
        case "mark":
            guard words.count >= 2 else {
                throw Self.usage("usage: mark <id|link> read|unread|flagged|unflagged [--color red|orange|yellow|green|blue|purple|gray]")
            }
            tool = "mark_message"
            arguments["id"] = .string(words[0])
            switch words[1].lowercased() {
            case "read": arguments["read"] = .bool(true)
            case "unread": arguments["read"] = .bool(false)
            case "unflagged": arguments["flagged"] = .bool(false)
            case "flagged":
                arguments["flagged"] = .bool(true)
                if let color = Words.value(args, "--color") { arguments["color"] = .string(color.lowercased()) }
            default: throw Self.usage("mark takes read, unread, flagged or unflagged, not `\(words[1])`")
            }
        case "move":
            guard words.count >= 2 else { throw Self.usage("usage: move <id|link> <mailbox id|name>") }
            tool = "move_message"
            arguments = ["id": .string(words[0]), "mailbox": .string(words[1])]
        case "archive", "delete", "junk":
            guard let ref = words.first else { throw Self.usage("usage: \(verb) <id|link>") }
            tool = "\(verb)_message"
            arguments = ["id": .string(ref)]
        default:
            let usage = "usage: draft reply|reply-all|forward <id|link>"
            guard let kind = words.first else { throw Self.usage(usage) }
            switch kind {
            case "reply", "reply-all", "forward":
                guard let ref = words.dropFirst().first else { throw Self.usage(usage) }
                tool = "open_reply_draft"
                arguments = ["id": .string(ref), "mode": .string(kind == "reply-all" ? "reply_all" : kind)]
            case "new":
                throw Refusal(failure: MailFailure(
                    code: "unsupported_in_extension", message: "A new message can\u{2019}t be started from this device yet: start it on your Mac."))
            default:
                throw Self.usage(usage)
            }
        }
        // One action, one call, one request id.
        return try Self.success(try await call(tool, arguments, requestId: requestId))
    }

    // MARK: permissions

    /// `permissions`: Full Disk Access as the Mac's own tools see it. Reading the mailboxes is the proof: it works, or it says why not.
    private func permissions(_ args: [String]) async throws -> MailCLIResult {
        switch args.first(where: { !$0.hasPrefix("-") }) {
        case nil:
            let state: String
            do {
                _ = try await call("list_mailboxes")
                state = "granted"
            } catch let refusal as Refusal {
                switch refusal.failure.code {
                case "fda_denied": state = "denied"
                case "no_mail_data": state = "noMailData"
                default: throw refusal.failure      // the tile says what went wrong instead of asking for access
                }
            }
            let report = try Self.success(.object(["fullDiskAccess": .string(state), "mailRoot": .null]))
            return MailCLIResult(status: state == "granted" ? 0 : 1, stdout: report.stdout, stderr: "")
        case "open", "automation":
            throw Refusal(failure: MailFailure(
                code: "unsupported_in_extension",
                message: "This has to be done on your Mac: open System Settings \u{203A} Privacy & Security \u{203A} Full Disk Access (and Automation), and turn on Work 42."))
        case let other?:
            throw Self.usage("unknown permissions subcommand `\(other)` (try `permissions`)")
        }
    }

    /// The counters as one string, like `MailIndex.mailboxSignature`: `id:total:unread` of every mailbox.
    private func mailboxSignature() async throws -> String {
        let answer = try await call("list_mailboxes")
        guard let accounts = answer.field("accounts")?.items else { throw Self.badOutput }
        return accounts.flatMap { $0.field("mailboxes")?.items ?? [] }
            .map { "\($0.field("id")?.integer ?? 0):\($0.field("total")?.integer ?? 0):\($0.field("unread")?.integer ?? 0)" }
            .joined(separator: ",")
    }

    // MARK: Results

    private static func usage(_ text: String) -> Refusal { Refusal(failure: MailFailure(code: "usage", message: text)) }

    private static func encode(_ value: WidgetJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private static func success(_ value: WidgetJSONValue) throws -> MailCLIResult {
        MailCLIResult(status: 0, stdout: try encode(value), stderr: "")
    }

    /// `{"error":{"code","message"}}` on stdout, the CLI's exit status for the code.
    private static func failed(_ failure: MailFailure) -> MailCLIResult {
        let envelope: WidgetJSONValue = .object(["error": .object(["code": .string(failure.code), "message": .string(failure.message)])])
        return MailCLIResult(
            status: MailCtlDirectTransport.exitStatus(forCode: failure.code), stdout: (try? encode(envelope)) ?? Data(), stderr: "")
    }
}

/// A failure of the tool itself (or of the arguments), which `run` answers the way the CLI does (status and error envelope) instead of throwing.
private nonisolated struct Refusal: Error { let failure: MailFailure }

// MARK: - Arguments, as the CLI read them

private nonisolated enum Words {

    static func value(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func positionals(_ args: [String]) -> [String] { args.filter { !$0.hasPrefix("-") } }

    /// Non-flag arguments, skipping the value that follows each flag in `valueFlags`.
    static func positionals(_ args: [String], valueFlags: Set<String>) -> [String] {
        var result: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(arg) { skipNext = true; continue }
            if !arg.hasPrefix("-") { result.append(arg) }
        }
        return result
    }

    static func intFlag(_ args: [String], _ name: String, min: Int) throws -> Int? {
        guard let raw = value(args, name) else { return nil }
        guard let number = Int(raw), number >= min else {
            throw Refusal(failure: MailFailure(code: "usage", message: "\(name) takes a whole number of \(min) or more, not `\(raw)`"))
        }
        return number
    }
}

// MARK: - Reading a tool's answer

private nonisolated extension WidgetJSONValue {
    func field(_ key: String) -> WidgetJSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
    var items: [WidgetJSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }
    var integer: Int? {
        if case .number(let number) = self { return Int(number) }
        return nil
    }
    var text: String? {
        if case .string(let text) = self { return text }
        return nil
    }
}
