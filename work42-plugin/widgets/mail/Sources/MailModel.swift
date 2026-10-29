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

/// The body of one message of the open conversation.
enum MailBodyState: Equatable {
    case loading
    /// The sanitised, themed HTML is on disk and reachable at this URL.
    case ready(URL)
    /// The message has no downloaded body.
    case unavailable
    case needsAccess
    case failed(String)
}

/// One message ready to show: its HTML file, its attachments, or the fact that it has no body.
private struct ReaderEntry {
    let file: URL?
    let url: URL?
    let key: String
    let attachments: [MailAttachment]
    /// Which theme the page was written in; a page from another theme is written again.
    let theme: Int
    var unavailable: Bool { file == nil }
}

@Observable
final class MailModel {

    /// The one model of the Mail42 tile. The header (drawn by Work42 around the tile) and the body must read the SAME
    /// state: with a model per view the header never saw the list the body had loaded (it said "0 unread · 0 messages"
    /// and its buttons stayed dimmed).
    static let shared = MailModel()

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
    /// Every message of the open conversation (all mailboxes, Sent included), oldest first.
    private(set) var thread: [MailEnvelope] = []
    /// The messages of the thread that are open (an accordion each); the others show as one line.
    private(set) var openIDs: Set<Int64> = []
    /// Each opened message's body, and its attachments.
    private(set) var bodies: [Int64: MailBodyState] = [:]
    private(set) var attachmentsByID: [Int64: [MailAttachment]] = [:]
    /// The message showing every address and the full date, if any.
    var detailsID: Int64?
    /// The signed-in Work42 user: their name and photo stand in for "You" and for their own address.
    private(set) var me: WidgetAccountUser?
    /// Set when a `mail42://` link points at a message that is no longer in Mail.
    private(set) var missingMessage = false
    /// A link clicked before the tile was ready; it opens once the list has loaded.
    private var pendingLink: URL?
    /// A short, transient message under the toolbar ("Saved report.pdf").
    private(set) var notice: String?

    private(set) var services: SessionServices?

    private static let pageSize = 50
    private static let searchLimit = 300
    private static let readerArtifactID = "mail42-reader"
    private static let keptReaders = 40
    private static let changeInterval: Duration = .seconds(6)
    private static let accessInterval: Duration = .seconds(2)

    private var watchTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var listGeneration = 0
    private var isLoadingMore = false
    private var treeSignature = ""

    /// Messages already written for the reader, oldest first (a small LRU: files and web views are disposable).
    private var readerCache: [Int64: ReaderEntry] = [:]
    private var readerOrder: [Int64] = []

    // MARK: - Lifecycle

    func start(services: SessionServices) {
        self.services = services
        if me == nil, let account = services.account {
            Task { [weak self] in self?.me = await account.currentUser() }
        }
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
            if state == .ready, let link = pendingLink { await openLink(link) }
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

    /// The typed search, kept to the view you are in (All Inboxes, Flagged, one account's Inbox) and the Unread filter.
    private func scoped(_ text: String) -> String {
        var combined = "(\(text))"
        switch selection {
        case .allInboxes: combined += " in:inbox"
        case .flagged: combined += " is:flagged"
        case .mailbox(let id): combined += " in:\(id)"
        }
        if unreadOnly { combined += " is:unread" }
        return combined
    }

    /// Searches the headers only (subject, sender, recipients, the preview line, dates, state): the answer is complete
    /// and instant. Reading the text of 160,000 messages is not something a tile can wait for.
    private func search(_ query: String) async throws -> [MailEnvelope] {
        try await MailCLI.json(
            [MailEnvelope].self, ["envelope", "search", query, "--headers", "--limit", String(Self.searchLimit)],
            timeout: 30)
    }

    private func fetch(limit: Int, before: Int64?) async throws -> [MailEnvelope] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            do {
                return try await search(scoped(text))
            } catch let failure as MailFailure where failure.code == "bad_query" {
                // Not valid search syntax (a stray colon or bracket): search the words exactly as typed instead.
                let literal = text.split(whereSeparator: \.isWhitespace)
                    .map { "\"" + $0.replacingOccurrences(of: "\"", with: " ") + "\"" }
                    .joined(separator: " ")
                return try await search(scoped(literal))
            }
        }
        var arguments = ["envelope", "list", "--conversations", "--limit", String(limit)]
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

