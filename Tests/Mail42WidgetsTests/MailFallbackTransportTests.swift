// MailFallbackTransportTests.swift — the in-process route first, the daemon only on a host that cannot have it (WOR-900).

import Foundation
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

/// A scripted route: records what it was asked, answers with `respond`, and owns the streams `changes()` handed out.
private nonisolated final class FakeRoute: MailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [[String]] = []
    private var closed = 0
    private var streams: [AsyncStream<String>.Continuation] = []
    private let respond: @Sendable ([String]) throws -> MailCLIResult

    init(_ respond: @escaping @Sendable ([String]) throws -> MailCLIResult) { self.respond = respond }

    var calls: [[String]] { lock.withLock { asked } }
    var closeCount: Int { lock.withLock { closed } }
    var subscribers: Int { lock.withLock { streams.count } }

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        lock.withLock { asked.append(arguments) }
        return try respond(arguments)
    }

    func changes() -> AsyncStream<String> {
        AsyncStream { continuation in lock.withLock { streams.append(continuation) } }
    }

    func close() {
        let all = lock.withLock { () -> [AsyncStream<String>.Continuation] in
            closed += 1
            defer { streams = [] }
            return streams
        }
        for continuation in all { continuation.finish() }
    }

    func emit(_ value: String) {
        let all = lock.withLock { streams }
        for continuation in all { continuation.yield(value) }
    }
}

private nonisolated func ok(_ text: String) -> MailCLIResult { MailCLIResult(status: 0, stdout: Data(text.utf8), stderr: "") }

/// The failed answer the direct transport gives with `--json`.
private nonisolated func failed(_ code: String, _ message: String = "it failed", status: Int32 = 1) -> MailCLIResult {
    let body = "{\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}"
    return MailCLIResult(status: status, stdout: Data(body.utf8), stderr: "")
}

private nonisolated final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

private nonisolated final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var done = false
    var values: [String] { lock.withLock { items } }
    var isFinished: Bool { lock.withLock { done } }
    func add(_ value: String) { lock.withLock { items.append(value) } }
    func finish() { lock.withLock { done = true } }
}

private func collect(_ stream: AsyncStream<String>) -> (Received, Task<Void, Never>) {
    let received = Received()
    let task = Task {
        for await value in stream { received.add(value) }
        received.finish()
    }
    return (received, task)
}

@Suite("Mail fallback transport: the daemon only where the in-process route cannot exist (WOR-900)")
struct MailFallbackTransportTests {

    private struct Made {
        let transport: MailFallbackTransport
        let primary: FakeRoute
        let fallback: FakeRoute
        let made: HitCounter
    }

    private func make(
        primary: @escaping @Sendable ([String]) throws -> MailCLIResult,
        fallback: @escaping @Sendable ([String]) throws -> MailCLIResult = { _ in ok("\"from the daemon\"") }
    ) -> Made {
        let first = FakeRoute(primary)
        let second = FakeRoute(fallback)
        let made = HitCounter()
        let transport = MailFallbackTransport(primary: first, fallback: { made.bump(); return second })
        return Made(transport: transport, primary: first, fallback: second, made: made)
    }

    private func text(_ result: MailCLIResult) -> String { String(decoding: result.stdout, as: UTF8.self) }

    // MARK: Falling back

    @Test("a good answer comes from the in-process route and the fallback is never even made")
    func healthyHostStaysDirect() async throws {
        let world = make(primary: { _ in ok("[]") })
        let result = try await world.transport.run(["mailbox", "list", "--json"])
        #expect(result.status == 0 && text(result) == "[]")
        #expect(world.made.count == 0 && world.fallback.calls.isEmpty && !world.transport.isOnFallback)
    }

    @Test("host_unsupported (a Work42 without the disk bridge) is answered by the fallback, which is made once")
    func fallsBackOnHostUnsupported() async throws {
        let world = make(primary: { _ in failed(MailCtl.hostUnsupportedCode, "this host does not support diskRead.stat(path:)") })
        let result = try await world.transport.run(["mailbox", "list", "--json"])
        #expect(result.status == 0 && text(result) == "\"from the daemon\"")
        #expect(world.fallback.calls == [["mailbox", "list", "--json"]])
        #expect(world.made.count == 1 && world.transport.isOnFallback)
    }

