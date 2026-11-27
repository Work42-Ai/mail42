// MailController.swift — the Mail widget's whole backend in one object, with no CLI and no daemon (WOR-900).
//
// `MailCtl.Controller` owns, for one session, the three services the extension is given (`services.diskRead`, `services.automation`
// and a private working folder) and answers what the widget and the MCP tools ask with typed, async, throwing methods:
//
//   reading   `access`, `mailboxTree`, `list`, `search`, `thread`, `resolve`, `read` / `message`, `attachments`, `attachmentData`
//   acting    `mark`, `flag`, `unflag`, `move`, `archive`, `delete`, `junk`, `draft`, `open` (Mail does the work, as Apple Events)
//
// How a read works: Apple Mail's Envelope Index is mirrored into the working folder through the disk bridge (`MailMirror`), opened
// read-only (`MailIndex`), and asked. The mirror is refreshed before a read, but a burst of calls shares one refresh: within a short
// interval nothing is asked again, and after it the remote index and `-wal` are only STATed (cheap) and copied again just when their
// size or modified time moved. One `MailIndex` is open per mirror generation; the old one is closed once nothing is using it.
//
// Message text is not in the index. It is read from the `.emlx` file, also through the bridge (`BodyReader`), with a size cap per
// file, parsed by `MailBodyParser` and made safe by `MailBodySanitizer`. The same reader answers a text search, reading only the
// first bytes of a big file (the search's note says so) and passing on a refusal instead of treating it as "no text".
//
// Every failure leaves here as a `MailFailure` carrying the CLI's code (`fda_denied`, `no_mail_data`, `not_found`, `bad_query`,
// `schema_unsupported`, `automation_denied`, …); only `CancellationError` passes through as it is.
//
// WRITING: the extension may not write outside its own sandbox, so nothing here saves an attachment anywhere. `attachmentData`
// returns the decoded bytes and a safe file name, and the caller (the widget, which has a save panel, or a tool) decides where they
// go. `read(…, out:)` writes only to the file the caller names, which must be inside the controller's working folder or a root of
// its `Configuration` (`path_not_allowed` otherwise: symbolic links are resolved, `..` and a link as the file are refused).

import Darwin
import Foundation
import Work42PluginKit