    /// The inbox switcher: All Inboxes, Flagged, then each account's Inbox named as Mail names the account (each
    /// with its unread count), then the Unread Only switch. Anything else is a search (`in:`). Ids are `all`,
    /// `flagged`, `mb:<id>` and `unread`.
    var mailboxMenu: [(id: String, title: String, icon: String?, selected: Bool)] {
        let inboxes = tree.flatMap(\.mailboxes).filter { $0.role == "inbox" }
        var items: [(String, String, String?, Bool)] = [
            ("all", "All Inboxes" + Self.badge(inboxes.reduce(0) { $0 + $1.unread }), "tray.2", selection == .allInboxes),
            ("flagged", "Flagged", "flag", selection == .flagged),
        ]
        for account in tree {
            guard let inbox = account.mailboxes.first(where: { $0.role == "inbox" }) else { continue }
            items.append((
                "mb:\(inbox.id)", account.account.name + Self.badge(inbox.unread), "tray", selection == .mailbox(inbox.id)))
        }
        items.append(("unread", "Unread Only", "envelope.badge", unreadOnly))
        return items
    }

    /// The switcher button's label: the view you are in, with its unread count.
    var switcherTitle: String {
        switch selection {
        case .allInboxes: return "All Inboxes" + Self.badge(tree.flatMap(\.mailboxes).filter { $0.role == "inbox" }.reduce(0) { $0 + $1.unread })
        case .flagged: return "Flagged"
        case .mailbox(let id):
            guard let box = mailbox(id) else { return "Mailbox" }
            let account = tree.first { $0.mailboxes.contains { $0.id == id } }?.account.name
            return (box.role == "inbox" ? account : nil).map { $0 + Self.badge(box.unread) } ?? box.name
        }
    }

    private static func badge(_ unread: Int64) -> String { unread > 0 ? " (\(unread.formatted()))" : "" }

