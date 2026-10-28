// MailModel.swift — the Mail widget's state: what's selected, what's loaded, and how the reader gets its HTML.
//
// Everything comes from the `mail42` CLI (see MailCLI). The list refreshes by itself whenever mail.db changes
// (a sync from the background agent, the toolbar, or an agent), found by a 2-second look at the file's
// fingerprint, the same way meet42's calendar widget notices new events.

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
    case fdaDenied
    case noAccounts
    case ready
    case failed(String)
}

enum MailReaderState: Equatable {
    case none
    case loading(Int64)
    /// The sanitised HTML is on disk and reachable at `url`; `key` identifies this load's web view.
    case ready(id: Int64, url: URL, key: String)
    /// The message has no downloaded body.
    case unavailable(Int64)
    case fdaDenied
    case failed(id: Int64, message: String)
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
    private(set) var isSyncing = false
    private(set) var selectedID: Int64?
    private(set) var reader: MailReaderState = .none
    private(set) var attachments: [MailAttachment] = []
    private(set) var lastSync: Date?
    /// A short, transient message under the toolbar ("Saved report.pdf").
    private(set) var notice: String?

    private(set) var services: SessionServices?

    private static let pageSize = 50
    private static let searchLimit = 100
    private static let readerArtifactID = "mail42-reader"
    private static let keptReaderFiles = 6

    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var readerGeneration = 0
    private var listGeneration = 0
    private var isLoadingMore = false
    private var readerKeys: [String] = []

    // MARK: - Lifecycle

