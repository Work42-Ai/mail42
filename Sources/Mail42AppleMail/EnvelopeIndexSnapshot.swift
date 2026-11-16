// EnvelopeIndexSnapshot.swift — a read-only connection to Apple Mail's Envelope Index.
//
// Apple Mail keeps its message index in `<mailRoot>/MailData/Envelope Index`, a SQLite database in WAL mode
// that Mail writes to while it runs. mail42 opens that file itself with `SQLITE_OPEN_READONLY` (never
// `immutable=1`, which would ignore the WAL and miss recent mail) and keeps every statement short, so it holds
// no lock Mail would wait for. A read-only connection can't write the database, which makes "never writes to
// Apple Mail" a property of the code path rather than a promise. Nothing is copied: the index is hundreds of
// megabytes, and a copy would also be stale the moment Mail receives a message.
//
// Only when the in-place open fails (for example the `-shm` file is missing and can't be created because Mail
// isn't running) does it fall back to the old way: copy the database and its `-wal` into a private temp folder
// and read the copy, read-only. That copy belongs to this open alone and is removed by `close()`. A process
// that is killed before `close()` leaves its copy behind, so every start sweeps copies whose process is gone
// (`removeStaleCopies`).
//
// The schema is private and changes between macOS releases, so `validateSchema()` checks the columns mail42
// reads before anything is indexed. Required columns are the ones che-apple-mail-mcp's queries have used
// against real mailboxes (messages, subjects, addresses, recipients, mailboxes, attachments). Columns that
// could not be verified without a real index (`summary`, `global_message_id`, `date_sent`) are optional: when
// they're absent mail42 falls back (snippet from the body, Message-ID from the .emlx, date_sent = date_received)
// instead of refusing to run.

import Darwin
import Foundation
import Mail42Kit

public final class EnvelopeIndexSnapshot {

    /// The versioned mail root this snapshot was taken from (`~/Library/Mail/V10`).
    public let mailRoot: URL
    /// The read-only connection, to Mail's own file or to the fallback copy. Valid until `close()`.
    public let connection: SQLiteConnection
    /// The private folder holding the fallback copy; nil when the connection is on Mail's own file (which is never removed).
    private let directory: URL?
    private var closed = false

    /// True when the connection reads Apple Mail's own file, false when it reads a private copy.
    public var readsInPlace: Bool { directory == nil }

    private init(mailRoot: URL, connection: SQLiteConnection, directory: URL?) {
        self.mailRoot = mailRoot
        self.connection = connection
        self.directory = directory
    }

    deinit { close() }

    // MARK: - Opening

    /// Opens the Envelope Index in place, read-only; if that fails, copies it (and its WAL) to a private temp
    /// folder and opens the copy read-only.
    /// - Parameter inPlace: `false` skips the in-place attempt (tests of the fallback).
    /// - Throws: `.fdaDenied` when macOS refuses the read, `.noMailData` when there is no index,
    ///   `.databaseNotAccessible` for anything else.
    public static func open(mailRoot: URL, inPlace: Bool = true) throws -> EnvelopeIndexSnapshot {
        let source = AppleMailAccess.envelopeIndexURL(mailRoot: mailRoot)
        switch FDAStatus.probe(path: source.path) {
        case .denied: throw Mail42Error.fdaDenied
        case .noMailData: throw Mail42Error.noMailData
        case .granted, .undetermined: break
        }

        if inPlace, let connection = try? openInPlace(source) {
            return EnvelopeIndexSnapshot(mailRoot: mailRoot, connection: connection, directory: nil)
        }
        return try openCopy(mailRoot: mailRoot, source: source)
    }

