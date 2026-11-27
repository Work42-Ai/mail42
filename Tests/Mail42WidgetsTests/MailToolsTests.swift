// MailToolsTests.swift — the Mail MCP tools (WOR-900), run end to end over the synthetic Apple Mail store of MailControllerTests:
// the tools as the extension declares them, called the way Work42 calls them (schema check, then the handler with a context), on a
// controller over a real Envelope Index and real .emlx files, with a stand-in for Mail's automation that records the Apple Events.

import Foundation
import Mail42TestSupport
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

// MARK: - A session's services, which the tools do not use (the controller is handed in)

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

@MainActor
private func context(_ sessionId: String) -> PluginToolContext {
    let services = SessionServices(
        composer: NullComposer(), shell: NullShell(), intents: NullIntents(), storage: NullStorage(), pill: NullPill(),
        sessionId: sessionId)
    return PluginToolContext(sessionId: sessionId, widgetId: "mail", invocationId: "call-1", services: services)
}

// MARK: - Reading what a tool answered

private extension WidgetJSONValue {
    func field(_ key: String) -> WidgetJSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
    var items: [WidgetJSONValue] {
        if case .array(let array) = self { return array }
        return []
    }
    var text: String? {
        if case .string(let text) = self { return text }
        return nil
    }
    var integer: Int? {
        if case .number(let number) = self { return Int(number) }
        return nil
    }
    var flag: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }
    var isNull: Bool { self == .null }
    var keySet: Set<String> {
        if case .object(let object) = self { return Set(object.keys) }
        return []
    }
    /// The ids of a `messages` list.
    var messageIDs: [Int] { field("messages")?.items.compactMap { $0.field("id")?.integer } ?? [] }
}

private func keys(ofCLI data: Data) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: data)
    if let dictionary = object as? [String: Any] { return Set(dictionary.keys) }
    if let array = object as? [[String: Any]], let first = array.first { return Set(first.keys) }
    return []
}

private func cliObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - The rig: a world, the sessions registry over it, and the mail MCP

/// The tools of the `mail` MCP over `world`, called as Work42 calls them.
@MainActor
private final class Rig {
    let world: CtlWorld
    let saveDirectory: URL
    let sessions: MailToolSessions
    let mcp: PluginMCPTools
    private let tools: [String: PluginTool]

    /// - Parameters:
    ///   - controller: what the sessions run on instead of `world.controller` (a controller with another automation).
    ///   - others: more sessions' worlds, by session id; every other id gets `world`.
    init(_ world: CtlWorld, controller: MailCtl.Controller? = nil, others: [String: CtlWorld] = [:], idle: Duration = .seconds(600)) throws {
        self.world = world
        let saveDirectory = URL(fileURLWithPath: "/tmp/w900-tools-save-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        self.saveDirectory = saveDirectory
        let folders = MailCtl.SaveFolders(roots: [saveDirectory])
        sessions = MailToolSessions(idleTimeout: idle) { context, _ in
            let chosen = others[context.sessionId] ?? world
            let controller = chosen === world ? (controller ?? world.controller) : chosen.controller
            return MailToolSession(
                controller: controller, saver: MailCtlDirectTransport(controller: controller, saveFolders: folders),
                saveDirectory: saveDirectory, workFolder: nil)
        }
        mcp = MailTools.mcp(sessions: sessions)
        tools = Dictionary(uniqueKeysWithValues: mcp.tools.map { ($0.id, $0) })
    }

    /// What Work42 does with a call: the schema's check, then the handler.
    func call(_ id: String, _ arguments: [String: WidgetJSONValue] = [:], session: String = "s1") async throws -> WidgetJSONValue {
        let tool = try #require(tools[id])
        if let problem = tool.input.problem(with: arguments) {
            throw PluginToolFailure(code: "invalid_arguments", message: problem)
        }
        let result = try await tool.run(PluginToolArguments(arguments), context(session))
        #expect(result.content.count == 1)
        return try #require(result.structured)
    }

    /// The failure a call ends with, or nil when it succeeds.
    func failure(_ id: String, _ arguments: [String: WidgetJSONValue] = [:], session: String = "s1") async -> PluginToolFailure? {
        do { _ = try await call(id, arguments, session: session); return nil } catch { return error as? PluginToolFailure }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: saveDirectory) }
}

private let link101 = "mail42://message/101?mid=alice-101%40example.com"

@MainActor
@Suite("Mail MCP tools: the controller's backend as tools an agent can call (WOR-900)")
struct MailToolsTests {

    // MARK: What is declared

    /// id, changesData, required arguments, in declaration order.
    private static let declared: [(String, Bool, [String])] = [
        ("list_mailboxes", false, []),
        ("list_messages", false, []),
        ("search_messages", false, ["query"]),
        ("read_message", false, ["id"]),
        ("read_thread", false, ["id"]),
        ("list_attachments", false, ["id"]),
        ("save_attachment", true, ["id", "part"]),
        ("get_message_link", false, ["id"]),
        ("mark_message", true, ["id"]),
        ("move_message", true, ["id", "mailbox"]),
        ("archive_message", true, ["id"]),
        ("delete_message", true, ["id"]),
        ("junk_message", true, ["id"]),
        ("open_reply_draft", true, ["id"]),
        ("open_in_mail", true, ["id"]),
    ]

