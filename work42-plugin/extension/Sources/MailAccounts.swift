// MailAccounts.swift — the names of the user's mail accounts, from the system Accounts database (WOR-900).
//
// Apple Mail's Envelope Index knows an account only by a UUID. The name and address live in `~/Library/Accounts/Accounts4.sqlite`
// (a Mail account row has no address of its own, its PARENT account does). This is the extension-side twin of the CLI's
// `AccountDirectory`: the same file, the same SQL and the same mapping, but the file is reached through Work42's Full Disk Access
// bridge (`services.diskRead`) and read from a private copy, exactly like the Envelope Index (see MailMirror.swift).
//
// Names are a nicety, never a requirement: a missing, unreadable or unfamiliar database gives an empty map and the list shows the
// UUID. The result says why, so a permission refusal can be told apart from "this Mac has no such file".

import Foundation
import Work42PluginKit

/// What reading the account names came to. Every case has `accounts`; only `loaded` has any.
nonisolated enum MailAccountsResult: Equatable, Sendable {
    /// The database was read (it may know no accounts at all).
    case loaded([String: MailIndexAccountInfo])
    /// There is no usable Accounts database (no file, or one this reader cannot make sense of). Accounts show by UUID.
    case missing(String)
    /// Work42's permission or macOS refused the read. Accounts show by UUID until Full Disk Access is on.
    case unavailable(String)

    /// Account UUID (upper case) → name and address; empty unless `loaded`.
    var accounts: [String: MailIndexAccountInfo] {
        if case .loaded(let accounts) = self { return accounts }
        return [:]
    }

    /// Why there are no names, when there are none for a reason.
    var reason: String? {
        switch self {
        case .loaded: return nil
        case .missing(let text), .unavailable(let text): return text
        }
    }
}

