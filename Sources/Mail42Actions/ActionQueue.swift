// ActionQueue.swift — Mail answers Apple Events one at a time, so mail42 sends them one at a time.
//
// Every action (mark, move, archive, delete, junk, draft) asks Mail to do something through Apple Events. Sent in
// parallel they only queue up inside Mail, each one waiting for those before it, and a busy Mail holds all of them.
// So a long-lived process (the `serve` daemon) puts its actions through one `ActionQueue`: strictly one runs at a
// time, in the order they arrived, and the reads that don't involve Mail never wait for it.
//
// Coalescing: a request can carry a `key` (`mark:123:read`, one message and one thing about it). If an earlier
// request with the same key is still WAITING (it has not started), it is not run: the later one replaces it, and the
// earlier request is answered with the later one's result when that finishes. Flagging and unflagging a message five
// times in a row costs Mail one Apple Event, and every one of the five asks gets an answer. A request that has
// already started is never touched.
//
// Where the work runs is up to the caller (`executor`): the daemon runs Apple Events on its main thread, which
// NSAppleScript is happiest on; tests use a plain background queue.

import Foundation

public final class ActionQueue<Result: Sendable>: @unchecked Sendable {

    private struct Item {
        let key: String?
        let work: @Sendable () -> Result
        var completions: [@Sendable (Result) -> Void]
    }

    private let executor: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var waiting: [Item] = []
    private var running = false

    /// - Parameter executor: runs a block somewhere (a serial place: only one block of this queue is in flight).
    public init(executor: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.executor = executor
    }

    /// Queues `work`. `completion` gets its result (or, if a later request with the same `key` replaces it before it
    /// starts, that request's result), on whatever thread the work ran on.
    public func submit(
        key: String? = nil, work: @escaping @Sendable () -> Result, completion: @escaping @Sendable (Result) -> Void
    ) {
        lock.lock()
        var completions = [completion]
        if let key, let index = waiting.firstIndex(where: { $0.key == key }) {
            completions = waiting[index].completions + completions     // the replaced request is answered too
            waiting.remove(at: index)
        }
        waiting.append(Item(key: key, work: work, completions: completions))
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { executor { [self] in drain() } }
    }

    /// How many requests are waiting (not counting the one running).
    public var waitingCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }

    private func drain() {
        while true {
            lock.lock()
            guard !waiting.isEmpty else {
                running = false
                lock.unlock()
                return
            }
            let item = waiting.removeFirst()
            lock.unlock()
            let result = item.work()
            for completion in item.completions { completion(result) }
        }
    }
}
