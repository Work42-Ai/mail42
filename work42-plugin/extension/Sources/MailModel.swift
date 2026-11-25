// MailModel.swift — the Mail widget's state: what's selected, what's loaded, and how the reader gets its HTML.
//
// Everything comes from mail42, which reads Apple Mail's own data live (there is no copy and no sync). The model never
// talks to it itself: it asks the `MailStore` (an actor, see MailStore.swift) and applies the finished, decoded value,
// so nothing on the main thread waits for mail. A list load is cancellable and coalesced (the newest request wins),
// and the list you are looking at stays on screen while a refresh runs.
//
// The model works only while a tile is on screen (`attach`/`detach`, one owner per visible tile, so one tile going away
// never stops it for another). While it works it asks nothing on a timer: mail42's daemon tells it when Mail changed
// (new mail, something read or flagged elsewhere) and it asks again for what it shows. The one exception is waiting for
// Full Disk Access: until it is granted the model checks every couple of seconds so the setup screen goes by itself.

import Foundation
import Observation
import Work42PluginKit
import Work42UI
#if canImport(AppKit)
import AppKit
#endif

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
    #if os(iOS)
    /// The iPad has no disk or loopback server of the Mac's to point a web view at: it is handed the page itself.
    case readyHTML(id: Int64, html: String, key: String)
    #endif
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
    /// Which theme the page was written in; a page from another theme is written again.
    let theme: Int
    /// The themed page itself (the iPad shows it from memory).
    var html: String? = nil
    var unavailable: Bool { file == nil && html == nil }
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
    private(set) var reader: MailReaderState = .none
    private(set) var attachments: [MailAttachment] = []
    /// Every message of the open conversation (all mailboxes, Sent included), oldest first.
    private(set) var thread: [MailEnvelope] = []
    /// The message of the thread whose body is open; the others show as one line.
    private(set) var expandedID: Int64?
    /// Whether the open message shows every address and the full date.
    var showDetails = false
    /// Set when a `mail42://` link points at a message that is no longer in Mail.
    private(set) var missingMessage = false
    /// A link clicked before the tile was ready; it opens once the list has loaded.
    private var pendingLink: URL?
    /// A short, transient message under the toolbar ("Saved report.pdf").
    private(set) var notice: String?

    private(set) var services: SessionServices?
    /// The signed-in Work42 user: their name and photo stand in for "You" and for their own address.
    private(set) var me: WidgetAccountUser?

    private static let pageSize = 50
    private static let searchLimit = 300
    fileprivate static let readerArtifactID = "mail42-reader"
    private static let keptReaders = 8
    private static let accessInterval: Duration = .seconds(2)

    private var watchTask: Task<Void, Never>?
    private var accessTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    /// What opening a message asks for. Opening another message cancels these (the mark-read is not one of them).
    private var readerTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var readerGeneration = 0
    private var listGeneration = 0
    private var isLoadingMore = false

    /// The visible tiles, by owner (and the services each brought). The model works while there is at least one.
    private var owners: Set<UUID> = []
    private var ownerServices: [UUID: SessionServices] = [:]
    private var storeStorage: MailStore?

    @ObservationIgnored private let makeTransport: (SessionServices?) -> any MailTransport
    #if os(macOS)
    @ObservationIgnored private let readerFiles: ReaderFiles
    #endif

    /// - Parameters:
    ///   - makeTransport: how requests reach mail42 (the daemon on the Mac, the paired Mac's shell on the iPad); tests pass a fake.
    ///   - readerFiles: where the reader's HTML lives (macOS); tests pass a temporary folder.
    #if os(macOS)
    init(
        makeTransport: @escaping (SessionServices?) -> any MailTransport = { MailModel.defaultTransport(services: $0) },
        readerFiles: ReaderFiles = .live
    ) {
        self.makeTransport = makeTransport
        self.readerFiles = readerFiles
    }
    #else
    init(makeTransport: @escaping (SessionServices?) -> any MailTransport = { MailModel.defaultTransport(services: $0) }) {
        self.makeTransport = makeTransport
    }
    #endif

    /// Where every question to mail42 goes (see MailStore.swift). Made when first needed, dropped when the last tile goes.
    private var mailStore: MailStore {
        if let storeStorage { return storeStorage }
        let created = MailStore(transport: makeTransport(services))
        storeStorage = created
        return created
    }

    private static func defaultTransport(services: SessionServices?) -> any MailTransport {
        #if os(macOS)
        // The daemon is started through the Work42 shell, which finds `mail42` on its own PATH.
        guard let services else { return MailServeClient() }
        return MailServeClient(startDaemon: MailServeClient.startDaemonCommand(shell: services.shell))
        #else
        guard let services else { return MailUnavailableTransport() }
        let shell = services.shell
        // The Mac pushes `widget:mail/changes` (its Work42 listens to the mail42 service for us); a host that has no such stream
        // finishes it at once, and the transport then falls back to asking for the counters.
        return MailShellTransport(shell: shell, changeStream: { await MainActor.run { services.stream("changes", widget: "widget:mail") } })
        #endif
    }

    /// Messages already written for the reader, oldest first (a small LRU: files and web views are disposable).
    private var readerCache: [Int64: ReaderEntry] = [:]
    private var readerOrder: [Int64] = []

    // MARK: - Lifecycle

    /// A widget instance came up: remember its services (a `mail42://` link or a header button can arrive before the tile
    /// is drawn). Starts nothing: only a tile on screen makes the model work.
    func adopt(services: SessionServices) {
        if self.services == nil { self.services = services }
    }

    /// A tile is on screen. The first one starts the model.
    func attach(owner: UUID, services: SessionServices?) {
        owners.insert(owner)
        if let services {
            ownerServices[owner] = services
            self.services = services
        }
        guard owners.count == 1 else { return }
        begin()
    }

    /// A tile went away. The model stops when the last one has; the others carry on.
    func detach(owner: UUID) {
        guard owners.remove(owner) != nil else { return }
        ownerServices[owner] = nil
        if owners.isEmpty {
            end()
        } else if let remaining = owners.compactMap({ ownerServices[$0] }).first {
            services = remaining
        }
    }

    /// How many tiles are keeping the model working (for tests).
    var attachedCount: Int { owners.count }

    private func begin() {
        guard watchTask == nil else { return }
        if me == nil, let account = services?.account {
            Task { [weak self] in self?.me = await account.currentUser() }
        }
        watchTask = Task { [weak self] in
            await self?.bootstrap()
            guard let self else { return }
            // Nothing is asked on a timer: mail42 says when Mail changed.
            for await _ in self.mailStore.changes() {
                guard !Task.isCancelled else { return }
                await self.mailChanged()
            }
        }
    }

    private func end() {
        watchTask?.cancel(); watchTask = nil
        accessTask?.cancel(); accessTask = nil
        listTask?.cancel(); listTask = nil
        searchTask?.cancel(); searchTask = nil
        noticeTask?.cancel(); noticeTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        readerTask?.cancel(); readerTask = nil
        threadTask?.cancel(); threadTask = nil
        readerGeneration += 1
        dropReaderCache()
        let finished = storeStorage
        storeStorage = nil
        if let finished { Task { await finished.shutdown() } }       // closes the connection: nothing is held while hidden
        services = nil
    }

    /// First load, and the retry after a failure.
    func bootstrap() async {
        if envelopes.isEmpty { state = .loading }
        switch await mailStore.access() {
        case .notInstalled: state = .notInstalled; waitForAccess()
        case .denied: state = .needsAccess; waitForAccess()
        case .noMailData: state = .noMail; waitForAccess()
        case .unreachable(let message): state = .failed(message)
        case .granted: await reloadAll()
        }
    }

    private var isWaitingForAccess: Bool { state == .needsAccess || state == .noMail || state == .notInstalled }

    /// Until Full Disk Access is granted (or Mail has an account) there is nothing for the daemon to tell us about, so
    /// look again every couple of seconds. This is the only timer, and it stops the moment mail is readable.
    private func waitForAccess() {
        guard accessTask == nil else { return }
        accessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.accessInterval)
                guard !Task.isCancelled, let self, self.isWaitingForAccess else { break }
                await self.bootstrap()
            }
            self?.accessTask = nil
        }
    }

    /// Checks again right away when Work42 comes back to the front (the user may just have flipped the switch).
    func recheckNow() {
        switch state {
        case .loading, .ready: break
        case .notInstalled, .needsAccess, .noMail, .failed: Task { await bootstrap() }
        }
    }

    /// mail42 says Mail changed (new mail, something read, flagged, moved or deleted, here or elsewhere): ask again for
    /// the counters and for the list as it is now, at the same depth, so nothing the user is looking at moves.
    private func mailChanged() async {
        guard state == .ready else { return }
        if let fresh = try? await mailStore.json([MailAccountTree].self, ["mailbox", "list"]) { tree = fresh }
        await refreshQuietly()
    }

    // MARK: - Loading the list

    private func reloadAll() async {
        do {
            async let fetchedTree = mailStore.json([MailAccountTree].self, ["mailbox", "list"])
            let page = try await fetch(limit: Self.pageSize, before: nil)
            let loaded = try await fetchedTree
            tree = loaded
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
        case "not_installed": state = .notInstalled; waitForAccess()
        case "fda_denied": state = .needsAccess; waitForAccess()
        case "no_mail_data": state = .noMail; waitForAccess()
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
        try await mailStore.json(
            [MailEnvelope].self, ["envelope", "search", query, "--headers", "--limit", String(Self.searchLimit)],
            priority: .list, timeout: .seconds(30))
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
        return try await mailStore.json([MailEnvelope].self, arguments, priority: .list)
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
            services?.platform.copy(envelope.link ?? "mail42://message/\(envelope.id)")
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
        do {
            _ = try await mailStore.json(MailActionResult.self, arguments, priority: .opened, timeout: .seconds(40))
        } catch { report(error, fallback: failure) }
    }

    /// Read or unread: the dot and the counts change at once; Mail is told in the background, and if it refuses the
    /// change is taken back.
    private func setRead(_ envelope: MailEnvelope, _ read: Bool) async {
        guard envelope.isRead != read else { return }
        applyRead(envelope.id, read, mailboxID: envelope.mailbox.id)
        do {
            _ = try await mailStore.json(
                MailActionResult.self, ["mark", envelope.reference, read ? "read" : "unread"], priority: .opened, timeout: .seconds(40))
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
        }
    }

    private func setFlag(_ envelope: MailEnvelope, _ color: String?) async {
        let before = envelope.isFlagged
        if let index = envelopes.firstIndex(where: { $0.id == envelope.id }) { envelopes[index].isFlagged = color != nil }
        do {
            var arguments = ["mark", envelope.reference, color == nil ? "unflagged" : "flagged"]
            if let color { arguments += ["--color", color] }
            _ = try await mailStore.json(MailActionResult.self, arguments, priority: .opened, timeout: .seconds(40))
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
            _ = try await mailStore.json(MailActionResult.self, arguments, priority: .opened, timeout: .seconds(60))
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
        expandedID = nil
        readerGeneration += 1
        readerTask?.cancel(); readerTask = nil
        threadTask?.cancel(); threadTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        reader = .none
        attachments = []
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
        _ = try? await mailStore.run(["permissions", "open"], priority: .opened, timeout: .seconds(20))
    }

    #if os(iOS)
    /// The attachment would be written on the Mac, where Quick Look is, not on this iPad.
    func quickLook(_ attachment: MailAttachment) async {
        show("Preview it on your Mac, or save it there")
    }

    /// Saves on the Mac (it is the Mac's mail42 that has the file), and says so.
    func saveAttachment(_ attachment: MailAttachment) async {
        guard let id = expandedID ?? selectedID else { return }
        do {
            nonisolated struct Saved: Decodable, Sendable { let path: String }
            let saved = try await mailStore.json(
                Saved.self, ["attachment", "save", String(id), attachment.part, "--to", "~/Downloads"], priority: .opened)
            show("Saved \(URL(fileURLWithPath: saved.path).lastPathComponent) to your Mac\u{2019}s Downloads")
        } catch let failure as MailFailure {
            show(failure.message)
        } catch {
            show(error.localizedDescription)
        }
    }
    #else
    /// Previews an attachment with macOS Quick Look: it is copied to a temporary folder and `qlmanage` shows it.
    func quickLook(_ attachment: MailAttachment) async {
        guard let id = expandedID ?? selectedID else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-quicklook-\(id)", isDirectory: true)
        do {
            nonisolated struct Saved: Decodable, Sendable { let path: String }
            let saved = try await mailStore.json(
                Saved.self, ["attachment", "save", String(id), attachment.part, "--to", folder.path], priority: .opened)
            // `qlmanage -p` stays up until its window is closed, so it is a started command (Work42 stops it with the widget).
            guard let shell = services?.shell else { throw MailFailure(code: "no_shell", message: "Quick Look needs Work42.") }
            _ = try await shell.start(command: "qlmanage -p \(MailCLI.quoted(saved.path)) >/dev/null 2>&1")
        } catch {
            report(error, fallback: "Couldn't preview the attachment")
        }
    }

    func saveAttachment(_ attachment: MailAttachment) async {
        guard let id = expandedID ?? selectedID else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Downloads"
        do {
            nonisolated struct Saved: Decodable, Sendable { let path: String }
            let saved = try await mailStore.json(
                Saved.self, ["attachment", "save", String(id), attachment.part, "--to", downloads], priority: .opened)
            services?.platform.reveal(URL(fileURLWithPath: saved.path))
            show("Saved \(URL(fileURLWithPath: saved.path).lastPathComponent)")
        } catch let failure as MailFailure {
            show(failure.message)
        } catch {
            show(error.localizedDescription)
        }
    }
    #endif

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
        expandedID = id
        showDetails = false
        thread = selectedSnapshot.map { [$0] } ?? []
        showReader(id: id)
        threadTask?.cancel()                                        // the previous message's conversation: no longer wanted
        threadTask = Task { [weak self] in
            guard let self else { return }
            guard let loaded = try? await self.mailStore.json([MailEnvelope].self, ["message", "thread", String(id)], priority: .opened)
            else { return }
            guard !Task.isCancelled, self.selectedID == id, !loaded.isEmpty else { return }
            self.thread = loaded
        }
    }

    /// A message of the conversation was clicked: open it, or close it again if it is the open one (an accordion).
    func toggle(_ id: Int64) {
        if id == expandedID { collapse() } else { expand(id) }
    }

    /// Opens another message of the conversation (a collapsed row was clicked, or ← →).
    func expand(_ id: Int64) {
        guard id != expandedID, let target = thread.first(where: { $0.id == id }) else { return }
        expandedID = id
        showDetails = false
        showReader(id: id)
        if !target.isRead { Task { await setRead(target, true) } }
    }

    /// Folds the open message back to a line; every message of the conversation is then one row.
    func collapse() {
        expandedID = nil
        showDetails = false
        readerGeneration += 1
        readerTask?.cancel(); readerTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        reader = .none
        attachments = []
    }

    /// Back to "no message selected" (Esc, or the Back button above the reader).
    func deselect() {
        missingMessage = false
        clearSelection()
    }

    func moveInThread(by step: Int) {
        guard !thread.isEmpty else { return }
        guard let current = thread.firstIndex(where: { $0.id == expandedID }) else {
            expand(step > 0 ? thread[0].id : thread[thread.count - 1].id)      // all folded: open the first (or last)
            return
        }
        let target = current + step
        if thread.indices.contains(target) { expand(thread[target].id) }
    }

    /// The message whose body is open (it may be an earlier one of the conversation); nil when all are folded.
    var expandedEnvelope: MailEnvelope? {
        guard let expandedID else { return nil }
        return thread.first { $0.id == expandedID } ?? (selectedEnvelope?.id == expandedID ? selectedEnvelope : nil)
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

    // MARK: - mail42:// links

    /// Opens the message a `mail42://message/…` link points at, wherever Mail has put it now.
    func openLink(_ url: URL) async {
        guard state == .ready else { pendingLink = url; return }
        pendingLink = nil
        var arguments = ["message", "resolve", url.absoluteString]
        if case .mailbox(let id) = selection { arguments += ["--prefer-mailbox", String(id)] }
        do {
            let found = try await mailStore.json(MailEnvelope.self, arguments, priority: .opened)
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

    func retryReader() {
        guard let id = selectedID else { return }
        evict(id)
        showReader(id: id)
    }

    private func showReader(id: Int64) {
        readerGeneration += 1
        let generation = readerGeneration
        prefetchTask?.cancel()
        if let entry = readerCache[id] {
            if entry.theme == CanvasTheme.tokensCSS().hashValue {   // already written in this theme: show it at once
                present(entry, id: id)
                touch(id)
                prefetchNeighbors(of: id)
                return
            }
            evict(id)                                               // the theme changed since: write it again
        }
        reader = .loading(id)
        attachments = []
        readerTask?.cancel()                                        // another message's body: no longer wanted
        readerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.prepare(id: id, priority: .opened)
                guard generation == self.readerGeneration, !Task.isCancelled else { return }   // another message was picked meanwhile
                self.store(entry, id: id)
                self.present(entry, id: id)
                self.prefetchNeighbors(of: id)
            } catch is CancellationError {
                return
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
        #if os(iOS)
        if let html = entry.html { reader = .readyHTML(id: id, html: html, key: entry.key) }
        #endif
    }

    #if os(iOS)
    /// Asks the Mac's mail42 for the message with its HTML in the answer (there is no folder to write it to), and
    /// puts it in Work42's theme.
    private func prepare(id: Int64, priority: MailStore.Priority) async throws -> ReaderEntry {
        let key = "\(id)-\(UUID().uuidString.prefix(8).lowercased())"
        async let list = mailStore.json([MailAttachment].self, ["attachment", "list", String(id)], priority: priority)
        let result = try await mailStore.json(MailReadResult.self, ["message", "read", String(id), "--html"], priority: priority)
        let listed = (try? await list) ?? []
        let tokens = CanvasTheme.tokensCSS()
        guard !result.bodyUnavailable, let html = result.html else {
            return ReaderEntry(file: nil, url: nil, key: "mail42:\(key)", attachments: listed, theme: tokens.hashValue)
        }
        let themed = await Task.detached(priority: .userInitiated) { MailBodyTheme.wrap(html, tokens: tokens) }.value
        return ReaderEntry(
            file: nil, url: nil, key: "mail42:\(key)", attachments: listed, theme: tokens.hashValue, html: themed)
    }
    #else
    /// Asks the CLI for the message (HTML to a file, attachments alongside) off the main thread.
    private func prepare(id: Int64, priority: MailStore.Priority) async throws -> ReaderEntry {
        guard let directory = readerDirectory() else {
            throw MailFailure(code: "no_folder", message: "mail42 couldn't prepare a folder to show the message from.")
        }
        let key = "\(id)-\(UUID().uuidString.prefix(8).lowercased())"
        let file = directory.appendingPathComponent("m\(key).html")
        async let list = mailStore.json([MailAttachment].self, ["attachment", "list", String(id)], priority: priority)
        let result = try await mailStore.json(
            MailReadResult.self, ["message", "read", String(id), "--html", "--out", file.path], priority: priority)
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
    #endif

    /// Warms the next message in the list, so stepping down the list is instant. Only that one, and last in line: a guess
    /// never delays what the user asked for, and opening another message cancels it.
    private func prefetchNeighbors(of id: Int64) {
        guard let index = envelopes.firstIndex(where: { $0.id == id }), envelopes.indices.contains(index + 1) else { return }
        let next = envelopes[index + 1].id
        guard readerCache[next] == nil else { return }
        prefetchTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if let entry = try? await self.prepare(id: next, priority: .prefetch), !Task.isCancelled {
                self.store(entry, id: next, becomesNewest: false)
            }
        }
    }

    // MARK: - The reader's files

    #if os(macOS)
    /// Where the reader's HTML lives and how the web view reaches it.
    ///
    /// The HTML lives in mail42's own folder, which is registered with the artifact server under mail42's own id (a
    /// stand-in "session"). The widget therefore works in a session tab and on the session-less workspace home alike
    /// (where `services.sessionId` is nil), and never fills a session's artifact gallery.
    struct ReaderFiles {
        /// The folder a message's page is written to (made if needed); nil when it can't be.
        var directory: () -> URL?
        /// The address the web view loads a written page from; nil while the artifact server isn't answering.
        var url: (String) -> URL?
        /// Deletes every page (when the model stops).
        var removeAll: () -> Void

        private static let hostID = "mail42-reader"
        private static var base: URL {
            RealHome.url.appendingPathComponent(".work42/mail42/reader", isDirectory: true)
        }
        private static var folder: URL { base.appendingPathComponent("artifacts/\(MailModel.readerArtifactID)", isDirectory: true) }

        /// `~/.work42/mail42/reader/artifacts/mail42-reader`, served by the artifact server.
        static let live = ReaderFiles(
            directory: {
                if ArtifactRuntime.directory(forSessionId: hostID) != base.path {
                    try? ArtifactRuntime.register(sessionId: hostID, directory: base.path)
                }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return folder
            },
            url: { fileName in
                guard let served = ArtifactRuntime.url(sessionId: hostID, artifactId: MailModel.readerArtifactID) else { return nil }
                return URL(string: served.absoluteString + fileName)
            },
            removeAll: { try? FileManager.default.removeItem(at: folder) })
    }

    private func readerDirectory() -> URL? { readerFiles.directory() }

    private func readerURL(fileName: String) -> URL? { readerFiles.url(fileName) }
    #endif

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
        // Only the saved HTML goes: the reader web view is one per tile and outlives every message in it.
        if let file = entry.file { try? FileManager.default.removeItem(at: file) }
    }

    private func dropReaderCache() {
        for id in Array(readerCache.keys) { evict(id) }
        #if os(macOS)
        readerFiles.removeAll()
        #endif
    }
}
