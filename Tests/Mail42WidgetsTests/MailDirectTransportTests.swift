// MailDirectTransportTests.swift — the widget's own argument vectors, answered with no CLI behind them (WOR-900). Every test goes
// through `MailCtlDirectTransport.run` and decodes what comes back the way `MailStore` does (`JSONDecoder` with `.iso8601`).

import Foundation
import Mail42TestSupport
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

/// What `MailStore.json` does with a successful answer.
private func decode<T: Decodable>(_ type: T.Type, _ result: MailCLIResult) throws -> T {
    try #require(result.status == 0, "status \(result.status): \(String(decoding: result.stdout, as: UTF8.self))")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: result.stdout)
}

private func object(_ result: MailCLIResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
}

/// What `MailCLI.failure(from:)` does with a failed answer.
private func failure(_ result: MailCLIResult) throws -> MailFailure {
    try #require(result.status != 0)
    return MailCLI.failure(from: result)
}

/// The answer is a failure with this exit status and this code, in the CLI's `{"error":{"code","message"}}` envelope.
private func expectFailure(_ result: MailCLIResult, status: Int32, code: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(result.status == status, sourceLocation: sourceLocation)
    let found = try failure(result)
    #expect(found.code == code && !found.message.isEmpty, sourceLocation: sourceLocation)
}

/// Values that arrive on a stream, readable from the test.
private nonisolated final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var finished = false
    var values: [String] { lock.withLock { items } }
    var isFinished: Bool { lock.withLock { finished } }
    func add(_ value: String) { lock.withLock { items.append(value) } }
    func finish() { lock.withLock { finished = true } }
}

private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
}

@Suite("Mail direct transport: the CLI's verbs without a CLI (WOR-900)")
struct MailDirectTransportTests {

    // MARK: Reading

