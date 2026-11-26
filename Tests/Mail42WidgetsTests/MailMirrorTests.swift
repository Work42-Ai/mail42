// MailMirrorTests.swift — Apple Mail's index through the disk bridge (WOR-900): a stand-in bridge over a real folder, and a real
// SQLite WAL database, so what is proved is what matters: the copy opens, and it shows the mail that was only in the `-wal`.

import Darwin
import Foundation
import SQLite3
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

// MARK: - A stand-in for services.diskRead

/// `services.diskRead` over a real folder, with what the tests need to watch and to interfere.
private nonisolated final class FakeBridge: WidgetDiskReadService, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String: Int] = [:]
    private var bytes: [String: Int64] = [:]
    /// Called before each read with (path, offset): a test uses it to change the remote while it is being copied.
    var beforeRead: (@Sendable (String, Int64) -> Void)?
    /// When set, every call fails with it.
    var refuse: WidgetServiceError?
    /// When set, a read of this path returns one byte fewer than it should and says it is the end.
    var shortReadPath: String?

    func readCount(_ suffix: String) -> Int { lock.withLock { reads.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +) } }
    func bytesRead(_ suffix: String) -> Int64 { lock.withLock { bytes.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +) } }
    func resetCounts() { lock.withLock { reads = [:]; bytes = [:] } }

    static func missing(_ path: String) -> WidgetServiceError {
        WidgetServiceError(message: "could not stat \(path): No such file or directory (errno 2)", suggestion: "check the path")
    }

    func stat(path: String) async throws -> DiskEntry {
        if let refuse { throw refuse }
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw Self.missing(path) }
        let kind: DiskEntryKind = (info.st_mode & S_IFMT) == S_IFDIR ? .directory : ((info.st_mode & S_IFMT) == S_IFREG ? .file : .other)
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return DiskEntry(name: (path as NSString).lastPathComponent, kind: kind, size: kind == .file ? Int64(info.st_size) : 0,
                         modifiedAt: modified)
    }

    func list(path: String, cursor: String?, limit: Int?) async throws -> DiskListing {
        if let refuse { throw refuse }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { throw Self.missing(path) }
        let sorted = names.sorted()
        let start = cursor.flatMap(Int.init) ?? 0
        let size = limit ?? 200
        let end = min(start + size, sorted.count)
        var entries: [DiskEntry] = []
        for name in sorted[start..<end] { entries.append(try await stat(path: path + "/" + name)) }
        return DiskListing(entries: entries, nextCursor: end < sorted.count ? String(end) : nil)
    }

    func read(path: String, offset: Int64, length: Int) async throws -> DiskChunk {
        if let refuse { throw refuse }
        beforeRead?(path, offset)
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Self.missing(path) }
        defer { try? handle.close() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        try handle.seek(toOffset: UInt64(offset))
        var data = try handle.read(upToCount: min(length, DiskReadLimits.maxReadLength)) ?? Data()
        if path == shortReadPath, !data.isEmpty { data.removeLast() }
        lock.withLock { reads[path, default: 0] += 1; bytes[path, default: 0] += Int64(data.count) }
        let end = path == shortReadPath ? true : offset + Int64(data.count) >= size
        return DiskChunk(data: data, offset: offset, size: size, isEnd: end)
    }
}

// MARK: - A Mail library with a WAL index