actor MailAccountsDirectory {

    /// Where the system keeps it.
    static let defaultPath = "~/Library/Accounts/Accounts4.sqlite"
    /// What the copy is called in the private folder.
    static let localName = "Accounts4.sqlite"

    private struct Stamp: Equatable {
        var size: Int64
        var modified: Double?
    }

    /// Why a copy could not be made, before it becomes a `MailAccountsResult`.
    private enum Failure: Error {
        case gone
        case permission(String)
        case other(String)
    }

    private let disk: any WidgetDiskReadService
    private let path: String
    private let directory: URL
    private let chunkLength: Int
    private var databaseStamp: Stamp?
    private var walStamp: Stamp?
    private var cached: MailAccountsResult?
    private var inFlight: Task<MailAccountsResult, Never>?

    /// - Parameters:
    ///   - disk: the bridge (`services.diskRead`), or a test's stand-in.
    ///   - path: the Accounts database on the user's Mac.
    ///   - directory: where the private copy lives: the extension's own folder.
    ///   - chunkLength: how much one bridge call reads (the bridge caps it at 4 MiB).
    init(disk: any WidgetDiskReadService, path: String = MailAccountsDirectory.defaultPath, directory: URL,
         chunkLength: Int = DiskReadLimits.maxReadLength) {
        self.disk = disk
        self.path = path
        self.directory = directory
        self.chunkLength = max(1, min(chunkLength, DiskReadLimits.maxReadLength))
    }

    /// The account names as of now. Never throws: every problem is a case of the result.
    func load() async -> MailAccountsResult {
        // Actor reentrancy lets a second load start while the first is suspended in the bridge; both would share the one
        // `.part` file. Later callers join the load already under way instead.
        if let inFlight { return await inFlight.value }
        let task = Task { await self.performLoad() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func performLoad() async -> MailAccountsResult {
        do {
            let result = try await refresh()
            cached = result
            return result
        } catch let failure as Failure {
            databaseStamp = nil
            walStamp = nil
            cached = nil
            switch failure {
            case .gone: return .missing("This Mac has no system Accounts database, so accounts are shown by identifier.")
            case .permission(let text): return .unavailable(text)
            case .other(let text): return .missing(text)
            }
        } catch {
            // Cancelled: keep what was known.
            return cached ?? .missing("Reading the account names was cancelled.")
        }
    }

    // MARK: - Refresh

    private func refresh() async throws -> MailAccountsResult {
        let local = directory.appendingPathComponent(Self.localName)
        var attempt = 0
        while true {
            attempt += 1
            let before = try await stamp(of: path)
            let walBefore = try await stampIfPresent(path + "-wal")
            if let cached, before == databaseStamp, walBefore == walStamp, FileManager.default.fileExists(atPath: local.path) {
                return cached
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if before != databaseStamp || !FileManager.default.fileExists(atPath: local.path) {
                databaseStamp = nil
                try await copy(path, to: local, expecting: before.size)
            }
            try await copyWAL(present: walBefore != nil, to: local)
            let after = try await stamp(of: path)
            let walAfter = try await stampIfPresent(path + "-wal")
            if after == before, walAfter == walBefore {
                databaseStamp = after
                walStamp = walAfter
                return read(local)
            }
            databaseStamp = nil
            guard attempt < 2 else { throw Failure.other("The system Accounts database kept changing while it was being read.") }
        }
    }

    /// The same SQL and mapping as the CLI's `AccountDirectory.load`.
    private func read(_ copy: URL) -> MailAccountsResult {
        do {
            let db = try MailSQLite(path: copy.path)
            defer { db.close() }
            var result: [String: MailIndexAccountInfo] = [:]
            try db.query(
                """
                SELECT a.ZIDENTIFIER, a.ZUSERNAME, a.ZACCOUNTDESCRIPTION, p.ZUSERNAME, p.ZACCOUNTDESCRIPTION
                FROM ZACCOUNT a LEFT JOIN ZACCOUNT p ON p.Z_PK = a.ZPARENTACCOUNT
                WHERE a.ZIDENTIFIER IS NOT NULL
                """
            ) { row in
                guard let uuid = row.text(0) else { return }
                let email = [row.text(1), row.text(3)].compactMap { $0 }.first { $0.contains("@") }
                guard let name = [row.text(2), row.text(4)].compactMap({ $0 }).first(where: { !$0.isEmpty }) ?? email else { return }
                result[uuid.uppercased()] = MailIndexAccountInfo(name: name, email: email)
            }
            return .loaded(result)
        } catch {
            return .missing("The system Accounts database could not be understood, so accounts are shown by identifier.")
        }
    }

    // MARK: - Copying

    /// The `-wal` next to the copy; none on the Mac's side leaves none here, and no `-shm` is ever kept.
    private func copyWAL(present: Bool, to local: URL) async throws {
        let walLocal = URL(fileURLWithPath: local.path + "-wal")
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: local.path + "-shm"))
        guard present else {
            try? FileManager.default.removeItem(at: walLocal)
            return
        }
        try await copy(path + "-wal", to: walLocal, expecting: nil)
    }

    /// `remote` in bounded chunks to `local`, replacing it only when the whole file arrived.
    private func copy(_ remote: String, to local: URL, expecting size: Int64?) async throws {
        let part = URL(fileURLWithPath: local.path + ".part")
        try? FileManager.default.removeItem(at: part)
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw Failure.other("Could not make a copy of the system Accounts database in the plugin's folder.")
        }
        let handle = try FileHandle(forWritingTo: part)
        var offset: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                let piece: DiskChunk
                do {
                    piece = try await disk.read(path: remote, offset: offset, length: chunkLength)
                } catch {
                    throw Self.failure(error)
                }
                if !piece.data.isEmpty { try handle.write(contentsOf: piece.data) }
                offset += Int64(piece.data.count)
                if piece.isEnd || piece.data.isEmpty { break }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: part)
            throw error
        }
        if let size, size != offset {
            try? FileManager.default.removeItem(at: part)
            throw Failure.other("The system Accounts database changed while it was being read.")
        }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: part, to: local)
    }

    // MARK: - The bridge, in this file's terms

    private func stamp(of path: String) async throws -> Stamp {
        guard let stamp = try await stampIfPresent(path) else { throw Failure.gone }
        return stamp
    }

    /// nil when the path is not there; any other failure is thrown.
    private func stampIfPresent(_ path: String) async throws -> Stamp? {
        do {
            let entry = try await disk.stat(path: path)
            guard entry.kind == .file || entry.kind == .symlink else { return nil }
            return Stamp(size: entry.size, modified: entry.modifiedAt?.timeIntervalSince1970)
        } catch {
            if MailMirror.errno(of: error) == ENOENT { return nil }
            throw Self.failure(error)
        }
    }

    private nonisolated static func failure(_ error: any Error) -> Failure {
        if let known = error as? Failure { return known }
        switch MailMirror.map(error) {
        case .permission(let text): return .permission(text)
        case .noMailData: return .gone
        case .failed(let text): return .other(text)
        }
    }
}
