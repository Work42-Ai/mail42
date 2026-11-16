// IndexWatcher.swift — tells a long-lived reader that Apple Mail's index changed, instead of it asking again and again.
//
// Mail writes every change to the `-wal` file next to `Envelope Index` (and, when it checkpoints or quits, to the
// main file, or replaces them). The watcher listens for those file events, waits for them to go quiet
// (`debounce`: a burst of writes is one change), then reads the mailbox counters (`signature`) and calls
// `onChange` only when they differ from the last ones it reported. Mail moves a counter whenever mail arrives, is
// read, flagged, moved or deleted, so a write that leaves every counter as it was (Mail re-indexing, a draft saved)
// reports nothing.
//
// A file that is deleted or replaced (the WAL goes away at a checkpoint when Mail quits) ends the event source on
// it; the watcher then waits for the file to exist again and listens anew.

import Darwin
import Foundation

public final class IndexWatcher: @unchecked Sendable {

    private let directory: URL
    private let debounce: TimeInterval
    private let signature: @Sendable () throws -> String
    private let onChange: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "mail42.index-watcher")

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private var rearm: DispatchSourceTimer?
    private var last: String?
    private var running = false

    /// - Parameters:
    ///   - mailRoot: the versioned mail root (`~/Library/Mail/V10`); `MailData/Envelope Index` and its `-wal` are watched.
    ///   - debounce: how long the files must stay quiet before the counters are read.
    ///   - signature: the current counters as one string (`LiveMail.mailboxSignature`).
    ///   - onChange: called with the new signature, on the watcher's own queue, when it differs from the last reported.
    public init(
        mailRoot: URL, debounce: TimeInterval = 0.3,
        signature: @escaping @Sendable () throws -> String, onChange: @escaping @Sendable (String) -> Void
    ) {
        self.directory = AppleMailAccess.envelopeIndexURL(mailRoot: mailRoot).deletingLastPathComponent()
        self.debounce = debounce
        self.signature = signature
        self.onChange = onChange
    }

    deinit { stop() }

    private var names: [String] { ["Envelope Index", "Envelope Index-wal"] }

    /// Starts listening. The current counters become the baseline: nothing is reported until they move.
    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            last = try? signature()
            for name in names { arm(name) }
            startRearmTimer()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            pending?.cancel(); pending = nil
            rearm?.cancel(); rearm = nil
            for source in sources.values { source.cancel() }
            sources = [:]
        }
    }

    /// The counters this watcher last reported (or saw when it started).
    public var lastSignature: String? { queue.sync { last } }

    // MARK: - File events

    private func arm(_ name: String) {
        guard running, sources[name] == nil else { return }
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }          // not there (yet): the timer tries again
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let gone = source.data.contains(.delete) || source.data.contains(.rename)
            if gone {
                source.cancel()
                self.sources[name] = nil
            }
            self.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        sources[name] = source
        source.resume()
    }

    /// A file that was deleted or replaced must be listened to again once it exists. A coarse timer covers that; it
    /// reads nothing and opens nothing unless a watched file is missing.
    private func startRearmTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            var rearmed = false
            for name in self.names where self.sources[name] == nil {
                self.arm(name)
                if self.sources[name] != nil { rearmed = true }
            }
            if rearmed { self.schedule() }              // it came back: something changed while it was gone
        }
        rearm = timer
        timer.resume()
    }

    /// Waits for the files to go quiet, then compares the counters.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func check() {
        guard running, let now = try? signature(), now != last else { return }
        last = now
        onChange(now)
    }
}