    @Test("the same when the direct route throws it (permissions has no envelope), and when only stderr says it (no --json)")
    func fallsBackOnThrownAndPlainFailures() async throws {
        let thrown = make(primary: { _ in throw MailFailure(code: MailCtl.hostUnsupportedCode, message: "this host does not support diskRead") })
        #expect(try await thrown.transport.run(["permissions", "--json"]).status == 0)
        #expect(thrown.transport.isOnFallback && thrown.fallback.calls.count == 1)

        let plain = make(primary: { _ in
            MailCLIResult(status: 1, stdout: Data(), stderr: "mail42: this host does not support diskRead (\(MailCtl.hostUnsupportedCode))\n")
        })
        #expect(try await plain.transport.run(["mailbox", "list"]).status == 0)
        #expect(plain.transport.isOnFallback)
    }

    @Test("an action on a host with no automation service falls back, and the action runs on the daemon")
    func fallsBackOnAutomationHostLacks() async throws {
        let world = make(primary: { _ in
            failed("action_failed", "Mail couldn\u{2019}t do that: this host does not support automation.send(_:)")
        })
        let result = try await world.transport.run(["mark", "101", "read", "--json"])
        #expect(result.status == 0 && world.fallback.calls == [["mark", "101", "read", "--json"]])
        #expect(world.transport.isOnFallback)
    }

    @Test("every real failure reaches the caller as it is: no fallback, whatever its code")
    func realFailuresAreNotFallenBackOn() async throws {
        let codes = [
            "fda_denied", "automation_denied", "not_declared", "no_mail_data", "schema_unsupported", "database_not_accessible",
            "mail_unreachable", "not_found", "bad_query", "usage", "path_not_allowed", "write_failed", "action_failed",
            "mail_timeout", "mail_not_running", "unsupported_in_extension", "error", "emlx_not_found", "failed",
        ]
        for code in codes {
            let world = make(primary: { _ in failed(code, "refused for real") })
            let result = try await world.transport.run(["envelope", "list", "--json"])
            #expect(result.status == 1 && MailCLI.failure(from: result).code == code, "\(code)")
            #expect(world.made.count == 0 && world.fallback.calls.isEmpty && !world.transport.isOnFallback, "\(code)")
        }
        // A thrown failure that is not host_unsupported, a cancellation, and an unknown error pass through the same way.
        let throwing: [any Error] = [MailFailure(code: "mail_unreachable", message: "no"), CancellationError(), URLError(.badURL)]
        for error in throwing {
            let world = make(primary: { _ in throw error })
            await #expect(throws: (any Error).self) { _ = try await world.transport.run(["mailbox", "list"]) }
            #expect(world.made.count == 0 && !world.transport.isOnFallback)
        }
        // Plain (stderr) refusals too.
        let plain = make(primary: { _ in MailCLIResult(status: 1, stdout: Data(), stderr: "mail42: no (fda_denied)\n") })
        #expect(try await plain.transport.run(["mailbox", "list"]).status == 1)
        #expect(!plain.transport.isOnFallback)
        // An ordinary action failure is not a host without automation.
        let action = make(primary: { _ in failed("action_failed", "Mail couldn\u{2019}t do that: can\u{2019}t get message (-1728)") })
        #expect(try await action.transport.run(["mark", "1", "read", "--json"]).status == 1)
        #expect(!action.transport.isOnFallback)
    }

    @Test("a denied permission whose text happens to mention the host is still a refusal, and a refusal is never a fallback")
    func refusalMentioningTheHost() async throws {
        let world = make(primary: { _ in failed("fda_denied", "this host does not support what you asked, but Full Disk Access is off") })
        let result = try await world.transport.run(["mailbox", "list", "--json"])
        #expect(MailCLI.failure(from: result).code == "fda_denied" && !world.transport.isOnFallback)
    }

