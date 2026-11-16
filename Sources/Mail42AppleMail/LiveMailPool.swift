// LiveMailPool.swift — one open `LiveMail` shared by every request of a long-lived process (the `serve` daemon).
//
// The CLI opens the index for one verb and exits. The daemon answers thousands of verbs, so it opens the index once
// and every verb reads through that one connection: reads run at the same time (the SQLite connection is
// serialised per call), and `LiveMail` guards the one thing that changes after it is opened, the mailbox list.
//
// A failure to open (no Full Disk Access, no mail data, an index mail42 doesn't understand) is never kept: the next
// request tries again, so granting access takes effect without restarting the daemon.
//
// An instance that is replaced is not closed: a request may still be using it, and it closes itself when the last
// request lets go of it.

import Foundation

public final class LiveMailPool: @unchecked Sendable {

    private let open: () throws -> LiveMail
    private let lock = NSLock()
    private var current: LiveMail?

    /// - Parameter open: how to open the index (the real one by default; tests pass their own).
    public init(open: @escaping () throws -> LiveMail = { try LiveMail.openFresh() }) {
        self.open = open
    }

    /// The shared `LiveMail`, opened on first use. Throws what opening throws, and keeps nothing when it does.
    public func get() throws -> LiveMail {
        lock.lock()
        defer { lock.unlock() }
        if let current { return current }
        let opened = try open()
        current = opened
        return opened
    }

    /// Makes the shared `LiveMail` reflect what Mail changed: reads the mailbox list and counters again, and opens
    /// the index afresh when an account appeared that it has no name for.
    public func reload() {
        lock.lock()
        let existing = current
        lock.unlock()
        guard let existing else { return }
        do {
            try existing.reloadMailboxes()
            if existing.hasUnknownAccount { replace(with: try open()) }
        } catch {
            // The index can't be read now (Mail is mid-write, or access was withdrawn): drop it, the next request opens it again.
            replace(with: nil)
        }
    }

    /// Drops the shared `LiveMail`; the next request opens the index again.
    public func reset() {
        replace(with: nil)
    }

    private func replace(with fresh: LiveMail?) {
        lock.lock()
        current = fresh
        lock.unlock()
    }
}
