// MailSync.swift — running `mail42 sync` safely from more than one place.
//
// The background agent (every ~2 minutes), the toolbar's Sync button and any number of sessions can all want a
// sync at once. A machine-wide `flock` lets exactly one run at a time (the others skip rather than queue), and a
// recent `sync-ok` in mail42's trace means somebody just did it. Apple Mail is only ever read, by the CLI.

import Foundation

/// A machine-wide, non-blocking lock around `mail42 sync`.
nonisolated enum MailSyncLock {

    private static var lockPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".work42/mail42/sync.lock").path
    }

    /// The lock's file descriptor, or nil when another process holds it.
    static func acquire() -> Int32? {
        let url = URL(fileURLWithPath: lockPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return nil
    }

    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Reads mail42's trace (`~/.work42/mail42/trace.jsonl`) for the last successful sync.
nonisolated enum MailTrace {

    private static var traceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".work42/mail42/trace.jsonl")
    }

    /// When the last `sync-ok` was written, or nil if there hasn't been one.
    static func lastSyncDate() -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: traceURL) else { return nil }
        defer { try? handle.close() }
        // Only the tail: the file only ever grows.
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 16_384
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let formatter = ISO8601DateFormatter()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == "sync-ok", let stamp = object["ts"] as? String else { continue }
            return formatter.date(from: stamp)
        }
        return nil
    }
}

/// What a sync attempt did.
enum MailSyncOutcome: Equatable {
    case synced(MailSyncSummary)
    case skippedFresh
    case busy
    case denied
    case notInstalled
    case failed(String)
}

@MainActor
enum MailSyncRunner {

    /// Runs `mail42 sync` unless another sync is running or (when `skipIfFresherThan` is set) one finished that
    /// recently.
    static func runOnce(skipIfFresherThan seconds: TimeInterval? = nil) async -> MailSyncOutcome {
        guard MailCLI.isInstalled() else { return .notInstalled }
        if let seconds, let last = MailTrace.lastSyncDate(), Date().timeIntervalSince(last) < seconds {
            return .skippedFresh
        }
        guard let fd = MailSyncLock.acquire() else { return .busy }
        defer { MailSyncLock.release(fd) }
        do {
            // A first sync of a big mailbox can take minutes: a generous limit, not the shell's 10 s.
            return .synced(try await MailCLI.json(MailSyncSummary.self, ["sync"], timeout: 1800))
        } catch let failure as MailFailure {
            switch failure.code {
            case "fda_denied": return .denied
            case "not_installed": return .notInstalled
            default: return .failed(failure.message)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// True when mail42 has Full Disk Access (`mail42 permissions` exits 0).
    static func accessGranted() async -> Bool {
        await MailCLI.run(["permissions", "--json"], timeout: 20)?.status == 0
    }
}

/// A cheap fingerprint of mail.db (and its write-ahead log): it changes whenever a sync, from anywhere, writes.
nonisolated enum MailStoreSignature {

    static func current() -> String {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".work42/mail42")
        return ["mail.db", "mail.db-wal"].map { name -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(modified)-\(size)"
        }.joined(separator: "|")
    }
}