nonisolated enum MailCtl {

    /// What a controller may be tuned with. The defaults are what the extension uses.
    struct Configuration: Sendable {
        /// Apple Mail's folder, whose `V<n>` child holds the index (the bridge expands `~`).
        var library = "~/Library/Mail"
        var accountsPath = MailAccountsDirectory.defaultPath
        /// A burst of calls within this many seconds shares the last refresh. 0 checks the remote files on every call.
        var refreshInterval: TimeInterval = 2
        /// The largest `.emlx` (or attachment cache file) `message`/`attachmentData` will read.
        var maxMessageBytes = 64 * 1024 * 1024
        /// A text search reads at most this many bytes from the start of each file (it reads thousands of them); a message
        /// bigger than that is searched partly, and the search's note says so.
        var maxSearchFileBytes = 4 * 1024 * 1024
        /// How much one bridge call reads (the bridge caps it at 4 MiB).
        var chunkLength = DiskReadLimits.maxReadLength
        /// Message files a text search reads at once.
        var searchConcurrency = 8
        /// The most attachment bytes one call loads from Mail's attachment cache (all the files it reads, together).
        var maxAttachmentBytes = 128 * 1024 * 1024
        /// Folders, besides the controller's own working folder, that `read(…, out:)` may write inside.
        var outputRoots: [URL] = []
    }

    /// What `message` should hand back as the body.
    enum ReadMode: Sendable { case text, html, headers }

    /// Which messages a list shows (`MailIndexListOptions` plus flat or conversations).
    struct ListOptions: Sendable {
        var mailbox: MailIndexSelector = .allInboxes
        var unreadOnly = false
        var flaggedOnly = false
        /// Only messages older than this one (the last id of the previous page).
        var beforeID: Int64?
        var limit = 50
        /// One row per conversation instead of one per message.
        var conversations = false

        var index: MailIndexListOptions {
            MailIndexListOptions(mailbox: mailbox, unreadOnly: unreadOnly, flaggedOnly: flaggedOnly, beforeID: beforeID, limit: limit)
        }

        /// `-m all|flagged|<id>|<name>` as the CLI read it.
        static func selector(_ text: String) -> MailIndexSelector {
            switch text.lowercased() {
            case "all": return .allInboxes
            case "flagged": return .flagged
            default: return Int64(text).map(MailIndexSelector.id) ?? .named(text)
            }
        }
    }

    /// One message as `message read` gives it.
    struct MessageContent: Sendable {
        var envelope: MailEnvelope
        /// Top-level headers, lowercase keys.
        var headers: [String: String]
        /// The text, in `.text` mode (nil when there is no file or the mode is another).
        var text: String?
        /// The sanitised HTML document, in `.html` mode.
        var html: String?
        var attachments: [MailAttachment]
        /// No body to show: no file, an unreadable one, or a partial download that never fetched the body.
        var bodyUnavailable: Bool
        var mode: ReadMode

        /// What the mode asked for.
        var content: String? { mode == .html ? html : (mode == .text ? text : nil) }
    }

    /// An attachment's decoded bytes and a file name that is safe as a single path component.
    struct AttachmentData: Sendable {
        var filename: String
        var mime: String
        var data: Data
    }

    struct Permissions: Sendable {
        var access: MailAccess
        /// `~/Library/Mail/V10` when Mail's index can be read.
        var mailRoot: String?
    }

    /// `mail42://message/<id>?mid=<Message-ID>`, or a bare row id.
    struct Link: Equatable, Sendable {
        var rowid: Int64
        /// Without angle brackets.
        var messageID: String?

        init(rowid: Int64, messageID: String?) {
            self.rowid = rowid
            self.messageID = messageID.flatMap(MailIndex.stripBrackets)
        }

        init?(string: String) {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = Int64(text) { self.init(rowid: id, messageID: nil); return }
            let prefix = "mail42://message/"
            guard text.hasPrefix(prefix) else { return nil }
            let parts = text.dropFirst(prefix.count).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let id = Int64(first) else { return nil }
            var mid: String?
            if parts.count == 2 {
                for pair in parts[1].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if kv.count == 2, kv[0] == "mid" { mid = String(kv[1]).removingPercentEncoding }
                }
            }
            self.init(rowid: id, messageID: mid)
        }
    }

    /// What `Controller.changeToken()` returns: `signature` is `mailboxSignature()` (what a change notification carries).
    struct ChangeToken: Equatable, Sendable {
        var signature: String
        /// Size and modified time of Apple's index and `-wal`, as last copied.
        var stamp: String
    }

    // MARK: Output paths

    /// The path an `--out` file may be written to, or `path_not_allowed`. It must be absolute, with no `..`, not itself a symbolic
    /// link, and, with the symbolic links of its deepest existing ancestor resolved, inside one of `roots` (resolved the same
    /// way). Nothing is created here. The result is the resolved path: write there, not to the path as given.
    static func containedOutput(_ file: URL, roots: [URL]) throws -> URL {
        func refused(_ why: String) -> MailFailure {
            MailFailure(code: "path_not_allowed", message: "Won\u{2019}t write \(file.path): \(why).")
        }
        guard file.isFileURL, file.path.hasPrefix("/") else { throw refused("it is not an absolute file path") }
        let parts = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { throw refused("it has no file name, or goes up with `..`") }
        let path = "/" + parts.joined(separator: "/")
        var info = Darwin.stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw refused("it is a symbolic link") }
        guard let target = resolvingExistingAncestor(of: path) else { throw refused("a link on the way leads nowhere") }
        let inside = roots.compactMap { resolvingExistingAncestor(of: $0.standardizedFileURL.path) }.contains { root in
            target.hasPrefix(root == "/" ? "/" : root + "/")
        }
        guard inside else { throw refused("it is outside the folders the Mail plugin writes in") }
        return URL(fileURLWithPath: target)
    }

    /// `path` with the symbolic links of its deepest existing ancestor resolved and the rest (not there yet) appended as it is.
    /// Nil when that ancestor is a link to something that does not exist (a write through it would create the target).
    private static func resolvingExistingAncestor(of path: String) -> String? {
        var info = Darwin.stat()
        var rest: [String] = []
        var head = path
        while lstat(head, &info) != 0 {
            guard head != "/", let slash = head.lastIndex(of: "/") else { return nil }
            rest.append(String(head[head.index(after: slash)...]))
            head = slash == head.startIndex ? "/" : String(head[..<slash])
        }
        if (info.st_mode & S_IFMT) == S_IFLNK, !FileManager.default.fileExists(atPath: head) { return nil }
        var url = URL(fileURLWithPath: head).resolvingSymlinksInPath()
        for part in rest.reversed() { url.appendPathComponent(part) }
        return url.path
    }

    // MARK: Failures

    static func notFound(_ what: String) -> MailFailure { MailFailure(code: "not_found", message: "Not found: \(what).") }

    /// Anything that can go wrong below, as the `MailFailure` the CLI would have printed. A `CancellationError` stays one.
    static func failure(from error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let failure = error as? MailFailure { return failure }
        if let mirror = error as? MailMirrorError {
            switch mirror {
            case .permission(let text): return MailFailure(code: "fda_denied", message: text)
            case .noMailData:
                return MailFailure(code: "no_mail_data", message: "No Apple Mail data found in ~/Library/Mail. Is Mail set up on this Mac?")
            case .failed(let text): return MailFailure(code: "database_not_accessible", message: text)
            }
        }
        if let index = error as? MailIndexError {
            switch index {
            case .database(let text):
                return MailFailure(code: "database_not_accessible", message: "Couldn\u{2019}t open the Apple Mail index: \(text)")
            case .schemaUnsupported: return MailFailure(code: "schema_unsupported", message: index.message)
            case .notFound(let what): return notFound(what)
            }
        }
        if let query = error as? MailQueryError { return query.failure }
        if error is WidgetServiceError { return failure(from: MailMirror.map(error)) }
        if let body = error as? MailBodyError, case .emlxParseFailed(let text) = body {
            return MailFailure(code: "emlx_parse_failed", message: "Couldn\u{2019}t parse the message file: \(text)")
        }
        return MailFailure(code: "error", message: error.localizedDescription)
    }
}

// MARK: - Reading message files through the bridge

