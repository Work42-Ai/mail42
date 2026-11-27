// MailStoreTests.swift — the widget's request queue: priority, sharing, cancellation, timeout.

import Foundation
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

/// A transport whose requests wait until the test lets them go, and which records what it was asked.
nonisolated final class FakeTransport: MailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [[String]] = []
    private var cancelled: [[String]] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var open: Set<String> = []
    private let autoRelease: Bool

    init(autoRelease: Bool = false) { self.autoRelease = autoRelease }

    var startedCalls: [[String]] { lock.withLock { started } }
    var cancelledCalls: [[String]] { lock.withLock { cancelled } }

    private func key(_ arguments: [String]) -> String { arguments.joined(separator: " ") }

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        let name = key(arguments)
        lock.withLock { started.append(arguments) }
        if !autoRelease {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = lock.withLock { () -> Bool in
                        if open.contains(name) { return true }
                        gates[name] = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            } onCancel: {
                let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    cancelled.append(arguments)
                    return gates.removeValue(forKey: name)
                }
                gate?.resume()
            }
        }
        try Task.checkCancellation()
        return MailCLIResult(status: 0, stdout: Data("{\"echo\":\"\(name)\"}".utf8), stderr: "")
    }

    /// Lets the request for `arguments` finish (now, or when it arrives).
    func release(_ arguments: [String]) {
        let name = key(arguments)
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            open.insert(name)
            return gates.removeValue(forKey: name)
        }
        gate?.resume()
    }

    func changes() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func close() {}
}

/// A transport whose every request fails with `error`.
nonisolated final class FailingTransport: MailTransport, @unchecked Sendable {
    private let error: any Error
    init(_ error: any Error) { self.error = error }
    func run(_ arguments: [String]) async throws -> MailCLIResult { throw error }
    func changes() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func close() {}
}

