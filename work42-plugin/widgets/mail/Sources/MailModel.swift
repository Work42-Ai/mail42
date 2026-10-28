// MailModel.swift — the Mail widget's state: what's selected, what's loaded, and how the reader gets its HTML.
//
// Everything comes from the `mail42` CLI, which reads Apple Mail's own data live (there is no copy and no sync).
// All CLI work and JSON decoding happen off the main thread; this class only holds finished values. A list load
// is cancellable and coalesced (the newest request wins), and the list you are looking at stays on screen while
// a refresh runs. While visible, one light loop watches for change: it waits for Full Disk Access when that
// isn't granted yet, and otherwise re-reads the mailbox counts every few seconds and refreshes the list when
// they move (new mail, something read or flagged elsewhere).

import AppKit
import Foundation
import Observation
import Work42PluginKit
import Work42UI

enum MailSelection: Equatable, Hashable {
    case allInboxes
    case flagged
    case mailbox(Int64)
}

enum MailLoadState: Equatable {
    case loading
    case notInstalled
    /// Full Disk Access isn't granted to mail42 yet: the guided setup is shown and the grant is detected by itself.
    case needsAccess
    /// Access is fine but Apple Mail has nothing to read (no accounts, or Mail was never opened).
    case noMail
    case ready
    case failed(String)
}

enum MailReaderState: Equatable {
    case none
    case loading(Int64)
    /// The sanitised HTML is on disk and reachable at `url`; `key` identifies this message's web view.
    case ready(id: Int64, url: URL, key: String)
    /// The message has no downloaded body.
    case unavailable(Int64)
    case needsAccess
    case failed(id: Int64, message: String)
}

/// One message ready to show: its HTML file, its attachments, or the fact that it has no body.
private struct ReaderEntry {
    let file: URL?
    let url: URL?
    let key: String
    let attachments: [MailAttachment]
    var unavailable: Bool { file == nil }
}

@Observable
final class MailModel {

    // MARK: - What the user chose

    var selection: MailSelection = .allInboxes
    var unreadOnly = false
    var query = ""

    // MARK: - What's loaded

    private(set) var state: MailLoadState = .loading
    private(set) var tree: [MailAccountTree] = []
    private(set) var envelopes: [MailEnvelope] = []
    private(set) var canLoadMore = false
    /// True while a list is being (re)loaded; the previous list stays visible meanwhile.
    private(set) var isRefreshing = false
    private(set) var selectedID: Int64?
    private(set) var reader: MailReaderState = .none
    private(set) var attachments: [MailAttachment] = []
    /// A short, transient message under the toolbar ("Saved report.pdf").
    private(set) var notice: String?

    private(set) var services: SessionServices?

    private static let pageSize = 50
    private static let searchLimit = 100
    private static let readerArtifactID = "mail42-reader"
    private static let keptReaders = 8
    private static let changeInterval: Duration = .seconds(6)
    private static let accessInterval: Duration = .seconds(2)

    private var watchTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var readerGeneration = 0
    private var listGeneration = 0
    private var isLoadingMore = false
    private var treeSignature = ""

    /// Messages already written for the reader, oldest first (a small LRU: files and web views are disposable).
    private var readerCache: [Int64: ReaderEntry] = [:]
    private var readerOrder: [Int64] = []

    // MARK: - Lifecycle

