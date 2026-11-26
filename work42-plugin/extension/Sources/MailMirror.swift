// MailMirror.swift — Apple Mail's index, read through Work42's Full Disk Access bridge (WOR-900).
//
// The extension cannot read `~/Library/Mail`: macOS keeps that from an extension however it is signed. Work42 can, and offers it
// as `services.diskRead` (permission `full-disk-access`, asked through Work42's pill). Mail's index is a SQLite database in WAL
// mode that Mail writes to while it runs, so it cannot be read a byte at a time like a plain file: SQLite wants the database and
// its `-wal` together, and a read that races a checkpoint sees a torn mixture.
//
// So the extension keeps a private mirror of just those two files in its own folder, copied through the bridge in bounded
// chunks, and opens the copy read-only. Opening a WAL database with no `-shm` beside it makes SQLite rebuild the shared memory
// from the `-wal`, so the copy shows every message Mail had committed when it was taken. The (large, rarely changing) database
// is copied again only when its size or modified time changed; the (small, always changing) `-wal` is copied every time. A
// copy during which the database changed is thrown away and taken again.
//
// This file is only the copying. Nothing here writes Apple Mail's files: the bridge has no way to.

import Foundation
import Work42PluginKit

/// Why the mirror could not be made.
nonisolated enum MailMirrorError: Error, Equatable {
    /// Work42's permission or macOS refused the read. The text says what to turn on.
    case permission(String)
    /// Apple Mail has no index here (it was never set up on this Mac).
    case noMailData
    /// Anything else, in words the person can read.
    case failed(String)

    var message: String {
        switch self {
        case .permission(let text), .failed(let text): return text
        case .noMailData: return "Apple Mail has no mail on this Mac yet."
        }
    }
}