/// Polls (without blocking a thread) until `condition` holds or `within` passes (thirty seconds by default: a busy full run can hold the pool for a while).
func eventually(within limit: Duration = .seconds(30), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private nonisolated struct Echo: Decodable, Sendable { let echo: String }

@Suite("MailStore")
struct MailStoreTests {

    @Test("a request is answered by the transport")
    func answers() async throws {
        let store = MailStore(transport: FakeTransport(autoRelease: true))
        let result = try await store.run(["mailbox", "list"])
        #expect(result.status == 0)
        let echo = try await store.json(Echo.self, ["mailbox", "list"])
        #expect(echo.echo == "mailbox list --json")
    }

    @Test("access: a failure says what failed; it is never read as 'no access'")
    func accessUnreachable() async {
        let refused = MailFailure(code: "service_version", message: "Work42's mail42 (0.3.2) is newer than this widget (0.4.0). Update Work42.")
        guard case .unreachable(let message) = await MailStore(transport: FailingTransport(refused)).access() else {
            Issue.record("a refusing host must read as unreachable"); return
        }
        #expect(message == refused.message)

        guard case .unreachable(let other) = await MailStore(transport: FailingTransport(CancellationError())).access() else {
            Issue.record("a non-MailFailure error must read as unreachable"); return
        }
        #expect(!other.isEmpty)
    }

    @Test("access: a model with no services is unreachable and says Mail needs Work 42 (not a missing tool)")
    func accessWithoutServices() async {
        guard case .unreachable(let message) = await MailStore(transport: MailUnavailableTransport()).access() else {
            Issue.record("the unavailable transport must read as unreachable"); return
        }
        #expect(message.contains("Work 42"))
        #expect(!message.lowercased().contains("install"))
    }

    @Test("the most urgent waiting request starts first, then the earliest")
    func priorityOrder() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport, maxInFlight: 1)
        let first = Task { try await store.run(["first"], priority: .list) }
        #expect(await eventually { transport.startedCalls == [["first"]] })

        let prefetch = Task { try await store.run(["prefetch"], priority: .prefetch) }
        let list = Task { try await store.run(["list"], priority: .list) }
        let opened = Task { try await store.run(["opened"], priority: .opened) }
        try await Task.sleep(for: .milliseconds(50))               // all three are queued behind `first`

        transport.release(["first"])
        _ = try await first.value
        #expect(await eventually { transport.startedCalls.count == 2 })
        #expect(transport.startedCalls[1] == ["opened"])
        transport.release(["opened"])
        _ = try await opened.value
        #expect(await eventually { transport.startedCalls.count == 3 })
        #expect(transport.startedCalls[2] == ["list"])
        transport.release(["list"])
        transport.release(["prefetch"])
        _ = try await list.value
        _ = try await prefetch.value
    }

    @Test("no more than maxInFlight requests run at once")
    func limitsInFlight() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport, maxInFlight: 2)
        let tasks = (0..<5).map { index in Task { try await store.run(["call", "\(index)"]) } }
        #expect(await eventually { transport.startedCalls.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.startedCalls.count == 2)
        for index in 0..<5 { transport.release(["call", "\(index)"]) }
        for task in tasks { _ = try await task.value }
        #expect(transport.startedCalls.count == 5)
    }

    @Test("two askers of one question share one request")
    func sharesIdenticalRequests() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport)
        let a = Task { try await store.run(["message", "read", "7"]) }
        let b = Task { try await store.run(["message", "read", "7"], priority: .opened) }
        try await Task.sleep(for: .milliseconds(50))
        transport.release(["message", "read", "7"])
        let (ra, rb) = try await (a.value, b.value)
        #expect(ra.stdout == rb.stdout)
        #expect(transport.startedCalls.count == 1)
    }

    @Test("cancelling the only asker cancels a running request")
    func cancelsRunning() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport)
        let task = Task { try await store.run(["slow"]) }
        #expect(await eventually { transport.startedCalls.count == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { transport.cancelledCalls == [["slow"]] })
    }

    @Test("cancelling a queued request means it never starts")
    func dropsQueued() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport, maxInFlight: 1)
        let blocker = Task { try await store.run(["blocker"]) }
        #expect(await eventually { transport.startedCalls.count == 1 })
        let waiting = Task { try await store.run(["waiting"]) }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        transport.release(["blocker"])
        _ = try await blocker.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(!transport.startedCalls.contains(["waiting"]))
    }

    @Test("one asker leaving does not cancel a request another still wants")
    func keepsSharedRequest() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport)
        let a = Task { try await store.run(["shared"]) }
        let b = Task { try await store.run(["shared"]) }
        #expect(await eventually { transport.startedCalls.count == 1 })
        try await Task.sleep(for: .milliseconds(30))
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.cancelledCalls.isEmpty)
        transport.release(["shared"])
        let result = try await b.value
        #expect(result.status == 0)
    }

    @Test("a request with no answer in time fails with a timeout, and is cancelled")
    func timesOut() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport)
        do {
            _ = try await store.run(["never"], timeout: .milliseconds(80))
            Issue.record("expected a timeout")
        } catch let failure as MailFailure {
            #expect(failure.code == "timeout")
        }
        #expect(await eventually { transport.cancelledCalls == [["never"]] })
    }

    @Test("a slot frees when a request is cancelled, so the next one runs")
    func slotFreesAfterCancel() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport, maxInFlight: 1)
        let stuck = Task { try await store.run(["stuck"]) }
        #expect(await eventually { transport.startedCalls.count == 1 })
        let next = Task { try await store.run(["next"]) }
        try await Task.sleep(for: .milliseconds(30))
        stuck.cancel()
        #expect(await eventually { transport.startedCalls.contains(["next"]) })
        transport.release(["next"])
        _ = try await next.value
    }

    // MARK: A changing action whose outcome is not known (Codex P1)

    private nonisolated static let changing: [[String]] = [
        ["archive", "1"], ["mark", "1", "read"], ["move", "1", "2"], ["delete", "1"], ["junk", "1"],
        ["draft", "reply", "1"], ["attachment", "save", "1", "2", "--to", "/tmp"], ["open", "1"],
    ]

    @Test("a changing request that was sent and got no answer in time is outcome_unknown (check on your Mac), never a plain timeout; a read stays a timeout")
    func changingTimeoutIsOutcomeUnknown() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport)
        for command in Self.changing {
            do {
                _ = try await store.run(command, timeout: .milliseconds(60))
                Issue.record("\(command) should not have been answered")
            } catch let failure as MailFailure {
                #expect(failure.code == "outcome_unknown", "\(command) → \(failure)")
                #expect(failure.message.contains("Check on your Mac before doing it again"), "\(command)")
            }
        }
        do {
            _ = try await store.run(["mailbox", "list"], timeout: .milliseconds(60))
            Issue.record("a read should time out")
        } catch let failure as MailFailure {
            #expect(failure.code == "timeout")
        }
        #expect(await eventually { transport.cancelledCalls.count == Self.changing.count + 1 })
    }

    @Test("a changing request that never left the queue times out plainly (it certainly did not run)")
    func queuedChangingTimeoutIsPlain() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport, maxInFlight: 1)
        let blocker = Task { try await store.run(["blocker"]) }
        #expect(await eventually { transport.startedCalls.count == 1 })
        do {
            _ = try await store.run(["archive", "1"], timeout: .milliseconds(60))
            Issue.record("expected a timeout")
        } catch let failure as MailFailure {
            #expect(failure.code == "timeout")
        }
        transport.release(["blocker"])
        _ = try await blocker.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(!transport.startedCalls.contains(["archive", "1"]))
    }

    @Test("cancelling the asker of a changing request that was sent is outcome_unknown; while still queued it is a plain cancellation")
    func changingCancellation() async throws {
        let transport = FakeTransport()
        let store = MailStore(transport: transport, maxInFlight: 1)
        let sent = Task { try await store.run(["archive", "1"]) }
        #expect(await eventually { transport.startedCalls == [["archive", "1"]] })
        let queued = Task { try await store.run(["delete", "2"]) }
        try await Task.sleep(for: .milliseconds(30))

        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }

        sent.cancel()
        do {
            _ = try await sent.value
            Issue.record("expected a failure")
        } catch let failure as MailFailure {
            #expect(failure.code == "outcome_unknown")
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!transport.startedCalls.contains(["delete", "2"]))
    }
}

