// MailPluginToolsTransportTests.swift — the iPad's route to Mail (WOR-900, WOR-902), run end to end on the Mac: the widget's `MailStore` over
// `MailPluginToolsTransport`, over a stand-in for `services.pluginTools` that runs the REAL `mail` tools (the handlers `MailTools.mcp`
// declares, behind the schema check the Mac's runtime does) on a controller over the synthetic Apple Mail store of MailControllerTests.
// What it proves is transport → tool → controller → JSON → the widget's own decode; what it does not (the link, the iPad, `#if os(iOS)`)
// is the iPad build's.

import Foundation
import Mail42TestSupport
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

// MARK: - The paired Mac: pluginTools serving the real tools

private struct NullComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
    nonisolated func clearCommentableSelection() async throws {}
}

private struct NullShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult { WidgetShellResult(stdout: "", stderr: "", exitCode: 0) }
}

private struct NullIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct NullStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct NullPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

/// One call as the extension's runtime makes it: the handler with a context.
@MainActor
private func invoke(_ tool: PluginTool, _ arguments: [String: WidgetJSONValue]) async throws -> PluginToolResult {
    let services = SessionServices(
        composer: NullComposer(), shell: NullShell(), intents: NullIntents(), storage: NullStorage(), pill: NullPill(), sessionId: "ipad")
    let context = PluginToolContext(sessionId: "ipad", widgetId: "mail", invocationId: "call-1", services: services)
    return try await tool.run(PluginToolArguments(arguments), context)
}

private nonisolated func serving(_ tools: [String: PluginTool]) -> @Sendable (String, [String: WidgetJSONValue]) async throws -> PluginToolResult {
    { id, arguments in
        // What the Mac's runtime does before a handler: the tool must exist, and its schema must accept the arguments.
        guard let tool = tools[id] else { throw PluginToolFailure(code: "not_permitted", message: "not a tool of the mail MCP: \(id)") }
        if let problem = tool.input.problem(with: arguments) { throw PluginToolFailure(code: "invalid_arguments", message: problem) }
        return try await invoke(tool, arguments)
    }
}

/// `services.pluginTools`: records every call, can be told to fail, and otherwise runs the real tool.
nonisolated final class ToolFake: WidgetPluginToolService, @unchecked Sendable {
    struct Call: Sendable {
        let tool: String
        let arguments: [String: WidgetJSONValue]
        let requestId: UUID
        let at: ContinuousClock.Instant
    }

    typealias Script = @Sendable (_ tool: String, _ nth: Int) -> (any Error)?

    private let lock = NSLock()
    private var log: [Call] = []
    private var script: Script?
    private let serve: @Sendable (String, [String: WidgetJSONValue]) async throws -> PluginToolResult

    fileprivate init(serve: @escaping @Sendable (String, [String: WidgetJSONValue]) async throws -> PluginToolResult) { self.serve = serve }

    var calls: [Call] { lock.withLock { log } }
    func calls(of tool: String) -> [Call] { calls.filter { $0.tool == tool } }

    /// From now on a call fails with what `script` returns for it (nil: it runs). `nth` counts the calls of that tool from 0.
    func fail(_ script: Script?) { lock.withLock { self.script = script } }

    func call(mcp: String, tool: String, arguments: [String: WidgetJSONValue], requestId: UUID) async throws -> PluginToolResult {
        let error = lock.withLock { () -> (any Error)? in
            let nth = log.filter { $0.tool == tool }.count
            log.append(Call(tool: tool, arguments: arguments, requestId: requestId, at: .now))
            return script?(tool, nth)
        }
        if let error { throw error }
        guard mcp == "mail" else { throw PluginToolFailure(code: "not_permitted", message: "not the widget's MCP") }
        try Task.checkCancellation()
        return try await serve(tool, arguments)
    }
}

private nonisolated let unreachable = PluginToolFailure(code: PluginRemoteFailure.macUnreachable, message: "Your Mac didn\u{2019}t answer.")
private nonisolated let outcomeUnknown = PluginToolFailure(code: PluginRemoteFailure.outcomeUnknown, message: "The Mac cannot say whether it ran.")

/// The paired Mac and the iPad's side of it: the widget's store, the transport, and the fake in between.
@MainActor
private final class Mac {
    let world: CtlWorld
    let saveDirectory: URL
    let fake: ToolFake
    let transport: MailPluginToolsTransport
    let store: MailStore
    let declared: [PluginTool]

    init(
        _ world: CtlWorld? = nil, controller: MailCtl.Controller? = nil, poll: Duration = .milliseconds(20),
        maxBackoff: Duration = .milliseconds(80)
    ) throws {
        let world = try world ?? CtlWorld()
        self.world = world
        let saveDirectory = URL(fileURLWithPath: "/tmp/w900-ipad-save-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        self.saveDirectory = saveDirectory
        let folders = MailCtl.SaveFolders(roots: [saveDirectory])
        let sessions = MailToolSessions { _, _ in
            let chosen = controller ?? world.controller
            return MailToolSession(
                controller: chosen, saver: MailCtlDirectTransport(controller: chosen, saveFolders: folders),
                saveDirectory: saveDirectory, workFolder: nil)
        }
        let mcp = MailTools.mcp(sessions: sessions)
        declared = mcp.tools
        fake = ToolFake(serve: serving(Dictionary(uniqueKeysWithValues: mcp.tools.map { ($0.id, $0) })))
        transport = MailPluginToolsTransport(tools: fake, pollInterval: poll, maxBackoff: maxBackoff)
        store = MailStore(transport: transport)
    }

    func cleanUp() {
        transport.close()
        try? FileManager.default.removeItem(at: saveDirectory)
    }

    /// `mail42 <arguments>` as the store sends it, answered with status 0.
    func ok(_ arguments: [String]) async throws -> MailCLIResult {
        let result = try await transport.run(arguments)
        #expect(result.status == 0, "\(arguments.joined(separator: " ")) → \(String(decoding: result.stdout, as: UTF8.self))")
        return result
    }

    /// The signature of the counters as the widget's tree gives them (the format `changes()` yields).
    func signature() async throws -> String {
        try await store.json([MailAccountTree].self, ["mailbox", "list"]).flatMap(\.mailboxes).map { "\($0.id):\($0.total):\($0.unread)" }
            .joined(separator: ",")
    }
}

/// What a consumer of `changes()` saw.
private nonisolated final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    private var done = false
    var values: [String] { lock.withLock { all } }
    var finished: Bool { lock.withLock { done } }
    func add(_ value: String) { lock.withLock { all.append(value) } }
    func finish() { lock.withLock { done = true } }