    func start(services: SessionServices) {
        self.services = services
        Task { await bootstrap() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var last = MailStoreSignature.current()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let current = MailStoreSignature.current()
                if current != last {
                    last = current
                    await self?.refreshQuietly()
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        searchTask?.cancel(); searchTask = nil
        noticeTask?.cancel(); noticeTask = nil
        readerGeneration += 1
        tearDownReaderSurfaces()
        removeReaderFiles(keeping: 0)
        services = nil
    }

    /// First load, and "Check again" from an empty state.
    func bootstrap() async {
        state = .loading
        guard MailCLI.isInstalled() else {
            state = .notInstalled
            return
        }
        await reloadAll()
    }

    /// Re-checks a blocked widget when Work42 becomes active again (the user may have just flipped a switch in
    /// System Settings).
    func recheckIfBlocked() {
        switch state {
        case .notInstalled, .fdaDenied, .noAccounts, .failed:
            Task { await bootstrap() }
        case .loading, .ready:
            break
        }
    }

    // MARK: - Loading the list

    private func reloadAll() async {
        do {
            tree = try await MailCLI.json([MailAccountTree].self, ["mailbox", "list"])
            try await loadFirstPage(limit: Self.pageSize)
            lastSync = MailTrace.lastSyncDate()
            if tree.isEmpty {
                state = await MailSyncRunner.accessGranted() ? .noAccounts : .fdaDenied
            } else {
                state = .ready
            }
        } catch {
            apply(error)
        }
    }

    /// A refresh that keeps what the user is looking at: same page depth, same selection.
    private func refreshQuietly() async {
        guard state == .ready || state == .noAccounts || state == .fdaDenied else { return }
        do {
            let fresh = try await MailCLI.json([MailAccountTree].self, ["mailbox", "list"])
            tree = fresh
            try await loadFirstPage(limit: min(max(envelopes.count, Self.pageSize), 500))
            lastSync = MailTrace.lastSyncDate()
            if !tree.isEmpty { state = .ready }
        } catch {
            // A quiet refresh never replaces a working list with an error.
        }
    }

    private func apply(_ error: any Error) {
        guard let failure = error as? MailFailure else {
            state = .failed(error.localizedDescription)
            return
        }
        switch failure.code {
        case "not_installed": state = .notInstalled
        case "fda_denied": state = .fdaDenied
        default: state = .failed(failure.message)
        }
    }

    private func loadFirstPage(limit: Int) async throws {
        listGeneration += 1
        let generation = listGeneration
        let page = try await fetch(limit: limit, before: nil)
        guard generation == listGeneration else { return }       // the filters changed while this was loading
        envelopes = page
        canLoadMore = query.trimmingCharacters(in: .whitespaces).isEmpty && page.count >= limit
    }

    /// Called when the mailbox, the unread filter or the search text changed.
    func filtersChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // A short pause so typing doesn't run a search per keystroke.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            do { try await self.loadFirstPage(limit: Self.pageSize) } catch { self.apply(error) }
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
                [MailEnvelope].self, ["envelope", "search", combined, "--limit", String(Self.searchLimit)])
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
        case .mailbox(let id): return mailbox(id).map { "\($0.name)" } ?? "Mailbox"
        }
    }

    /// `12 unread · 4,812 messages · synced 1 min ago`
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
        if let lastSync {
            parts.append("synced \(RelativeDateTimeFormatter().localizedString(for: lastSync, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    private func mailbox(_ id: Int64) -> MailMailbox? { tree.flatMap(\.mailboxes).first { $0.id == id } }

    /// Menu entries for the mailbox picker: ids are `all`, `flagged`, or `mb:<id>`.
    var mailboxMenu: [(id: String, title: String, selected: Bool)] {
        var items: [(String, String, Bool)] = [
            ("all", "All Inboxes", selection == .allInboxes),
            ("flagged", "Flagged", selection == .flagged),
        ]
        for account in tree {
            for box in account.mailboxes {
                let unread = box.unread > 0 ? " (\(box.unread))" : ""
                items.append(("mb:\(box.id)", "\(account.label) · \(box.name)\(unread)", selection == .mailbox(box.id)))
            }
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

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        switch await MailSyncRunner.runOnce() {
        case .synced(let summary):
            show("Synced: +\(summary.added) ~\(summary.updated) −\(summary.removed)")
            await reloadAll()
        case .busy:
            show("A sync is already running")
        case .skippedFresh:
            break
        case .denied:
            if envelopes.isEmpty { state = .fdaDenied } else { show("Full Disk Access isn't granted to mail42") }
        case .notInstalled:
            state = .notInstalled
        case .failed(let message):
            show(message)
        }
    }

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
            struct Saved: Decodable { let path: String }
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
        readerGeneration += 1
        let generation = readerGeneration
        reader = .loading(id)
        attachments = []
        tearDownReaderSurfaces()
        Task { await openReader(id: id, generation: generation) }
    }

    func retryReader() {
        guard let id = selectedID else { return }
        readerGeneration += 1
        let generation = readerGeneration
        reader = .loading(id)
        tearDownReaderSurfaces()
        Task { await openReader(id: id, generation: generation) }
    }

    private func openReader(id: Int64, generation: Int) async {
        do {
            guard let directory = readerDirectory() else {
                throw MailFailure(code: "no_session", message: "This widget has no session folder to show the message from.")
            }
            let key = "\(id)-\(UUID().uuidString.prefix(8).lowercased())"
            let file = directory.appendingPathComponent("m\(key).html")
            async let list = MailCLI.json([MailAttachment].self, ["attachment", "list", String(id)])
            let result = try await MailCLI.json(
                MailReadResult.self, ["message", "read", String(id), "--html", "--out", file.path])
            let listed = (try? await list) ?? []
            guard generation == readerGeneration else {                 // another message was picked meanwhile
                try? FileManager.default.removeItem(at: file)
                return
            }
            attachments = listed
            if result.bodyUnavailable {
                reader = .unavailable(id)
                return
            }
            guard let url = readerURL(fileName: file.lastPathComponent) else {
                throw MailFailure(code: "no_server", message: "Work42's local artifact server isn't answering yet.")
            }
            readerKeys.append("mail42:\(key)")
            reader = .ready(id: id, url: url, key: "mail42:\(key)")
            removeReaderFiles(keeping: Self.keptReaderFiles)
        } catch let failure as MailFailure {
            guard generation == readerGeneration else { return }
            reader = failure.code == "fda_denied" ? .fdaDenied : .failed(id: id, message: failure.message)
        } catch {
            guard generation == readerGeneration else { return }
            reader = .failed(id: id, message: error.localizedDescription)
        }
    }

    /// `<session folder>/artifacts/mail42-reader`: the artifact server serves this folder to the web view.
    private func readerDirectory() -> URL? {
        guard let services else { return nil }
        guard let base = services.sessionId.flatMap({ ArtifactRuntime.directory(forSessionId: $0) }) ?? services.worktreePath,
              !base.isEmpty else { return nil }
        // Make the session known to the artifact server, as meet42's pinned-artifact widgets do.
        if let sessionId = services.sessionId, ArtifactRuntime.directory(forSessionId: sessionId) == nil {
            try? ArtifactRuntime.register(sessionId: sessionId, directory: base)
        }
        let directory = URL(fileURLWithPath: base).appendingPathComponent("artifacts/\(Self.readerArtifactID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func readerURL(fileName: String) -> URL? {
        guard let sessionId = services?.sessionId,
              let base = ArtifactRuntime.url(sessionId: sessionId, artifactId: Self.readerArtifactID) else { return nil }
        return URL(string: base.absoluteString + fileName)
    }

    /// Keeps the newest few reader files; the rest are disposable.
    private func removeReaderFiles(keeping keep: Int) {
        guard let services,
              let base = services.sessionId.flatMap({ ArtifactRuntime.directory(forSessionId: $0) }) ?? services.worktreePath
        else { return }
        let directory = URL(fileURLWithPath: base).appendingPathComponent("artifacts/\(Self.readerArtifactID)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let ordered = files.filter { $0.pathExtension == "html" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in ordered.dropFirst(keep) { try? FileManager.default.removeItem(at: file) }
        if keep == 0 { try? FileManager.default.removeItem(at: directory) }
    }

    private func tearDownReaderSurfaces() {
        for key in readerKeys { BrowserSurfaceCache.shared.teardown(key: key) }
        readerKeys.removeAll()
    }
}
