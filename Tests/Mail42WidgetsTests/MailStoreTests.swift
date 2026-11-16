// MailStoreTests.swift — the widget's request queue: priority, sharing, cancellation, timeout.

import Foundation
import Testing
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
}