    func start(services: SessionServices) {
        self.services = services
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            await self?.bootstrap()
            while !Task.isCancelled {
                guard let self else { return }
                let waiting = self.state == .needsAccess || self.state == .noMail || self.state == .notInstalled
                try? await Task.sleep(for: waiting ? Self.accessInterval : Self.changeInterval)
                guard !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    func stop() {
        watchTask?.cancel(); watchTask = nil
        listTask?.cancel(); listTask = nil
        searchTask?.cancel(); searchTask = nil
        noticeTask?.cancel(); noticeTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        readerGeneration += 1
        dropReaderCache()
        services = nil
    }

    /// First load, and the retry after a failure.
    func bootstrap() async {
        if envelopes.isEmpty { state = .loading }
        switch await MailCLI.access() {
        case .notInstalled: state = .notInstalled
        case .denied: state = .needsAccess
        case .noMailData: state = .noMail
        case .granted: await reloadAll()
        }
    }

    /// Checks again right away when Work42 comes back to the front (the user may just have flipped the switch).
    func recheckNow() {
        switch state {
        case .loading, .ready: break
        case .notInstalled, .needsAccess, .noMail, .failed: Task { await bootstrap() }
        }
    }

    /// One beat of the watch loop.
    private func tick() async {
        switch state {
        case .needsAccess, .noMail, .notInstalled:
            await bootstrap()
        case .ready:
            // The mailbox list is the cheap change detector: Apple Mail keeps its counters current.
            guard let fresh = try? await MailCLI.json([MailAccountTree].self, ["mailbox", "list"]) else { return }
            let signature = Self.signature(of: fresh)
            guard signature != treeSignature else { return }
            tree = fresh
            treeSignature = signature
            await refreshQuietly()
        case .loading, .failed:
            break
        }
    }

    private static func signature(of tree: [MailAccountTree]) -> String {
        tree.flatMap { account in account.mailboxes.map { "\($0.id):\($0.total):\($0.unread)" } }.joined(separator: ",")
    }

    // MARK: - Loading the list

    private func reloadAll() async {
        do {
            async let fetchedTree = MailCLI.json([MailAccountTree].self, ["mailbox", "list"])
            let page = try await fetch(limit: Self.pageSize, before: nil)
            let loaded = try await fetchedTree
            tree = loaded
            treeSignature = Self.signature(of: loaded)
            envelopes = page
            canLoadMore = query.trimmingCharacters(in: .whitespaces).isEmpty && page.count >= Self.pageSize
            state = loaded.isEmpty ? .noMail : .ready
        } catch {
            apply(error)
        }
    }

    /// A refresh that keeps what the user is looking at: same page depth, same selection, same scroll.
    private func refreshQuietly() async {
        guard state == .ready else { return }
        let depth = min(max(envelopes.count, Self.pageSize), 500)
        await loadFirstPage(limit: depth, replacing: false)
    }

    private func apply(_ error: any Error) {
        guard let failure = error as? MailFailure else {
            state = .failed(error.localizedDescription)
            return
        }
        switch failure.code {
        case "not_installed": state = .notInstalled
        case "fda_denied": state = .needsAccess
        case "no_mail_data": state = .noMail
        default: state = .failed(failure.message)
        }
    }

    /// Loads the first page; a newer call cancels and supersedes an older one. The old list stays until the new
    /// one is in, so there is never a blank flash.
    private func loadFirstPage(limit: Int, replacing: Bool = true) async {
        listGeneration += 1
        let generation = listGeneration
        isRefreshing = true
        defer { if generation == listGeneration { isRefreshing = false } }
        do {
            let page = try await fetch(limit: limit, before: nil)
            guard generation == listGeneration, !Task.isCancelled else { return }
            envelopes = page
            canLoadMore = query.trimmingCharacters(in: .whitespaces).isEmpty && page.count >= limit
            if state != .ready, !tree.isEmpty { state = .ready }
        } catch {
            guard generation == listGeneration, !Task.isCancelled else { return }
            if replacing { apply(error) }                           // a quiet refresh never swaps a list for an error
        }
    }

    /// Called when the mailbox, the unread filter or the search text changed.
    func filtersChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // A short pause so typing doesn't run a search per keystroke.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.loadFirstPage(limit: Self.pageSize)
        }
    }