    func consume(_ stream: AsyncStream<String>) -> Task<Void, Never> {
        Task {
            for await value in stream { add(value) }
            finish()
        }
    }
}

private nonisolated struct Acted: Decodable, Sendable {
    let ok: Bool
    let action: String
    let id: Int64?
    let link: String?
}

private nonisolated struct Probe: Decodable, Sendable {
    let id: Int
}

private nonisolated struct Saved: Decodable, Sendable {
    let path: String
    let bytes: Int
}

private func label(_ access: MailAccess) -> String {
    switch access {
    case .granted: return "granted"
    case .denied: return "denied"
    case .noMailData: return "noMailData"
    case .unreachable(let text): return "unreachable: \(text)"
    }
}

private let link101 = "mail42://message/101?mid=alice-101%40example.com"

// MARK: - Tests

@MainActor
@Suite("Mail plugin-tools transport: the iPad's route to the paired Mac's mail tools (WOR-900, WOR-902)")
struct MailPluginToolsTransportTests {

    // MARK: What it relies on

    @Test("the tools the transport calls are the ones the Mail widget declares, and it treats exactly the changesData ones as changing mail")
    func declaredTools() throws {
        let declared = try #require(MailWidget().mcpTools.first)
        #expect(declared.id == "mail")
        let changing = Set(declared.tools.filter(\.changesData).map(\.id))
        #expect(MailPluginToolsTransport.changing == changing)
        let known = Set(declared.tools.map(\.id))
        for tool in ["list_mailboxes", "list_messages", "search_messages", "read_message", "read_thread", "list_attachments",
                     "save_attachment", "get_message_link", "open_in_mail"] + Array(changing) {
            #expect(known.contains(tool), "\(tool) is declared")
        }
    }

    // MARK: Reading, decoded as the widget does

    @Test("mailbox list and envelope list decode into the widget's models, dates and counters intact")
    func listsDecode() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        let trees = try await mac.store.json([MailAccountTree].self, ["mailbox", "list"])
        let tree = try #require(trees.first)
        #expect(trees.count == 1 && tree.account.name == "Work" && tree.account.email == "yan@example.com" && tree.account.kind == "imap")
        #expect(tree.mailboxes.map(\.name) == ["INBOX", "Archive", "Junk"] && tree.mailboxes.map(\.role).first == "inbox")
        #expect(tree.mailboxes.first?.unread == 3 && tree.mailboxes.first?.total == 4)

        let conversations = try await mac.store.json(
            [MailEnvelope].self, ["envelope", "list", "--conversations", "--limit", "50", "-m", "all"], priority: .list)
        #expect(conversations.map(\.id) == [103, 102, 104])
        let roadmap = try #require(conversations.first { $0.id == 102 })
        #expect(roadmap.conversationCount == 2 && roadmap.participants == ["Bo", "Alice"] && roadmap.heading == "Bo, Alice")
        #expect(roadmap.link?.hasPrefix("mail42://message/102") == true && roadmap.reference == roadmap.link)
        #expect(conversations.first?.date == Date(timeIntervalSince1970: TimeInterval(ctlBase + 300)))
        #expect(conversations.first { $0.id == 104 }?.isFlagged == true && conversations.first { $0.id == 103 }?.isRead == true)
        #expect(conversations.first { $0.id == 103 }?.hasAttachments == true)
        #expect(conversations.first?.from.name == "Carol" && conversations.first?.account.email == "yan@example.com")