nonisolated extension MailCtl {

    /// A message file as read from disk.
    struct Emlx: Sendable {
        /// Under `BodyReader.placeholderRoot`; `BodyReader.remote(_:)` turns it into a real path.
        let path: String
        let data: Data
        let isPartial: Bool
        /// Only the first bytes of a file bigger than that were read (a text search reads a prefix of a big message).
        var isTruncated = false
    }

    /// Which attachments' bytes `BodyReader.parse` loads from Mail's attachment cache for a partial download. The others keep
    /// their size (from a stat) but no bytes.
    enum AttachmentLoad: Sendable {
        case none
        /// The inline images (what the HTML shows).
        case inline
        /// The one part (by the id `attachments` lists).
        case part(String)

        func wants(_ part: MailBodyPart) -> Bool {
            switch self {
            case .none: return false
            case .inline: return part.isInline
            case .part(let id): return part.part == id
            }
        }
    }

    /// Finds and reads `.emlx` files through `services.diskRead`, and is the `MailBodyTextSource` of a text search.
    actor BodyReader: MailBodyTextSource {

        /// `MailEmlxPath` builds `URL(fileURLWithPath:)`s, which never expand `~`: it works under this stand-in root, and
        /// `remote(_:)` swaps the real one back before any path reaches the bridge.
        static let placeholderRoot = "/mail42-root"

        private let disk: any WidgetDiskReadService
        private let root: String
        private let configuration: Configuration
        private var stores: [String: [String]] = [:]

        init(disk: any WidgetDiskReadService, root: String, configuration: Configuration) {
            self.disk = disk
            self.root = root
            self.configuration = configuration
        }

        private func remote(_ path: String) -> String {
            path.hasPrefix(Self.placeholderRoot) ? root + path.dropFirst(Self.placeholderRoot.count) : path
        }

        // MARK: Locating

        /// The message's file (the full `.emlx` before the `.partial.emlx`), or nil when Mail has none on disk. A file over `cap` is
        /// read from its start only (`prefixOnly`: the first `cap` bytes, `isTruncated` says so) or reported as
        /// `message_too_large`. Only a missing file is nil: a refusal by the bridge is thrown.
        func emlx(rowid: Int64, mailboxURL: String, cap: Int, prefixOnly: Bool) async throws -> Emlx? {
            guard let directory = MailEmlxPath.mailboxDirectory(mailboxURL: mailboxURL, mailRoot: Self.placeholderRoot) else { return nil }
            let listedBefore = stores[directory] != nil
            if let found = try await find(rowid, mailboxURL, directory, relist: false, cap: cap, prefixOnly: prefixOnly) { return found }
            // A store folder made since the listing was kept: look once more at the disk.
            guard listedBefore else { return nil }
            return try await find(rowid, mailboxURL, directory, relist: true, cap: cap, prefixOnly: prefixOnly)
        }

        private func find(
            _ rowid: Int64, _ mailboxURL: String, _ directory: String, relist: Bool, cap: Int, prefixOnly: Bool
        ) async throws -> Emlx? {
            if relist || stores[directory] == nil { stores[directory] = try await names(in: directory) }
            let candidates = MailEmlxPath.candidates(
                rowid: rowid, mailboxURL: mailboxURL, mailRoot: Self.placeholderRoot, stores: stores[directory] ?? [])
            for path in candidates {
                guard let entry = try await statIfPresent(path), entry.kind == .file || entry.kind == .symlink else { continue }
                let tooBig = entry.size > Int64(cap)
                if tooBig, !prefixOnly {
                    throw MailFailure(
                        code: "message_too_large",
                        message: "Message \(rowid) is \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)), more than this reader opens.")
                }
                guard let data = try await read(path, limit: cap, strict: !prefixOnly) else { continue }   // gone since the stat
                return Emlx(path: path, data: data, isPartial: MailEmlxPath.isPartial(path: path), isTruncated: tooBig)
            }
            return nil
        }

        /// The names in a folder; none when it is not there.
        private func names(in directory: String) async throws -> [String] {
            var names: [String] = []
            var cursor: String?
            repeat {
                let page: DiskListing
                do {
                    page = try await disk.list(path: remote(directory), cursor: cursor, limit: DiskReadLimits.maxListLimit)
                } catch {
                    if Self.isMissing(error) { return names }
                    throw MailMirror.map(error)
                }
                names += page.entries.map(\.name)
                cursor = page.nextCursor
            } while cursor != nil
            return names
        }

        private func statIfPresent(_ path: String) async throws -> DiskEntry? {
            do {
                return try await disk.stat(path: remote(path))
            } catch {
                if Self.isMissing(error) { return nil }
                throw MailMirror.map(error)
            }
        }

        private static func isMissing(_ error: any Error) -> Bool {
            let code = MailMirror.errno(of: error)
            return code == ENOENT || code == ENOTDIR
        }

        /// A file's bytes from its start, in bridge-sized pieces. `strict`: all of it, and more than `limit` is `message_too_large`.
        /// Not strict: at most `limit` bytes, the rest left unread. Nil when the file is not there (any other failure is thrown).
        private func read(_ path: String, limit: Int, strict: Bool) async throws -> Data? {
            var data = Data()
            var offset: Int64 = 0
            while true {
                try Task.checkCancellation()
                let wanted = strict ? configuration.chunkLength : min(configuration.chunkLength, max(1, limit - data.count))
                let piece: DiskChunk
                do {
                    piece = try await disk.read(path: remote(path), offset: offset, length: wanted)
                } catch {
                    if Self.isMissing(error) { return nil }
                    throw MailMirror.map(error)
                }
                data.append(piece.data)
                offset += Int64(piece.data.count)
                if piece.isEnd || piece.data.isEmpty { break }
                if strict {
                    guard data.count <= limit else {
                        throw MailFailure(code: "message_too_large", message: "A message file grew past what this reader opens while it was read.")
                    }
                } else if data.count >= limit {
                    break
                }
            }
            return data
        }

        // MARK: Parsing

        /// The message in a file. The attachments a partial download no longer carries get their size from Mail's attachment cache
        /// (a stat), and their bytes only where `load` asks for them, within `configuration.maxAttachmentBytes` for the call. Nil
        /// when the bytes are not an `.emlx`. A refusal reading the cache is thrown.
        func parse(_ file: Emlx, loading load: AttachmentLoad = .none) async throws -> MailBodyMessage? {
            let first = await Task.detached { try? MailBodyParser.parse(emlx: file.data, isPartial: file.isPartial) }.value
            guard let first else { return nil }
            guard file.isPartial else { return first }
            let empty = first.parts.filter { $0.filename != nil && $0.data.isEmpty }
            guard !empty.isEmpty else { return first }
            let cached = try await cacheFiles(forEmlx: file.path, parts: empty, load: load)
            guard !cached.isEmpty else { return first }
            let parts = first.parts.map { part -> MailBodyPart in
                guard part.data.isEmpty, let name = part.filename, let found = cached[(name as NSString).lastPathComponent] else { return part }
                return MailBodyPart(
                    part: part.part, filename: part.filename, mime: part.mime, size: found.size, contentID: part.contentID,
                    isInline: part.isInline, data: found.data)
            }
            return MailBodyMessage(headers: first.headers, text: first.text, html: first.html, parts: parts, isPartial: first.isPartial)
        }

        private struct CacheFile {
            var size: Int
            var data: Data
        }

        /// `<hash>/Attachments/<ROWID>/<part-id>/<name>` for each part's name, whichever part folder holds it: its size, and its
        /// bytes when `load` wants that part. Over the budget, an inline image is left without bytes and a requested part is
        /// `message_too_large`.
        private func cacheFiles(forEmlx path: String, parts: [MailBodyPart], load: AttachmentLoad) async throws -> [String: CacheFile] {
            let directory = MailEmlxPath.attachmentsDirectory(forEmlx: path)
            let folders = try await names(in: directory).sorted()
            guard !folders.isEmpty else { return [:] }
            var budget = configuration.maxAttachmentBytes
            var found: [String: CacheFile] = [:]
            for part in parts {
                guard let name = part.filename.map({ ($0 as NSString).lastPathComponent }),
                      !name.isEmpty, name != ".", name != "..", found[name] == nil else { continue }
                for folder in folders {
                    guard let entry = try await statIfPresent(directory + "/" + folder + "/" + name), entry.kind == .file else { continue }
                    var data = Data()
                    if load.wants(part) {
                        if entry.size > Int64(configuration.maxMessageBytes) || entry.size > Int64(budget) {
                            guard case .inline = load else {
                                throw MailFailure(
                                    code: "message_too_large",
                                    message: "The attachment `\(name)` is \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)), more than this reader opens.")
                            }
                        } else {
                            data = try await read(directory + "/" + folder + "/" + name, limit: configuration.maxMessageBytes, strict: true) ?? Data()
                            budget -= data.count
                        }
                    }
                    found[name] = CacheFile(size: Int(entry.size), data: data)
                    break
                }
            }
            return found
        }

        // MARK: MailBodyTextSource

        /// What one message's read gave a text search.
        private struct SearchRead: Sendable {
            var id: Int64
            var text: String?
            var truncated = false
            var failure: (any Error)?
        }

        /// The searchable text of a file. One that was only read from its start is MIME cut short: it is parsed as far as it goes
        /// (the parser does not need the closing boundary), and the text before a big attachment is what a search wants.
        static func searchText(of file: Emlx) -> String? {
            let text: String?
            if file.isTruncated {
                guard let newline = file.data.firstIndex(of: 0x0A) else { return nil }
                let rfc822 = Data(file.data[file.data.index(after: newline)...])
                text = MailBodyParser.parse(rfc822: rfc822, isPartial: file.isPartial).plainText
            } else {
                text = (try? MailBodyParser.parse(emlx: file.data, isPartial: file.isPartial))?.plainText
            }
            return text.flatMap { $0.isEmpty ? nil : $0 }
        }

        func bodyTexts(for messages: [MailBodyCandidate], timeLimit: TimeInterval) async -> MailBodyTextBatch {
            let deadline = Date().addingTimeInterval(timeLimit)
            let cap = configuration.maxSearchFileBytes
            let width = max(1, configuration.searchConcurrency)
            var texts: [Int64: String] = [:]
            var partial = Set<Int64>()
            var failure: (any Error)?
            var ranOutOfTime = false
            var start = 0
            while start < messages.count, failure == nil {
                if Date() >= deadline || Task.isCancelled { ranOutOfTime = true; break }
                let wave = Array(messages[start..<min(start + width, messages.count)])
                await withTaskGroup(of: SearchRead.self) { group in
                    for candidate in wave {
                        group.addTask {
                            // No file is a message with no text; any other failure (a refusal by macOS or the bridge) is the search's.
                            do {
                                guard let file = try await self.emlx(
                                    rowid: candidate.id, mailboxURL: candidate.mailboxURL, cap: cap, prefixOnly: true) else {
                                    return SearchRead(id: candidate.id)
                                }
                                return SearchRead(id: candidate.id, text: Self.searchText(of: file), truncated: file.isTruncated)
                            } catch {
                                return SearchRead(id: candidate.id, failure: MailCtl.failure(from: error))
                            }
                        }
                    }
                    for await read in group {
                        if let text = read.text { texts[read.id] = text }
                        if read.truncated { partial.insert(read.id) }
                        if failure == nil, let error = read.failure { failure = error }
                    }
                }
                start += wave.count
            }
            return MailBodyTextBatch(texts: texts, ranOutOfTime: ranOutOfTime, partial: partial, failure: failure)
        }
    }
}

