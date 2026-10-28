import Foundation
import Testing
@testable import Mail42Kit

@Suite struct SQLiteTests {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("mail42-sqlite-\(UUID().uuidString).db").path
    }

    @Test func createsInsertsAndQueriesWithBoundParameters() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try SQLiteConnection(path: path, readOnly: false)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, payload BLOB, note TEXT)")
        try db.query("INSERT INTO t (name, score, payload, note) VALUES (?, ?, ?, ?)",
                     [.text("it's \"quoted\""), .double(1.5), .blob(Data([1, 2, 3])), .null]) { _ in }

        var seen = 0
        try db.query("SELECT name, score, payload, note, id FROM t WHERE name = ?", [.text("it's \"quoted\"")]) { row in
            seen += 1
            #expect(row.text(0) == "it's \"quoted\"")
            #expect(row.double(1) == 1.5)
            #expect(row.blob(2) == Data([1, 2, 3]))
            #expect(row.isNull(3))
            #expect(row.text(3) == nil)
            #expect(row.int(4) == 1)
        }
        #expect(seen == 1)
    }

    @Test func aBoundParameterIsNeverInterpretedAsSQL() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try SQLiteConnection(path: path, readOnly: false)
        try db.execute("CREATE TABLE t (name TEXT)")
        try db.query("INSERT INTO t VALUES (?)", [.text("x'); DROP TABLE t; --")]) { _ in }
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 1)
    }

    @Test func readsColumnNamesLowercasedAndEmptyForMissingTables() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try SQLiteConnection(path: path, readOnly: false)
        try db.execute("CREATE TABLE Messages (ROWID INTEGER PRIMARY KEY, Subject TEXT, date_received INTEGER)")
        #expect(try db.columns(of: "Messages") == ["rowid", "subject", "date_received"])
        #expect(try db.columns(of: "nope").isEmpty)
        #expect(try db.columns(of: "x\"; DROP TABLE Messages; --").isEmpty)
        #expect(try db.columns(of: "Messages").count == 3)
    }

    @Test func aReadOnlyConnectionRefusesWrites() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try SQLiteConnection(path: path, readOnly: false)
        try writer.execute("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1)")
        writer.close()
        let reader = try SQLiteConnection(path: path, readOnly: true)
        #expect(try reader.scalarInt("SELECT a FROM t") == 1)
        #expect(throws: Mail42Error.self) { try reader.execute("INSERT INTO t VALUES (2)") }
        #expect(throws: Mail42Error.self) { try reader.query("DELETE FROM t") { _ in } }
    }

    @Test func openingAMissingFileReadOnlyFailsInsteadOfCreatingIt() {
        let path = tempPath()
        #expect(throws: Mail42Error.self) { try SQLiteConnection(path: path, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func badSQLThrowsAQueryFailedError() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try SQLiteConnection(path: path, readOnly: false)
        #expect(throws: Mail42Error.self) { try db.execute("NOT SQL") }
        #expect(throws: Mail42Error.self) { try db.query("SELECT * FROM missing") { _ in } }
    }

    @Test func scalarIntIsNilForNoRowsAndForNull() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try SQLiteConnection(path: path, readOnly: false)
        try db.execute("CREATE TABLE t (a INTEGER)")
        #expect(try db.scalarInt("SELECT a FROM t") == nil)
        try db.execute("INSERT INTO t VALUES (NULL)")
        #expect(try db.scalarInt("SELECT a FROM t") == nil)
    }
}