/// `<root>/Library/V10/MailData/Envelope Index` as a real SQLite database in WAL mode, kept open so its `-wal` is not folded away.
private nonisolated final class Library {
    let root: URL
    let mailRoot: URL
    var library: String { root.appendingPathComponent("Library").path }
    var index: String { mailRoot.appendingPathComponent("MailData/Envelope Index").path }
    nonisolated(unsafe) private var db: OpaquePointer?

    init(version: String = "V10", withIndex: Bool = true) throws {
        root = URL(fileURLWithPath: "/tmp/w900-\(UUID().uuidString.prefix(8))", isDirectory: true)
        mailRoot = root.appendingPathComponent("Library/\(version)")
        try FileManager.default.createDirectory(at: mailRoot.appendingPathComponent("MailData"), withIntermediateDirectories: true)
        guard withIndex else { return }
        try #require(sqlite3_open(index, &db) == SQLITE_OK)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA wal_autocheckpoint=0")
        try exec("CREATE TABLE messages (id INTEGER PRIMARY KEY, subject TEXT)")
    }

    deinit {
        if let db { sqlite3_close(db) }
        try? FileManager.default.removeItem(at: root)
    }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        if status != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "sqlite \(status)"
            sqlite3_free(message)
            throw NSError(domain: "sqlite", code: Int(status), userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    func insert(_ subjects: [String]) throws {
        for subject in subjects { try exec("INSERT INTO messages (subject) VALUES ('\(subject)')") }
    }

    /// Folds the `-wal` into the database file, as Mail does now and then.
    func checkpoint() throws { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    func addVersion(_ name: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/\(name)/MailData"), withIntermediateDirectories: true)
    }
}

/// The subjects in a mirrored copy, opened read-only the way the widget will open it.
private func subjects(in copy: URL) throws -> [String] {
    var db: OpaquePointer?
    try #require(sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    try #require(sqlite3_prepare_v2(db, "SELECT subject FROM messages ORDER BY id", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    var found: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW { found.append(String(cString: sqlite3_column_text(statement, 0))) }
    return found
}

private func mirrorDirectory() -> URL { URL(fileURLWithPath: "/tmp/w900-mirror-\(UUID().uuidString.prefix(8))", isDirectory: true) }

// MARK: - Tests

@Suite("MailMirror: Apple Mail's index through the disk bridge (WOR-900)")
struct MailMirrorTests {

    @Test("the copy opens and shows the mail that was only in the -wal, copied in several chunks")
    func copyShowsTheWAL() async throws {
        let library = try Library()
        try library.insert(["one", "two", "three"])
        try library.checkpoint()
        try library.insert(["four", "five"])        // only in the -wal now
        let walSize = (try? FileManager.default.attributesOfItem(atPath: library.index + "-wal")[.size] as? Int) ?? 0
        try #require(walSize > 0)

        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = FakeBridge()
        let mirror = MailMirror(disk: bridge, library: library.library, directory: directory, chunkLength: 4096)
        let copy = try await mirror.refresh()

        // Before it is opened: opening a WAL database makes SQLite create its own -shm beside it.
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-shm"), "no -shm is copied: SQLite rebuilds it from the -wal")
        #expect(!FileManager.default.fileExists(atPath: copy.path + ".part"))
        #expect(bridge.readCount("Envelope Index") > 1, "the database came in more than one chunk")
        #expect(try subjects(in: copy) == ["one", "two", "three", "four", "five"])
    }

    @Test("an unchanged database is not copied again, but the -wal is, so new mail shows")
    func theDatabaseIsCopiedOnlyWhenItChanged() async throws {
        let library = try Library()
        try library.insert(["one", "two"])
        try library.checkpoint()
        try library.insert(["three"])

        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = FakeBridge()
        let mirror = MailMirror(disk: bridge, library: library.library, directory: directory)
        _ = try await mirror.refresh()
        let first = bridge.bytesRead("Envelope Index")
        #expect(first > 0)

        bridge.resetCounts()
        try library.insert(["four"])                 // lands in the -wal; the database file itself is untouched
        let copy = try await mirror.refresh()
        #expect(bridge.bytesRead("Envelope Index") <= 1, "the database was not read again (one byte is the access check)")
        #expect(bridge.bytesRead("Envelope Index-wal") > 0, "the -wal was")
        #expect(try subjects(in: copy) == ["one", "two", "three", "four"])
    }

    @Test("a database Mail checkpointed is copied again, and the new copy matches")
    func aChangedDatabaseIsCopiedAgain() async throws {
        let library = try Library()
        try library.insert(["one"])
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = FakeBridge()
        let mirror = MailMirror(disk: bridge, library: library.library, directory: directory)
        _ = try await mirror.refresh()

        try library.insert(["two", "three"])
        try library.checkpoint()
        bridge.resetCounts()
        let copy = try await mirror.refresh()
        #expect(try subjects(in: copy) == ["one", "two", "three"])
        #expect(bridge.bytesRead("Envelope Index") > 0, "the checkpoint changed the database, so it was read again")
    }

    @Test("a state that survives a restart: a new mirror over the same folder does not copy the database again")
    func stateIsKept() async throws {
        let library = try Library()
        try library.insert(["one"])
        try library.checkpoint()
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = FakeBridge()
        _ = try await MailMirror(disk: bridge, library: library.library, directory: directory).refresh()
        bridge.resetCounts()
        let copy = try await MailMirror(disk: bridge, library: library.library, directory: directory).refresh()
        #expect(bridge.bytesRead("Envelope Index") <= 1, "one byte is the access check")
        #expect(try subjects(in: copy) == ["one"])
    }

    @Test("a database that changes while it is copied is copied again; one that never settles is reported")
    func tornCopies() async throws {
        let library = try Library()
        try library.insert(["one", "two"])
        try library.checkpoint()
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = FakeBridge()
        let index = library.index
        // The first time the database is read, Mail changes it (the mtime moves).
        let touched = TouchOnce(path: index)
        bridge.beforeRead = { path, _ in if path == index { touched.touch() } }
        let mirror = MailMirror(disk: bridge, library: library.library, directory: directory, chunkLength: 4096)
        let copy = try await mirror.refresh()
        #expect(touched.count == 1)
        #expect(try subjects(in: copy) == ["one", "two"])

        // Mail never stops changing it: the mirror gives up with a sentence, and keeps no half copy.
        let busy = try Library()
        try busy.insert(["x"])
        try busy.checkpoint()
        let busyBridge = FakeBridge()
        let busyIndex = busy.index
        let toucher = TouchOnce(path: busyIndex, every: true)
        busyBridge.beforeRead = { path, _ in if path == busyIndex { toucher.touch() } }
        let busyDirectory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: busyDirectory) }
        let busyMirror = MailMirror(disk: busyBridge, library: busy.library, directory: busyDirectory, chunkLength: 4096)
        do {
            _ = try await busyMirror.refresh()
            Issue.record("a database that kept changing was reported as copied")
        } catch let error as MailMirrorError {
            #expect(error.message.contains("kept changing"))
        }
        #expect(!FileManager.default.fileExists(atPath: busyDirectory.appendingPathComponent("Envelope Index.part").path))
    }

    @Test("a copy that comes up short is refused, the old copy stays, and no half file is left")
    func shortCopy() async throws {
        let library = try Library()
        try library.insert(["one"])
        try library.checkpoint()
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = FakeBridge()
        let mirror = MailMirror(disk: bridge, library: library.library, directory: directory)
        let good = try await mirror.refresh()
        let before = try Data(contentsOf: good)

        try library.insert(["two"])
        try library.checkpoint()
        bridge.shortReadPath = library.index
        do {
            _ = try await mirror.refresh()
            Issue.record("a short copy was accepted")
        } catch let error as MailMirrorError {
            #expect(error.message.contains("changed while"))
        }
        #expect(try Data(contentsOf: good) == before, "the earlier copy is untouched")
        #expect(!FileManager.default.fileExists(atPath: good.path + ".part"))
    }

    @Test("with no -wal on Mail's side the mirror keeps none, and never a stale -shm")
    func noWAL() async throws {
        let library = try Library()
        try library.insert(["one"])
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = FakeBridge()
        let mirror = MailMirror(disk: bridge, library: library.library, directory: directory)
        let copy = try await mirror.refresh()
        try Data("stale".utf8).write(to: URL(fileURLWithPath: copy.path + "-shm"))
        try library.checkpoint()                      // TRUNCATE leaves an empty -wal; remove it as a quiet Mail does
        try? FileManager.default.removeItem(atPath: library.index + "-wal")
        try? FileManager.default.removeItem(atPath: library.index + "-shm")
        _ = try await mirror.refresh()
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-shm"))
    }

    // MARK: Access

    @Test("the newest V folder is the mail root")
    func newestVersion() async throws {
        let library = try Library(version: "V9")
        try library.addVersion("V10")
        try library.addVersion("Vfoo")
        let mirror = MailMirror(disk: FakeBridge(), library: library.library, directory: mirrorDirectory())
        // V10 has no index: that is "no mail", not a fall back to V9.
        await #expect(throws: MailMirrorError.noMailData) { _ = try await mirror.mailRoot() }

        let both = try Library(version: "V9")
        let newer = both.root.appendingPathComponent("Library/V10/MailData")
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: newer.appendingPathComponent("Envelope Index"))
        let found = try await MailMirror(disk: FakeBridge(), library: both.library, directory: mirrorDirectory()).mailRoot()
        #expect(found.hasSuffix("/V10"))
    }

    @Test("no Mail folder, or Mail never set up, is noMailData")
    func noMailData() async throws {
        let empty = URL(fileURLWithPath: "/tmp/w900-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("Library"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let none = MailMirror(disk: FakeBridge(), library: empty.appendingPathComponent("Library").path, directory: mirrorDirectory())
        await #expect(throws: MailMirrorError.noMailData) { _ = try await none.mailRoot() }
        let gone = MailMirror(disk: FakeBridge(), library: empty.appendingPathComponent("Nope").path, directory: mirrorDirectory())
        await #expect(throws: MailMirrorError.noMailData) { _ = try await gone.refresh() }
    }

    @Test("Work42's permission and macOS each refuse in their own words")
    func refusals() async throws {
        let library = try Library()
        func attempt(_ error: WidgetServiceError) async -> MailMirrorError? {
            let bridge = FakeBridge()
            bridge.refuse = error
            do {
                _ = try await MailMirror(disk: bridge, library: library.library, directory: mirrorDirectory()).refresh()
                return nil
            } catch let failure as MailMirrorError {
                return failure
            } catch {
                return .failed("\(error)")
            }
        }
        let notDeclared = await attempt(WidgetServiceError(message: PluginPermissionError.notDeclaredPrefix + "full-disk-access"))
        if case .permission(let text)? = notDeclared { #expect(text.contains("manifest")) } else { Issue.record("not declared was \(String(describing: notDeclared))") }

        let denied = await attempt(WidgetServiceError(message: PluginPermissionError.deniedPrefix + "full-disk-access: You chose Not now."))
        #expect(denied == .permission("You chose Not now."))

        let macOS = await attempt(WidgetServiceError(message: "could not list x: Operation not permitted (errno 1)"))
        if case .permission(let text)? = macOS { #expect(text.contains("Full Disk Access")) } else { Issue.record("EPERM was \(String(describing: macOS))") }

        let other = await attempt(WidgetServiceError(message: "could not read x: Input/output error (errno 5)"))
        #expect(other == .failed("could not read x: Input/output error (errno 5)"))
    }

    @Test("an errno is read from a bridge message, and only from its end")
    func errnoParsing() {
        #expect(MailMirror.errno(of: WidgetServiceError(message: "could not stat /x: No such file or directory (errno 2)")) == 2)
        #expect(MailMirror.errno(of: WidgetServiceError(message: "a (errno 9) b (errno 13)")) == 13)
        #expect(MailMirror.errno(of: WidgetServiceError(message: "no number here")) == nil)
        #expect(MailMirror.errno(of: NSError(domain: "x", code: 2)) == nil)
    }
}

/// Moves a file's modified time, once or every time it is asked: Mail changing its index under a reader.
private nonisolated final class TouchOnce: @unchecked Sendable {
    private let path: String
    private let every: Bool
    private let lock = NSLock()
    private var touches = 0
    var count: Int { lock.withLock { touches } }

    init(path: String, every: Bool = false) {
        self.path = path
        self.every = every
    }

    func touch() {
        let go = lock.withLock { () -> Bool in
            guard every || touches == 0 else { return false }
            touches += 1
            return true
        }
        guard go else { return }
        let future = Date().addingTimeInterval(Double(count) * 5)
        try? FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: path)
    }
}
