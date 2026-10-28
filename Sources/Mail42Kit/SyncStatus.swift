// SyncStatus.swift — live progress of a running `mail42 sync`, shared through `~/.work42/mail42/sync-status.json`.
//
// A first sync of a real mailbox takes minutes, and until it is done the index looks empty. The sync writes this
// small file as it goes (after reading the snapshot, and after every batch it indexes) so the Mail widget can show
// "Loading your mail… 3,500 of 5,366" instead of an empty state. Writing it is best effort and never fails a sync.
//
// A `running` file only counts while its writer is alive and recently updated: a crashed or killed sync leaves a
// stale file behind, and a stale file must not keep the widget "loading" forever.

import Foundation

public struct SyncStatus: Codable, Equatable, Sendable {

    public enum State: String, Codable, Sendable {
        case running
        case idle
    }

    public var state: State
    /// `reading` (opening Apple Mail's snapshot, working out what changed) or `indexing` (copying messages in).
    public var phase: String?
    public var pid: Int32?
    public var started: Date?
    /// When this file was last written; a running file that stops being updated goes stale.
    public var updated: Date?
    /// Messages indexed so far in this run.
    public var processed: Int
    /// Messages this run will index, once known.
    public var total: Int?
    public var finished: Date?

    /// A `running` status nobody has updated for this long is treated as dead.
    public static let staleAfter: TimeInterval = 600

    public init(
        state: State, phase: String? = nil, pid: Int32? = nil, started: Date? = nil, updated: Date? = nil,
        processed: Int = 0, total: Int? = nil, finished: Date? = nil
    ) {
        self.state = state
        self.phase = phase
        self.pid = pid
        self.started = started
        self.updated = updated
        self.processed = processed
        self.total = total
        self.finished = finished
    }

    public static func idle(finished: Date) -> SyncStatus {
        SyncStatus(state: .idle, finished: finished)
    }

    /// True while a sync is really running: marked running, its process still exists, and it was updated recently.
    public func isRunning(now: Date = Date(), processIsAlive: (Int32) -> Bool = SyncStatus.processIsAlive) -> Bool {
        guard state == .running else { return false }
        if let last = updated ?? started, now.timeIntervalSince(last) > Self.staleAfter { return false }
        if let pid, !processIsAlive(pid) { return false }
        return true
    }

    /// 0…1 when the total is known and positive.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(processed) / Double(total))
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - File

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The status in `url`, or nil when there is no (readable) file.
    public static func read(from url: URL) -> SyncStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SyncStatus.self, from: data)
    }

    /// Replaces the file atomically (a reader never sees half a write). Best effort.
    public func write(to url: URL) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