    @Test("mailbox list decodes into [MailAccountTree] with the account's name and Apple's counters")
    func mailboxList() async throws {
        let world = try CtlWorld()
        let result = try await world.transport.run(["mailbox", "list", "--json"])
        let trees = try decode([MailAccountTree].self, result)
        let tree = try #require(trees.first)
        #expect(tree.account == .init(id: EnvelopeIndexBuilder.accountUUID, name: "Work", email: "yan@example.com", kind: "imap"))
        #expect(tree.mailboxes == [
            MailMailbox(id: 1, name: "INBOX", role: "inbox", total: 4, unread: 3),
            MailMailbox(id: 2, name: "Archive", role: "archive", total: 1, unread: 0),
            MailMailbox(id: 3, name: "Junk", role: "junk", total: 0, unread: 0),
        ])
        #expect(result.stderr.isEmpty)
    }

    @Test("envelope list: flat and conversations, as the widget asks, decode into [MailEnvelope] with ISO-8601 dates")
    func envelopeList() async throws {
        let world = try CtlWorld()
        let flat = try decode([MailEnvelope].self, try await world.transport.run(["envelope", "list", "--limit", "50", "-m", "all", "--json"]))
        #expect(flat.map(\.id) == [103, 102, 101, 104])
        let first = try #require(flat.first)
        #expect(first.subject == "Invoice attached" && first.from.name == "Carol" && first.from.addr == "carol@example.com")
        #expect(first.date == Date(timeIntervalSince1970: TimeInterval(ctlBase + 300)))
        #expect(first.isRead && !first.isFlagged && first.hasAttachments)
        #expect(first.account.name == "Work" && first.mailbox == MailMailboxRef(id: 1, name: "INBOX", role: "inbox"))
        #expect(first.link == "mail42://message/103?mid=carol-103%40example.com" && first.conversationCount == nil)
        let roadmap = try #require(flat.first { $0.id == 101 })
        #expect(roadmap.to == [MailPerson(name: "Yan", addr: "yan@example.com")] && roadmap.snippet == "Roadmap for Q4 planning")
        #expect(roadmap.conversationID == 7 && flat.last?.conversationID == nil)

        let args = ["envelope", "list", "--conversations", "--limit", "50", "-m", "all"]
        let conversations = try decode([MailEnvelope].self, try await world.transport.run(args + ["--json"]))
        #expect(conversations.map(\.id) == [103, 102, 104])
        #expect(conversations[1].conversationCount == 2 && conversations[1].participants == ["Bo", "Alice"])
        #expect(conversations[1].heading == "Bo, Alice")
    }

    @Test("paging with --before, and the flagged, mailbox and unread selections")
    func paging() async throws {
        let world = try CtlWorld()
        func ids(_ arguments: [String]) async throws -> [Int64] {
            try decode([MailEnvelope].self, try await world.transport.run(["envelope", "list"] + arguments + ["--json"])).map(\.id)
        }
        #expect(try await ids(["--limit", "2", "-m", "all"]) == [103, 102])
        #expect(try await ids(["--limit", "2", "-m", "all", "--before", "102"]) == [101, 104])
        #expect(try await ids(["--conversations", "--limit", "2", "-m", "all"]) == [103, 102])
        #expect(try await ids(["--conversations", "--limit", "2", "-m", "all", "--before", "102"]) == [104])
        #expect(try await ids(["--conversations", "--limit", "50", "-m", "flagged"]) == [104])
        #expect(try await ids(["--conversations", "--limit", "50", "-m", "2"]) == [105])
        #expect(try await ids(["--conversations", "--limit", "50", "-m", "all", "--unread"]) == [102, 104])
    }

    @Test("search: header terms, body terms, and --headers to skip the message files")
    func search() async throws {
        let world = try CtlWorld()
        func ids(_ arguments: [String]) async throws -> [Int64] {
            try decode([MailEnvelope].self, try await world.transport.run(["envelope", "search"] + arguments + ["--json"])).map(\.id)
        }
        #expect(try await ids(["from:alice", "--headers", "--limit", "50"]) == [101])
        #expect(try await ids(["subject:invoice", "--limit", "50"]) == [103])
        #expect(try await ids(["quokkabody", "--headers", "--limit", "50"]).isEmpty)
        #expect(try await ids(["quokkabody", "--limit", "50"]) == [101])
        #expect(try await ids(["headline", "--limit", "50"]) == [102])
        // Unquoted words are one query, as on the command line.
        #expect(try await ids(["from:alice", "is:unread", "--headers"]) == [101])
    }

    @Test("a query that is not valid is bad_query with exit 2, and a blank one is a usage error")
    func badQuery() async throws {
        let world = try CtlWorld()
        let bad = try await world.transport.run(["envelope", "search", "from:", "--headers", "--limit", "50", "--json"])
        try expectFailure(bad, status: 2, code: "bad_query")
        try expectFailure(try await world.transport.run(["envelope", "search", "  ", "--json"]), status: 2, code: "usage")
    }

    @Test("message read --html: written to the file the widget names, or returned inline, sanitised either way")
    func readHTML() async throws {
        let world = try CtlWorld()
        let file = world.folder.appendingPathComponent("reader/m102.html")

        let written = try decode(MailReadResult.self, try await world.transport.run(
            ["message", "read", "102", "--html", "--out", file.path, "--json"]))
        #expect(written.path == file.path && !written.bodyUnavailable)
        let body = try String(contentsOf: file, encoding: .utf8)
        #expect(body.contains("Roadmap headline") && !body.contains("SCRIPT RAN") && !body.contains("onclick"))

        let inline = try await world.transport.run(["message", "read", "102", "--html", "--json"])
        let read = try decode(MailReadResult.self, inline)
        #expect(read.path == nil && read.html?.contains("Roadmap headline") == true && !read.bodyUnavailable)
        let whole = try object(inline)
        #expect(Set(whole.keys) == ["envelope", "headers", "text", "html", "attachments", "body_unavailable", "truncated"])
        #expect(whole["truncated"] as? Bool == false, "read in this process, whole")
        #expect(whole["text"] is NSNull)
        #expect((whole["envelope"] as? [String: Any])?["id"] as? Int == 102)

        let text = try object(try await world.transport.run(["message", "read", "101", "--json"]))
        #expect((text["text"] as? String)?.contains("quokkabody") == true && text["html"] is NSNull)
    }

    @Test("a partial download with no body is body_unavailable, with or without --out, and nothing is written")
    func readPartial() async throws {
        let world = try CtlWorld()
        let file = world.folder.appendingPathComponent("reader/m104.html")
        let out = try decode(MailReadResult.self, try await world.transport.run(
            ["message", "read", "104", "--html", "--out", file.path, "--json"]))
        #expect(out.path == nil && out.bodyUnavailable && !FileManager.default.fileExists(atPath: file.path))
        let inline = try decode(MailReadResult.self, try await world.transport.run(["message", "read", "104", "--html", "--json"]))
        #expect(inline.bodyUnavailable)
        let none = try decode(MailReadResult.self, try await world.transport.run(["message", "read", "105", "--html", "--json"]))
        #expect(none.bodyUnavailable && none.html == nil)

        try expectFailure(try await world.transport.run(["message", "read", "999", "--html", "--json"]), status: 2, code: "not_found")
    }

    @Test("a partial download that has its text reads like a full one")
    func readWithAndWithoutAPartialFile() async throws {
        let world = try CtlWorld()
        try world.addPartialWithAttachment(cached: true)
        let partial = try decode(MailReadResult.self, try await world.transport.run(["message", "read", "106", "--html", "--json"]))
        #expect(!partial.bodyUnavailable && partial.html?.contains("The attachment bytes live in Mail") == true)
    }

    @Test("message thread and message resolve")
    func threadAndResolve() async throws {
        let world = try CtlWorld()
        let thread = try decode([MailEnvelope].self, try await world.transport.run(["message", "thread", "102", "--json"]))
        #expect(thread.map(\.id) == [101, 102])

        let link = "mail42://message/101?mid=alice-101%40example.com"
        #expect(try decode(MailEnvelope.self, try await world.transport.run(["message", "resolve", link, "--json"])).id == 101)
        // The row id is stale; the Message-ID finds the message, and the widget's selected mailbox is preferred.
        let moved = "mail42://message/9999?mid=bo-102%40example.com"
        let found = try decode(MailEnvelope.self, try await world.transport.run(
            ["message", "resolve", moved, "--prefer-mailbox", "1", "--json"]))
        #expect(found.id == 102)

        let gone = try await world.transport.run(["message", "resolve", "mail42://message/9999?mid=nobody%40example.com", "--json"])
        try expectFailure(gone, status: 2, code: "not_found")
    }

    @Test("attachment list decodes into [MailAttachment]; attachment save writes nowhere unless a save folder was configured")
    func attachments() async throws {
        let world = try CtlWorld()
        let listed = try decode([MailAttachment].self, try await world.transport.run(["attachment", "list", "103", "--json"]))
        #expect(listed == [MailAttachment(part: "2", filename: "report.pdf", mime: "application/pdf", size: Int64(MailFixtures.attachmentBytes.count))])
        #expect(try decode([MailAttachment].self, try await world.transport.run(["attachment", "list", "101", "--json"])).isEmpty)

        // The world's transport has no save folders: no folder at all is one it may write in.
        let save = try await world.transport.run(["attachment", "save", "103", "2", "--to", "~/Downloads", "--json"])
        try expectFailure(save, status: 2, code: "path_not_allowed")
    }

    // MARK: Saving an attachment (the widget's Save Attachment and Quick Look)

    /// A scratch folder tree: `allowed` (a save root), `outside` (next to it, in no root).
    private final class Folders {
        let base = URL(fileURLWithPath: "/tmp/w900-save-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var allowed: URL { base.appendingPathComponent("allowed", isDirectory: true) }
        var outside: URL { base.appendingPathComponent("outside", isDirectory: true) }
        init() throws {
            try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func contents(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    }

    private func saver(_ world: CtlWorld, _ folders: MailCtl.SaveFolders) -> MailCtlDirectTransport {
        MailCtlDirectTransport(controller: world.controller, saveFolders: folders)
    }

    private func save(_ transport: MailCtlDirectTransport, to directory: String, part: String = "2") async throws -> MailCLIResult {
        try await transport.run(["attachment", "save", "103", part, "--to", directory, "--json"])
    }

    @Test("attachment save writes the bytes under the attachment's own name in an allowed folder, and prints {path, bytes} as the CLI did")
    func saveWritesTheFile() async throws {
        let world = try CtlWorld()
        let folders = try Folders()
        let transport = saver(world, .init(roots: [folders.allowed]))
        let target = folders.allowed.appendingPathComponent("sub", isDirectory: true)      // made, like the CLI did

        let result = try await save(transport, to: target.path)
        let printed = try object(result)
        #expect(result.status == 0 && result.stderr.isEmpty)
        #expect(printed["path"] as? String == target.appendingPathComponent("report.pdf").path)
        #expect(printed["bytes"] as? Int == MailFixtures.attachmentBytes.count)
        #expect(Set(printed.keys) == ["path", "bytes"])
        #expect(try Data(contentsOf: target.appendingPathComponent("report.pdf")) == MailFixtures.attachmentBytes)
    }

    @Test("a second save of the same attachment gets a numbered name and never overwrites the first")
    func saveCollisionIsNumbered() async throws {
        let world = try CtlWorld()
        let folders = try Folders()
        let transport = saver(world, .init(roots: [folders.allowed]))
        try Data("mine".utf8).write(to: folders.allowed.appendingPathComponent("report.pdf"))

        let first = try object(try await save(transport, to: folders.allowed.path))
        #expect(first["path"] as? String == folders.allowed.appendingPathComponent("report (1).pdf").path)
        let second = try object(try await save(transport, to: folders.allowed.path))
        #expect(second["path"] as? String == folders.allowed.appendingPathComponent("report (2).pdf").path)
        #expect(try String(contentsOf: folders.allowed.appendingPathComponent("report.pdf"), encoding: .utf8) == "mine")
        #expect(try Data(contentsOf: folders.allowed.appendingPathComponent("report (2).pdf")) == MailFixtures.attachmentBytes)
        #expect(folders.contents(folders.allowed) == ["report (1).pdf", "report (2).pdf", "report.pdf"])
    }

    @Test("a folder outside the save folders, one with .. in it, or one that is a link out are refused, and nothing is written")
    func saveRefusesWhatIsNotAllowed() async throws {
        let world = try CtlWorld()
        let folders = try Folders()
        let transport = saver(world, .init(roots: [folders.allowed]))
        let link = folders.allowed.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folders.outside)
        let hole = folders.allowed.appendingPathComponent("hole")
        try FileManager.default.createSymbolicLink(at: hole, withDestinationURL: folders.base.appendingPathComponent("nowhere"))

        let refused = [
            folders.outside.path,                                                      // not in a root
            folders.outside.appendingPathComponent("new").path,                        // below nothing allowed, not there yet
            folders.allowed.path + "/../outside",                                      // goes up out of the root
            folders.allowed.appendingPathComponent("a/../../outside").path,
            link.path,                                                                 // a link to a folder outside
            link.appendingPathComponent("deeper").path,                                // below that link
            hole.path,                                                                 // a link to something that is not there
            "relative/folder",
            "/",
        ]
        for directory in refused {
            let result = try await save(transport, to: directory)
            try expectFailure(result, status: 2, code: "path_not_allowed")
        }
        #expect(folders.contents(folders.outside).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folders.base.appendingPathComponent("nowhere").path))
        #expect(folders.contents(folders.allowed) == ["escape", "hole"])

        // With no folder configured at all, nothing is allowed.
        let none = saver(world, .init())
        try expectFailure(try await save(none, to: folders.allowed.path), status: 2, code: "path_not_allowed")
        #expect(folders.contents(folders.allowed) == ["escape", "hole"])
    }

    @Test("the Quick Look folder (mail42-quicklook-<id> directly in the temp folder) is accepted, other folders there are not")
    func saveQuickLookFolder() async throws {
        let world = try CtlWorld()
        let folders = try Folders()
        let temp = folders.base.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let transport = saver(world, .init(children: [.init(parent: temp, prefix: "mail42-quicklook-")]))

        let quickLook = temp.appendingPathComponent("mail42-quicklook-103", isDirectory: true)
        let printed = try object(try await save(transport, to: quickLook.path))
        #expect(printed["path"] as? String == quickLook.appendingPathComponent("report.pdf").path)
        #expect(try Data(contentsOf: quickLook.appendingPathComponent("report.pdf")) == MailFixtures.attachmentBytes)

        // Saving again into the same folder works too (the widget opens the same attachment twice).
        let again = try object(try await save(transport, to: quickLook.path))
        #expect(again["path"] as? String == quickLook.appendingPathComponent("report (1).pdf").path)

        let link = temp.appendingPathComponent("mail42-quicklook-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folders.outside)
        let refused = [
            temp.path,                                                                  // the temp folder itself
            temp.appendingPathComponent("other", isDirectory: true).path,               // anything else in it
            temp.appendingPathComponent("mail42-quicklook-", isDirectory: true).path,   // the prefix alone
            quickLook.appendingPathComponent("nested").path,                            // below a Quick Look folder
            temp.path + "/x/../mail42-quicklook-9",                                     // .. in the way
            link.path,                                                                  // a Quick Look name that is a link out
            folders.outside.appendingPathComponent("mail42-quicklook-1").path,          // the name in another parent
        ]
        for directory in refused {
            try expectFailure(try await save(transport, to: directory), status: 2, code: "path_not_allowed")
        }
        #expect(folders.contents(folders.outside).isEmpty)
        #expect(folders.contents(temp) == ["mail42-quicklook-103", "mail42-quicklook-link"])
    }

    @Test("attachment save answers the controller's own failures (no such part, missing --to, bad id) and writes nothing")
    func saveFailures() async throws {
        let world = try CtlWorld()
        let folders = try Folders()
        let transport = saver(world, .init(roots: [folders.allowed]))
        try expectFailure(try await save(transport, to: folders.allowed.path, part: "9"), status: 2, code: "not_found")
        try expectFailure(try await transport.run(["attachment", "save", "103", "2", "--json"]), status: 2, code: "usage")
        try expectFailure(try await transport.run(["attachment", "save", "103", "--to", folders.allowed.path, "--json"]), status: 2, code: "usage")
        try expectFailure(try await transport.run(["attachment", "save", "abc", "2", "--to", folders.allowed.path, "--json"]), status: 2, code: "usage")
        try expectFailure(try await transport.run(["attachment", "save", "9999", "2", "--to", folders.allowed.path, "--json"]), status: 2, code: "not_found")
        #expect(folders.contents(folders.allowed).isEmpty)
    }

    @Test("a folder swapped for a link between the check and the open writes nothing outside the save folder")
    func saveSurvivesAFolderSwappedForALink() async throws {
        let world = try CtlWorld()
        let folders = try Folders()
        let sub = folders.allowed.appendingPathComponent("sub", isDirectory: true)
        let moved = folders.allowed.appendingPathComponent("moved", isDirectory: true)
        let outside = folders.outside
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // After the folder was validated, another process renames it and puts a link to a folder outside the root in its place.
        let transport = MailCtlDirectTransport(
            controller: world.controller, saveFolders: .init(roots: [folders.allowed]),
            beforeSaveOpen: { _ in
                try? FileManager.default.moveItem(at: sub, to: moved)
                try? FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
            })

        let result = try await save(transport, to: sub.path)
        try expectFailure(result, status: 2, code: "path_not_allowed")
        #expect(folders.contents(folders.outside).isEmpty)
        #expect(folders.contents(moved).isEmpty)
    }

    @Test("the same swap one level up, for a folder that is made by the save, writes nothing outside either")
    func saveSurvivesAnAncestorSwappedForALink() async throws {
        let world = try CtlWorld()
        let folders = try Folders()
        let parent = folders.allowed.appendingPathComponent("parent", isDirectory: true)
        let moved = folders.allowed.appendingPathComponent("moved", isDirectory: true)
        let outside = folders.outside
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let transport = MailCtlDirectTransport(
            controller: world.controller, saveFolders: .init(roots: [folders.allowed]),
            beforeSaveOpen: { _ in
                try? FileManager.default.moveItem(at: parent, to: moved)
                try? FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            })

        let result = try await save(transport, to: parent.appendingPathComponent("new/deeper").path)
        try expectFailure(result, status: 2, code: "path_not_allowed")
        #expect(folders.contents(folders.outside).isEmpty)
        #expect(folders.contents(moved).isEmpty)
    }

    // MARK: A host without the services

    @Test("a host that lacks the disk bridge answers host_unsupported (not a permission, not no mail data) on every verb")
    func hostLacksDisk() async throws {
        let world = try CtlWorld()
        world.bridge.refuse = WidgetServiceError.hostLacks("diskRead.stat(path:)")
        for arguments in [["mailbox", "list"], ["envelope", "list", "-m", "all"], ["message", "read", "101", "--html"], ["attachment", "list", "103"]] {
            try expectFailure(try await world.transport.run(arguments + ["--json"]), status: 1, code: MailCtl.hostUnsupportedCode)
        }
        // `permissions` has no envelope of its own: it throws, with the same code.
        let thrown = await #expect(throws: MailFailure.self) { _ = try await world.transport.run(["permissions", "--json"]) }
        #expect(thrown?.code == MailCtl.hostUnsupportedCode)
    }

    // MARK: Acting

    @Test("mark read sends Mail the lookup and the set, and answers {ok, link} as MailActionResult decodes it")
    func markRead() async throws {
        let world = try CtlWorld()
        let link = "mail42://message/101?mid=alice-101%40example.com"
        let result = try await world.transport.run(["mark", link, "read", "--json"])
        let action = try decode(MailActionResult.self, result)
        #expect(action.ok && action.link == link)
        let raw = try object(result)
        #expect(raw["action"] as? String == "mark" && raw["id"] as? Int == 101)

        let requests = world.automation.requests
        #expect(requests.map(\.eventID) == ["getd", "setd"])
        #expect(requests.allSatisfy { $0.target == "com.apple.mail" })
        #expect(requests.last?.parameters.last == .init("data", .bool(true)))
    }

    @Test("flag with a colour, unflag, archive, delete, junk, move and the drafts all reach Mail")
    func otherActions() async throws {
        let world = try CtlWorld()
        let reference = "103"
        func send(_ arguments: [String]) async throws -> MailActionResult {
            try decode(MailActionResult.self, try await world.transport.run(arguments + ["--json"]))
        }
        _ = try await send(["mark", reference, "flagged", "--color", "blue"])
        #expect(world.automation.requests.suffix(2).map(\.eventID) == ["setd", "setd"])
        #expect(world.automation.requests.last?.parameters.last == .init("data", .int(4)))
        _ = try await send(["mark", reference, "unflagged"])
        _ = try await send(["archive", reference])
        _ = try await send(["delete", reference])
        _ = try await send(["junk", reference])
        _ = try await send(["move", reference, "archive"])
        _ = try await send(["draft", "reply", reference])
        _ = try await send(["draft", "reply-all", reference])
        _ = try await send(["draft", "forward", reference])
        _ = try await send(["draft", "new", "--subject", "Hi", "--body", "Hello"])
        let events = world.automation.requests.map { "\($0.eventClass.rawValue)/\($0.eventID.rawValue)" }
        #expect(events.contains("emal/rpms") && events.contains("emal/fwms") && events.contains("core/delo") && events.contains("core/crel"))

        let open = try object(try await world.transport.run(["open", "103", "--json"]))
        #expect(open["url"] as? String == "message://%3Ccarol-103%40example.com%3E" && open["opened"] as? Bool == true)
    }

    @Test("open answers {ok, url, opened}: MailModel decodes it as a MailActionResult")
    func openDecodesAsAnActionResult() async throws {
        let world = try CtlWorld()
        let result = try await world.transport.run(["open", "103", "--json"])
        let action = try decode(MailActionResult.self, result)
        #expect(action.ok)
        let raw = try object(result)
        #expect(raw["url"] as? String == "message://%3Ccarol-103%40example.com%3E" && raw["opened"] as? Bool == true)
    }

    @Test("message read --out outside the extension's folders is path_not_allowed with exit 2, and writes nothing")
    func readOutOutsideTheSandbox() async throws {
        let world = try CtlWorld()
        let outside = URL(fileURLWithPath: "/tmp/w900-outside-\(UUID().uuidString.prefix(8))/m.html")
        defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let result = try await world.transport.run(["message", "read", "102", "--html", "--out", outside.path, "--json"])
        try expectFailure(result, status: 2, code: "path_not_allowed")
        #expect(!FileManager.default.fileExists(atPath: outside.deletingLastPathComponent().path))
    }

    @Test("bad action arguments are usage errors, and an unknown message sends nothing to Mail")
    func actionErrors() async throws {
        let world = try CtlWorld()
        try expectFailure(try await world.transport.run(["mark", "103", "maybe", "--json"]), status: 2, code: "usage")
        try expectFailure(try await world.transport.run(["mark", "103", "flagged", "--color", "mauve", "--json"]), status: 2, code: "usage")
        try expectFailure(try await world.transport.run(["mark", "999", "read", "--json"]), status: 2, code: "not_found")
        try expectFailure(
            try await world.transport.run(["draft", "new", "--to", "a@example.com", "--json"]), status: 1, code: "unsupported_by_automation")
        try expectFailure(try await world.transport.run(["serve", "--json"]), status: 2, code: "usage")
        #expect(world.automation.requests.isEmpty)
    }

    // MARK: Permissions and failures

    @Test("permissions --json reports granted with exit 0, and denied / noMailData with exit 1, as MailStore.access reads it")
    func permissions() async throws {
        let world = try CtlWorld()
        let granted = try await world.transport.run(["permissions", "--json"])
        #expect(granted.status == 0)
        let report = try JSONDecoder().decode(MailPermissionsReport.self, from: granted.stdout)
        #expect(report.fullDiskAccess == "granted")
        #expect(try object(granted)["mailRoot"] as? String == world.builder.mailRoot.path)

        world.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        let denied = try await world.transport.run(["permissions", "--json"])
        #expect(denied.status == 1)
        #expect(try JSONDecoder().decode(MailPermissionsReport.self, from: denied.stdout).fullDiskAccess == "denied")

        let empty = try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))")
        let none = try await empty.transport.run(["permissions", "--json"])
        #expect(none.status == 1)
        #expect(try JSONDecoder().decode(MailPermissionsReport.self, from: none.stdout).fullDiskAccess == "noMailData")

        // Neither of these can be done from an extension.
        for verb in [["permissions", "open", "--json"], ["permissions", "automation", "--check", "--json"]] {
            try expectFailure(try await world.transport.run(verb), status: 1, code: "unsupported_in_extension")
        }
        // The widget asks for `permissions open` without --json: the CLI's one line goes to stderr.
        let plain = try await world.transport.run(["permissions", "open"])
        #expect(plain.status == 1 && plain.stdout.isEmpty && plain.stderr.contains("unsupported_in_extension"))
        // The bridge itself failing is not "denied": run throws, as the shell transport does.
        world.bridge.refuse = WidgetServiceError(message: "boom")
        await #expect(throws: MailFailure.self) { _ = try await world.transport.run(["permissions", "--json"]) }
    }

    @Test("a refusal by Work 42 or macOS is the fda_denied envelope with exit 1, on every reading verb")
    func permissionDenied() async throws {
        let world = try CtlWorld()
        world.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        for arguments in [["mailbox", "list"], ["envelope", "list", "-m", "all"], ["envelope", "search", "from:alice", "--headers"],
                          ["message", "read", "101", "--html"], ["message", "thread", "101"], ["attachment", "list", "103"]] {
            let result = try await world.transport.run(arguments + ["--json"])
            #expect(result.status == 1, "\(arguments)")
            let envelope = try JSONDecoder().decode(MailErrorEnvelope.self, from: result.stdout)
            #expect(envelope.error.code == "fda_denied" && !envelope.error.message.isEmpty, "\(arguments)")
        }
        // Without --json the CLI's text goes to stderr and stdout stays empty.
        let plain = try await world.transport.run(["mailbox", "list"])
        #expect(plain.status == 1 && plain.stdout.isEmpty && plain.stderr.contains("fda_denied"))
    }

    @Test("a Mac with no Apple Mail data is the no_mail_data envelope with exit 1")
    func noMailData() async throws {
        let world = try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))")
        let result = try await world.transport.run(["mailbox", "list", "--json"])
        #expect(result.status == 1)
        #expect(try JSONDecoder().decode(MailErrorEnvelope.self, from: result.stdout).error.code == "no_mail_data")
        #expect(try failure(result).code == "no_mail_data")
    }

    // MARK: The mirror, through the transport

    @Test("a burst of requests is one refresh of the mirror")
    func burst() async throws {
        let world = try CtlWorld(refreshInterval: 60)
        for arguments in [["mailbox", "list"], ["envelope", "list", "-m", "all"], ["message", "thread", "101"],
                          ["attachment", "list", "103"], ["envelope", "search", "from:alice", "--headers"]] {
            let result = try await world.transport.run(arguments + ["--json"])
            #expect(result.status == 0, "\(arguments)")
        }
        #expect(await world.controller.refreshCount == 1)
        #expect(world.bridge.copyStarts("Envelope Index") == 1)
    }

    @Test("what Mail changed on disk shows in the next answer")
    func mirrorFollowsTheIndex() async throws {
        let world = try CtlWorld(refreshInterval: 0)
        func unread() async throws -> Int64? {
            try decode([MailAccountTree].self, try await world.transport.run(["mailbox", "list", "--json"])).first?.mailboxes.first?.unread
        }
        #expect(try await unread() == 3)
        try world.builder.setRead(rowid: 101, true)
        try world.builder.setMailboxCounts(id: 1, total: 4, unread: 2)
        #expect(try await unread() == 2)
        let list = try decode([MailEnvelope].self, try await world.transport.run(["envelope", "list", "-m", "all", "--json"]))
        #expect(list.first { $0.id == 101 }?.isRead == true)
        #expect(await world.controller.refreshCount == 2)
    }

    // MARK: changes()

    @Test("changes() yields the new signature after a counter moves, and nothing before; close() ends it")
    func changes() async throws {
        let world = try CtlWorld(refreshInterval: 0)
        let received = Received()
        _ = Task {
            for await signature in world.transport.changes() { received.add(signature) }
            received.finish()
        }
        // The first poll mirrors the index and records the counters; that first state is not reported.
        for _ in 0..<200 {
            if await world.controller.refreshCount >= 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!received.isFinished)
        #expect(received.values.isEmpty)

        try world.builder.setMailboxCounts(id: 1, total: 5, unread: 4)
        try await eventually { !received.values.isEmpty }
        #expect(received.values == ["1:5:4,2:1:0,3:0:0"])

        world.transport.close()
        try await eventually { received.isFinished }
        #expect(received.isFinished)

        // The transport is usable again after close.
        let again = try await world.transport.run(["mailbox", "list", "--json"])
        #expect(again.status == 0)
    }

    @Test("changes() reports a flag change that leaves every mailbox counter as it was")
    func aFlagChangeNotifies() async throws {
        let world = try CtlWorld(refreshInterval: 0)
        let received = Received()
        _ = Task {
            for await signature in world.transport.changes() { received.add(signature) }
            received.finish()
        }
        for _ in 0..<200 {
            if await world.controller.refreshCount >= 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(received.values.isEmpty)

        try world.builder.setFlagged(rowid: 101, true)          // no counter moves
        try await eventually { !received.values.isEmpty }
        #expect(received.values == ["1:4:3,2:1:0,3:0:0"])

        // A read change that leaves the unread counter alone notifies too.
        let before = received.values.count
        try world.builder.setRead(rowid: 102, true)
        try await eventually { received.values.count > before }
        #expect(received.values.count > before)
        world.transport.close()
        try await eventually { received.isFinished }
    }

    @Test("close() while a poll is mirroring leaves no index open once the copy finishes")
    func closeBeatsAnInFlightPoll() async throws {
        let world = try CtlWorld(refreshInterval: 0)
        let gate = CtlGate()
        world.bridge.gate = gate
        let received = Received()
        _ = Task {
            for await signature in world.transport.changes() { received.add(signature) }
            received.finish()
        }
        try await ctlEventually { gate.hasEntered }
        #expect(gate.hasEntered)
        world.transport.close()
        try await ctlEventually { await world.controller.closeCount >= 1 }
        gate.release()
        try await eventually { received.isFinished }
        try await Task.sleep(for: .milliseconds(200))

        #expect(await world.controller.isOpen == false)
        #expect(await world.controller.refreshCount == 0)
        #expect(received.values.isEmpty)
    }
}
