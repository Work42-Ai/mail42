// MailFallbackTransport.swift — the in-process route first, the `mail42` daemon only on a host that cannot have it (WOR-900).
//
// The Mac widget reads Apple Mail through `MailCtlDirectTransport` (Work42's disk and automation services). A Work42 older than
// SDK 3.5.0 has neither: its services throw `WidgetServiceError.hostLacks`, which the direct route reports as the failure code
// `host_unsupported` (`MailCtl.hostUnsupportedCode`). That, and only that, moves the transport to its fallback (the `mail42`
// daemon), for good: it never goes back, and `changes()` and `close()` follow the route in use.
//
// Every other failure is the user's to see exactly as it is: a refusal (`fda_denied`, `automation_denied`), a permission the
// manifest does not declare, no mail data, a schema this reader does not know, a bad query. Falling back on one of them would hide
// the real reason behind "mail42 is not installed".

import Foundation

nonisolated final class MailFallbackTransport: MailTransport, @unchecked Sendable {

    private struct Listener {
        /// The fallback took over: follow its `changes()` instead.
        let switched: @Sendable (any MailTransport, Int) -> Void
        let finish: @Sendable () -> Void
    }

    private let primary: any MailTransport
    private let makeFallback: @Sendable () -> any MailTransport

    private let lock = NSLock()
    /// Non-nil once the transport fell back.
    private var fallback: (any MailTransport)?
    /// 0 on the direct route, 1 once the transport fell back: a `follow` made for an older generation than a stream's latest is stale.
    private var generation = 0
    private var listeners: [UUID: Listener] = [:]
    /// A test hook, called by `changes()` after the stream is registered and before it follows a route.
    var afterRegistering: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - primary: the in-process route.
    ///   - fallback: makes the route for a host without it; called at most once, when it is first needed.
    init(primary: any MailTransport, fallback: @escaping @Sendable () -> any MailTransport) {
        self.primary = primary
        self.makeFallback = fallback
    }

    /// Whether the transport has fallen back (a test and a diagnostic).
    var isOnFallback: Bool { lock.withLock { fallback != nil } }

    // MARK: MailTransport

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        if let route = lock.withLock({ fallback }) { return try await route.run(arguments) }
        let result: MailCLIResult
        do {
            result = try await primary.run(arguments)
        } catch let failure as MailFailure where failure.code == MailCtl.hostUnsupportedCode {
            return try await takeOver().run(arguments)
        }
        if Self.hostCannot(result) { return try await takeOver().run(arguments) }
        return result
    }

    func changes() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            let forward = Forward()
            // Registered either way: `close()` ends every stream, and a fall moves the ones still on the direct route.
            let (route, chosen): (any MailTransport, Int) = lock.withLock {
                listeners[id] = Listener(
                    switched: { next, generation in forward.follow(next, generation: generation, into: continuation) },
                    finish: { continuation.finish() })
                return (fallback ?? primary, generation)
            }
            afterRegistering?()
            // A takeover between the lock and here already followed the fallback (generation 1): this follow of the direct route
            // (generation 0) is stale and `Forward` ignores it.
            forward.follow(route, generation: chosen, into: continuation)
            continuation.onTermination = { [weak self] _ in
                forward.cancel()
                self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
            }
        }
    }

    /// Ends every `changes()` stream and closes the route in use. The transport can be used again.
    func close() {
        let (route, all) = lock.withLock { () -> (any MailTransport, [Listener]) in
            let all = Array(listeners.values)
            listeners = [:]
            return (fallback ?? primary, all)
        }
        for listener in all { listener.finish() }
        route.close()
    }

    // MARK: Switching

    /// The fallback, made if this is the first time, with every open `changes()` stream moved to it.
    private func takeOver() -> any MailTransport {
        let (route, moved, made, next) = lock.withLock { () -> (any MailTransport, [Listener], Bool, Int) in
            if let fallback { return (fallback, [], false, generation) }
            let made = makeFallback()
            fallback = made
            generation += 1
            return (made, Array(listeners.values), true, generation)      // they stay registered: `close()` still ends them
        }
        if made {
            for listener in moved { listener.switched(route, next) }
            primary.close()                         // lets go of the open index and ends the streams that followed it
        }
        return route
    }

    /// An answer that says the in-process route cannot exist here: `host_unsupported` (a missing disk bridge), or an action whose
    /// failure is Work42's "this host does not support automation…" (a host that has no automation service). Nothing else.
    static func hostCannot(_ result: MailCLIResult) -> Bool {
        guard result.status != 0 else { return false }
        let failure = MailCLI.failure(from: result)
        if failure.code == MailCtl.hostUnsupportedCode { return true }
        if failure.code == "action_failed" { return failure.message.contains("this host does not support automation") }
        // Without --json the CLI's one line is on stderr: `mail42: <message> (<code>)`.
        let line = result.stderr
        return line.contains("(\(MailCtl.hostUnsupportedCode))")
            || (line.contains("(action_failed)") && line.contains("this host does not support automation"))
    }

    /// Follows one route's `changes()` for one stream, and the next one after a switch.
    private final class Forward: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        private var latest = -1

        /// Follows `route`, the one of `generation`, in place of the previous one. Ignored (the route is not even asked) when the
        /// stream is cancelled or already follows a newer generation: a delayed follow of the direct route after the fall.
        func follow(_ route: any MailTransport, generation: Int, into continuation: AsyncStream<String>.Continuation) {
            let old = lock.withLock { () -> Task<Void, Never>? in
                if cancelled || generation < latest { return nil }
                latest = generation
                let next = Task { for await value in route.changes() { continuation.yield(value) } }
                defer { task = next }
                return task
            }
            old?.cancel()
        }

        func cancel() {
            let old = lock.withLock { () -> Task<Void, Never>? in
                cancelled = true
                defer { task = nil }
                return task
            }
            old?.cancel()
        }
    }
}
