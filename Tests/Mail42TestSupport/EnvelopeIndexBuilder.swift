// EnvelopeIndexBuilder.swift — builds a synthetic Apple Mail store in a temp folder for tests:
//
//   <tmp>/Library/Mail/V10/MailData/Envelope Index          the SQLite index (optionally WAL-only data)
//   <tmp>/Library/Mail/V10/<account>/<mailbox>.mbox/<store>/Data/<hash>/Messages/<rowid>.emlx
//
// The column names are the ones Apple's real index has (verified against che-apple-mail-mcp's queries); the
// optional ones (`summary`, `global_message_id`, `date_sent`) can be left out with `schemaOmitting` to test the
// fallbacks, and any column can be left out to test `schema_unsupported`.

import Foundation
import Mail42Kit

public final class EnvelopeIndexBuilder {

    public static let accountUUID = "E51B96AC-1111-4222-8333-444455556666"
    public static let storeUUID = "A0A0A0A0-B1B1-4C2C-8D3D-E4E4E4E4E4E4"

    /// `<tmp>`: delete it with `cleanup()`.
    public let root: URL
    /// `<tmp>/Library/Mail`.
    public let library: URL
    /// `<tmp>/Library/Mail/V10`.
    public let mailRoot: URL

    private let omitted: Set<String>
    private var writer: SQLiteConnection?
    private var subjectIDs: [String: Int64] = [:]
    private var addressIDs: [String: Int64] = [:]
    private var summaryIDs: [String: Int64] = [:]
    private var globalIDs: [String: Int64] = [:]

    public struct Message {
        public var rowid: Int64
        public var subject: String
        public var senderAddress: String
        public var senderName: String?
        public var mailboxID: Int64
        public var dateReceived: Int64
        public var dateSent: Int64?
        public var read = false
        public var flagged = false
        public var deleted = false
        public var size: Int64 = 1000
        public var conversationID: Int64 = 0
        public var summary: String?
        public var messageIDHeader: String?

        public init(
            rowid: Int64, subject: String, senderAddress: String, senderName: String? = nil,
            mailboxID: Int64, dateReceived: Int64, dateSent: Int64? = nil, read: Bool = false,
            flagged: Bool = false, deleted: Bool = false, size: Int64 = 1000, conversationID: Int64 = 0,
            summary: String? = nil, messageIDHeader: String? = nil
        ) {
            self.rowid = rowid
            self.subject = subject
            self.senderAddress = senderAddress
            self.senderName = senderName
            self.mailboxID = mailboxID
            self.dateReceived = dateReceived
            self.dateSent = dateSent
            self.read = read
            self.flagged = flagged
            self.deleted = deleted
            self.size = size
            self.conversationID = conversationID
            self.summary = summary
            self.messageIDHeader = messageIDHeader
        }
    }

    /// - Parameters:
    ///   - schemaOmitting: `"table.column"` pairs (e.g. `"messages.summary"`) to leave out of the schema.
    ///   - wal: put the index in WAL mode and keep every write in the `-wal` file (no checkpoint), as a running
    ///     Mail does. Call `cleanup()` (or release the builder) to close it.
    public init(schemaOmitting: Set<String> = [], wal: Bool = false) throws {
        self.omitted = schemaOmitting
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail42-fixture-\(UUID().uuidString)", isDirectory: true)
        self.library = root.appendingPathComponent("Library/Mail", isDirectory: true)
        self.mailRoot = library.appendingPathComponent("V10", isDirectory: true)
        let dataDir = mailRoot.appendingPathComponent("MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let connection = try SQLiteConnection(
            path: dataDir.appendingPathComponent("Envelope Index").path, readOnly: false)
        if wal {
            try connection.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        }
        self.writer = connection
        try createSchema()
    }

    deinit { cleanup() }

    public var envelopeIndexURL: URL {
        mailRoot.appendingPathComponent("MailData/Envelope Index")
    }