    func chooseMailbox(menuID: String) {
        switch menuID {
        case "all": selection = .allInboxes
        case "flagged": selection = .flagged
        case "unread": toggleUnread(); return
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

    /// Everything a person can do with a message, from the header, the More menu, a right-click or a shortcut.
    enum MailAction: Equatable {
        case reply, replyAll, forward
        case archive, delete, junk
        case move(Int64)
        case markRead(Bool)
        /// A flag colour (Mail's names), or nil to clear the flag.
        case flag(String?)
        case copyLink, openInMail, newMessage
    }

    /// The names of Mail's seven flag colours, in its order.
    static let flagColors = ["red", "orange", "yellow", "green", "blue", "purple", "gray"]

    /// The mailboxes of the open message's own account (the places Move can send it to).
    var moveTargets: [MailMailbox] {
        guard let envelope = selectedEnvelope else { return [] }
        let boxes = tree.first { $0.account.id == envelope.account.id }?.mailboxes ?? []
        return boxes.filter { $0.id != envelope.mailbox.id }
    }

    func perform(_ action: MailAction) async {
        switch action {
        case .newMessage:
            await run(["draft", "new"], failure: "Couldn't open a new message in Mail")
            return
        default: break
        }
        guard let envelope = selectedEnvelope else { return }
        let ref = envelope.reference
        switch action {
        case .reply: await run(["draft", "reply", ref], failure: "Couldn't start the reply")
        case .replyAll: await run(["draft", "reply-all", ref], failure: "Couldn't start the reply")
        case .forward: await run(["draft", "forward", ref], failure: "Couldn't start the forward")
        case .openInMail: await run(["open", String(envelope.id)], failure: "Couldn't open the message in Mail")
        case .copyLink:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(envelope.link ?? "mail42://message/\(envelope.id)", forType: .string)
            show("Link copied")
        case .markRead(let read): await setRead(envelope, read)
        case .flag(let color): await setFlag(envelope, color)
        case .archive: await relocate(envelope, ["archive", ref], done: "Archived")
        case .delete: await relocate(envelope, ["delete", ref], done: "Moved to Trash")
        case .junk: await relocate(envelope, ["junk", ref], done: "Marked as junk")
        case .move(let id):
            let name = mailbox(id)?.name ?? "mailbox"
            await relocate(envelope, ["move", ref, String(id)], done: "Moved to \(name)")
        case .newMessage: break
        }
    }

    /// Runs a verb that opens something in Mail (a draft, a message): there is nothing to change in the list.
    private func run(_ arguments: [String], failure: String) async {
        do { _ = try await MailCLI.json(MailActionResult.self, arguments, timeout: 40) } catch { report(error, fallback: failure) }
    }

    /// Read or unread: the dot and the counts change at once; Mail is told in the background, and if it refuses the
    /// change is taken back.
    private func setRead(_ envelope: MailEnvelope, _ read: Bool) async {
        guard envelope.isRead != read else { return }
        applyRead(envelope.id, read, mailboxID: envelope.mailbox.id)
        do {
            _ = try await MailCLI.json(MailActionResult.self, ["mark", envelope.reference, read ? "read" : "unread"], timeout: 40)
        } catch {
            applyRead(envelope.id, !read, mailboxID: envelope.mailbox.id)
            report(error, fallback: "Couldn't change the message in Mail")
        }
    }

    private func applyRead(_ id: Int64, _ read: Bool, mailboxID: Int64) {
        var changed = false
        if let index = envelopes.firstIndex(where: { $0.id == id }), envelopes[index].isRead != read {
            envelopes[index].isRead = read
            changed = true
        }
        if let index = thread.firstIndex(where: { $0.id == id }), thread[index].isRead != read {
            thread[index].isRead = read
            changed = true
        }
        if changed { adjustUnread(mailboxID, by: read ? -1 : 1) }
    }

    private func adjustUnread(_ mailboxID: Int64, by delta: Int64) {
        for account in tree.indices {
            guard let box = tree[account].mailboxes.firstIndex(where: { $0.id == mailboxID }) else { continue }
            tree[account].mailboxes[box].unread = max(0, tree[account].mailboxes[box].unread + delta)
            treeSignature = Self.signature(of: tree)               // our own change is not "news" for the watcher
        }
    }

    private func setFlag(_ envelope: MailEnvelope, _ color: String?) async {
        let before = envelope.isFlagged
        if let index = envelopes.firstIndex(where: { $0.id == envelope.id }) { envelopes[index].isFlagged = color != nil }
        do {
            var arguments = ["mark", envelope.reference, color == nil ? "unflagged" : "flagged"]
            if let color { arguments += ["--color", color] }
            _ = try await MailCLI.json(MailActionResult.self, arguments, timeout: 40)
        } catch {
            if let index = envelopes.firstIndex(where: { $0.id == envelope.id }) { envelopes[index].isFlagged = before }
            report(error, fallback: "Couldn't change the flag in Mail")
        }
    }

    /// Archive, delete, junk, move: the conversation leaves the list at once and the next one is opened; if Mail
    /// refuses, the list is reloaded so it shows what is really there.
    private func relocate(_ envelope: MailEnvelope, _ arguments: [String], done: String) async {
        let position = envelopes.firstIndex { $0.id == envelope.id }
        envelopes.removeAll { $0.id == envelope.id }
        if !envelope.isRead { adjustUnread(envelope.mailbox.id, by: -1) }
        if selectedID == envelope.id {
            let next = position.flatMap { envelopes.indices.contains($0) ? envelopes[$0] : envelopes.last }
            if let next { select(next.id) } else { clearSelection() }
        }
        do {
            _ = try await MailCLI.json(MailActionResult.self, arguments, timeout: 60)
            show(done)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.refreshQuietly()
            }
        } catch {
            report(error, fallback: "Mail couldn't do that")
            await refreshQuietly()
        }
    }

    private func clearSelection() {
        selectedID = nil
        selectedSnapshot = nil
        thread = []
        openIDs = []
        bodies = [:]
        attachmentsByID = [:]
        detailsID = nil
    }

    /// Says why an action failed, in one line (the CLI's own words when it has them).
    private func report(_ error: any Error, fallback: String) {
        if let failure = error as? MailFailure {
            switch failure.code {
            case "automation_denied", "mail_timeout", "no_archive_mailbox": show(failure.message)
            default: show(fallback + ": " + failure.message)
            }
        } else {
            show(fallback)
        }
    }

    func openSelectedInMail() async { await perform(.openInMail) }

    func openFullDiskAccessSettings() async {
        _ = await MailCLI.run(["permissions", "open"], timeout: 20)
    }

    /// Previews an attachment with macOS Quick Look: it is copied to a temporary folder and `qlmanage` shows it.
    func quickLook(_ attachment: MailAttachment, in id: Int64) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-quicklook-\(id)", isDirectory: true)
        do {
            nonisolated struct Saved: Decodable, Sendable { let path: String }
            let saved = try await MailCLI.json(
                Saved.self, ["attachment", "save", String(id), attachment.part, "--to", folder.path])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            process.arguments = ["-p", saved.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            report(error, fallback: "Couldn't preview the attachment")
        }
    }

    func saveAttachment(_ attachment: MailAttachment, in id: Int64) async {
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
        missingMessage = false
        selectedID = id
        selectedSnapshot = envelopes.first { $0.id == id }
        beginReading(id: id)
        // Opening a message reads it: the dot goes at once, and Mail is told in the background.
        if let envelope = selectedSnapshot, !envelope.isRead { Task { await setRead(envelope, true) } }
    }

    /// Opens `id` in the reader and loads its conversation.
    private func beginReading(id: Int64) {
        openIDs = [id]
        bodies = [:]
        attachmentsByID = [:]
        detailsID = nil
        thread = selectedSnapshot.map { [$0] } ?? []
        ensureBody(id)
        Task { [weak self] in
            guard let loaded = try? await MailCLI.json([MailEnvelope].self, ["message", "thread", String(id)]) else { return }
            guard let self, self.selectedID == id, !loaded.isEmpty else { return }
            self.thread = loaded
        }
    }

    /// A message of the conversation was clicked: open it, or fold it again (an accordion).
    func toggle(_ id: Int64) {
        if openIDs.contains(id) {
            openIDs.remove(id)
            if detailsID == id { detailsID = nil }
        } else {
            open(id)
        }
    }

    /// Opens a message of the conversation in place (a row was clicked, or scrolling reached the next one).
    func open(_ id: Int64) {
        guard !openIDs.contains(id),
              let target = thread.first(where: { $0.id == id }) ?? (selectedEnvelope?.id == id ? selectedEnvelope : nil)
        else { return }
        openIDs.insert(id)
        if bodies[id] == nil { ensureBody(id) }
        if !target.isRead { Task { await setRead(target, true) } }
    }

    /// Back to "no message selected" (Esc, or the Back button above the reader).
    func deselect() {
        missingMessage = false
        clearSelection()
    }

    // MARK: - You

    /// Whether this address is the signed-in user's (Work42 account or the mail account the message sits in).
    func isMyAddress(_ address: String?, in envelope: MailEnvelope) -> Bool {
        guard let address = address?.lowercased(), !address.isEmpty else { return false }
        return address == me?.email?.lowercased() || address == envelope.account.email?.lowercased()
    }

    /// The name shown for a person: the user's Work42 name for their own address, else the mail's own.
    func name(of person: MailPerson, in envelope: MailEnvelope) -> String {
        if isMyAddress(person.addr, in: envelope), let mine = me?.displayName, !mine.isEmpty { return mine }
        return person.display
    }

    /// The name shown for the sender of a message ("You" only if Work42 doesn't know the user's name).
    func senderName(_ envelope: MailEnvelope) -> String {
        if isMine(envelope) { return me?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "You" }
        return envelope.from.display
    }

    /// How many unread messages the current view holds, for the empty state's one-line summary.
    var unreadInView: Int64 {
        switch selection {
        case .allInboxes: return tree.flatMap(\.mailboxes).filter { $0.role == "inbox" }.reduce(0) { $0 + $1.unread }
        case .flagged: return 0
        case .mailbox(let id): return mailbox(id)?.unread ?? 0
        }
    }

    /// True when the open message was reached by a link and the list is showing something else.
    var isOutsideView: Bool {
        guard let selectedID else { return false }
        return !envelopes.contains { $0.id == selectedID }
    }

    /// Whether a message is the user's own (Sent, or from the account's address): drawn in the "You" colour.
    func isMine(_ envelope: MailEnvelope) -> Bool {
        if envelope.mailbox.role == "sent" { return true }
        guard let mine = envelope.account.email?.lowercased(), let from = envelope.from.addr?.lowercased() else { return false }
        return mine == from
    }

    // MARK: - mail42:// links

    /// Opens the message a `mail42://message/…` link points at, wherever Mail has put it now.
    func openLink(_ url: URL) async {
        guard state == .ready else { pendingLink = url; return }
        pendingLink = nil
        var arguments = ["message", "resolve", url.absoluteString]
        if case .mailbox(let id) = selection { arguments += ["--prefer-mailbox", String(id)] }
        do {
            let found = try await MailCLI.json(MailEnvelope.self, arguments)
            missingMessage = false
            if envelopes.contains(where: { $0.id == found.id }) {
                select(found.id)
            } else {
                // Not in this list (another mailbox, or archived): open it anyway; the list stays as it is.
                guard found.id != selectedID else { return }
                selectedID = found.id
                selectedSnapshot = found
                beginReading(id: found.id)
                if !found.isRead { Task { await setRead(found, true) } }
            }
        } catch let failure as MailFailure where failure.code == "not_found" {
            clearSelection()
            missingMessage = true
        } catch {
            report(error, fallback: "Couldn't open that message")
        }
    }

    /// Moves the selection to the row above (-1) or below (+1) the open one.
    func moveSelection(by step: Int) {
        guard !envelopes.isEmpty else { return }
        let current = envelopes.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : envelopes.count)
        let target = min(max(current + step, 0), envelopes.count - 1)
        select(envelopes[target].id)
    }

