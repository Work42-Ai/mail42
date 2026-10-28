// Mail42Paths.swift — where mail42 keeps its own files, and where Apple Mail keeps its.
//
// mail42 owns ~/.work42/mail42/ (mail.db, trace.jsonl). It only ever READS ~/Library/Mail.

import Foundation

public enum Mail42Paths {

    /// `~/.work42/mail42`.
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".work42", isDirectory: true)
            .appendingPathComponent("mail42", isDirectory: true)
    }

    /// `~/.work42/mail42/mail.db` — the synced index (envelopes, recipients, attachments, FTS).
    public static var db: URL { root.appendingPathComponent("mail.db") }

    /// `~/.work42/mail42/trace.jsonl` — one JSON line per sync outcome and notable event.
    public static var trace: URL { root.appendingPathComponent("trace.jsonl") }

    /// Creates `~/.work42/mail42` if needed.
    @discardableResult
    public static func ensureRoot() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `~/Library/Mail`, the parent of Apple Mail's versioned store.
    public static var appleMailLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
    }

    /// The highest `~/Library/Mail/V<n>` directory (Apple Mail's store: `V10` since macOS Ventura), or nil
    /// when it can't be listed (no Mail data, or Full Disk Access isn't granted).
    public static func appleMailRoot() -> URL? {
        appleMailRoot(in: appleMailLibrary)
    }

    /// `appleMailRoot()` against an explicit `Library/Mail` directory, so it can be tested.
    public static func appleMailRoot(in library: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: library.path) else { return nil }
        let versions: [(Int, String)] = names.compactMap { name in
            guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
            return (n, name)
        }
        guard let highest = versions.max(by: { $0.0 < $1.0 }) else { return nil }
        return library.appendingPathComponent(highest.1, isDirectory: true)
    }
}

/// Appends one JSON object per line to `Mail42Paths.trace`, e.g.
/// `{"ts":"…","src":"sync","event":"sync-ok","added":3,…}`. Never throws: tracing must not break a verb.
public enum Trace {

    public static func append(src: String, event: String, fields: [String: Any] = [:]) {
        append(src: src, event: event, fields: fields, to: Mail42Paths.trace)
    }

    /// The same, to an explicit file (tests).
    public static func append(src: String, event: String, fields: [String: Any], to file: URL) {
        var object: [String: Any] = fields
        object["ts"] = ISO8601DateFormatter().string(from: Date())
        object["src"] = src
        object["event"] = event
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file)
            }
        } catch {
            // Best effort.
        }
    }
}