    @Test("the widget declares one MCP, mail, with these tools, these changesData flags and these required arguments")
    func declaredTools() throws {
        let mcps = MailWidget().mcpTools
        #expect(mcps.map(\.id) == ["mail"])
        let tools = try #require(mcps.first).tools
        #expect(tools.map(\.id) == Self.declared.map(\.0))
        for (tool, expected) in zip(tools, Self.declared) {
            #expect(tool.changesData == expected.1, "\(tool.id) changesData")
            #expect(tool.input.required == expected.2.sorted(), "\(tool.id) required")
            #expect(!tool.longRunning)
            #expect(!tool.description.isEmpty, "\(tool.id) has a description")
            #expect(tool.id.allSatisfy { $0.isLowercase || $0 == "_" }, "\(tool.id) is snake_case")
            // Every argument is described, for the agent that reads the schema.
            #expect(tool.input.properties.values.allSatisfy { $0.description?.isEmpty == false }, "\(tool.id) arguments are described")
        }
        // What packaging reads from the extension, as it is written into the release.
        let described = PluginMCPDescription(describing: try #require(mcps.first))
        #expect(described.tools.count == Self.declared.count)
    }

    @Test("the mail MCP id is declared in widgets/mail/widget.yaml as an extension MCP, and the folder is the widget's id")
    func widgetYAML() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work42-plugin/widgets/mail/widget.yaml")
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("id: mail"))
        #expect(lines.contains("- id: mail"))
        #expect(lines.contains("source: extension"))
        #expect(MailWidget().id == "mail")
    }

    // MARK: Reading

    @Test("list_mailboxes answers the accounts with their mailboxes and counters")
    func listMailboxes() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        let answer = try await rig.call("list_mailboxes")
        let account = try #require(answer.field("accounts")?.items.first)
        #expect(account.field("account")?.field("name")?.text == "Work")
        #expect(account.field("account")?.field("email")?.text == "yan@example.com")
        let boxes = try #require(account.field("mailboxes")).items
        #expect(boxes.compactMap { $0.field("name")?.text } == ["INBOX", "Archive", "Junk"])
        #expect(boxes.first?.field("unread")?.integer == 3 && boxes.first?.field("total")?.integer == 4)
    }

    @Test("list_messages: newest first, paged with next_before_id, by mailbox id or name, flagged, unread and as conversations")
    func listMessages() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        let all = try await rig.call("list_messages")
        #expect(all.messageIDs == [103, 102, 101, 104])
        #expect(all.field("count")?.integer == 4 && all.field("next_before_id") == nil)

        let first = try await rig.call("list_messages", ["limit": .number(2)])
        #expect(first.messageIDs == [103, 102] && first.field("next_before_id")?.integer == 102)
        let second = try await rig.call("list_messages", ["limit": .number(2), "before_id": .number(102)])
        #expect(second.messageIDs == [101, 104])

        #expect(try await rig.call("list_messages", ["mailbox": .string("flagged")]).messageIDs == [104])
        #expect(try await rig.call("list_messages", ["mailbox": .string("2")]).messageIDs == [105])
        #expect(try await rig.call("list_messages", ["mailbox": .string("Archive")]).messageIDs == [105])
        #expect(try await rig.call("list_messages", ["unread_only": .bool(true)]).messageIDs == [102, 101, 104])
        #expect(try await rig.call("list_messages", ["flagged_only": .bool(true)]).messageIDs == [104])

        let conversations = try await rig.call("list_messages", ["conversations": .bool(true)])
        #expect(conversations.messageIDs == [103, 102, 104])
        let roadmap = try #require(conversations.field("messages")?.items.first { $0.field("id")?.integer == 102 })
        #expect(roadmap.field("conversation_count")?.integer == 2)
        #expect(roadmap.field("participants")?.items.compactMap(\.text) == ["Bo", "Alice"])
    }

    @Test("search_messages: header terms, body terms from the message files, headers_only skips the files")
    func searchMessages() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        #expect(try await rig.call("search_messages", ["query": .string("from:alice")]).messageIDs == [101])
        #expect(try await rig.call("search_messages", ["query": .string("subject:invoice")]).messageIDs == [103])
        #expect(try await rig.call("search_messages", ["query": .string("quokkabody")]).messageIDs == [101])
        #expect(try await rig.call("search_messages", ["query": .string("quokkabody"), "headers_only": .bool(true)]).messageIDs == [])
        #expect(try await rig.call("search_messages", ["query": .string("is:unread"), "limit": .number(1)]).messageIDs == [102])
    }

    @Test("read_message: text by default, by id or by link, with the envelope, headers and attachments; html is sanitised; a partial download is body_unavailable")
    func readMessage() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        let byID = try await rig.call("read_message", ["id": .string("101")])
        #expect(byID.field("text")?.text?.contains("quokkabody") == true)
        #expect(byID.field("html")?.isNull == true)
        #expect(byID.field("truncated")?.flag == false && byID.field("body_unavailable")?.flag == false)
        #expect(byID.field("envelope")?.field("subject")?.text == "Quarterly roadmap")
        #expect(byID.field("envelope")?.field("link")?.text == link101)
        #expect(byID.field("headers")?.field("subject")?.text == "Quarterly roadmap")

        let byLink = try await rig.call("read_message", ["id": .string(link101)])
        #expect(byLink.field("envelope")?.field("id")?.integer == 101)

        let html = try await rig.call("read_message", ["id": .string("102"), "format": .string("html")])
        let document = try #require(html.field("html")?.text)
        #expect(!document.lowercased().contains("<script") && html.field("text")?.isNull == true)

        let partial = try await rig.call("read_message", ["id": .string("104")])
        #expect(partial.field("body_unavailable")?.flag == true)

        let withAttachment = try await rig.call("read_message", ["id": .string("103")])
        #expect(withAttachment.field("attachments")?.items.first?.field("filename")?.text == "report.pdf")
    }

    @Test("a body longer than the cap is cut and says so; a shorter one is untouched")
    func bodyCap() {
        let long = String(repeating: "é", count: MailTools.maxBodyCharacters + 5)
        let cut = MailTools.capped(long)
        #expect(cut.truncated && cut.text?.count == MailTools.maxBodyCharacters)
        let exact = String(repeating: "a", count: MailTools.maxBodyCharacters)
        #expect(MailTools.capped(exact).truncated == false && MailTools.capped(exact).text == exact)
        #expect(MailTools.capped(nil).text == nil && MailTools.capped(nil).truncated == false)
        #expect(MailTools.capped("abcdef", limit: 3).text == "abc")
    }

    @Test("read_thread answers the whole conversation oldest first; list_attachments the parts save_attachment takes")
    func threadAndAttachments() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        let thread = try await rig.call("read_thread", ["id": .string("102")])
        #expect(thread.messageIDs == [101, 102] && thread.field("count")?.integer == 2)

        let attachments = try await rig.call("list_attachments", ["id": .string("103")])
        let report = try #require(attachments.field("attachments")?.items.first)
        #expect(report.field("part")?.text == "2" && report.field("filename")?.text == "report.pdf")
        #expect(report.field("mime")?.text?.isEmpty == false && report.field("size")?.integer == MailFixtures.attachmentBytes.count)
    }

    @Test("get_message_link answers the mail42 link and Mail's message:// URL")
    func messageLink() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        let answer = try await rig.call("get_message_link", ["id": .string("101")])
        #expect(answer.field("link")?.text == link101)
        #expect(answer.field("message_url")?.text == "message://%3Calice-101%40example.com%3E")
        #expect(answer.field("id")?.integer == 101)
    }

    // MARK: Saving

    @Test("save_attachment writes the bytes into the allowed folder under the attachment's name, numbers a taken name, and answers the path")
    func saveAttachment() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        let saved = try await rig.call("save_attachment", ["id": .string("103"), "part": .string("2")])
        let path = try #require(saved.field("path")?.text)
        #expect(saved.keySet == ["path", "bytes"] && saved.field("bytes")?.integer == MailFixtures.attachmentBytes.count)
        #expect(path == rig.saveDirectory.appendingPathComponent("report.pdf").path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == MailFixtures.attachmentBytes)

        let again = try await rig.call("save_attachment", ["id": .string("103"), "part": .string("2")])
        #expect(again.field("path")?.text == rig.saveDirectory.appendingPathComponent("report (1).pdf").path)

        let unknown = await rig.failure("save_attachment", ["id": .string("103"), "part": .string("9")])
        #expect(unknown?.code == "not_found")
    }

    // MARK: Acting

    @Test("mark_message looks the message up in Mail, then sets its read status, and answers what the CLI printed")
    func markMessage() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        let answer = try await rig.call("mark_message", ["id": .string(link101), "read": .bool(true)])
        #expect(answer.field("ok")?.flag == true && answer.field("action")?.text == "mark" && answer.field("id")?.integer == 101)
        #expect(answer.field("link")?.text == link101)
        let sent = world.automation.requests
        #expect(sent.map { "\($0.eventClass)/\($0.eventID)" } == ["core/getd", "core/setd"])
        #expect(sent.last?.parameters.last == .init("data", .bool(true)))
        #expect(sent.allSatisfy { $0.target == "com.apple.mail" })
    }

    @Test("mark_message flags with a colour (the flag index) and unflags")
    func flagMessage() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        _ = try await rig.call("mark_message", ["id": .string("101"), "flagged": .bool(true), "color": .string("blue")])
        let sent = world.automation.requests
        #expect(sent.map { "\($0.eventClass)/\($0.eventID)" } == ["core/getd", "core/setd", "core/setd"])
        #expect(sent.last?.parameters.last == .init("data", .int(MailAct.FlagColor.blue.index)))
        _ = try await rig.call("mark_message", ["id": .string("101"), "flagged": .bool(false)])
        #expect(world.automation.requests.last?.parameters.last == .init("data", .bool(false)))
    }

    @Test("archive, move, delete, junk and a reply draft each send Mail the Apple Event of that verb")
    func otherActions() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        func lastEvent() -> String { world.automation.requests.last.map { "\($0.eventClass)/\($0.eventID)" } ?? "" }

        let archived = try await rig.call("archive_message", ["id": .string("103")])
        #expect(archived.field("action")?.text == "archive" && lastEvent() == "core/move")
        let moved = try await rig.call("move_message", ["id": .string("103"), "mailbox": .string("Archive")])
        #expect(moved.field("action")?.text == "move" && lastEvent() == "core/move")
        #expect(try await rig.call("delete_message", ["id": .string("103")]).field("action")?.text == "delete")
        #expect(lastEvent() == "core/delo")
        #expect(try await rig.call("junk_message", ["id": .string("103")]).field("action")?.text == "junk")
        #expect(lastEvent() == "core/move")          // the account has a Junk mailbox: marked, then moved

        let before = world.automation.requests.count
        let reply = try await rig.call("open_reply_draft", ["id": .string("101"), "mode": .string("reply_all")])
        #expect(reply.field("action")?.text == "draft reply-all")
        let draft = Array(world.automation.requests.dropFirst(before))
        #expect(draft.map { "\($0.eventClass)/\($0.eventID)" } == ["core/getd", "emal/rpms", "misc/actv"])
        #expect(draft[1].parameters.contains(.init("rpal", .bool(true))))
        _ = try await rig.call("open_reply_draft", ["id": .string("101"), "mode": .string("forward")])
        #expect(world.automation.requests.contains { $0.eventClass == "emal" && $0.eventID == "fwms" })
    }

    @Test("open_in_mail sends Mail its message:// link and changes nothing")
    func openInMail() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        let answer = try await rig.call("open_in_mail", ["id": .string("101")])
        #expect(answer.field("opened")?.flag == true && answer.field("url")?.text == "message://%3Calice-101%40example.com%3E")
        let sent = try #require(world.automation.requests.last)
        #expect(sent.eventClass == "GURL" && sent.parameters == [.init(.directObject, .string("message://%3Calice-101%40example.com%3E"))])
    }

    // MARK: Failures an agent can act on

    @Test("Full Disk Access refused is fda_denied, with the System Settings step; Mail with no data is no_mail_data")
    func accessFailures() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        world.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        let denied = try #require(await rig.failure("list_mailboxes"))
        #expect(denied.code == "fda_denied")
        #expect(denied.suggestion?.contains("Full Disk Access for Work 42") == true)
        #expect(denied.suggestion?.contains("System Settings") == true && !denied.message.isEmpty)
        // A read of a message goes through the same mapping.
        #expect(await rig.failure("read_message", ["id": .string("101")])?.code == "fda_denied")

        let empty = try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))")
        let noData = try #require(await (try Rig(empty)).failure("list_messages"))
        #expect(noData.code == "no_mail_data" && noData.suggestion?.contains("set up Mail") == true)
    }

    @Test("an unknown message is not_found, a malformed id is invalid_arguments, and a bad search is bad_query with the syntax")
    func readFailures() async throws {
        let rig = try Rig(try CtlWorld())
        defer { rig.cleanUp() }
        let missing = try #require(await rig.failure("read_message", ["id": .string("999")]))
        #expect(missing.code == "not_found" && missing.suggestion?.contains("search_messages") == true)
        #expect(await rig.failure("read_thread", ["id": .string("mail42://message/999?mid=nobody%40example.com")])?.code == "not_found")
        let usage = try #require(await rig.failure("read_message", ["id": .string("not a message")]))
        #expect(usage.code == "invalid_arguments" && usage.suggestion?.contains("mail42://") == true)

        let bad = try #require(await rig.failure("search_messages", ["query": .string("from:")]))
        #expect(bad.code == "bad_query")
        #expect(bad.suggestion?.contains("from:") == true && bad.suggestion?.contains("date:") == true)
        let blank = try #require(await rig.failure("search_messages", ["query": .string("   ")]))
        #expect(blank.code == "invalid_arguments")
    }

    @Test("search_messages refuses an over-long query before parsing or touching the index, and a too-deeply nested one as bad_query")
    func hostileSearches() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        for query in [String(repeating: "(", count: 10_000), String(repeating: "not ", count: 10_000), String(repeating: "a", count: 1_048_576)] {
            let refused = try #require(await rig.failure("search_messages", ["query": .string(query)]))
            #expect(refused.code == "invalid_arguments" && refused.message.contains("long"), "\(query.prefix(4)): \(refused.message)")
            #expect(refused.suggestion?.isEmpty == false)
        }
        #expect(rig.sessions.madeCount == 0, "refused before a controller was even made")

        // Under the length limit but nested past the depth limit: the parser's own refusal.
        let deep = String(repeating: "(", count: 100) + "a" + String(repeating: ")", count: 100)
        let nested = try #require(await rig.failure("search_messages", ["query": .string(deep)]))
        #expect(nested.code == "bad_query" && nested.message.contains("nested"))
        // A legal deep query still searches.
        let legal = String(repeating: "(", count: 10) + "from:alice" + String(repeating: ")", count: 10)
        #expect(try await rig.call("search_messages", ["query": .string(legal)]).messageIDs == [101])
    }

    @Test("move_message: an ambiguous mailbox name is ambiguous_mailbox with the candidates and a way out; the id works")
    func moveMessageAmbiguousMailbox() async throws {
        let world = try CtlWorld()
        for (id, path) in [(4, ["Clients", "Reports"]), (5, ["Personal", "Reports"])] {
            try world.builder.addMailbox(id: Int64(id), url: EnvelopeIndexBuilder.mailboxURL(path))
        }
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        let ambiguous = try #require(await rig.failure("move_message", ["id": .string("103"), "mailbox": .string("Reports")]))
        #expect(ambiguous.code == "ambiguous_mailbox")
        #expect(ambiguous.message.contains("Clients/Reports") && ambiguous.message.contains("Personal/Reports"))
        #expect(ambiguous.suggestion?.contains("id") == true)
        #expect(world.automation.requests.isEmpty)
        #expect(await rig.failure("move_message", ["id": .string("103"), "mailbox": .string("5")]) == nil)
        #expect(world.automation.requests.last.map { "\($0.eventClass)/\($0.eventID)" } == "core/move")
    }

    @Test("Mail's own refusals are named: automation_denied with the Automation step, no_archive_mailbox, a mailbox that is not there")
    func actionFailures() async throws {
        let world = try CtlWorld()
        let denied = MailCtl.Controller(
            disk: world.bridge, automation: FakeAutomation { _ in AppleEventReply(errorNumber: -1743, errorMessage: "not allowed") },
            directory: world.folder.appendingPathComponent("denied"), configuration: world.configuration())
        let deniedRig = try Rig(world, controller: denied)
        defer { deniedRig.cleanUp() }
        let refused = try #require(await deniedRig.failure("mark_message", ["id": .string("101"), "read": .bool(true)]))
        #expect(refused.code == "automation_denied" && refused.suggestion?.contains("Automation") == true)

        let rig = try Rig(world)
        defer { rig.cleanUp() }
        #expect(await rig.failure("move_message", ["id": .string("103"), "mailbox": .string("Nowhere")])?.code == "not_found")
        // Message 105 is in the Archive mailbox, whose account has an Archive mailbox: the verb is found; 999 is not.
        #expect(await rig.failure("archive_message", ["id": .string("999")])?.code == "not_found")
        #expect(world.automation.requests.isEmpty)
    }

    @Test("every code the controller can fail with has a suggestion an agent can follow, and cancellation is not turned into a failure")
    func failureMapping() {
        for code in ["fda_denied", "no_mail_data", "automation_denied", "not_found", "bad_query", "mail_timeout", "mail_not_running",
                     "no_archive_mailbox", "attachment_not_downloaded", "emlx_not_found", "message_too_large", "path_not_allowed",
                     "schema_unsupported", "action_failed", "ambiguous_mailbox", MailCtl.hostUnsupportedCode] {
            #expect(MailTools.suggestion(forCode: code) != nil, "\(code) has a suggestion")
        }
        let failure = MailTools.failure(from: MailFailure(code: "automation_denied", message: "no")) as? PluginToolFailure
        #expect(failure?.code == "automation_denied" && failure?.message == "no")
        #expect(MailTools.failure(from: CancellationError()) is CancellationError)
        let own = PluginToolFailure(code: "invalid_arguments", message: "x")
        #expect((MailTools.failure(from: own) as? PluginToolFailure) == own)
        #expect((MailTools.failure(from: MailFailure(code: "usage", message: "u")) as? PluginToolFailure)?.code == "invalid_arguments")
    }

    // MARK: Arguments

    @Test("the schema refuses a missing or unknown argument, a wrong type and a choice that is not offered, before the handler runs")
    func schemaValidation() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        #expect(await rig.failure("read_message")?.message == "'id' is required")
        #expect(await rig.failure("read_message", ["id": .string("101"), "extra": .bool(true)])?.message == "'extra' is not an argument of this tool")
        #expect(await rig.failure("read_message", ["id": .number(101)])?.message == "'id' must be a string")
        #expect(await rig.failure("read_message", ["id": .string("101"), "format": .string("pdf")])?.message == "'format' must be one of: text, html")
        #expect(await rig.failure("list_messages", ["limit": .number(2.5)])?.message == "'limit' must be a whole number")
        #expect(await rig.failure("open_reply_draft", ["id": .string("101"), "mode": .string("send")])?.code == "invalid_arguments")
        #expect(await rig.failure("mark_message", ["id": .string("101"), "color": .string("pink")])?.code == "invalid_arguments")
        #expect(await rig.failure("search_messages", ["query": .string("a")]) == nil)
        #expect(world.automation.requests.isEmpty)
    }

    @Test("ranges are checked in the handler too: limit 1…100, a positive before_id, a change needs something to change")
    func rangeValidation() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        for limit in [0, 101, -1] {
            let refused = try #require(await rig.failure("list_messages", ["limit": .number(Double(limit))]))
            #expect(refused.code == "invalid_arguments" && refused.suggestion?.contains("100") == true)
            #expect(await rig.failure("search_messages", ["query": .string("a"), "limit": .number(Double(limit))])?.code == "invalid_arguments")
        }
        #expect(await rig.failure("list_messages", ["limit": .number(100)]) == nil)
        #expect(await rig.failure("list_messages", ["before_id": .number(0)])?.code == "invalid_arguments")

        let nothing = try #require(await rig.failure("mark_message", ["id": .string("101")]))
        #expect(nothing.code == "invalid_arguments" && nothing.suggestion?.contains("read") == true)
        #expect(await rig.failure("mark_message", ["id": .string("101"), "read": .bool(true), "color": .string("red")])?.code == "invalid_arguments")
        #expect(await rig.failure("move_message", ["id": .string("101"), "mailbox": .string("  ")])?.code == "invalid_arguments")
        #expect(await rig.failure("save_attachment", ["id": .string("103"), "part": .string("")])?.code == "invalid_arguments")
        #expect(world.automation.requests.isEmpty)
    }

    // MARK: Sessions

    @Test("the calls of one session share one controller, so Apple's index is copied once")
    func controllerIsReused() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        _ = try await rig.call("list_mailboxes")
        _ = try await rig.call("list_messages")
        _ = try await rig.call("search_messages", ["query": .string("from:alice")])
        _ = try await rig.call("read_message", ["id": .string("101")])
        #expect(rig.sessions.madeCount == 1 && rig.sessions.activeSessions == ["s1"])
        #expect(await world.controller.refreshCount == 1)
    }

    @Test("two sessions have two controllers: a refusal in one does not reach the other")
    func sessionsAreIsolated() async throws {
        let one = try CtlWorld()
        let two = try CtlWorld()
        let rig = try Rig(one, others: ["s2": two])
        defer { rig.cleanUp() }
        two.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        #expect(try await rig.call("list_messages", session: "s1").messageIDs == [103, 102, 101, 104])
        #expect(await rig.failure("list_messages", session: "s2")?.code == "fda_denied")
        #expect(try await rig.call("list_messages", session: "s1").messageIDs == [103, 102, 101, 104])
        #expect(rig.sessions.madeCount == 2 && rig.sessions.activeSessions == ["s1", "s2"])
        #expect(await one.controller.refreshCount == 1)

        // An action in one session is sent through that session's automation only.
        _ = try await rig.call("mark_message", ["id": .string("101"), "read": .bool(true)], session: "s1")
        #expect(one.automation.requests.count == 2 && two.automation.requests.isEmpty)
    }

    @Test("a session's controller is dropped (index closed) once its tools are idle, and the next call makes a new one")
    func idleControllerIsDropped() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world, idle: .milliseconds(150))
        defer { rig.cleanUp() }
        _ = try await rig.call("list_mailboxes")
        #expect(rig.sessions.activeSessions == ["s1"])
        try await ctlEventually { rig.sessions.activeSessions.isEmpty }
        #expect(rig.sessions.activeSessions.isEmpty)
        try await ctlEventually { await world.controller.closeCount == 1 }
        #expect(await world.controller.closeCount == 1)

        _ = try await rig.call("list_mailboxes")
        #expect(rig.sessions.madeCount == 2)
    }

    @Test("a call keeps the session alive: the idle time counts from the last use")
    func useRestartsTheIdleTime() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world, idle: .milliseconds(600))
        defer { rig.cleanUp() }
        for _ in 0..<4 {
            _ = try await rig.call("list_mailboxes")
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(rig.sessions.madeCount == 1 && rig.sessions.activeSessions == ["s1"])
    }

    @Test("release drops a session's controller at once")
    func releaseDrops() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        _ = try await rig.call("list_mailboxes")
        rig.sessions.release(sessionId: "s1")
        #expect(rig.sessions.activeSessions.isEmpty)
        try await ctlEventually { await world.controller.closeCount == 1 }
        #expect(await world.controller.closeCount == 1)
    }

    @Test("a session id becomes a safe folder name: a hex digest of the whole id, never the id's own characters")
    func folderNames() {
        for id in ["abc-DEF_123", "../../etc/passwd", "", String(repeating: "a", count: 200), "é/\u{0}"] {
            let name = MailToolSessions.folderName(forSession: id)
            #expect(name.count == 32 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(id.prefix(10)) -> \(name)")
        }
        #expect(MailToolSessions.folderName(forSession: "s1") == MailToolSessions.folderName(forSession: "s1"))
    }

    @Test("distinct session ids get distinct folders: a/b vs a_b, empty vs 'session', a shared 80-character start, case-only differences")
    func folderNamesDoNotCollide() {
        let long = String(repeating: "x", count: 100)
        let pairs = [("a/b", "a_b"), ("", "session"), (long + "1", long + "2"), ("Session", "session"), ("../x", "__x"), ("é", "_")]
        for (one, other) in pairs {
            let first = MailToolSessions.folderName(forSession: one)
            let second = MailToolSessions.folderName(forSession: other)
            #expect(first != second, "\(one.prefix(5)) vs \(other.prefix(5))")
            // A case-insensitive filesystem must tell them apart too.
            #expect(first.lowercased() != second.lowercased(), "\(one.prefix(5)) vs \(other.prefix(5)) lowercased")
        }
    }

    /// A registry whose factory records the folder name each controller generation was given.
    private final class Folders { var made: [String] = [] }

    @Test("the same session id is one registry entry while it lives; distinct ids made distinct folders, and each generation has its own")
    func registryKeysAndGenerations() async throws {
        let world = try CtlWorld()
        let folders = Folders()
        let sessions = MailToolSessions(idleTimeout: .seconds(600)) { _, name in
            folders.made.append(name)
            return MailToolSession(
                controller: world.controller, saver: MailCtlDirectTransport(controller: world.controller, saveFolders: .init(roots: [])),
                saveDirectory: world.folder, workFolder: nil)
        }
        for id in ["a/b", "a_b", "", "session", "Abc", "abc"] { try await sessions.withSession(for: context(id)) { _ in } }
        try await sessions.withSession(for: context("a/b")) { _ in }
        #expect(sessions.madeCount == 6 && Set(folders.made).count == 6, "six ids, six entries, six folders; the repeat of a/b made none")
        #expect(sessions.activeSessions == ["a/b", "a_b", "", "session", "Abc", "abc"])

        // Once released, a new generation of the same id gets a folder no earlier generation had.
        sessions.release(sessionId: "a/b")
        try await sessions.withSession(for: context("a/b")) { _ in }
        #expect(folders.made.count == 7 && Set(folders.made).count == 7)
    }

    @Test("a call longer than the idle time is not expired or disposed while it runs; the idle time starts when it ends")
    func longCallIsNotInterrupted() async throws {
        let world = try CtlWorld()
        let sessions = MailToolSessions(idleTimeout: .milliseconds(100)) { _, _ in
            MailToolSession(
                controller: world.controller, saver: MailCtlDirectTransport(controller: world.controller, saveFolders: .init(roots: [])),
                saveDirectory: world.folder, workFolder: nil)
        }
        try await sessions.withSession(for: context("s1")) { _ in
            try await Task.sleep(for: .milliseconds(500))
            #expect(sessions.activeSessions == ["s1"], "still registered after 5x the idle time")
            #expect(await world.controller.closeCount == 0, "its controller was not closed under it")
        }
        #expect(sessions.activeSessions == ["s1"], "it just ended: the idle time has not run yet")
        try await ctlEventually { sessions.activeSessions.isEmpty }
        try await ctlEventually { await world.controller.closeCount == 1 }
        #expect(sessions.madeCount == 1)
    }

    @Test("a second call during a long one shares the controller, and the session lives until the last call ends")
    func overlappingCallsShareALease() async throws {
        let world = try CtlWorld()
        let sessions = MailToolSessions(idleTimeout: .milliseconds(80)) { _, _ in
            MailToolSession(
                controller: world.controller, saver: MailCtlDirectTransport(controller: world.controller, saveFolders: .init(roots: [])),
                saveDirectory: world.folder, workFolder: nil)
        }
        async let long: Void = sessions.withSession(for: context("s1")) { _ in try await Task.sleep(for: .milliseconds(400)) }
        try await Task.sleep(for: .milliseconds(30))
        try await sessions.withSession(for: context("s1")) { _ in }       // a short call ends first
        try await Task.sleep(for: .milliseconds(200))                      // longer than the idle time, with the long call still running
        #expect(sessions.activeSessions == ["s1"] && sessions.madeCount == 1)
        try await long
        try await ctlEventually { sessions.activeSessions.isEmpty }
    }

    @Test("release while a call is running leaves the controller alone until that call ends")
    func releaseWaitsForTheCall() async throws {
        let world = try CtlWorld()
        let sessions = MailToolSessions(idleTimeout: .seconds(600)) { _, _ in
            MailToolSession(
                controller: world.controller, saver: MailCtlDirectTransport(controller: world.controller, saveFolders: .init(roots: [])),
                saveDirectory: world.folder, workFolder: nil)
        }
        try await sessions.withSession(for: context("s1")) { _ in
            sessions.release(sessionId: "s1")
            #expect(sessions.activeSessions.isEmpty)
            try await Task.sleep(for: .milliseconds(150))
            #expect(await world.controller.closeCount == 0, "not closed while its call runs")
        }
        try await ctlEventually { await world.controller.closeCount == 1 }
        #expect(await world.controller.closeCount == 1)
    }

    @Test("a session that expires and is called again at once keeps the new controller's folder: a late disposal only removes its own generation's")
    func lateDisposalCannotDeleteTheNewFolder() async throws {
        let world = try CtlWorld()
        let base = URL(fileURLWithPath: "/tmp/w900-gen-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folders = Folders()
        let sessions = MailToolSessions(idleTimeout: .milliseconds(40), disposalDelay: .milliseconds(500)) { _, name in
            folders.made.append(name)
            let work = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data("mirror".utf8).write(to: work.appendingPathComponent("mirror.db"))
            return MailToolSession(
                controller: world.controller, saver: MailCtlDirectTransport(controller: world.controller, saveFolders: .init(roots: [])),
                saveDirectory: base, workFolder: work)
        }
        try await sessions.withSession(for: context("s1")) { _ in }
        try await ctlEventually { sessions.activeSessions.isEmpty }          // expired; its disposal is still waiting
        try await sessions.withSession(for: context("s1")) { _ in }          // a new generation, at once
        #expect(folders.made.count == 2 && folders.made[0] != folders.made[1], "each generation has its own folder")
        let first = base.appendingPathComponent(folders.made[0]).appendingPathComponent("mirror.db")
        let second = base.appendingPathComponent(folders.made[1]).appendingPathComponent("mirror.db")

        try await ctlEventually { !FileManager.default.fileExists(atPath: first.path) }
        #expect(!FileManager.default.fileExists(atPath: first.path), "the old generation's folder is removed")
        #expect(FileManager.default.fileExists(atPath: second.path), "the new generation's files are still there")
    }

    @Test("disposal waits for the controller's close() before it removes the folder")
    func disposalAwaitsClose() async throws {
        let world = try CtlWorld()
        let base = URL(fileURLWithPath: "/tmp/w900-close-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessions = MailToolSessions(idleTimeout: .milliseconds(30)) { _, name in
            let work = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            return MailToolSession(
                controller: world.controller, saver: MailCtlDirectTransport(controller: world.controller, saveFolders: .init(roots: [])),
                saveDirectory: base, workFolder: work)
        }
        try await sessions.withSession(for: context("s1")) { _ in }
        try await ctlEventually { sessions.activeSessions.isEmpty }
        try await ctlEventually { (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.isEmpty == true }
        #expect(await world.controller.closeCount == 1, "closed before (or when) the folder went")
    }

    // MARK: The CLI's shapes

    @Test("the tools' JSON keys are the CLI's: envelopes, conversations, messages, attachments, mailboxes and action results")
    func keysMatchTheCLI() async throws {
        let world = try CtlWorld()
        let rig = try Rig(world)
        defer { rig.cleanUp() }
        func cli(_ arguments: [String]) async throws -> Data { try await world.transport.run(arguments + ["--json"]).stdout }

        // Envelopes, flat (explicit nulls included) and as conversations (+ conversation_count, participants).
        let flat = try await rig.call("list_messages", ["limit": .number(1)])
        let flatEnvelope = try #require(flat.field("messages")?.items.first)
        let cliFlat = try cliObject(try await cli(["envelope", "list", "--limit", "1"]).firstElement())
        #expect(flatEnvelope.keySet == Set(cliFlat.keys))
        for nested in ["account", "mailbox", "from"] {
            #expect(flatEnvelope.field(nested)?.keySet == Set((cliFlat[nested] as? [String: Any] ?? [:]).keys), "\(nested)")
        }
        #expect(flatEnvelope.field("conversation_id")?.integer == 8 && flatEnvelope.field("message_id")?.text?.contains("carol-103@example.com") == true)

        let conversations = try await rig.call("list_messages", ["limit": .number(1), "conversations": .bool(true)])
        let cliConversation = try keys(ofCLI: try await cli(["envelope", "list", "--limit", "1", "--conversations"]))
        #expect(conversations.field("messages")?.items.first?.keySet == cliConversation)
        #expect(cliConversation.isSuperset(of: ["conversation_count", "participants"]))

        // A message with a null where the CLI printed one.
        let dan = try await rig.call("read_message", ["id": .string("104")])
        #expect(dan.field("envelope")?.field("snippet") == .null)
        #expect(dan.field("envelope")?.field("cc") == .array([]))

        // `message read`: the CLI's keys plus the cap's `truncated`.
        let read = try await rig.call("read_message", ["id": .string("101")])
        let cliRead = try keys(ofCLI: try await cli(["message", "read", "101"]))
        #expect(read.keySet == cliRead.union(["truncated"]))
        #expect(read.field("envelope")?.keySet == flatEnvelope.keySet)

        // `message thread`, `attachment list`, `mailbox list`.
        let thread = try await rig.call("read_thread", ["id": .string("101")])
        #expect(thread.field("messages")?.items.first?.keySet == (try keys(ofCLI: try await cli(["message", "thread", "101"]))))
        let attachments = try await rig.call("list_attachments", ["id": .string("103")])
        #expect(attachments.field("attachments")?.items.first?.keySet == (try keys(ofCLI: try await cli(["attachment", "list", "103"]))))
        let tree = try await rig.call("list_mailboxes")
        let cliTree = try keys(ofCLI: try await cli(["mailbox", "list"]))
        #expect(tree.field("accounts")?.items.first?.keySet == cliTree)

        // An action prints {ok, action, id, link}; `open` prints {ok, url, opened}.
        let marked = try await rig.call("mark_message", ["id": .string("101"), "read": .bool(true)])
        #expect(marked.keySet == (try keys(ofCLI: try await cli(["mark", "101", "read"]))))
        let opened = try await rig.call("open_in_mail", ["id": .string("101")])
        #expect(opened.keySet == (try keys(ofCLI: try await cli(["open", "101"]))))
    }
}

private extension Data {
    /// The first element of a JSON array, as JSON.
    func firstElement() throws -> Data {
        let array = try #require(try JSONSerialization.jsonObject(with: self) as? [Any])
        return try JSONSerialization.data(withJSONObject: try #require(array.first))
    }
}