    /// Loads a message's body again (the "Try again" button).
    func retryBody(_ id: Int64) {
        evict(id)
        bodies[id] = nil
        ensureBody(id)
    }

    /// Makes sure the body of `id` is being prepared (or is ready): `bodies[id]` says where it is.
    private func ensureBody(_ id: Int64) {
        let conversation = selectedID
        if conversation == id { prefetchTask?.cancel() }
        if let entry = readerCache[id] {
            if entry.theme == CanvasTheme.tokensCSS().hashValue {   // already written in this theme: show it at once
                apply(entry, id: id)
                touch(id)
                if conversation == id { prefetchNeighbors(of: id) }
                return
            }
            evict(id)                                               // the theme changed since: write it again
        }
        bodies[id] = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.prepare(id: id)
                guard self.selectedID == conversation else { return }       // another conversation was picked meanwhile
                self.store(entry, id: id)
                self.apply(entry, id: id)
                if conversation == id { self.prefetchNeighbors(of: id) }
            } catch let failure as MailFailure {
                guard self.selectedID == conversation else { return }
                self.bodies[id] = failure.code == "fda_denied" ? .needsAccess : .failed(failure.message)
            } catch {
                guard self.selectedID == conversation else { return }
                self.bodies[id] = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ entry: ReaderEntry, id: Int64) {
        attachmentsByID[id] = entry.attachments
        if entry.unavailable {
            bodies[id] = .unavailable
        } else if let url = entry.url {
            bodies[id] = .ready(url)
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
        let tokens = CanvasTheme.tokensCSS()
        let stamp = tokens.hashValue
        if result.bodyUnavailable {
            try? FileManager.default.removeItem(at: file)
            return ReaderEntry(file: nil, url: nil, key: "mail42:\(key)", attachments: listed, theme: stamp)
        }
        // Put the message in Work42's theme (see MailBodyTheme), off the main thread: a newsletter can be megabytes.
        await Task.detached(priority: .userInitiated) {
            guard let html = try? String(contentsOf: file, encoding: .utf8) else { return }
            try? MailBodyTheme.wrap(html, tokens: tokens).write(to: file, atomically: true, encoding: .utf8)
        }.value
        guard let url = readerURL(fileName: file.lastPathComponent) else {
            throw MailFailure(code: "no_server", message: "Work42's local artifact server isn't answering yet.")
        }
        return ReaderEntry(file: file, url: url, key: "mail42:\(key)", attachments: listed, theme: stamp)
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