    /// Closes the writer and deletes the whole temp tree.
    public func cleanup() {
        writer?.close()
        writer = nil
        // Directories made unreadable by a test must be writable again before removal.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Schema

    private func has(_ table: String, _ column: String) -> Bool { !omitted.contains("\(table).\(column)") }

    private func createTable(_ name: String, _ columns: [(String, String)]) throws {
        let kept = columns.filter { has(name, $0.0) }.map { "\($0.0) \($0.1)" }
        try conn.execute("CREATE TABLE \(name) (\(kept.joined(separator: ", ")))")
    }

    private var conn: SQLiteConnection {
        guard let writer else { fatalError("EnvelopeIndexBuilder used after cleanup()") }
        return writer
    }

    private func createSchema() throws {
        try createTable("messages", [
            ("ROWID", "INTEGER PRIMARY KEY"), ("subject", "INTEGER"), ("sender", "INTEGER"),
            ("summary", "INTEGER"), ("mailbox", "INTEGER"), ("date_sent", "INTEGER"),
            ("date_received", "INTEGER"), ("read", "INTEGER"), ("flagged", "INTEGER"),
            ("deleted", "INTEGER"), ("size", "INTEGER"), ("conversation_id", "INTEGER"),
            ("global_message_id", "INTEGER"),
        ])
        try createTable("subjects", [("ROWID", "INTEGER PRIMARY KEY"), ("subject", "TEXT")])
        try createTable("addresses", [("ROWID", "INTEGER PRIMARY KEY"), ("address", "TEXT"), ("comment", "TEXT")])
        try createTable("recipients", [
            ("message", "INTEGER"), ("address", "INTEGER"), ("type", "INTEGER"), ("position", "INTEGER"),
        ])
        try createTable("mailboxes", [
            ("ROWID", "INTEGER PRIMARY KEY"), ("url", "TEXT"), ("total_count", "INTEGER"), ("unread_count", "INTEGER"),
        ])
        try createTable("attachments", [
            ("ROWID", "INTEGER PRIMARY KEY"), ("message", "INTEGER"), ("attachment_id", "TEXT"), ("name", "TEXT"),
        ])
        try createTable("summaries", [("ROWID", "INTEGER PRIMARY KEY"), ("summary", "TEXT")])
        try createTable("message_global_data", [("ROWID", "INTEGER PRIMARY KEY"), ("message_id_header", "TEXT")])
    }

    // MARK: - Rows

    public func addMailbox(id: Int64, url: String, total: Int64 = 0, unread: Int64 = 0) throws {
        try conn.query(
            "INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES (?, ?, ?, ?)",
            [.int(id), .text(url), .int(total), .int(unread)]) { _ in }
    }

    public func addMessage(_ message: Message) throws {
        var columns: [(String, SQLiteValue)] = [
            ("ROWID", .int(message.rowid)),
            ("subject", .int(try id(of: message.subject, in: "subjects", column: "subject", cache: \.subjectIDs))),
            ("sender", .int(try addressID(message.senderAddress, name: message.senderName))),
            ("mailbox", .int(message.mailboxID)),
            ("date_received", .int(message.dateReceived)),
            ("read", .int(message.read ? 1 : 0)),
            ("flagged", .int(message.flagged ? 1 : 0)),
            ("deleted", .int(message.deleted ? 1 : 0)),
            ("size", .int(message.size)),
            ("conversation_id", .int(message.conversationID)),
        ]
        if has("messages", "date_sent") { columns.append(("date_sent", .int(message.dateSent ?? message.dateReceived))) }
        if has("messages", "summary"), has("summaries", "summary"), let summary = message.summary {
            columns.append(("summary", .int(try id(of: summary, in: "summaries", column: "summary", cache: \.summaryIDs))))
        }
        if has("messages", "global_message_id"), has("message_global_data", "message_id_header"),
           let header = message.messageIDHeader {
            columns.append((
                "global_message_id",
                .int(try id(of: header, in: "message_global_data", column: "message_id_header", cache: \.globalIDs))))
        }
        let names = columns.map(\.0).filter { has("messages", $0) }
        let values = columns.filter { has("messages", $0.0) }.map(\.1)
        try conn.query(
            "INSERT INTO messages (\(names.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))",
            values) { _ in }
    }

    public func addRecipient(messageRowid: Int64, address: String, name: String? = nil, type: Int64, position: Int64) throws {
        try conn.query(
            "INSERT INTO recipients (message, address, type, position) VALUES (?, ?, ?, ?)",
            [.int(messageRowid), .int(try addressID(address, name: name)), .int(type), .int(position)]) { _ in }
    }

    public func addAttachment(messageRowid: Int64, attachmentID: String, name: String) throws {
        try conn.query(
            "INSERT INTO attachments (message, attachment_id, name) VALUES (?, ?, ?)",
            [.int(messageRowid), .text(attachmentID), .text(name)]) { _ in }
    }

    public func setRead(rowid: Int64, _ read: Bool) throws {
        try conn.query("UPDATE messages SET read = ? WHERE ROWID = ?", [.int(read ? 1 : 0), .int(rowid)]) { _ in }
    }

    public func deleteMessage(rowid: Int64) throws {
        try conn.query("DELETE FROM messages WHERE ROWID = ?", [.int(rowid)]) { _ in }
    }

    private func id(
        of text: String, in table: String, column: String, cache: ReferenceWritableKeyPath<EnvelopeIndexBuilder, [String: Int64]>
    ) throws -> Int64 {
        if let known = self[keyPath: cache][text] { return known }
        try conn.query("INSERT INTO \(table) (\(column)) VALUES (?)", [.text(text)]) { _ in }
        let rowid = try conn.scalarInt("SELECT last_insert_rowid()") ?? 0
        self[keyPath: cache][text] = rowid
        return rowid
    }

    private func addressID(_ address: String, name: String?) throws -> Int64 {
        if let known = addressIDs[address] { return known }
        try conn.query(
            "INSERT INTO addresses (address, comment) VALUES (?, ?)",
            [.text(address), name.map(SQLiteValue.text) ?? .null]) { _ in }
        let rowid = try conn.scalarInt("SELECT last_insert_rowid()") ?? 0
        addressIDs[address] = rowid
        return rowid
    }

    // MARK: - Message files

    /// The mailbox URL Mail stores for an IMAP mailbox path, e.g. `["[Gmail]", "All Mail"]`.
    public static func mailboxURL(_ path: [String], scheme: String = "imap") -> String {
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        return "\(scheme)://\(accountUUID)/\(encoded.joined(separator: "/"))"
    }

    /// Writes `<rowid>.emlx` (or `.partial.emlx`) where Apple Mail keeps it. The hash folder is worked out
    /// here independently of the production locator (decimal digits of rowid/1000, right to left).
    @discardableResult
    public func writeEmlx(rowid: Int64, mailboxPath: [String] = ["INBOX"], data: Data, partial: Bool = false) throws -> URL {
        let messages = try dataDirectory(mailboxPath: mailboxPath, rowid: rowid).appendingPathComponent("Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let file = messages.appendingPathComponent("\(rowid).\(partial ? "partial.emlx" : "emlx")")
        try data.write(to: file)
        return file
    }

    /// Writes an attachment into Mail's external cache: `<hash>/Attachments/<rowid>/<partID>/<filename>`.
    @discardableResult
    public func writeAttachmentCache(
        rowid: Int64, mailboxPath: [String] = ["INBOX"], partID: String, filename: String, data: Data
    ) throws -> URL {
        let folder = try dataDirectory(mailboxPath: mailboxPath, rowid: rowid)
            .appendingPathComponent("Attachments/\(rowid)/\(partID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(filename)
        try data.write(to: file)
        return file
    }

    private func dataDirectory(mailboxPath: [String], rowid: Int64) throws -> URL {
        var dir = mailRoot.appendingPathComponent(Self.accountUUID, isDirectory: true)
        for component in mailboxPath { dir.appendPathComponent("\(component).mbox", isDirectory: true) }
        dir.appendPathComponent(Self.storeUUID, isDirectory: true)
        dir.appendPathComponent("Data", isDirectory: true)
        var n = rowid / 1000
        var digits: [String] = []
        while n > 0 { digits.append(String(n % 10)); n /= 10 }
        for digit in digits { dir.appendPathComponent(digit, isDirectory: true) }
        return dir
    }
}
