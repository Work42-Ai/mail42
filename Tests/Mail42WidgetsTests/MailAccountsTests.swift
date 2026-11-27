// MailAccountsTests.swift — the account names through the disk bridge (WOR-900): a real Accounts database built by the test
// support, served by a stand-in bridge over its folder.

import Darwin
import Foundation
import Mail42TestSupport
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

/// `services.diskRead` over a real folder, counting what is read.
private nonisolated final class AccountsBridge: WidgetDiskReadService, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: Int64] = [:]
    var refuse: WidgetServiceError?
    /// Suspends every `read`, so a second caller can run while the first is inside the bridge.
    var readDelay: UInt64 = 0

    func bytesRead(_ suffix: String) -> Int64 { lock.withLock { bytes.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +) } }
    func resetCounts() { lock.withLock { bytes = [:] } }

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
        throw Self.missing(path)
    }

    func read(path: String, offset: Int64, length: Int) async throws -> DiskChunk {
        if let refuse { throw refuse }
        if readDelay > 0 { try await Task.sleep(nanoseconds: readDelay) }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Self.missing(path) }
        defer { try? handle.close() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(length, DiskReadLimits.maxReadLength)) ?? Data()
        lock.withLock { bytes[path, default: 0] += Int64(data.count) }
        return DiskChunk(data: data, offset: offset, size: size, isEnd: offset + Int64(data.count) >= size)
    }
}

private func mirrorDirectory() -> URL { URL(fileURLWithPath: "/tmp/w900-accts-\(UUID().uuidString.prefix(8))", isDirectory: true) }

private let gmail = "E51B96AC-1111-4222-8333-444455556666"
private let icloud = "AAAAAAAA-0000-4000-8000-BBBBBBBBBBBB"
private let local = "CCCCCCCC-0000-4000-8000-DDDDDDDDDDDD"

@Suite("MailAccounts: account names through the disk bridge (WOR-900)")
struct MailAccountsTests {

    @Test("names and addresses are mapped through the parent account; identifiers compare case-insensitively")
    func mapping() async throws {
        let builder = try EnvelopeIndexBuilder()
        defer { builder.cleanup() }
        let db = try builder.writeAccountsDatabase([
            .init(pk: 18, identifier: "PARENT-1", username: "user@example.com", description: "Google", type: "Gmail"),
            .init(pk: 19, identifier: gmail, parent: 18),                       // no name of its own
            .init(pk: 24, identifier: "PARENT-2", username: "work@example.com", description: "work@example.com", type: "Gmail"),
            .init(pk: 25, identifier: icloud.lowercased(), parent: 24),         // lower-case in the database
            .init(pk: 14, identifier: local, description: "On My Mac", type: "Local"),
        ])
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await MailAccountsDirectory(disk: AccountsBridge(), path: db.path, directory: directory, chunkLength: 4096).load()
        guard case .loaded(let accounts) = result else { Issue.record("not loaded: \(result)"); return }

        #expect(accounts[gmail] == MailIndexAccountInfo(name: "Google", email: "user@example.com"))
        #expect(accounts[icloud] == MailIndexAccountInfo(name: "work@example.com", email: "work@example.com"))
        #expect(accounts[local] == MailIndexAccountInfo(name: "On My Mac", email: nil))
        #expect(accounts[icloud.lowercased()] == nil, "keys are upper case")
        #expect(result.reason == nil)
    }

    @Test("the same fallbacks as the CLI: own username with an @, description or address as the name, rows with nothing skipped")
    func schemaVariants() async throws {
        let builder = try EnvelopeIndexBuilder()
        defer { builder.cleanup() }
        let db = try builder.writeAccountsDatabase([
            .init(pk: 1, identifier: "OWN", username: "me@example.com", description: "Work"),
            .init(pk: 2, identifier: "NOAT", username: "plainname", description: "Plain"),
            .init(pk: 3, identifier: "ADDRESSONLY", username: "only@example.com"),                 // name falls back to the address
            .init(pk: 4, identifier: "EMPTYDESC", username: "e@example.com", description: ""),
            .init(pk: 5, identifier: "NOTHING"),                                                    // no name, no address
        ])
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = await MailAccountsDirectory(disk: AccountsBridge(), path: db.path, directory: directory).load().accounts

        #expect(accounts["OWN"] == MailIndexAccountInfo(name: "Work", email: "me@example.com"))
        #expect(accounts["NOAT"] == MailIndexAccountInfo(name: "Plain", email: nil))
        #expect(accounts["ADDRESSONLY"] == MailIndexAccountInfo(name: "only@example.com", email: "only@example.com"))
        #expect(accounts["EMPTYDESC"] == MailIndexAccountInfo(name: "e@example.com", email: "e@example.com"))
        #expect(accounts["NOTHING"] == nil, "the list falls back to the identifier")
    }

    @Test("no Accounts database is an empty map with a reason, not an error")
    func missingFile() async throws {
        let result = await MailAccountsDirectory(disk: AccountsBridge(), path: "/tmp/w900-nope-\(UUID().uuidString)/Accounts4.sqlite",
                                                 directory: mirrorDirectory()).load()
        guard case .missing(let reason) = result else { Issue.record("was \(result)"); return }
        #expect(!reason.isEmpty)
        #expect(result.accounts.isEmpty)
        #expect(result.reason == reason)
    }