    @Test("once fallen back it stays on the fallback: the direct route is not asked again, even for a request it would answer")
    func staysOnTheFallback() async throws {
        let calls = HitCounter()
        let world = make(primary: { _ in
            calls.bump()
            return calls.count == 1 ? failed(MailCtl.hostUnsupportedCode) : ok("\"direct\"")
        })
        _ = try await world.transport.run(["mailbox", "list", "--json"])
        for _ in 0..<3 { _ = try await world.transport.run(["envelope", "list", "--json"]) }
        #expect(world.primary.calls.count == 1)
        #expect(world.fallback.calls.count == 4 && world.made.count == 1)
    }

    @Test("concurrent first requests on a host without the services make one fallback and all end on it")
    func concurrentFallbackIsMadeOnce() async throws {
        let world = make(primary: { _ in failed(MailCtl.hostUnsupportedCode) })
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 { group.addTask { [transport = world.transport] in
                String(decoding: try await transport.run(["envelope", "list", "\(index)"]).stdout, as: UTF8.self)
            } }
            var all: [String] = []
            for try await one in group { all.append(one) }
            return all
        }
        #expect(results.count == 8 && results.allSatisfy { $0 == "\"from the daemon\"" })
        #expect(world.made.count == 1 && world.fallback.calls.count == 8)
    }

    // MARK: changes() and close()

    @Test("changes() follows the in-process route, and moves to the fallback's when the transport falls back")
    func changesFollowTheActiveRoute() async throws {
        let world = make(primary: { arguments in
            arguments == ["fall"] ? failed(MailCtl.hostUnsupportedCode) : ok("[]")
        })
        let (received, task) = collect(world.transport.changes())
        try await ctlEventually { world.primary.subscribers == 1 }
        world.primary.emit("direct-1")
        try await ctlEventually { received.values == ["direct-1"] }
        #expect(received.values == ["direct-1"] && world.fallback.subscribers == 0)

        _ = try await world.transport.run(["fall"])
        try await ctlEventually { world.fallback.subscribers == 1 }
        #expect(world.fallback.subscribers == 1 && world.primary.closeCount == 1)   // the direct route was let go of
        world.fallback.emit("daemon-1")
        world.primary.emit("direct-2")                                              // nobody listens to it any more
        try await ctlEventually { received.values.contains("daemon-1") }
        #expect(received.values == ["direct-1", "daemon-1"] && !received.isFinished)
        task.cancel()
    }

    @Test("a stream asked for after the fall comes from the fallback alone")
    func changesAfterFallbackUseTheFallback() async throws {
        let world = make(primary: { _ in failed(MailCtl.hostUnsupportedCode) })
        _ = try await world.transport.run(["mailbox", "list"])
        let (received, task) = collect(world.transport.changes())
        try await ctlEventually { world.fallback.subscribers == 1 }
        #expect(world.primary.subscribers == 0)
        world.fallback.emit("daemon")
        try await ctlEventually { received.values == ["daemon"] }
        #expect(received.values == ["daemon"])
        task.cancel()
    }

    @Test("close() ends every stream and closes the route in use, then the transport can be used again")
    func closeFollowsTheActiveRoute() async throws {
        let direct = make(primary: { _ in ok("[]") })
        let (first, firstTask) = collect(direct.transport.changes())
        try await ctlEventually { direct.primary.subscribers == 1 }
        direct.transport.close()
        try await ctlEventually { first.isFinished }
        #expect(first.isFinished && direct.primary.closeCount == 1 && direct.fallback.closeCount == 0)
        #expect(try await direct.transport.run(["mailbox", "list"]).status == 0)
        firstTask.cancel()

        let fell = make(primary: { _ in failed(MailCtl.hostUnsupportedCode) })
        _ = try await fell.transport.run(["mailbox", "list"])
        let (second, secondTask) = collect(fell.transport.changes())
        try await ctlEventually { fell.fallback.subscribers == 1 }
        fell.transport.close()
        try await ctlEventually { second.isFinished }
        #expect(second.isFinished && fell.fallback.closeCount == 1)
        #expect(fell.primary.closeCount == 1)                    // only the one made when it fell back: close() followed the fallback
        #expect(fell.transport.isOnFallback)
        secondTask.cancel()
    }

    @Test("ending the consumer of a stream stops following the route")
    func cancellingAStreamLetsGo() async throws {
        let world = make(primary: { _ in ok("[]") })
        let (received, task) = collect(world.transport.changes())
        try await ctlEventually { world.primary.subscribers == 1 }
        task.cancel()
        try await ctlEventually { received.isFinished }
        // A fall afterwards has no stream to move.
        let result = try await MailFallbackTransport(primary: FakeRoute { _ in failed(MailCtl.hostUnsupportedCode) }, fallback: { world.fallback })
            .run(["x"])
        #expect(result.status == 0 && world.fallback.subscribers == 0)
    }

    @Test("a fall between a stream's registration and its first follow leaves the stream on the fallback, not back on the direct route")
    func fallBetweenRegistrationAndFollow() async throws {
        let world = make(primary: { arguments in arguments == ["fall"] ? failed(MailCtl.hostUnsupportedCode) : ok("[]") })
        let transport = world.transport
        transport.afterRegistering = {
            // The takeover runs to its end exactly here, before `changes()` follows the route it chose under the lock.
            let done = DispatchSemaphore(value: 0)
            Task { _ = try? await transport.run(["fall"]); done.signal() }
            _ = done.wait(timeout: .now() + 10)
            transport.afterRegistering = nil
        }
        let stream = await Task.detached { transport.changes() }.value
        let (received, task) = collect(stream)
        #expect(transport.isOnFallback)

        try await ctlEventually { world.fallback.subscribers == 1 }
        world.fallback.emit("daemon")
        try await ctlEventually { received.values == ["daemon"] }
        world.primary.emit("direct")                       // the direct route is let go of: nobody may be listening to it
        try await Task.sleep(for: .milliseconds(150))
        #expect(received.values == ["daemon"] && world.primary.subscribers == 0 && !received.isFinished)
        task.cancel()
    }

    // MARK: With the real direct route

    @Test("over the real direct transport: a bridge that lacks the service falls back, a macOS refusal does not")
    func overTheDirectTransport() async throws {
        let lacking = try CtlWorld()
        lacking.bridge.refuse = WidgetServiceError.hostLacks("diskRead.stat(path:)")
        let daemon = FakeRoute { _ in ok("[\"daemon\"]") }
        let fallingBack = MailFallbackTransport(primary: lacking.transport, fallback: { daemon })
        let answered = try await fallingBack.run(["mailbox", "list", "--json"])
        #expect(answered.status == 0 && String(decoding: answered.stdout, as: UTF8.self) == "[\"daemon\"]" && fallingBack.isOnFallback)
        // `permissions` is thrown by the direct route, not answered: it is the same.
        let permissions = MailFallbackTransport(primary: lacking.transport, fallback: { daemon })
        #expect(try await permissions.run(["permissions", "--json"]).status == 0 && permissions.isOnFallback)

        let refused = try CtlWorld()
        refused.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        let stays = MailFallbackTransport(primary: refused.transport, fallback: { daemon })
        let denied = try await stays.run(["mailbox", "list", "--json"])
        #expect(MailCLI.failure(from: denied).code == "fda_denied" && !stays.isOnFallback)

        let healthy = try CtlWorld()
        let direct = MailFallbackTransport(primary: healthy.transport, fallback: { daemon })
        let trees = try await direct.run(["mailbox", "list", "--json"])
        #expect(trees.status == 0 && !direct.isOnFallback)

        let missing = try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))")
        let none = MailFallbackTransport(primary: missing.transport, fallback: { daemon })
        _ = try await none.run(["mailbox", "list", "--json"])
        #expect(!none.isOnFallback)
    }
}