// MARK: - The model, over a scripted transport

#if os(macOS)

/// A transport that answers each request with `handler`, and records what it was asked.
nonisolated final class ScriptedTransport: MailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    private let handler: @Sendable ([String]) throws -> MailCLIResult

    init(_ handler: @escaping @Sendable ([String]) throws -> MailCLIResult) { self.handler = handler }

    var calls: [[String]] { lock.withLock { log } }

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        lock.withLock { log.append(arguments) }
        return try handler(arguments)
    }
    func changes() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func close() {}
}

private nonisolated func answer(_ json: String) -> MailCLIResult { MailCLIResult(status: 0, stdout: Data(json.utf8), stderr: "") }

private nonisolated let modelEnvelope = """
    {"id":7,"message_id":"a@x","conversation_id":null,"account":{"id":"A","name":"Work","email":"w@x.com"},\
    "mailbox":{"id":1,"name":"INBOX","role":"inbox"},"from":{"name":"Al","addr":"al@x.com"},"to":[],"cc":[],\
    "subject":"Hi","date":"2026-01-01T10:00:00Z","snippet":null,"is_read":true,"is_flagged":false,"has_attachments":false,\
    "link":"mail42://message/7?mid=a%40x"}
    """

private nonisolated let modelTree = """
    [{"account":{"id":"A","name":"Work","email":"w@x.com","kind":"imap"},\
    "mailboxes":[{"id":1,"name":"INBOX","role":"inbox","total":5,"unread":2}]}]
    """