// MARK: - The controller

nonisolated extension MailCtl {

    actor Controller {

        private struct FileStamp: Equatable {
            var size: Int64
            var modified: Double?
        }

        /// What the remote index and its `-wal` looked like when they were last copied.
        private struct RemoteStamp: Equatable {
            var database: FileStamp
            var wal: FileStamp?
        }

        private let disk: any WidgetDiskReadService
        private let configuration: Configuration
        private let mirror: MailMirror
        private let accountNames: MailAccountsDirectory
        private let automation: any WidgetAutomationService
        /// Where `read(…, out:)` may write: the working folder and the configuration's `outputRoots`.
        private let outputRoots: [URL]
        private var actionsStorage: MailAct.Controller?

        private var index: MailIndex?
        private var reader: BodyReader?
        private var retired: [MailIndex] = []
        private var active = 0
        private var refreshedAt: Date?
        private var lastStamp: RemoteStamp?
        private var refreshTask: Task<Void, any Error>?
        /// Bumped by `close()`: a refresh that started before it publishes nothing.
        private var generation = 0
        /// Bumped by every successful action: a refresh that started before it does not make the cache look current.
        private var invalidations = 0
        /// How many times the mirror was copied again (a test and a diagnostic: a burst of calls adds one).
        private(set) var refreshCount = 0

        /// - Parameters:
        ///   - disk: `services.diskRead`.
        ///   - automation: `services.automation` (Mail's actions).
        ///   - directory: the extension's own folder; the mirror and the account copy live in `mirror` and `accounts` below it.
        init(disk: any WidgetDiskReadService, automation: any WidgetAutomationService, directory: URL,
             configuration: Configuration = Configuration()) {
            self.disk = disk
            self.configuration = configuration
            mirror = MailMirror(
                disk: disk, library: configuration.library, directory: directory.appendingPathComponent("mirror", isDirectory: true),
                chunkLength: configuration.chunkLength)
            accountNames = MailAccountsDirectory(
                disk: disk, path: configuration.accountsPath, directory: directory.appendingPathComponent("accounts", isDirectory: true),
                chunkLength: configuration.chunkLength)
            self.automation = automation
            outputRoots = [directory] + configuration.outputRoots
        }

        /// `MailAct.Controller` is main-actor isolated (its extension is not `nonisolated`), so it is made there, once.
        private func actions() async -> MailAct.Controller {
            if let actionsStorage { return actionsStorage }
            let automation = automation
            let made = await MainActor.run {
                MailAct.Controller(automation: automation) { [weak self] rowid in
                    guard let self else { throw MailFailure(code: "error", message: "The Mail controller was closed.") }
                    return try await self.target(for: rowid)
                }
            }
            if let actionsStorage { return actionsStorage }
            actionsStorage = made
            return made
        }

        /// Whether an index is open (a test and a diagnostic).
        var isOpen: Bool { index != nil || reader != nil }
        /// How many times `close()` was called (a test and a diagnostic).
        private(set) var closeCount = 0

        /// Lets go of the open index. The controller can be used again (it mirrors afresh).
        func close() {
            closeCount += 1
            generation += 1                     // a refresh under way finds out when it next checks, and installs nothing
            refreshTask?.cancel()
            refreshTask = nil
            if let old = index { retired.append(old) }
            index = nil
            reader = nil
            refreshedAt = nil
            lastStamp = nil
            if active == 0 { closeRetired() }
        }

        // MARK: Access

        func permissions() async -> Permissions {
            do {
                return Permissions(access: .granted, mailRoot: try await mirror.mailRoot())
            } catch {
                switch MailMirror.map(error) {
                case .permission: return Permissions(access: .denied, mailRoot: nil)
                case .noMailData: return Permissions(access: .noMailData, mailRoot: nil)
                case .failed(let text): return Permissions(access: .unreachable(text), mailRoot: nil)
                }
            }
        }

        /// Full Disk Access as the bridge sees it: granted, denied, or Mail has no data here.
        func access() async -> MailAccess { await permissions().access }

        // MARK: Reading

        func mailboxTree() async throws -> [MailAccountTree] {
            try await withIndex { index, _ in index.accountTrees() }
        }

        func list(_ options: ListOptions) async throws -> [MailEnvelope] {
            try await withIndex { index, _ in
                try options.conversations ? index.listConversations(options.index) : index.listEnvelopes(options.index)
            }
        }

        /// - Throws: `bad_query` (with the position) for a query that is not valid.
        func search(
            _ query: String, limit: Int = 50, headersOnly: Bool = false, scan: MailSearchLimits = .standard
        ) async throws -> MailSearchOutcome {
            try await withIndex { index, reader in
                try await index.search(query, limit: limit, scan: scan, headersOnly: headersOnly, textScanner: reader)
            }
        }

        /// The conversation a message belongs to, oldest first.
        func thread(_ id: Int64) async throws -> [MailEnvelope] {
            try await withIndex { index, _ in try index.thread(containing: id) }
        }

        /// The message a `mail42://message/…` link (or a bare id) points at, even after Mail moved it and gave it a new id.
        func resolve(_ reference: String, preferMailbox: Int64? = nil) async throws -> MailEnvelope {
            guard let link = Link(string: reference) else {
                throw MailFailure(code: "usage", message: "expected a message id or a mail42://message/\u{2026} link")
            }
            return try await withIndex { index, _ in
                try index.ctlResolve(rowid: link.rowid, messageID: link.messageID, preferMailbox: preferMailbox)
            }
        }

        /// One message with its body: the text, the sanitised HTML document, or just the headers.
        func message(_ id: Int64, mode: ReadMode = .text) async throws -> MessageContent {
            let limit = configuration.maxMessageBytes
            return try await withIndex { index, reader -> MessageContent in
                guard let envelope = try index.envelope(id: id) else { throw MailIndexError.notFound("message \(id)") }
                var parsed: MailBodyMessage?
                if let url = try index.ctlStoredMailboxURL(of: id),
                   let file = try await reader.emlx(rowid: id, mailboxURL: url, cap: limit, prefixOnly: false) {
                    parsed = try await reader.parse(file, loading: mode == .html ? .inline : .none)
                }
                let attachments = try parsed.map(Self.attachments(of:)) ?? index.ctlIndexAttachments(of: id)
                var content = MessageContent(
                    envelope: envelope, headers: parsed?.headers ?? [:], text: nil, html: nil, attachments: attachments,
                    bodyUnavailable: parsed?.bodyUnavailable ?? true, mode: mode)
                if let parsed {
                    switch mode {
                    case .text: content.text = parsed.plainText
                    case .html: content.html = MailBodySanitizer.render(message: parsed, id: id)
                    case .headers: break
                    }
                }
                return content
            }
        }

        /// `message read`: with `out` the body is written to that file (inside the extension's sandbox: the caller chooses) and
        /// `path` says where; without it the HTML comes back in `html` (the text mode has no field in `MailReadResult`: use
        /// `message`).
        func read(_ id: Int64, mode: ReadMode = .text, out file: URL? = nil) async throws -> MailReadResult {
            // Checked before anything is read or created: a path outside the allowed folders is refused whatever the message holds.
            let destination = try file.map { try MailCtl.containedOutput($0, roots: outputRoots) }
            let loaded = try await message(id, mode: mode)
            guard let file, let destination else {
                return MailReadResult(path: nil, html: loaded.html, bodyUnavailable: loaded.bodyUnavailable)
            }
            let text = mode == .headers ? Self.headerLines(loaded.headers) : loaded.content
            guard let text, !(loaded.bodyUnavailable && mode != .headers) else {
                return MailReadResult(path: nil, html: nil, bodyUnavailable: true)
            }
            do {
                // The resolved path, so a link made after the check does not lead the write elsewhere.
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: destination, options: .atomic)
            } catch {
                throw MailFailure(code: "write_failed", message: "Couldn\u{2019}t write the file: \(file.path): \(error.localizedDescription)")
            }
            return MailReadResult(path: file.path, html: nil, bodyUnavailable: false)
        }

        func read(_ id: Int64, html: Bool, out file: URL? = nil) async throws -> MailReadResult {
            try await read(id, mode: html ? .html : .text, out: file)
        }

        func attachments(_ id: Int64) async throws -> [MailAttachment] {
            try await message(id, mode: .headers).attachments
        }

        /// The decoded bytes of one attachment (by the `part` that `attachments` lists) and a safe file name. Nothing is
        /// written: the extension may not write outside its sandbox, so the caller chooses where the bytes go.
        func attachmentData(id: Int64, part: String) async throws -> AttachmentData {
            let limit = configuration.maxMessageBytes
            return try await withIndex { index, reader -> AttachmentData in
                guard try index.envelope(id: id) != nil else { throw MailIndexError.notFound("message \(id)") }
                guard let url = try index.ctlStoredMailboxURL(of: id),
                      let file = try await reader.emlx(rowid: id, mailboxURL: url, cap: limit, prefixOnly: false) else {
                    throw MailFailure(
                        code: "emlx_not_found",
                        message: "The message file for message \(id) isn\u{2019}t on disk (this message has no file on disk).")
                }
                guard let parsed = try await reader.parse(file, loading: .part(part)) else {
                    throw MailFailure(code: "emlx_parse_failed", message: "Couldn\u{2019}t parse the message file: it is not an .emlx.")
                }
                guard let found = parsed.parts.first(where: { $0.part == part && $0.filename != nil }) else {
                    throw MailCtl.notFound("attachment part `\(part)` of message \(id) (see the attachment list)")
                }
                guard !found.data.isEmpty else {
                    throw MailFailure(
                        code: "attachment_not_downloaded",
                        message: "The attachment `\(found.filename ?? "part \(part)")` hasn\u{2019}t been downloaded by Mail yet. Open the message in Mail so it fetches it, then try again.")
                }
                return AttachmentData(
                    filename: MailBodyAttachment.safeName(found.filename, fallback: "attachment-\(part)"), mime: found.mime, data: found.data)
            }
        }

        /// Every mailbox's id and counters as one string: it changes exactly when mail arrives, is read, flagged, moved or deleted.
        func signature() async throws -> String {
            try await withIndex { index, _ in try index.mailboxSignature() }
        }

        /// What `changes()` compares: the mailbox counters, and the size and modified time of Apple's index and `-wal` as last
        /// copied. A flag, or a read that leaves the unread counter alone, moves the second part only.
        func changeToken() async throws -> ChangeToken {
            let counters = try await signature()
            return ChangeToken(signature: counters, stamp: lastStamp.map(Self.describe) ?? "")
        }

        private static func describe(_ stamp: RemoteStamp) -> String {
            func text(_ file: FileStamp?) -> String { file.map { "\($0.size)@\($0.modified ?? 0)" } ?? "-" }
            return text(stamp.database) + "|" + text(stamp.wal)
        }

        // MARK: Acting (Mail does the work; see MailAct)

        /// Runs an action, and after it succeeded makes the next read look at the mirror again (once: Mail may have changed its
        /// index already, and the cached copy must not be reused for the rest of the refresh interval).
        private func acted(_ run: () async throws -> MailActionResult) async throws -> MailActionResult {
            let result = try await run()
            invalidations += 1
            refreshedAt = nil
            return result
        }

        func mark(_ id: Int64, read: Bool) async throws -> MailActionResult { try await acted { try await actions().mark(id, read: read) } }

        func flag(_ id: Int64, color: MailAct.FlagColor? = nil) async throws -> MailActionResult {
            try await acted { try await actions().flag(id, color: color) }
        }

        func unflag(_ id: Int64) async throws -> MailActionResult { try await acted { try await actions().unflag(id) } }

        /// Moves to another mailbox of the message's account, named by id, full name, last name or role.
        func move(_ id: Int64, to mailbox: String) async throws -> MailActionResult {
            let path: [String] = try await withIndex { index, _ -> [String] in
                guard let envelope = try index.envelope(id: id) else { throw MailIndexError.notFound("message \(id)") }
                let boxes = index.mailboxRows.filter { $0.accountID == envelope.account.id }
                let wanted = mailbox.lowercased()
                let found = Int64(mailbox).flatMap { number in boxes.first { $0.id == number } }
                    ?? boxes.first { $0.name.lowercased() == wanted }
                    ?? boxes.first { $0.name.lowercased().hasSuffix("/" + wanted) }
                    ?? boxes.first { $0.role == wanted }
                guard let found else {
                    throw MailCtl.notFound("a mailbox matching `\(mailbox)` in the account \(envelope.account.name)")
                }
                return MailAct.path(ofMailboxNamed: found.name)
            }
            return try await acted { try await actions().move(id, toMailbox: path) }
        }

        func archive(_ id: Int64) async throws -> MailActionResult { try await acted { try await actions().archive(id) } }
        func delete(_ id: Int64) async throws -> MailActionResult { try await acted { try await actions().delete(id) } }
        func junk(_ id: Int64) async throws -> MailActionResult { try await acted { try await actions().junk(id) } }

        func draft(_ kind: MailAct.Draft, of id: Int64? = nil) async throws -> MailActionResult {
            try await acted { try await actions().draft(kind, of: id) }
        }

        func open(_ id: Int64) async throws -> MailActionResult { try await actions().open(id) }

        /// What Mail needs to address a message with: its account as Mail names it, the mailbox it is shown in (a Gmail message
        /// is stored in All Mail but shown under its Inbox label), its Message-ID and link, and the account's archive and junk
        /// mailboxes.
        private func target(for id: Int64) async throws -> MailAct.Target {
            try await withIndex { index, _ -> MailAct.Target in
                guard let envelope = try index.envelope(id: id) else { throw MailIndexError.notFound("message \(id)") }
                let shown = try index.ctlMailboxes(containing: id)
                let chosen = shown.first { $0.role == "inbox" } ?? shown.first
                let account = index.mailboxRows.filter { $0.accountID == envelope.account.id }
                    .map { MailMailboxRef(id: $0.id, name: $0.name, role: $0.role) }
                return MailAct.Target(
                    accountName: envelope.account.name, mailboxPath: MailAct.path(ofMailboxNamed: chosen?.name ?? envelope.mailbox.name),
                    rowid: id, messageID: envelope.messageID, link: envelope.link, archivePath: MailAct.archivePath(in: account),
                    junkPath: MailAct.junkPath(in: account))
            }
        }

        // MARK: The mirror and the open index

        /// Runs `body` on the index of the current mirror generation. The generation is kept open until `body` ends, even if a
        /// refresh makes a newer one meanwhile.
        private func withIndex<T>(_ body: (MailIndex, BodyReader) async throws -> T) async throws -> T {
            try Task.checkCancellation()                // a caller that was cancelled (a closed stream) starts no refresh
            let ready: (MailIndex, BodyReader)
            do { ready = try await fresh() } catch { throw MailCtl.failure(from: error) }
            active += 1
            defer {
                active -= 1
                if active == 0 { closeRetired() }
            }
            do { return try await body(ready.0, ready.1) } catch { throw MailCtl.failure(from: error) }
        }

        private func fresh() async throws -> (MailIndex, BodyReader) {
            if let index, let reader, let at = refreshedAt, Date().timeIntervalSince(at) < configuration.refreshInterval {
                return (index, reader)
            }
            if let refreshTask {
                try await refreshTask.value                     // a refresh is under way: share it
            } else {
                // Unstructured, so the caller that started it going away does not cancel the others waiting for it.
                let started = generation
                let task = Task { [self] in
                    do { try await refresh() } catch { finishRefresh(started); throw error }
                    finishRefresh(started)
                }
                refreshTask = task
                try await task.value
            }
            guard let index, let reader else { throw MailFailure(code: "error", message: "The Mail index is not open.") }
            return (index, reader)
        }

        /// The refresh of generation `started` is over; it only clears the slot if `close()` did not already.
        private func finishRefresh(_ started: Int) {
            if started == generation { refreshTask = nil }
        }

        private func refresh() async throws {
            let started = generation
            let epoch = invalidations
            // After every await: a `close()` meanwhile means this refresh belongs to a controller that was let go of.
            func stillCurrent() throws {
                guard started == generation else { throw MailFailure(code: "error", message: "The Mail controller was closed.") }
            }
            let root = try await mirror.mailRoot()
            try stillCurrent()
            let stamp = try await probe(root)
            try stillCurrent()
            if index != nil, reader != nil, stamp == lastStamp {      // nothing moved on the Mac: the copy is current
                refreshedAt = epoch == invalidations ? Date() : nil
                return
            }
            let copy = try await mirror.refresh()
            try stillCurrent()
            let names = await accountNames.load().accounts
            try stillCurrent()
            let opened = try MailIndex(database: copy, accounts: names)    // no await from here to the end: nothing can close in between
            if let old = index { retired.append(old) }
            index = opened
            reader = BodyReader(disk: disk, root: root, configuration: configuration)
            lastStamp = stamp
            refreshedAt = epoch == invalidations ? Date() : nil           // an action ran while this copied: the next read looks again
            refreshCount += 1
            if active == 0 { closeRetired() }
        }

        /// The remote index's and `-wal`'s size and modified time: a few bytes through the bridge, no copying.
        private func probe(_ root: String) async throws -> RemoteStamp {
            let path = root + "/" + MailMirror.envelopeIndexPath
            let database = try await disk.stat(path: path)
            var wal: FileStamp?
            do {
                let entry = try await disk.stat(path: path + "-wal")
                wal = FileStamp(size: entry.size, modified: entry.modifiedAt?.timeIntervalSince1970)
            } catch {
                if MailMirror.errno(of: error) != ENOENT { throw error }
            }
            return RemoteStamp(
                database: FileStamp(size: database.size, modified: database.modifiedAt?.timeIntervalSince1970), wal: wal)
        }

        private func closeRetired() {
            for old in retired { old.close() }
            retired.removeAll()
        }

        // MARK: Helpers

        private static func attachments(of message: MailBodyMessage) -> [MailAttachment] {
            message.attachmentRows.map { MailAttachment(part: $0.part, filename: $0.filename, mime: $0.mime, size: Int64($0.size)) }
        }

        private static func headerLines(_ headers: [String: String]) -> String {
            headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
        }
    }
}