    @Test("a file that is not a database degrades to empty with a reason")
    func brokenFile() async throws {
        let folder = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bad = folder.appendingPathComponent("Accounts4.sqlite")
        try Data("this is not sqlite".utf8).write(to: bad)
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await MailAccountsDirectory(disk: AccountsBridge(), path: bad.path, directory: directory).load()
        guard case .missing = result else { Issue.record("was \(result)"); return }
        #expect(result.accounts.isEmpty)
    }

    @Test("a database without the Accounts tables degrades to empty")
    func unfamiliarSchema() async throws {
        let builder = try EnvelopeIndexBuilder()
        defer { builder.cleanup() }
        // The Envelope Index is a valid SQLite file with none of the Accounts tables.
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = builder.mailRoot.appendingPathComponent("MailData/Envelope Index")
        let result = await MailAccountsDirectory(disk: AccountsBridge(), path: index.path, directory: directory).load()
        guard case .missing = result else { Issue.record("was \(result)"); return }
        #expect(result.accounts.isEmpty)
    }

    @Test("a refusal by Work42 or macOS is `unavailable`, with an empty map")
    func refusals() async throws {
        let builder = try EnvelopeIndexBuilder()
        defer { builder.cleanup() }
        let db = try builder.writeAccountsDatabase([.init(pk: 1, identifier: gmail, username: "a@example.com", description: "A")])
        func attempt(_ error: WidgetServiceError) async -> MailAccountsResult {
            let bridge = AccountsBridge()
            bridge.refuse = error
            return await MailAccountsDirectory(disk: bridge, path: db.path, directory: mirrorDirectory()).load()
        }
        let denied = await attempt(WidgetServiceError(message: PluginPermissionError.deniedPrefix + "full-disk-access: You chose Not now."))
        #expect(denied == .unavailable("You chose Not now."))
        #expect(denied.accounts.isEmpty)

        let macOS = await attempt(WidgetServiceError(message: "could not stat x: Operation not permitted (errno 1)"))
        guard case .unavailable(let text) = macOS else { Issue.record("EPERM was \(macOS)"); return }
        #expect(text.contains("Full Disk Access"))

        let notDeclared = await attempt(WidgetServiceError(message: PluginPermissionError.notDeclaredPrefix + "full-disk-access"))
        guard case .unavailable = notDeclared else { Issue.record("not declared was \(notDeclared)"); return }

        let other = await attempt(WidgetServiceError(message: "could not read x: Input/output error (errno 5)"))
        #expect(other == .missing("could not read x: Input/output error (errno 5)"))
    }

    @Test("two loads at once share one copy: nothing is read twice and both get the same names")
    func concurrentLoadsShareOneCopy() async throws {
        let builder = try EnvelopeIndexBuilder()
        defer { builder.cleanup() }
        let db = try builder.writeAccountsDatabase([.init(pk: 1, identifier: gmail, username: "a@example.com", description: "A")])
        let size = Int64((try FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int) ?? 0)
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = AccountsBridge()
        bridge.readDelay = 50_000_000
        // Small chunks: the copy takes several reads, each a suspension point.
        let accounts = MailAccountsDirectory(disk: bridge, path: db.path, directory: directory, chunkLength: 4096)

        async let first = accounts.load()
        async let second = accounts.load()
        let (a, b) = await (first, second)

        #expect(a == b)
        #expect(a.accounts[gmail]?.name == "A")
        #expect(bridge.bytesRead("Accounts4.sqlite") == size, "one copy, not two")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Accounts4.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Accounts4.sqlite.part").path))
    }

    @Test("an unchanged database is not copied twice, and a changed one is read again")
    func cachedByStamp() async throws {
        let builder = try EnvelopeIndexBuilder()
        defer { builder.cleanup() }
        let db = try builder.writeAccountsDatabase([.init(pk: 1, identifier: gmail, username: "a@example.com", description: "A")])
        let directory = mirrorDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = AccountsBridge()
        let accounts = MailAccountsDirectory(disk: bridge, path: db.path, directory: directory)

        let first = await accounts.load()
        let firstBytes = bridge.bytesRead("Accounts4.sqlite")
        #expect(firstBytes > 0)
        #expect(first.accounts[gmail]?.name == "A")

        bridge.resetCounts()
        let second = await accounts.load()
        #expect(bridge.bytesRead("Accounts4.sqlite") == 0, "nothing was read again")
        #expect(second == first)

        // The system rewrites the database: new size and time, so it is read again and shows the change.
        try FileManager.default.removeItem(at: db)
        let rewritten = try builder.writeAccountsDatabase([
            .init(pk: 1, identifier: gmail, username: "a@example.com", description: "Renamed"),
            .init(pk: 2, identifier: icloud, username: "b@example.com", description: "B"),
        ])
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: rewritten.path)
        let third = await accounts.load()
        #expect(bridge.bytesRead("Accounts4.sqlite") > 0)
        #expect(third.accounts[gmail]?.name == "Renamed")
        #expect(third.accounts[icloud]?.name == "B")
    }
}