    /// A read-only connection on Mail's own file. The schema read at the end proves the connection works (a WAL
    /// database whose `-shm` can't be opened fails there, not at `sqlite3_open`).
    private static func openInPlace(_ source: URL) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(path: source.path, readOnly: true)
        do {
            guard try !connection.columns(of: "messages").isEmpty else {
                throw Mail42Error.databaseNotAccessible("\(source.path): no messages table")
            }
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    private static func openCopy(mailRoot: URL, source: URL) throws -> EnvelopeIndexSnapshot {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("mail42-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let copy = directory.appendingPathComponent("Envelope Index")
            try fm.copyItem(at: source, to: copy)
            // The WAL holds the changes Mail hasn't folded into the main file yet. Copied right after the
            // main file; SQLite rebuilds the shared-memory index itself, so `-shm` is not copied.
            let wal = URL(fileURLWithPath: source.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
            let connection = try SQLiteConnection(path: copy.path, readOnly: true)
            return EnvelopeIndexSnapshot(mailRoot: mailRoot, connection: connection, directory: directory)
        } catch let error as Mail42Error {
            try? fm.removeItem(at: directory)
            throw error
        } catch {
            try? fm.removeItem(at: directory)
            if (error as NSError).code == NSFileReadNoPermissionError { throw Mail42Error.fdaDenied }
            throw Mail42Error.databaseNotAccessible(error.localizedDescription)
        }
    }

    /// Closes the connection and deletes the fallback copy, if there is one (Apple Mail's own file is never touched).
    /// Safe to call twice.
    public func close() {
        guard !closed else { return }
        closed = true
        connection.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Stale copies

    /// The folder name prefix of a fallback copy: `mail42-<pid>-<uuid>`.
    static let copyPrefix = "mail42-"

    /// The process id a copy folder was made by, or nil when the name isn't one of ours.
    static func owner(ofCopyNamed name: String) -> pid_t? {
        guard name.hasPrefix(copyPrefix) else { return nil }
        let rest = name.dropFirst(copyPrefix.count)
        guard let dash = rest.firstIndex(of: "-"), let pid = pid_t(rest[rest.startIndex..<dash]), pid > 0 else { return nil }
        return pid
    }

    /// Removes the fallback copies in `directory` whose process no longer runs (it was killed before it could
    /// close). A copy whose process is alive, and anything that isn't a `mail42-<pid>-…` folder, is left alone.
    /// - Returns: how many folders were removed.
    @discardableResult
    public static func removeStaleCopies(
        in directory: URL = FileManager.default.temporaryDirectory,
        isRunning: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names {
            guard let pid = owner(ofCopyNamed: name), !isRunning(pid) else { continue }
            if (try? fm.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Schema

    /// Tables and columns mail42 cannot work without (`ROWID` is implicit on every table).
    static let requiredColumns: [(table: String, columns: [String])] = [
        ("messages", ["subject", "sender", "mailbox", "date_received", "read", "flagged", "deleted", "size", "conversation_id"]),
        ("subjects", ["subject"]),
        ("addresses", ["address", "comment"]),
        ("recipients", ["message", "address", "type", "position"]),
        ("mailboxes", ["url", "total_count", "unread_count"]),
        ("attachments", ["message", "name", "attachment_id"]),
    ]

    /// Throws `.schemaUnsupported(table:column:)` for the first required column that is missing.
    public func validateSchema() throws {
        for (table, columns) in Self.requiredColumns {
            let present = try connection.columns(of: table)
            for column in columns where !present.contains(column) {
                throw Mail42Error.schemaUnsupported(table: table, column: column)
            }
        }
    }

    /// Which optional enrichments this macOS version's index offers.
    public struct Capabilities: Equatable, Sendable {
        /// `messages.summary` → `summaries.summary`: Apple's own snippet.
        public let hasSummary: Bool
        /// `messages.date_sent`.
        public let hasDateSent: Bool
        /// `messages.global_message_id` → `message_global_data.message_id_header`: the RFC 5322 Message-ID.
        public let hasMessageIDHeader: Bool
    }

    public func capabilities() throws -> Capabilities {
        let messages = try connection.columns(of: "messages")
        let summaries = try connection.columns(of: "summaries")
        let globalData = try connection.columns(of: "message_global_data")
        return Capabilities(
            hasSummary: messages.contains("summary") && summaries.contains("summary"),
            hasDateSent: messages.contains("date_sent"),
            hasMessageIDHeader: messages.contains("global_message_id") && globalData.contains("message_id_header")
        )
    }
}