actor MailMirror {

    /// The index inside Mail's versioned folder (`~/Library/Mail/V10`).
    static let envelopeIndexPath = "MailData/Envelope Index"
    /// What the database copy is called in the mirror.
    static let localName = "Envelope Index"

    /// What was copied and when it looked so, by the remote path.
    private struct Stamp: Codable, Equatable {
        var size: Int64
        var modified: Double?
    }

    private let disk: any WidgetDiskReadService
    private let library: String
    private let directory: URL
    private let chunkLength: Int
    private var stamps: [String: Stamp] = [:]
    private var loadedStamps = false

    /// - Parameters:
    ///   - disk: the bridge (`services.diskRead`), or a test's stand-in.
    ///   - library: Apple Mail's folder, whose `V<n>` child holds the index.
    ///   - directory: where the mirror lives: the extension's own folder.
    ///   - chunkLength: how much one bridge call reads (the bridge caps it at 4 MiB).
    init(disk: any WidgetDiskReadService, library: String = "~/Library/Mail", directory: URL,
         chunkLength: Int = DiskReadLimits.maxReadLength) {
        self.disk = disk
        self.library = library
        self.directory = directory
        self.chunkLength = max(1, min(chunkLength, DiskReadLimits.maxReadLength))
    }

    // MARK: - Access

    /// The mail root (`~/Library/Mail/V10`) when Apple Mail's index can be read, else why not.
    func mailRoot() async throws -> String {
        let entries: [DiskEntry]
        do {
            entries = try await list(library)
        } catch let error as MailMirrorError {
            throw error
        }
        let versions = entries.compactMap { entry -> (Int, String)? in
            guard entry.kind == .directory || entry.kind == .symlink, entry.name.hasPrefix("V"),
                  let number = Int(entry.name.dropFirst()) else { return nil }
            return (number, entry.name)
        }
        guard let newest = versions.max(by: { $0.0 < $1.0 }) else { throw MailMirrorError.noMailData }
        let root = library.hasSuffix("/") ? library + newest.1 : library + "/" + newest.1
        let index = root + "/" + Self.envelopeIndexPath
        do {
            let entry = try await disk.stat(path: index)
            guard entry.kind == .file || entry.kind == .symlink else { throw MailMirrorError.noMailData }
            // A read of one byte is the proof: stat can answer where a read is refused.
            _ = try await disk.read(path: index, offset: 0, length: 1)
        } catch let error as MailMirrorError {
            throw error
        } catch {
            throw Self.map(error)
        }
        return root
    }

    // MARK: - Refresh

    /// The local copy of the Envelope Index, current as of now. The first call copies the database; later calls copy it again
    /// only if it changed, and the `-wal` every time.
    func refresh() async throws -> URL {
        loadStamps()
        let root = try await mailRoot()
        let remote = root + "/" + Self.envelopeIndexPath
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent(Self.localName)

        var attempt = 0
        while true {
            attempt += 1
            let before = try await stamp(of: remote)
            if stamps[remote] != before || !FileManager.default.fileExists(atPath: local.path) {
                try await copy(remote, to: local, expecting: before.size)
                stamps[remote] = nil   // not trusted until the copy is known to be of an unchanged database
            }
            try await copyWAL(of: remote, to: local)
            let after = try await stamp(of: remote)
            if after == before {
                stamps[remote] = after
                saveStamps()
                return local
            }
            // The database changed under the copy (Mail checkpointed): take it again, once more at most.
            stamps[remote] = nil
            guard attempt < 2 else {
                throw MailMirrorError.failed("Apple Mail kept changing its index while it was being read. Try again in a moment.")
            }
        }
    }

    /// The `-wal` copied next to the database copy; a database with no `-wal` leaves none behind, and no `-shm` is ever kept
    /// (SQLite builds a fresh one from the `-wal`).
    private func copyWAL(of remote: String, to local: URL) async throws {
        let walRemote = remote + "-wal"
        let walLocal = URL(fileURLWithPath: local.path + "-wal")
        let shmLocal = URL(fileURLWithPath: local.path + "-shm")
        try? FileManager.default.removeItem(at: shmLocal)
        guard let entry = try await statIfPresent(walRemote), entry.kind == .file else {
            try? FileManager.default.removeItem(at: walLocal)
            return
        }
        try await copy(walRemote, to: walLocal, expecting: nil)
    }

    // MARK: - Copying

    /// `remote` in bounded chunks to `local`, replacing it only when the whole file arrived. `expecting` is the size the file had
    /// when it was looked at: a different count means it changed meanwhile.
    private func copy(_ remote: String, to local: URL, expecting size: Int64?) async throws {
        let part = URL(fileURLWithPath: local.path + ".part")
        try? FileManager.default.removeItem(at: part)
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw MailMirrorError.failed("Could not make a copy of Apple Mail's index in the plugin's folder.")
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
                    throw Self.map(error)
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
            throw MailMirrorError.failed("Apple Mail's index changed while it was being read. Try again in a moment.")
        }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: part, to: local)
    }

    // MARK: - The bridge, in this file's terms

    private func stamp(of path: String) async throws -> Stamp {
        guard let entry = try await statIfPresent(path) else { throw MailMirrorError.noMailData }
        return Stamp(size: entry.size, modified: entry.modifiedAt?.timeIntervalSince1970)
    }

    /// nil when the path is not there; any other failure is thrown.
    private func statIfPresent(_ path: String) async throws -> DiskEntry? {
        do {
            return try await disk.stat(path: path)
        } catch {
            if Self.errno(of: error) == ENOENT { return nil }
            throw Self.map(error)
        }
    }

    /// Every page of a folder.
    private func list(_ path: String) async throws -> [DiskEntry] {
        var entries: [DiskEntry] = []
        var cursor: String?
        repeat {
            let page: DiskListing
            do {
                page = try await disk.list(path: path, cursor: cursor, limit: DiskReadLimits.maxListLimit)
            } catch {
                if Self.errno(of: error) == ENOENT { throw MailMirrorError.noMailData }
                throw Self.map(error)
            }
            entries += page.entries
            cursor = page.nextCursor
        } while cursor != nil
        return entries
    }

    // MARK: - Errors

    /// The errno a bridge failure carries (`… (errno 2)`), if any.
    nonisolated static func errno(of error: any Error) -> Int32? {
        guard let message = (error as? WidgetServiceError)?.message,
              let range = message.range(of: "(errno ", options: .backwards) else { return nil }
        let digits = message[range.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }

    /// A failure of the bridge as the mirror reports it: a refusal by Work42 or macOS is `permission`, a missing file
    /// `noMailData`, anything else its own words.
    nonisolated static func map(_ error: any Error) -> MailMirrorError {
        if let known = error as? MailMirrorError { return known }
        if let service = error as? WidgetServiceError {
            if service.message.hasPrefix(PluginPermissionError.notDeclaredPrefix) {
                return .permission("The Mail plugin needs Full Disk Access to read Apple Mail, and its manifest does not ask for it.")
            }
            if service.message.hasPrefix(PluginPermissionError.deniedPrefix) {
                let rest = service.message.dropFirst(PluginPermissionError.deniedPrefix.count)
                let detail = rest.range(of: ": ").map { String(rest[$0.upperBound...]) } ?? String(rest)
                return .permission(detail.isEmpty ? "Full Disk Access is off for Work 42. Turn it on in System Settings → Privacy & Security." : detail)
            }
            switch errno(of: service) {
            case EPERM?, EACCES?:
                return .permission("macOS will not let Work 42 read Apple Mail. Turn on Full Disk Access for Work 42 in System Settings → Privacy & Security, then try again.")
            case ENOENT?, ENOTDIR?:
                return .noMailData
            default:
                return .failed(service.message)
            }
        }
        return .failed(error.localizedDescription)
    }

    // MARK: - What was copied

    private var stampsURL: URL { directory.appendingPathComponent("mirror-state.json") }

    private func loadStamps() {
        guard !loadedStamps else { return }
        loadedStamps = true
        if let data = try? Data(contentsOf: stampsURL), let saved = try? JSONDecoder().decode([String: Stamp].self, from: data) {
            stamps = saved
        }
    }

    private func saveStamps() {
        guard let data = try? JSONEncoder().encode(stamps) else { return }
        try? data.write(to: stampsURL, options: .atomic)
    }
}