/// Mail as the widget's model sees it: one read message, and `action` for every verb that changes it.
private nonisolated func modelMail(
    _ arguments: [String], action: @Sendable () throws -> MailCLIResult = { answer(#"{"ok":true,"link":null}"#) },
    read: @Sendable () throws -> MailCLIResult = { throw MailFailure(code: "not_found", message: "no page in this test") }
) throws -> MailCLIResult {
    switch (arguments.first, arguments.dropFirst().first) {
    case ("permissions", _): return answer(#"{"fullDiskAccess":"granted"}"#)
    case ("mailbox", _): return answer(modelTree)
    case ("envelope", _): return answer("[\(modelEnvelope)]")
    case ("mark", _), ("archive", _), ("move", _), ("delete", _), ("junk", _): return try action()
    case ("open", _): return answer(#"{"ok":true,"link":null}"#)
    case ("message", "read"): return try read()
    case ("attachment", "save"): return answer(#"{"path":"/tmp/mail42-quicklook-7/report.pdf","bytes":3}"#)
    case ("attachment", _): return answer("[]")
    default: throw MailFailure(code: "not_found", message: "not in this test")
    }
}

private struct ModelComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
    nonisolated func clearCommentableSelection() async throws {}
}

/// A shell that records every attempt to use it.
private nonisolated final class RecordingShell: WidgetShellService, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [String] = []
    var used: [String] { lock.withLock { attempts } }
    func run(command: String) async throws -> WidgetShellResult {
        lock.withLock { attempts.append(command) }
        return WidgetShellResult(stdout: "", stderr: "", exitCode: 0)
    }
    func start(command: String) async throws -> WidgetShellProcess {
        lock.withLock { attempts.append(command) }
        throw WidgetServiceError.hostLacks("shell.start(command:)")
    }
}

private nonisolated final class RecordingPlatform: WidgetPlatformService, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var opened: [URL] { lock.withLock { urls } }
    @MainActor func open(_ url: URL) { lock.withLock { urls.append(url) } }
    @MainActor func copy(_ text: String) {}
}

private struct ModelIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct ModelStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct ModelPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

@MainActor
private func loadedModel(
    _ transport: ScriptedTransport, shell: RecordingShell = RecordingShell(), platform: RecordingPlatform = RecordingPlatform(),
    readerFolder: URL? = nil
) async -> MailModel {
    let files = MailModel.ReaderFiles(
        directory: { readerFolder }, url: { name in readerFolder.map { _ in URL(string: "http://127.0.0.1/reader/\(name)")! } },
        removeAll: {})
    let model = MailModel(makeTransport: { _ in transport }, readerFiles: files)
    model.adopt(services: SessionServices(
        composer: ModelComposer(), shell: shell, intents: ModelIntents(), storage: ModelStorage(), pill: ModelPill(),
        platform: platform, sessionId: "model"))
    await model.bootstrap()
    model.select(7)
    return model
}

@MainActor
@Suite("MailModel: what the widget shows when an action's outcome is unknown, and Quick Look without a shell")
struct MailModelOutcomeTests {

    private func outcomeUnknown() -> ScriptedTransport {
        ScriptedTransport { try modelMail($0, action: { throw MailFailure.outcomeUnknown }) }
    }

    @Test("mark read/unread with an unknown outcome keeps the optimistic state and shows the 'check on your Mac' message as it is")
    func markKeepsOptimisticState() async throws {
        let model = await loadedModel(outcomeUnknown())
        #expect(model.envelopes.first?.isRead == true)
        await model.perform(.markRead(false))
        #expect(model.envelopes.first?.isRead == false, "the unread dot is not taken back: the Mac may have done it")
        #expect(model.notice == MailFailure.checkOnMac)
    }

    @Test("flag with an unknown outcome keeps the flag and shows the message as it is")
    func flagKeepsOptimisticState() async throws {
        let model = await loadedModel(outcomeUnknown())
        await model.perform(.flag("red"))
        #expect(model.envelopes.first?.isFlagged == true)
        #expect(model.notice == MailFailure.checkOnMac)
    }

    @Test("archive/delete/junk/move with an unknown outcome leave the conversation out of the list (no reload that pretends nothing happened)")
    func relocateKeepsOptimisticState() async throws {
        for action in [MailModel.MailAction.archive, .delete, .junk, .move(2)] {
            let transport = outcomeUnknown()
            let model = await loadedModel(transport)
            let listsBefore = transport.calls.filter { $0.first == "envelope" }.count
            await model.perform(action)
            #expect(model.envelopes.isEmpty, "\(action): the list was reloaded as if nothing had happened")
            #expect(model.notice == MailFailure.checkOnMac, "\(action)")
            #expect(transport.calls.filter { $0.first == "envelope" }.count == listsBefore, "\(action) did not reload the list")
        }
    }

    @Test("a failure that says the action did not happen still takes the change back, as before")
    func definiteFailureStillReverts() async throws {
        let model = await loadedModel(ScriptedTransport {
            try modelMail($0, action: { throw MailFailure(code: "action_failed", message: "Mail refused.") })
        })
        await model.perform(.markRead(false))
        #expect(model.envelopes.first?.isRead == true)
        #expect(model.notice == "Couldn't change the message in Mail: Mail refused.")
    }

    @Test("a message the Mac cut is flagged for the reader's notice, with an Open in Mail action for it; a whole one is not")
    func truncatedReader() async throws {
        #expect(MailModel.truncatedNotice == "This message is long; showing the first part. Open in Mail for the rest.")
        let folder = URL(fileURLWithPath: "/tmp/mail42-model-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for cut in [true, false] {
            let transport = ScriptedTransport {
                try modelMail($0, read: { answer(#"{"path":null,"html":null,"body_unavailable":false,"truncated":\#(cut)}"#) })
            }
            let model = await loadedModel(transport, readerFolder: folder)
            for _ in 0..<400 {
                if case .ready = model.reader { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard case .ready = model.reader else { Issue.record("the reader never became ready: \(model.reader)"); continue }
            #expect(model.readerTruncated == cut)
            await model.openExpandedInMail()
            #expect(transport.calls.contains(["open", "7", "--json"]))
        }
    }

    @Test("Quick Look opens the saved copy in its default app through the platform service, and starts no command")
    func quickLookOpensWithoutAShell() async throws {
        let shell = RecordingShell()
        let platform = RecordingPlatform()
        let model = await loadedModel(ScriptedTransport { try modelMail($0) }, shell: shell, platform: platform)
        await model.quickLook(MailAttachment(part: "2", filename: "report.pdf", mime: "application/pdf", size: 3))
        #expect(platform.opened == [URL(fileURLWithPath: "/tmp/mail42-quicklook-7/report.pdf")])
        #expect(shell.used.isEmpty, "nothing was started in a shell: \(shell.used)")
    }
}

#endif