    func loadMoreIfNeeded(current envelope: MailEnvelope) {
        guard canLoadMore, !isLoadingMore, envelope.id == envelopes.last?.id, let last = envelopes.last else { return }
        isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingMore = false }
            do {
                let more = try await self.fetch(limit: Self.pageSize, before: last.id)
                let known = Set(self.envelopes.map(\.id))
                self.envelopes += more.filter { !known.contains($0.id) }
                self.canLoadMore = more.count >= Self.pageSize
            } catch {
                self.canLoadMore = false
            }
        }
    }

    private func fetch(limit: Int, before: Int64?) async throws -> [MailEnvelope] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // The filters ride along as search terms, so one query covers everything.
            var combined = "(\(text))"
            switch selection {
            case .allInboxes: combined += " in:inbox"
            case .flagged: combined += " is:flagged"
            case .mailbox(let id): combined += " in:\(id)"
            }
            if unreadOnly { combined += " is:unread" }
            return try await MailCLI.json(
                [MailEnvelope].self, ["envelope", "search", combined, "--limit", String(Self.searchLimit)],
                timeout: 30)
        }
        var arguments = ["envelope", "list", "--limit", String(limit)]
        switch selection {
        case .allInboxes: arguments += ["-m", "all"]
        case .flagged: arguments += ["-m", "flagged"]
        case .mailbox(let id): arguments += ["-m", String(id)]
        }
        if unreadOnly { arguments.append("--unread") }
        if let before { arguments += ["--before", String(before)] }
        return try await MailCLI.json([MailEnvelope].self, arguments)
    }

    // MARK: - Header and toolbar

    /// The open message: the list's current copy, else the one clicked (a search or filter may have dropped it
    /// from the list while it's still open).
    var selectedEnvelope: MailEnvelope? {
        envelopes.first { $0.id == selectedID } ?? (selectedSnapshot?.id == selectedID ? selectedSnapshot : nil)
    }

    private var selectedSnapshot: MailEnvelope?

    var title: String {
        switch selection {
        case .allInboxes: return "All Inboxes"
        case .flagged: return "Flagged"
        case .mailbox(let id): return mailbox(id).map(\.name) ?? "Mailbox"
        }
    }

    /// `12 unread · 4,812 messages`
    var detail: String {
        var parts: [String] = []
        switch selection {
        case .allInboxes:
            let inboxes = tree.flatMap(\.mailboxes).filter { $0.role == "inbox" }
            parts.append("\(inboxes.reduce(0) { $0 + $1.unread }) unread")
            parts.append("\(inboxes.reduce(0) { $0 + $1.total }) messages")
        case .flagged:
            break
        case .mailbox(let id):
            if let box = mailbox(id) {
                parts.append("\(box.unread) unread")
                parts.append("\(box.total) messages")
            }
        }
        if unreadOnly { parts.append("unread only") }
        return parts.joined(separator: " · ")
    }

    private func mailbox(_ id: Int64) -> MailMailbox? { tree.flatMap(\.mailboxes).first { $0.id == id } }

    /// The minimal mailbox picker: All Inboxes, Flagged, then each account's Inbox named as Mail names the
    /// account. Anything else is a search (`in:`). Ids are `all`, `flagged`, or `mb:<id>`.
    var mailboxMenu: [(id: String, title: String, selected: Bool)] {
        var items: [(String, String, Bool)] = [
            ("all", "All Inboxes", selection == .allInboxes),
            ("flagged", "Flagged", selection == .flagged),
        ]
        for account in tree {
            guard let inbox = account.mailboxes.first(where: { $0.role == "inbox" }) else { continue }
            let unread = inbox.unread > 0 ? " (\(inbox.unread))" : ""
            items.append(("mb:\(inbox.id)", account.account.name + unread, selection == .mailbox(inbox.id)))
        }
        return items
    }

    func chooseMailbox(menuID: String) {
        switch menuID {
        case "all": selection = .allInboxes
        case "flagged": selection = .flagged
        default:
            if menuID.hasPrefix("mb:"), let id = Int64(menuID.dropFirst(3)) { selection = .mailbox(id) } else { return }
        }
        filtersChanged()
    }

    func toggleUnread() {
        unreadOnly.toggle()
        filtersChanged()
    }

    // MARK: - Actions

    func openSelectedInMail() async {
        guard let id = selectedID else { return }
        guard let result = await MailCLI.run(["open", String(id)]), result.status == 0 else {
            show("Couldn't open the message in Mail")
            return
        }
    }

    func openFullDiskAccessSettings() async {
        _ = await MailCLI.run(["permissions", "open"], timeout: 20)
    }

    func saveAttachment(_ attachment: MailAttachment) async {
        guard let id = selectedID else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Downloads"
        do {
            nonisolated struct Saved: Decodable, Sendable { let path: String }
            let saved = try await MailCLI.json(
                Saved.self, ["attachment", "save", String(id), attachment.part, "--to", downloads])
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved.path)])
            show("Saved \(URL(fileURLWithPath: saved.path).lastPathComponent)")
        } catch let failure as MailFailure {
            show(failure.message)
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    // MARK: - The reader

    func select(_ id: Int64) {
        guard id != selectedID else { return }
        selectedID = id
        selectedSnapshot = envelopes.first { $0.id == id }
        showReader(id: id)
    }

    func retryReader() {
        guard let id = selectedID else { return }
        evict(id)
        showReader(id: id)
    }

    private func showReader(id: Int64) {
        readerGeneration += 1
        let generation = readerGeneration
        prefetchTask?.cancel()
        if let entry = readerCache[id] {                            // already written: show it at once
            present(entry, id: id)
            touch(id)
            prefetchNeighbors(of: id)
            return
        }
        reader = .loading(id)
        attachments = []
        Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.prepare(id: id)
                guard generation == self.readerGeneration else { return }   // another message was picked meanwhile
                self.store(entry, id: id)
                self.present(entry, id: id)
                self.prefetchNeighbors(of: id)
            } catch let failure as MailFailure {
                guard generation == self.readerGeneration else { return }
                self.reader = failure.code == "fda_denied" ? .needsAccess : .failed(id: id, message: failure.message)
            } catch {
                guard generation == self.readerGeneration else { return }
                self.reader = .failed(id: id, message: error.localizedDescription)
            }
        }
    }

    private func present(_ entry: ReaderEntry, id: Int64) {
        attachments = entry.attachments
        if entry.unavailable {
            reader = .unavailable(id)
        } else if let url = entry.url {
            reader = .ready(id: id, url: url, key: entry.key)
        }
    }

    /// Asks the CLI for the message (HTML to a file, attachments alongside) off the main thread.
    private func prepare(id: Int64) async throws -> ReaderEntry {
        guard let directory = readerDirectory() else {
            throw MailFailure(code: "no_folder", message: "mail42 couldn't prepare a folder to show the message from.")
        }
        let key = "\(id)-\(UUID().uuidString.prefix(8).lowercased())"
        let file = directory.appendingPathComponent("m\(key).html")
        async let list = MailCLI.json([MailAttachment].self, ["attachment", "list", String(id)])
        let result = try await MailCLI.json(
            MailReadResult.self, ["message", "read", String(id), "--html", "--out", file.path])
        let listed = (try? await list) ?? []
        if result.bodyUnavailable {
            try? FileManager.default.removeItem(at: file)
            return ReaderEntry(file: nil, url: nil, key: "mail42:\(key)", attachments: listed)
        }
        guard let url = readerURL(fileName: file.lastPathComponent) else {
            throw MailFailure(code: "no_server", message: "Work42's local artifact server isn't answering yet.")
        }
        return ReaderEntry(file: file, url: url, key: "mail42:\(key)", attachments: listed)
    }

    /// Warms the next messages in the list so stepping through them is instant.
    private func prefetchNeighbors(of id: Int64) {
        guard let index = envelopes.firstIndex(where: { $0.id == id }) else { return }
        let neighbours = [index + 1, index - 1, index + 2].filter { envelopes.indices.contains($0) }.map { envelopes[$0].id }
        prefetchTask = Task { [weak self] in
            for neighbour in neighbours {
                guard let self, !Task.isCancelled else { return }
                if self.readerCache[neighbour] != nil { continue }
                if let entry = try? await self.prepare(id: neighbour), !Task.isCancelled {
                    self.store(entry, id: neighbour, becomesNewest: false)
                }
            }
        }
    }

    // MARK: - The reader's files

    // The reader's HTML lives in mail42's own folder, which is registered with the artifact server under mail42's
    // own id (a stand-in "session"). The widget therefore works in a session tab and on the session-less
    // workspace home alike (where `services.sessionId` is nil), and never fills a session's artifact gallery.
    private static let readerHostID = "mail42-reader"

    private static var readerBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".work42/mail42/reader", isDirectory: true)
    }

    private static var readerFolder: URL {
        readerBase.appendingPathComponent("artifacts/\(readerArtifactID)", isDirectory: true)
    }

    /// `~/.work42/mail42/reader/artifacts/mail42-reader`: the artifact server serves this folder to the web view.
    private func readerDirectory() -> URL? {
        if ArtifactRuntime.directory(forSessionId: Self.readerHostID) != Self.readerBase.path {
            try? ArtifactRuntime.register(sessionId: Self.readerHostID, directory: Self.readerBase.path)
        }
        let directory = Self.readerFolder
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func readerURL(fileName: String) -> URL? {
        guard let base = ArtifactRuntime.url(sessionId: Self.readerHostID, artifactId: Self.readerArtifactID)
        else { return nil }
        return URL(string: base.absoluteString + fileName)
    }

    private func store(_ entry: ReaderEntry, id: Int64, becomesNewest: Bool = true) {
        readerCache[id] = entry
        readerOrder.removeAll { $0 == id }
        if becomesNewest { readerOrder.append(id) } else { readerOrder.insert(id, at: 0) }
        while readerOrder.count > Self.keptReaders, let oldest = readerOrder.first, oldest != selectedID {
            evict(oldest)
        }
    }

    private func touch(_ id: Int64) {
        readerOrder.removeAll { $0 == id }
        readerOrder.append(id)
    }

    private func evict(_ id: Int64) {
        guard let entry = readerCache.removeValue(forKey: id) else { return }
        readerOrder.removeAll { $0 == id }
        BrowserSurfaceCache.shared.teardown(key: entry.key)
        if let file = entry.file { try? FileManager.default.removeItem(at: file) }
    }

    private func dropReaderCache() {
        for id in Array(readerCache.keys) { evict(id) }
        try? FileManager.default.removeItem(at: Self.readerFolder)
    }
}