        func ids(_ arguments: [String]) async throws -> [Int64] {
            try await mac.store.json([MailEnvelope].self, ["envelope", "list"] + arguments).map(\.id)
        }
        #expect(try await ids(["--limit", "50"]) == [103, 102, 101, 104])
        #expect(try await ids(["-m", "flagged"]) == [104])
        #expect(try await ids(["-m", "2"]) == [105])
        #expect(try await ids(["--unread"]) == [102, 101, 104])
        #expect(try await ids(["--limit", "2", "--before", "102"]) == [101, 104])
        #expect(try await ids(["--limit", "2"]) == [103, 102])
    }

    @Test("envelope list maps its flags to list_messages exactly")
    func listArguments() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        _ = try await mac.ok(["envelope", "list", "--conversations", "--limit", "50", "-m", "flagged", "--unread", "--before", "102", "--json"])
        let call = try #require(mac.fake.calls.last)
        #expect(call.tool == "list_messages")
        #expect(call.arguments == [
            "conversations": .bool(true), "unread_only": .bool(true), "mailbox": .string("flagged"), "limit": .number(50),
            "before_id": .number(102),
        ])
        _ = try await mac.ok(["envelope", "list", "--limit", "7", "--mailbox", "Archive", "--flagged"])
        #expect(mac.fake.calls.last?.arguments == ["flagged_only": .bool(true), "mailbox": .string("Archive"), "limit": .number(7)])
    }

    @Test("a limit above the tool's 100 is paged with before_id until it is met or the mailbox ends")
    func paging() async throws {
        let world = try CtlWorld()
        for index in 0..<120 {
            let rowid = Int64(1000 + index)
            try world.builder.addMessage(.init(
                rowid: rowid, subject: "Bulk \(index)", senderAddress: "bulk@example.com", senderName: "Bulk", mailboxID: 1,
                dateReceived: ctlBase + 1000 + Int64(index), read: true, flagged: false, conversationID: 0, summary: nil,
                messageIDHeader: "<bulk-\(rowid)@example.com>"))
        }
        let mac = try Mac(world)
        defer { mac.cleanUp() }
        let all = try await mac.store.json([MailEnvelope].self, ["envelope", "list", "--limit", "150"])
        #expect(all.count == 124 && Set(all.map(\.id)).count == 124)
        #expect(all.first?.id == 1119 && all.last?.id == 104)
        let sent = mac.fake.calls(of: "list_messages")
        #expect(sent.count == 2)
        #expect(sent[0].arguments["limit"] == .number(100) && sent[0].arguments["before_id"] == nil)
        #expect(sent[1].arguments["limit"] == .number(50) && sent[1].arguments["before_id"] == .number(1020))

        // A limit the tool can answer in one page is one call, and a page that is exactly full does not ask for another.
        let before = mac.fake.calls.count
        let hundred = try await mac.store.json([MailEnvelope].self, ["envelope", "list", "--limit", "100"])
        #expect(hundred.count == 100 && mac.fake.calls.count == before + 1)
    }

    @Test("envelope search: the words are one query, --headers is headers_only, the limit is the tool's at most, and it decodes")
    func search() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        let alice = try await mac.store.json([MailEnvelope].self, ["envelope", "search", "from:alice", "--headers", "--limit", "300"])
        #expect(alice.map(\.id) == [101])
        let call = try #require(mac.fake.calls.last)
        #expect(call.tool == "search_messages")
        #expect(call.arguments == ["query": .string("from:alice"), "limit": .number(100), "headers_only": .bool(true)])

        #expect(try await mac.store.json([MailEnvelope].self, ["envelope", "search", "quokkabody"]).map(\.id) == [101])
        #expect(mac.fake.calls.last?.arguments == ["query": .string("quokkabody"), "limit": .number(50)])
        #expect(try await mac.store.json([MailEnvelope].self, ["envelope", "search", "quokkabody", "--headers"]).map(\.id) == [])
        #expect(try await mac.store.json([MailEnvelope].self, ["envelope", "search", "(from:alice)", "in:inbox"]).map(\.id) == [101])
        #expect(await ctlFailure { try await mac.store.json([MailEnvelope].self, ["envelope", "search", "  "]) }?.code == "usage")
    }

    @Test("message read --html: the page is in the answer (no --out), an unavailable body says so, text and html are the CLI's keys")
    func readMessage() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        let page = try await mac.store.json(MailReadResult.self, ["message", "read", "102", "--html"])
        #expect(page.path == nil && page.bodyUnavailable == false)
        let html = try #require(page.html)
        #expect(!html.lowercased().contains("<script") && !html.isEmpty)
        #expect(mac.fake.calls.last?.tool == "read_message" && mac.fake.calls.last?.arguments == ["id": .string("102"), "format": .string("html")])

        let partial = try await mac.store.json(MailReadResult.self, ["message", "read", "104", "--html"])
        #expect(partial.bodyUnavailable == true, "an unavailable body says so (the widget then ignores any html)")

        // The CLI's own object: an envelope, headers, text and html (one null), attachments and body_unavailable.
        let raw = try JSONSerialization.jsonObject(with: try await mac.ok(["message", "read", link101, "--json"]).stdout) as? [String: Any]
        #expect(Set(try #require(raw).keys) == ["envelope", "headers", "text", "html", "attachments", "body_unavailable", "truncated"])
        #expect(raw?["truncated"] as? Bool == false)
        #expect((raw?["text"] as? String)?.contains("quokkabody") == true && raw?["html"] is NSNull)
        #expect(mac.fake.calls.last?.arguments == ["id": .string(link101), "format": .string("text")])
    }

    @Test("message thread, attachment list and message resolve decode as the widget needs them")
    func threadAttachmentsResolve() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        #expect(try await mac.store.json([MailEnvelope].self, ["message", "thread", "102"]).map(\.id) == [101, 102])

        let attachments = try await mac.store.json([MailAttachment].self, ["attachment", "list", "103"])
        #expect(attachments.map(\.part) == ["2"] && attachments.first?.filename == "report.pdf")
        #expect(attachments.first?.size == Int64(MailFixtures.attachmentBytes.count) && attachments.first?.mime.isEmpty == false)

        // resolve: a link, a bare id, a message that is the only one of its conversation, and one with no file on disk.
        let byLink = try await mac.store.json(MailEnvelope.self, ["message", "resolve", link101])
        #expect(byLink.id == 101 && byLink.subject == "Quarterly roadmap" && byLink.conversationCount == nil)
        for id in [101, 104, 105] {
            #expect(try await mac.store.json(MailEnvelope.self, ["message", "resolve", String(id)]).id == Int64(id))
        }
        // `--prefer-mailbox` is sent to the link tool as `prefer_mailbox` (a mailbox id), and only when it was given.
        #expect(mac.fake.calls(of: "get_message_link").last?.arguments.keys.contains("prefer_mailbox") == false)
        let preferred = try await mac.store.json(MailEnvelope.self, ["message", "resolve", link101, "--prefer-mailbox", "1"])
        #expect(preferred.id == 101)
        #expect(mac.fake.calls(of: "get_message_link").last?.arguments == ["id": .string(link101), "prefer_mailbox": .number(1)])
        let missing = await ctlFailure { try await mac.store.json(MailEnvelope.self, ["message", "resolve", "999"]) }
        #expect(missing?.code == "not_found")
    }

    @Test("attachment save runs on the Mac: {path, bytes} as the CLI printed, the file is there, a taken name is numbered")
    func saveAttachment() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        let saved = try await mac.store.json(Saved.self, ["attachment", "save", "103", "2", "--to", "~/Downloads"])
        #expect(saved.path == mac.saveDirectory.appendingPathComponent("report.pdf").path && saved.bytes == MailFixtures.attachmentBytes.count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == MailFixtures.attachmentBytes)
        let call = try #require(mac.fake.calls.last)
        #expect(call.tool == "save_attachment" && call.arguments == ["id": .string("103"), "part": .string("2")])
        let again = try await mac.store.json(Saved.self, ["attachment", "save", "103", "2", "--to", "~/Downloads"])
        #expect(again.path.hasSuffix("report (1).pdf"))
        #expect(await ctlFailure { try await mac.store.json(Saved.self, ["attachment", "save", "103", "9", "--to", "~"]) }?.code == "not_found")
        #expect(await ctlFailure { try await mac.store.json(Saved.self, ["attachment", "save", "103"]) }?.code == "usage")
    }

    // MARK: Acting

    @Test("every action verb calls its tool with the arguments mapped exactly, and answers {ok, action, id, link}")
    func actions() async throws {
        let world = try CtlWorld()
        let mac = try Mac(world)
        defer { mac.cleanUp() }
        let table: [(command: [String], tool: String, arguments: [String: WidgetJSONValue], action: String)] = [
            (["mark", link101, "read"], "mark_message", ["id": .string(link101), "read": .bool(true)], "mark"),
            (["mark", "101", "unread"], "mark_message", ["id": .string("101"), "read": .bool(false)], "mark"),
            (["mark", "101", "flagged"], "mark_message", ["id": .string("101"), "flagged": .bool(true)], "mark"),
            (["mark", "101", "flagged", "--color", "blue"], "mark_message",
             ["id": .string("101"), "flagged": .bool(true), "color": .string("blue")], "mark"),
            (["mark", "101", "unflagged"], "mark_message", ["id": .string("101"), "flagged": .bool(false)], "mark"),
            (["move", "103", "Archive"], "move_message", ["id": .string("103"), "mailbox": .string("Archive")], "move"),
            (["move", link101, "2"], "move_message", ["id": .string(link101), "mailbox": .string("2")], "move"),
            (["archive", "103"], "archive_message", ["id": .string("103")], "archive"),
            (["delete", "103"], "delete_message", ["id": .string("103")], "delete"),
            (["junk", "103"], "junk_message", ["id": .string("103")], "junk"),
            (["draft", "reply", "101"], "open_reply_draft", ["id": .string("101"), "mode": .string("reply")], "draft reply"),
            (["draft", "reply-all", "101"], "open_reply_draft", ["id": .string("101"), "mode": .string("reply_all")], "draft reply-all"),
            (["draft", "forward", link101], "open_reply_draft", ["id": .string(link101), "mode": .string("forward")], "draft forward"),
        ]
        for row in table {
            let result = try await mac.ok(row.command + ["--json"])
            let call = try #require(mac.fake.calls.last)
            #expect(call.tool == row.tool && call.arguments == row.arguments, "\(row.command)")
            let acted = try JSONDecoder().decode(Acted.self, from: result.stdout)
            #expect(acted.ok && acted.action == row.action, "\(row.command)")
            #expect(acted.id == (Int64(row.command[1]) ?? 101), "\(row.command)")      // a link names message 101
            // The widget's own decode.
            #expect(try await mac.store.json(MailActionResult.self, row.command).ok, "\(row.command)")
        }
        #expect(world.automation.requests.contains { $0.eventClass == "emal" && $0.eventID == "fwms" })
        #expect(world.automation.requests.contains { $0.eventClass == "core" && $0.eventID == "delo" })

        let opened = try await mac.store.json(MailActionResult.self, ["open", "101"])
        #expect(opened.ok)
        #expect(mac.fake.calls.last?.tool == "open_in_mail" && mac.fake.calls.last?.arguments == ["id": .string("101")])
        #expect(world.automation.requests.last?.eventClass == "GURL")
    }

    @Test("what has no tool or no meaning here is refused, never run as something else: draft new, --out, --headers, permissions open, unknown verbs")
    func unsupported() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        for (command, code) in [
            (["draft", "new", "--json"], "unsupported_in_extension"),
            (["message", "read", "101", "--html", "--out", "/tmp/x.html", "--json"], "unsupported_in_extension"),
            (["message", "read", "101", "--headers", "--json"], "usage"),
            (["permissions", "open", "--json"], "unsupported_in_extension"),
            (["permissions", "automation", "--json"], "unsupported_in_extension"),
            (["permissions", "frobnicate"], "usage"),
            (["serve"], "usage"),
            (["mark", "101", "sideways"], "usage"),
            (["mark", "101"], "usage"),
            (["move", "101"], "usage"),
            (["envelope", "list", "--limit", "zero"], "usage"),
            (["envelope", "list", "--before", "soon"], "usage"),
            ([], "usage"),
        ] as [([String], String)] {
            let result = try await mac.transport.run(command)
            #expect(result.status != 0 && result.stdout.isEmpty == false, "\(command)")
            let failure = MailCLI.failure(from: result)
            #expect(failure.code == code, "\(command) → \(failure)")
        }
        #expect(mac.fake.calls.isEmpty, "none of them reached the Mac")
    }

    // MARK: Permissions

    @Test("permissions --json: reading the mailboxes decides: granted is exit 0, fda_denied and no_mail_data are the CLI's report, anything else is unreachable")
    func permissions() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        #expect(label(await mac.store.access()) == "granted")
        let granted = try await mac.transport.run(["permissions", "--json"])
        #expect(granted.status == 0 && mac.fake.calls.last?.tool == "list_mailboxes")
        #expect(try JSONDecoder().decode(MailPermissionsReport.self, from: granted.stdout).fullDiskAccess == "granted")

        let refusing = try Mac()
        defer { refusing.cleanUp() }
        refusing.world.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        #expect(label(await refusing.store.access()) == "denied")
        let denied = try await refusing.transport.run(["permissions", "--json"])
        #expect(denied.status == 1)
        #expect(try JSONDecoder().decode(MailPermissionsReport.self, from: denied.stdout).fullDiskAccess == "denied")

        let empty = try Mac(try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))"))
        defer { empty.cleanUp() }
        #expect(label(await empty.store.access()) == "noMailData")
        let none = try await empty.transport.run(["permissions", "--json"])
        let noneReport = try JSONDecoder().decode(MailPermissionsReport.self, from: none.stdout)
        #expect(none.status == 1 && noneReport.fullDiskAccess == "noMailData")

        mac.fake.fail { _, _ in unreachable }
        let calls = mac.fake.calls.count
        guard case .unreachable(let message) = await mac.store.access() else {
            Issue.record("a Mac that does not answer is not an access state")
            return
        }
        #expect(message == "Your Mac didn\u{2019}t answer." && mac.fake.calls.count == calls + 1)
        mac.fake.fail { _, _ in PluginToolFailure(code: "schema_unsupported", message: "this Mail index is not understood") }
        guard case .unreachable(let other) = await mac.store.access() else {
            Issue.record("another failure is not an access state")
            return
        }
        #expect(other == "this Mail index is not understood")
    }

    // MARK: Failures

    @Test("the tool's own failures pass through unchanged: fda_denied, no_mail_data, not_found, bad_query, automation_denied, usage")
    func toolFailures() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        func code(_ arguments: [String]) async -> String? { await ctlFailure { try await mac.store.json(MailEnvelope.self, arguments) }?.code }

        // As the CLI prints them: a status and the error envelope; through the store a MailFailure with the same words.
        let missing = try await mac.transport.run(["message", "thread", "999", "--json"])
        #expect(missing.status == 2)
        let failure = MailCLI.failure(from: missing)
        #expect(failure.code == "not_found" && !failure.message.isEmpty)
        #expect(await code(["message", "resolve", "999"]) == "not_found")
        #expect(await ctlFailure { try await mac.store.json([MailEnvelope].self, ["envelope", "search", "from:"]) }?.code == "bad_query")
        #expect(await ctlFailure { try await mac.store.json(MailReadResult.self, ["message", "read", "999", "--html"]) }?.code == "not_found")
        #expect(await ctlFailure { try await mac.store.json(MailActionResult.self, ["mark", "999", "read"]) }?.code == "not_found")
        #expect(await ctlFailure { try await mac.store.json(MailActionResult.self, ["archive", "not a message"]) }?.code == "usage")

        let refusing = try Mac()
        defer { refusing.cleanUp() }
        refusing.world.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        let denied = try await refusing.transport.run(["mailbox", "list", "--json"])
        #expect(denied.status == 1 && MailCLI.failure(from: denied).code == "fda_denied")
        #expect(await ctlFailure { try await refusing.store.json([MailAccountTree].self, ["mailbox", "list"]) }?.code == "fda_denied")
        #expect(await ctlFailure { try await refusing.store.json([MailEnvelope].self, ["envelope", "list"]) }?.code == "fda_denied")

        let empty = try Mac(try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))"))
        defer { empty.cleanUp() }
        #expect(await ctlFailure { try await empty.store.json([MailEnvelope].self, ["envelope", "list"]) }?.code == "no_mail_data")

        let world = try CtlWorld()
        let controller = MailCtl.Controller(
            disk: world.bridge, automation: FakeAutomation { _ in throw WidgetServiceError.notPermitted("automation is not allowed") },
            directory: world.folder, configuration: world.configuration())
        let denying = try Mac(world, controller: controller)
        defer { denying.cleanUp() }
        let refused = await ctlFailure { try await denying.store.json(MailActionResult.self, ["mark", "101", "read"]) }
        #expect(refused?.code == "automation_denied" && refused?.message.isEmpty == false)
    }

    @Test("a Mac that does not answer is mac_unreachable with the shell transport's words; not_permitted is not_permitted; neither is retried")
    func linkFailures() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }

        mac.fake.fail { _, _ in unreachable }
        let first = await ctlFailure { try await mac.transport.run(["mailbox", "list", "--json"]) }
        #expect(first == MailFailure(code: "mac_unreachable", message: "Your Mac didn\u{2019}t answer."))
        #expect(mac.fake.calls.count == 1, "a read is not retried")

        mac.fake.fail { _, _ in PluginToolFailure(code: PluginRemoteFailure.macUnreachable, message: "the link dropped") }
        let wrapped = await ctlFailure { try await mac.transport.run(["envelope", "list"]) }
        #expect(wrapped == MailFailure(code: "mac_unreachable", message: "Your Mac didn\u{2019}t answer: the link dropped"))

        // The same through the widget's store.
        let viaStore = await ctlFailure { try await mac.store.json([MailAccountTree].self, ["mailbox", "list"]) }
        #expect(viaStore?.code == "mac_unreachable")

        // Anything else that goes wrong before an answer: a read could not be reached, the service's own refusal is a refusal.
        mac.fake.fail { _, _ in URLError(.networkConnectionLost) }
        #expect(await ctlFailure { try await mac.transport.run(["mailbox", "list"]) }?.code == "mac_unreachable")
        mac.fake.fail { _, _ in WidgetServiceError.notPermitted("this widget may not run that tool") }
        let notPermitted = await ctlFailure { try await mac.transport.run(["mailbox", "list"]) }
        #expect(notPermitted?.code == "not_permitted" && notPermitted?.message.contains("may not run") == true)
        mac.fake.fail { _, _ in PluginToolFailure(code: PluginRemoteFailure.notPermitted, message: "Your Mac doesn\u{2019}t allow it.") }
        #expect(await ctlFailure { try await mac.transport.run(["archive", "101"]) } == MailFailure(code: "not_permitted", message: "Your Mac doesn\u{2019}t allow it."))
        mac.fake.fail { _, _ in WidgetServiceError.hostLacks("pluginTools.call") }
        #expect(await ctlFailure { try await mac.transport.run(["mailbox", "list"]) }?.code == "mac_unreachable")
        #expect(mac.fake.calls.count == 7, "every run made exactly one call: nothing was retried")
    }

    @Test("outcome_unknown on a changing tool is surfaced as outcome_unknown with 'check on your Mac', after exactly one call; a lost connection to one is the same")
    func outcomeUnknownIsNeverRetried() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        for command in [["mark", "101", "read"], ["move", "103", "Archive"], ["archive", "103"], ["delete", "103"], ["junk", "103"],
                        ["draft", "reply", "101"], ["attachment", "save", "103", "2", "--to", "~/Downloads"], ["open", "101"]] {
            for error in [outcomeUnknown as any Error, URLError(.networkConnectionLost)] {
                mac.fake.fail { _, _ in error }
                let before = mac.fake.calls.count
                let failure = await ctlFailure { try await mac.transport.run(command + ["--json"]) }
                #expect(failure?.code == "outcome_unknown", "\(command) \(error)")
                #expect(failure?.message.contains("Check on your Mac before doing it again") == true)
                #expect(mac.fake.calls.count == before + 1, "\(command) was asked once")
            }
        }
        // Through the widget's store, the way the model sees it.
        mac.fake.fail { _, _ in outcomeUnknown }
        let viaStore = await ctlFailure { try await mac.store.json(MailActionResult.self, ["mark", "101", "read"]) }
        #expect(viaStore?.code == "outcome_unknown")
        // Nothing ran on the Mac.
        #expect(mac.world.automation.requests.isEmpty)
    }

    @Test("a cancelled call is a CancellationError (the store cancels what nobody waits for), not a failure")
    func cancellation() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        mac.fake.fail { _, _ in PluginToolFailure.cancelled }
        do {
            _ = try await mac.transport.run(["mailbox", "list"])
            Issue.record("expected a cancellation")
        } catch is CancellationError {
        }
        mac.fake.fail(nil)
        let task = Task { try await mac.transport.run(["mailbox", "list"]) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled task still ran a call")
        } catch is CancellationError {
        }
    }

    // MARK: Uncertain outcomes (Codex P1)

    private static let changingCommands: [[String]] = [
        ["mark", "101", "read"], ["move", "103", "Archive"], ["archive", "103"], ["delete", "103"], ["junk", "103"],
        ["draft", "reply", "101"], ["attachment", "save", "103", "2", "--to", "~/Downloads"], ["open", "101"],
    ]

    @Test("a changing call cancelled after it was sent is outcome_unknown (check on your Mac); one cancelled before it was sent is a plain cancellation; a read is a plain cancellation")
    func cancelledChangingCall() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        for command in Self.changingCommands {
            for error in [PluginToolFailure.cancelled as any Error, CancellationError()] {
                mac.fake.fail { _, _ in error }
                let before = mac.fake.calls.count
                let failure = await ctlFailure { try await mac.transport.run(command + ["--json"]) }
                #expect(failure?.code == "outcome_unknown", "\(command) \(error)")
                #expect(failure?.message.contains("Check on your Mac before doing it again") == true)
                #expect(mac.fake.calls.count == before + 1)
            }
        }
        mac.fake.fail { _, _ in PluginToolFailure.cancelled }
        do {
            _ = try await mac.transport.run(["mailbox", "list"])
            Issue.record("a cancelled read is a cancellation")
        } catch is CancellationError {
        }

        // Cancelled before anything was sent: it certainly did not run.
        mac.fake.fail(nil)
        let before = mac.fake.calls.count
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await mac.transport.run(["archive", "103"])
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a task cancelled before the send still ran")
        } catch is CancellationError {
        }
        #expect(mac.fake.calls.count == before, "nothing was sent")
    }

    @Test("the remote service's timeout of a changing call is outcome_unknown; the same words on a read are mac_unreachable")
    func remoteTimeoutOfChangingCall() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        let timedOut = PluginToolFailure(code: PluginRemoteFailure.macUnreachable, message: "Your Mac didn\u{2019}t answer in time (75 s).")
        mac.fake.fail { _, _ in timedOut }
        for command in Self.changingCommands {
            let failure = await ctlFailure { try await mac.transport.run(command + ["--json"]) }
            #expect(failure?.code == "outcome_unknown", "\(command) → \(String(describing: failure))")
        }
        #expect(await ctlFailure { try await mac.transport.run(["mailbox", "list"]) }?.code == "mac_unreachable")
        // No Mac to reach at all (nothing was sent) is still plainly unreachable.
        mac.fake.fail { _, _ in unreachable }
        #expect(await ctlFailure { try await mac.transport.run(["archive", "103", "--json"]) }?.code == "mac_unreachable")
    }

    // MARK: Integers that do not survive a JSON number (Codex P1)

    @Test("an id or cursor that cannot round-trip through a double (Int64.max, 2^53+1) is refused before the Mac is asked; 2^53 is not")
    func unsafeIntegersAreRefused() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        for raw in ["9223372036854775807", "9007199254740993", "-9007199254740993", "-9223372036854775808"] {
            for command in [["envelope", "list", "--before", raw], ["message", "resolve", link101, "--prefer-mailbox", raw]] {
                let result = try await mac.transport.run(command + ["--json"])
                #expect(result.status != 0 && MailCLI.failure(from: result).code == "usage", "\(command)")
            }
        }
        #expect(mac.fake.calls.isEmpty, "none of them reached the Mac")
        let edge = try await mac.transport.run(["envelope", "list", "--before", "9007199254740992", "--json"])
        #expect(mac.fake.calls.count == 1, "2^53 is exact and is sent")
        #expect(MailCLI.failure(from: edge).code == "not_found", "the Mac says there is no such message")
    }

    @Test("an integer in a tool's answer that is not exact (a cursor or id beyond 2^53) is bad_output, never a trap")
    func unsafeIntegersInResults() async throws {
        let huge = 9.3e18
        let fake = ToolFake { tool, _ in
            switch tool {
            case "list_messages", "search_messages":
                return PluginToolResult(content: [], structured: .object([
                    "messages": .array([.object(["id": .number(5)])]), "count": .number(1), "next_before_id": .number(huge),
                ]))
            default:
                return PluginToolResult(content: [], structured: .object(["id": .number(huge), "link": .string("mail42://message/1")]))
            }
        }
        let transport = MailPluginToolsTransport(tools: fake)
        for command in [["envelope", "list", "--limit", "150"], ["envelope", "search", "x", "--limit", "150"], ["message", "resolve", "7"]] {
            let result = try await transport.run(command + ["--json"])
            #expect(result.status != 0 && MailCLI.failure(from: result).code == "bad_output", "\(command)")
        }
    }

    // MARK: A cut message says so (Codex P2)

    @Test("message read carries the tool's `truncated` flag to the widget's decode; an older answer without it decodes as not cut")
    func truncatedReachesTheWidget() async throws {
        let fake = ToolFake { _, _ in
            PluginToolResult(content: [], structured: .object([
                "envelope": .null, "headers": .object([:]), "text": .null, "html": .string("<p>start"), "attachments": .array([]),
                "body_unavailable": .bool(false), "truncated": .bool(true),
            ]))
        }
        let store = MailStore(transport: MailPluginToolsTransport(tools: fake))
        let cut = try await store.json(MailReadResult.self, ["message", "read", "1", "--html"])
        #expect(cut.truncated == true && cut.isTruncated && cut.html == "<p>start")

        let older = try JSONDecoder().decode(MailReadResult.self, from: Data(#"{"path":null,"body_unavailable":false}"#.utf8))
        #expect(older.truncated == nil && !older.isTruncated)
    }

    // MARK: Searches beyond 100 (Codex P2)

    @Test("a search for more than the tool's 100 pages with before_id: every match once, newest first, no gap at the page seam")
    func searchPaging() async throws {
        let world = try CtlWorld()
        for index in 0..<130 {
            let rowid = Int64(1000 + index)
            try world.builder.addMessage(.init(
                rowid: rowid, subject: "Bulk \(index)", senderAddress: "bulk@example.com", senderName: "Bulk", mailboxID: 1,
                dateReceived: ctlBase + 1000 + Int64(index / 2), read: true, flagged: false, conversationID: 0, summary: nil,
                messageIDHeader: "<bulk-\(rowid)@example.com>"))      // pairs share a date, so the seam can fall between ties
        }
        let mac = try Mac(world)
        defer { mac.cleanUp() }
        let all = try await mac.store.json([MailEnvelope].self, ["envelope", "search", "subject:bulk", "--headers", "--limit", "300"])
        #expect(all.map(\.id) == (1000..<1130).reversed().map(Int64.init), "130 matches, each once, newest first")
        let sent = mac.fake.calls(of: "search_messages")
        #expect(sent.count == 2)
        guard sent.count == 2, all.count > 99 else { return }
        #expect(sent[0].arguments["limit"] == .number(100) && sent[0].arguments["before_id"] == nil)
        #expect(sent[1].arguments["before_id"] == .number(Double(all[99].id)) && sent[1].arguments["headers_only"] == .bool(true))
        #expect(Set(sent.map(\.requestId)).count == 2, "no request id is shared between pages")

        // Exactly the limit is one call; fewer than a page is one call.
        let before = mac.fake.calls.count
        #expect(try await mac.store.json([MailEnvelope].self, ["envelope", "search", "subject:bulk", "--headers", "--limit", "100"]).count == 100)
        #expect(try await mac.store.json([MailEnvelope].self, ["envelope", "search", "subject:bulk", "--headers", "--limit", "7"]).count == 7)
        #expect(mac.fake.calls.count == before + 2)
    }

    @Test("a search is paged up to 500 results and no further")
    func searchPagingCap() async throws {
        let fake = ToolFake { tool, arguments in
            var limit = 0
            if case .number(let n)? = arguments["limit"] { limit = Int(n) }
            var start = 100_000
            if case .number(let n)? = arguments["before_id"] { start = Int(n) }
            let ids = (0..<limit).map { start - 1 - $0 }
            return PluginToolResult(content: [], structured: .object([
                "messages": .array(ids.map { .object(["id": .number(Double($0))]) }), "count": .number(Double(limit)),
                "next_before_id": .number(Double(ids.last ?? 0)),
            ]))
        }
        let transport = MailPluginToolsTransport(tools: fake)
        let result = try await transport.run(["envelope", "search", "x", "--headers", "--limit", "900", "--json"])
        let ids = try JSONDecoder().decode([Probe].self, from: result.stdout).map(\.id)
        #expect(ids.count == 500 && Set(ids).count == 500)
        #expect(fake.calls(of: "search_messages").count == 5)
    }

    // MARK: --prefer-mailbox (Codex P2)

    @Test("a stale link whose Message-ID has a copy in two mailboxes resolves to the copy in the preferred mailbox")
    func preferMailbox() async throws {
        let world = try CtlWorld()
        for (rowid, mailbox, offset) in [(Int64(300), Int64(1), Int64(2000)), (301, 2, 2001)] {
            try world.builder.addMessage(.init(
                rowid: rowid, subject: "Copy", senderAddress: "copy@example.com", senderName: "Copy", mailboxID: mailbox,
                dateReceived: ctlBase + offset, read: true, flagged: false, conversationID: 0, summary: nil,
                messageIDHeader: "<copy@example.com>"))
        }
        let mac = try Mac(world)
        defer { mac.cleanUp() }
        let stale = "mail42://message/9999?mid=copy%40example.com"
        #expect(try await mac.store.json(MailEnvelope.self, ["message", "resolve", stale]).id == 301, "the newest copy by default")
        #expect(try await mac.store.json(MailEnvelope.self, ["message", "resolve", stale, "--prefer-mailbox", "1"]).id == 300)
        #expect(try await mac.store.json(MailEnvelope.self, ["message", "resolve", stale, "--prefer-mailbox", "2"]).id == 301)
        #expect(try await mac.store.json(MailEnvelope.self, ["message", "resolve", stale, "--prefer-mailbox", "3"]).id == 301, "none there: the newest")
    }

    // MARK: Request ids

    @Test("a changing action is one call with one request id; no id is used twice across actions, pages or reads")
    func requestIds() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        let actions: [[String]] = [
            ["mark", "101", "read"], ["mark", "101", "read"], ["archive", "103"], ["move", "103", "Archive"], ["draft", "reply", "101"],
            ["junk", "103"], ["delete", "103"], ["mark", "101", "flagged", "--color", "red"],
            ["attachment", "save", "103", "2", "--to", "~/Downloads"], ["open", "101"], ["open", "101"],
        ]
        for command in actions { _ = try await mac.ok(command) }
        _ = try await mac.ok(["envelope", "list", "--limit", "150"])
        _ = try await mac.ok(["message", "resolve", "101"])
        _ = try await mac.ok(["mailbox", "list"])

        let changing = mac.fake.calls.filter { MailPluginToolsTransport.changing.contains($0.tool) }
        #expect(changing.count == actions.count, "one call per action")
        #expect(Set(changing.map(\.requestId)).count == actions.count, "a repeated action is a new action with a new id")
        let everything = mac.fake.calls
        #expect(Set(everything.map(\.requestId)).count == everything.count, "no id is reused for anything")
    }

    // MARK: changes()

    @Test("changes(): the first read is silent, a counter change yields the new signature once, and nothing changing yields nothing")
    func changesOnCounterChange() async throws {
        let world = try CtlWorld(refreshInterval: 0)
        let mac = try Mac(world)
        defer { mac.cleanUp() }
        let before = try await mac.signature()
        let seen = Seen()
        let consumer = seen.consume(mac.transport.changes())
        defer { consumer.cancel() }
        try await ctlEventually { mac.fake.calls(of: "list_mailboxes").count >= 4 }
        #expect(mac.fake.calls(of: "list_mailboxes").count >= 4)
        #expect(seen.values.isEmpty, "the first read, and the same counters after it, are not changes")

        try world.builder.setMailboxCounts(id: 1, total: 9, unread: 8)
        try await ctlEventually { !seen.values.isEmpty }
        let after = try await mac.signature()
        #expect(after != before && after.hasPrefix("1:9:8"))
        #expect(seen.values == [after])
        let settled = mac.fake.calls(of: "list_mailboxes").count
        try await ctlEventually { mac.fake.calls(of: "list_mailboxes").count >= settled + 3 }
        #expect(seen.values == [after], "unchanged counters yield nothing more")
    }

    @Test("changes(): polls only while someone consumes it; cancelling the consumer stops it, close() ends the stream")
    func changesStop() async throws {
        let mac = try Mac()
        defer { mac.cleanUp() }
        #expect(mac.fake.calls.isEmpty)

        let seen = Seen()
        let consumer = seen.consume(mac.transport.changes())
        try await ctlEventually { mac.fake.calls(of: "list_mailboxes").count >= 3 }
        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(100))
        let stopped = mac.fake.calls.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(mac.fake.calls.count == stopped, "no polling after the consumer is gone")

        let other = Seen()
        let ended = other.consume(mac.transport.changes())
        defer { ended.cancel() }
        try await ctlEventually { mac.fake.calls.count > stopped }
        mac.transport.close()
        try await ctlEventually { other.finished }
        #expect(other.finished, "close() finishes the stream")
        try await Task.sleep(for: .milliseconds(100))
        let closed = mac.fake.calls.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(mac.fake.calls.count == closed, "no polling after close()")
    }

    @Test("changes(): while the Mac does not answer the interval doubles up to the ceiling; it is not asked every tick; recovery is not a change")
    func changesBackOff() async throws {
        let mac = try Mac(poll: .milliseconds(30), maxBackoff: .milliseconds(120))
        defer { mac.cleanUp() }
        mac.fake.fail { _, _ in unreachable }
        let seen = Seen()
        let consumer = seen.consume(mac.transport.changes())
        defer { consumer.cancel() }
        try await Task.sleep(for: .milliseconds(800))
        let polls = mac.fake.calls(of: "list_mailboxes")
        // Gaps are at least 60, 120, 120, … ms (a sleep never ends early). The window is as long as the test was kept waiting (a busy
        // main actor can wake it late), so the count is held against the time that really passed, not 800 ms.
        let elapsed = try #require(polls.first).at.duration(to: .now)
        #expect(polls.count >= 3 && polls.count <= 2 + Int(elapsed / .milliseconds(110)), "polled \(polls.count) times in \(elapsed)")
        let gaps = zip(polls, polls.dropFirst()).map { $0.1.at - $0.0.at }
        #expect(gaps.first.map { $0 >= .milliseconds(55) } == true)
        #expect(gaps.dropFirst(2).allSatisfy { $0 >= .milliseconds(110) }, "the ceiling is reached and held")
        #expect(seen.values.isEmpty)

        // The Mac comes back: the poll goes on, and coming back is not a change.
        mac.fake.fail(nil)
        let atRecovery = mac.fake.calls.count
        try await ctlEventually { mac.fake.calls.count >= atRecovery + 3 }
        #expect(mac.fake.calls.count >= atRecovery + 3)
        #expect(seen.values.isEmpty, "the first answer after an outage is a read, not a change")
    }

    @Test("changes(): a signature is the counters as id:total:unread of every mailbox, and a counter that moved after an outage is a change")
    func changesAfterOutage() async throws {
        let world = try CtlWorld(refreshInterval: 0)
        let mac = try Mac(world)
        defer { mac.cleanUp() }
        let seen = Seen()
        let consumer = seen.consume(mac.transport.changes())
        defer { consumer.cancel() }
        try await ctlEventually { mac.fake.calls(of: "list_mailboxes").count >= 2 }
        let baseline = try await mac.signature()

        mac.fake.fail { _, _ in unreachable }
        try await Task.sleep(for: .milliseconds(100))
        try world.builder.setMailboxCounts(id: 2, total: 3, unread: 2)
        mac.fake.fail(nil)
        try await ctlEventually { !seen.values.isEmpty }
        let moved = try await mac.signature()
        #expect(moved != baseline && seen.values == [moved])
        #expect(moved.split(separator: ",").count == 3 && moved.split(separator: ",").allSatisfy { $0.split(separator: ":").count == 3 })
    }
}
