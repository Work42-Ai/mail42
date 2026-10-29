// SQLite.swift — a thin wrapper over the raw sqlite3 C API, shared by everything in mail42 that touches a
// database: the read-only snapshot of Apple's Envelope Index (Mail42AppleMail) and mail42's own mail.db store.
//
// Deliberately small: open, execute, run a query with bound parameters, and inspect a table's columns.
// No ORM, no migrations framework (the store does additive migrations itself, as meet42's CalendarStore does).

import Foundation
import SQLite3

/// A value bound to a `?` placeholder.
public enum SQLiteValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// One result row, valid only inside the `query` callback (it wraps the live statement).
public struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    /// The column as text, or nil when it is NULL.
    public func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    public func blob(_ i: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// An open SQLite database. Not thread-safe: use one connection per thread/actor.
public final class SQLiteConnection {

    private var db: OpaquePointer?
    public let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens `path`. `readOnly: true` uses `SQLITE_OPEN_READONLY` (never `immutable=1`, which would ignore the
    /// WAL and miss recent changes). `readOnly: false` creates the file if it doesn't exist.
    public init(path: String, readOnly: Bool) throws {
        self.path = path
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw Mail42Error.databaseNotAccessible("\(path): \(message)")
        }
        self.db = handle
    }

    deinit { close() }

    public func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    /// The most recent error message from SQLite.
    public var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
    }

    /// Runs statements that return no rows (DDL, PRAGMAs that set, BEGIN/COMMIT). May contain several
    /// statements separated by `;`.
    public func execute(_ sql: String) throws {
        guard let db else { throw Mail42Error.queryFailed("database closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "code \(rc)"
            sqlite3_free(errorMessage)
            throw Mail42Error.queryFailed(message)
        }
    }

    /// Runs one statement with bound parameters, calling `onRow` for each result row.
    public func query(
        _ sql: String,
        _ params: [SQLiteValue] = [],
        _ onRow: (SQLiteRow) throws -> Void
    ) throws {
        guard let db else { throw Mail42Error.queryFailed("database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Mail42Error.queryFailed("prepare failed: \(lastError)")
        }
        defer { sqlite3_finalize(stmt) }

        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, index)
            case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(v.count), Self.transient)
                }
            }
            guard rc == SQLITE_OK else { throw Mail42Error.queryFailed("bind failed: \(lastError)") }
        }

        let row = SQLiteRow(stmt: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try onRow(row)
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw Mail42Error.queryFailed("step failed: \(lastError)")
            }
        }
    }

    /// The lowercase column names of `table` (empty when the table doesn't exist). Used to check Apple's
    /// private schema and to run mail42's additive migrations.
    public func columns(of table: String) throws -> Set<String> {
        // PRAGMA can't take a bound table name, so quote it as an identifier.
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var names = Set<String>()
        try query("PRAGMA table_info(\(quoted))") { row in
            if let name = row.text(1) { names.insert(name.lowercased()) }
        }
        return names
    }

    /// First column of the first row as Int64, or nil when there is no row.
    public func scalarInt(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64? {
        var result: Int64?
        try query(sql, params) { row in
            if result == nil, !row.isNull(0) { result = row.int(0) }
        }
        return result
    }
}
