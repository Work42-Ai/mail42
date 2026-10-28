// EnvelopeIndexSnapshot.swift — a private, read-only copy of Apple Mail's Envelope Index.
//
// Apple Mail keeps its message index in `<mailRoot>/MailData/Envelope Index`, a SQLite database in WAL mode
// that Mail writes to while it runs. mail42 never opens that file itself: it copies the database and its
// `-wal` into a private temp folder and reads the copy, read-only (never `immutable=1`, which would ignore the
// WAL and miss recent mail). That keeps mail42 off Mail's locks and makes "never writes to Apple Mail" a
// property of the code path rather than a promise.
//
// The schema is private and changes between macOS releases, so `validateSchema()` checks the columns mail42
// reads before anything is indexed. Required columns are the ones che-apple-mail-mcp's queries have used
// against real mailboxes (messages, subjects, addresses, recipients, mailboxes, attachments). Columns that
// could not be verified without a real index (`summary`, `global_message_id`, `date_sent`) are optional: when
// they're absent mail42 falls back (snippet from the body, Message-ID from the .emlx, date_sent = date_received)
// instead of refusing to run.

import Foundation
import Mail42Kit

public final class EnvelopeIndexSnapshot {

    /// The versioned mail root this snapshot was taken from (`~/Library/Mail/V10`).
    public let mailRoot: URL
    /// The read-only connection to the copy. Valid until `close()`.
    public let connection: SQLiteConnection
    private let directory: URL
    private var closed = false

    private init(mailRoot: URL, connection: SQLiteConnection, directory: URL) {
        self.mailRoot = mailRoot
        self.connection = connection
        self.directory = directory
    }

    deinit { close() }

    // MARK: - Opening

    /// Copies the Envelope Index (and its WAL) to a private temp folder and opens the copy read-only.
    /// - Throws: `.fdaDenied` when macOS refuses the read, `.noMailData` when there is no index,
    ///   `.databaseNotAccessible` for anything else.
    public static func open(mailRoot: URL) throws -> EnvelopeIndexSnapshot {
        let source = AppleMailAccess.envelopeIndexURL(mailRoot: mailRoot)
        switch FDAStatus.probe(path: source.path) {
        case .denied: throw Mail42Error.fdaDenied
        case .noMailData: throw Mail42Error.noMailData
        case .granted, .undetermined: break
        }

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

    /// Closes the connection and deletes the temp copy. Safe to call twice.
    public func close() {
        guard !closed else { return }
        closed = true
        connection.close()
        try? FileManager.default.removeItem(at: directory)
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
