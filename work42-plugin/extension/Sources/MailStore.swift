// MailStore.swift — everything the Mail widget asks mail42, in one place that is never the main thread.
//
// The model (on the main actor) used to start a process for every question and wait for it. It now asks the store, an
// actor, which owns the one connection to mail42 (`MailTransport`) and decides what to ask, in what order, and when to
// stop asking:
//
//   priority      the message you opened comes first, then what the list shows, then guesses (prefetch)
//   at most N     requests are in flight at once (the rest wait their turn by priority, then arrival)
//   shared        a question already in flight is not asked twice: the second asker waits for the first's answer
//   cancellable   a task that stops waiting (you opened another message) really cancels the request; when every asker
//                 of a question has gone, the question is dropped if it is still queued and cancelled if it is running
//   bounded       a request that gets no answer within its timeout ends with a `timeout` failure
//
// The model only ever awaits the store and applies the finished, decoded value.

import Foundation

actor MailStore {

    /// Lower runs first.
    enum Priority: Int, Comparable, Sendable {
        /// The message you opened (its body, attachments, conversation) and what you just did to it.
        case opened = 0
        /// What the list shows: the page, a search, the counters.
        case list = 1
        /// Guesses: the next message, read before you ask.
        case prefetch = 2

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One question, however many callers are waiting for its answer.
    private final class Entry {
        let key: String
        let arguments: [String]
        var priority: Priority
        let sequence: Int
        var waiters: [UUID: CheckedContinuation<MailCLIResult, Error>] = [:]
        var timers: [UUID: Task<Void, Never>] = [:]
        var task: Task<Void, Never>?

        init(key: String, arguments: [String], priority: Priority, sequence: Int) {
            self.key = key; self.arguments = arguments; self.priority = priority; self.sequence = sequence
        }
    }

    private let transport: any MailTransport
    private let maxInFlight: Int
    private var queued: [Entry] = []
    private var running: [String: Entry] = [:]       // questions that can still take another asker
    private var inFlight = 0                          // requests started and not yet ended (includes cancelled ones winding down)
    private var sequence = 0

    init(transport: any MailTransport, maxInFlight: Int = 4) {
        self.transport = transport
        self.maxInFlight = max(1, maxInFlight)
    }

    // MARK: - Asking

    /// `mail42 <arguments>`, as printed. Throws `CancellationError` when the calling task is cancelled, and a
    /// `MailFailure` with code `timeout` when `timeout` passes first.
    func run(
        _ arguments: [String], priority: Priority = .list, timeout: Duration = .seconds(60)
    ) async throws -> MailCLIResult {
        let key = arguments.joined(separator: "\u{1F}")
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(key: key, arguments: arguments, priority: priority, timeout: timeout, waiter: waiter, continuation: continuation)
            }
        } onCancel: {
            Task { await self.stopWaiting(key: key, waiter: waiter, error: CancellationError()) }
        }
    }

    /// `mail42 <arguments> --json`, decoded off the store (a newsletter list can be megabytes). A failure is the
    /// `MailFailure` the CLI reported (`{"error":{"code","message"}}`), else its own words.
    func json<T: Decodable & Sendable>(
        _ type: T.Type, _ arguments: [String], priority: Priority = .list, timeout: Duration = .seconds(60)
    ) async throws -> T {
        let result = try await run(arguments + ["--json"], priority: priority, timeout: timeout)
        guard result.status == 0 else { throw MailCLI.failure(from: result) }
        return try await Self.decode(type, from: result.stdout)
    }

    /// A signal each time Mail's mailboxes changed (see `MailTransport.changes`).
    nonisolated func changes() -> AsyncStream<String> { transport.changes() }

    /// Lets go of the connection; every `changes()` stream ends. The store can be used again (it connects afresh).
    func shutdown() {
        transport.close()
    }

    /// Full Disk Access as mail42 itself sees it (`mail42 permissions`: exit 0 when granted).
    func access() async -> MailAccess {
        do {
            let result = try await run(["permissions", "--json"], priority: .list, timeout: .seconds(20))
            if result.status == 0 { return .granted }
            let report = try? JSONDecoder().decode(MailPermissionsReport.self, from: result.stdout)
            return report?.fullDiskAccess == "noMailData" ? .noMailData : .denied
        } catch let failure as MailFailure {
            // A host that refuses, does not answer or times out is not "no access": the tile says what went wrong.
            return .unreachable(failure.message)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private nonisolated static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MailFailure(code: "bad_output", message: "mail42 printed something unexpected: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue

    private func enqueue(
        key: String, arguments: [String], priority: Priority, timeout: Duration, waiter: UUID,
        continuation: CheckedContinuation<MailCLIResult, Error>
    ) {
        let entry: Entry
        if let existing = running[key] {
            entry = existing                                         // already being asked: share the answer
        } else if let existing = queued.first(where: { $0.key == key }) {
            if priority < existing.priority { existing.priority = priority }   // someone more urgent wants it
            entry = existing
        } else {
            sequence += 1
            entry = Entry(key: key, arguments: arguments, priority: priority, sequence: sequence)
            queued.append(entry)
        }
        entry.waiters[waiter] = continuation
        entry.timers[waiter] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.stopWaiting(key: key, waiter: waiter, error: MailFailure(code: "timeout", message: "mail42 didn\u{2019}t answer in time."))
        }
        pump()
    }

    /// Starts queued questions while there is room: most urgent first, then the one that arrived first.
    private func pump() {
        while inFlight < maxInFlight, let next = queued.min(by: Self.before) {
            queued.removeAll { $0 === next }
            running[next.key] = next
            inFlight += 1
            let transport = self.transport
            next.task = Task {
                let outcome: Result<MailCLIResult, Error>
                do { outcome = .success(try await transport.run(next.arguments)) } catch { outcome = .failure(error) }
                await self.finish(next, outcome)
            }
        }
    }

    private static func before(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.priority != rhs.priority ? lhs.priority < rhs.priority : lhs.sequence < rhs.sequence
    }

    private func finish(_ entry: Entry, _ outcome: Result<MailCLIResult, Error>) {
        if running[entry.key] === entry { running[entry.key] = nil }
        inFlight -= 1
        let waiters = entry.waiters
        entry.waiters = [:]
        for timer in entry.timers.values { timer.cancel() }
        entry.timers = [:]
        for continuation in waiters.values { continuation.resume(with: outcome) }
        pump()
    }

    /// One asker is done waiting (cancelled, or timed out). The others keep waiting; when none is left the question is
    /// dropped (if it hasn't started) or cancelled (if it is running).
    private func stopWaiting(key: String, waiter: UUID, error: any Error) {
        let entry = running[key].flatMap { $0.waiters[waiter] != nil ? $0 : nil }
            ?? queued.first { $0.key == key && $0.waiters[waiter] != nil }
        guard let entry, let continuation = entry.waiters.removeValue(forKey: waiter) else { return }
        entry.timers.removeValue(forKey: waiter)?.cancel()
        continuation.resume(throwing: error)
        guard entry.waiters.isEmpty else { return }

        if running[entry.key] === entry {
            running[entry.key] = nil                                 // nobody can join a question being cancelled
            entry.task?.cancel()                                     // the transport ends the request; `finish` frees the slot
        } else {
            queued.removeAll { $0 === entry }
        }
    }
}