// MARK: - What the controller asks of the index that MailIndex does not answer itself

nonisolated extension MailIndex {

    /// The URL of the mailbox a message is STORED in (its file is there, which for a Gmail message is All Mail, not its Inbox
    /// label).
    func ctlStoredMailboxURL(of id: Int64) throws -> String? {
        guard let stored = try db.scalarInt("SELECT mailbox FROM messages WHERE ROWID = ?", [.int(id)]) else { return nil }
        return mailboxRows.first { $0.id == stored }?.url
    }

    /// Every mailbox a message is in: where it is stored first, then the ones it is labelled with.
    func ctlMailboxes(containing id: Int64) throws -> [MailIndexMailbox] {
        var ids: [Int64] = []
        if let stored = try db.scalarInt("SELECT mailbox FROM messages WHERE ROWID = ?", [.int(id)]) { ids.append(stored) }
        if hasLabels {
            try db.query("SELECT mailbox_id FROM labels WHERE message_id = ?", [.int(id)]) { row in
                let label = row.int(0)
                if !ids.contains(label) { ids.append(label) }
            }
        }
        return ids.compactMap { id in mailboxRows.first { $0.id == id } }
    }

    /// The attachment names Apple's index holds, for a message whose file cannot be read (no type, no size).
    func ctlIndexAttachments(of id: Int64) throws -> [MailAttachment] {
        var rows: [MailAttachment] = []
        try db.query(
            "SELECT attachment_id, name FROM attachments WHERE message = ? AND name IS NOT NULL AND name != '' ORDER BY attachment_id",
            [.int(id)]
        ) { rows.append(MailAttachment(part: $0.text(0) ?? "", filename: $0.text(1) ?? "", mime: "", size: 0)) }
        return rows
    }

    /// Finds the message a link names: the row id when it still holds that message, else by Message-ID (Mail gives a moved
    /// message a new row), preferring the one in `preferMailbox`. Ported from `LiveMail.resolve`.
    func ctlResolve(rowid: Int64, messageID: String?, preferMailbox: Int64?) throws -> MailEnvelope {
        if let record = try envelope(id: rowid) {
            guard let mid = messageID else { return record }
            if record.messageID.flatMap(Self.stripBrackets) == mid { return record }
        }
        let hasHeaders = try db.columns(of: "messages").contains("global_message_id")
            && db.columns(of: "message_global_data").contains("message_id_header")
        guard let mid = messageID, hasHeaders else { throw MailIndexError.notFound("message \(rowid)") }
        var ids: [Int64] = []
        try db.query(
            """
            SELECT m.ROWID FROM message_global_data g JOIN messages m ON m.global_message_id = g.ROWID
            WHERE g.message_id_header IN (?, ?) AND m.deleted = 0 ORDER BY m.date_received DESC, m.ROWID DESC
            """, [.text(mid), .text("<\(mid)>")]
        ) { ids.append($0.int(0)) }
        guard !ids.isEmpty else { throw MailIndexError.notFound("message \(rowid) (Message-ID \(mid))") }

        var chosen = ids[0]
        if let preferMailbox, ids.count > 1 {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var inMailbox = Set<Int64>()
            try db.query(
                "SELECT ROWID FROM messages WHERE ROWID IN (\(marks)) AND mailbox = ?",
                ids.map(MailSQLValue.int) + [.int(preferMailbox)]
            ) { inMailbox.insert($0.int(0)) }
            if hasLabels {
                try db.query(
                    "SELECT message_id FROM labels WHERE message_id IN (\(marks)) AND mailbox_id = ?",
                    ids.map(MailSQLValue.int) + [.int(preferMailbox)]
                ) { inMailbox.insert($0.int(0)) }
            }
            if let first = ids.first(where: inMailbox.contains) { chosen = first }
        }
        guard let record = try envelope(id: chosen) else { throw MailIndexError.notFound("message \(chosen)") }
        return record
    }
}
