// MailDirectTransport.swift — the widget's `MailTransport` with no CLI and no daemon behind it (WOR-900).
//
// `MailModel` and `MailStore` ask Mail for everything by sending the `mail42` command line's argument vectors (`envelope list
// --conversations --limit 50 -m all`, `message read 48213 --html --out …`, `mark <link> read`) and decoding the JSON the CLI printed.
// This transport takes those same vectors and answers them from `MailCtl.Controller`, with the JSON the CLI printed (same keys, ISO-8601
// dates, explicit nulls) or its `{"error":{"code","message"}}` envelope and exit status, so the widget needs no change but the
// transport it is given. Output is always JSON, as if `--json` were present; without the flag only the error text changes (stderr).
//
// What the extension cannot do is answered with a typed failure instead of being faked:
//   `attachment save`            on the Mac it writes the bytes `MailCtl.Controller.attachmentData` returns into `--to <dir>`, but only
//                                where `MailCtl.SaveFolders` allows (Downloads, the Quick Look folder): `path_not_allowed` anywhere
//                                else. On the iPad it is `unsupported_in_extension` (there is no disk to write to).
//   `permissions open`           `unsupported_in_extension`: nothing in the extension can open System Settings.
//   `permissions automation`     `unsupported_in_extension`: macOS does not tell an extension its Automation state; an action that
//                                is refused answers `automation_denied`.
// `serve` and any other verb are `usage` failures.

import Darwin
import Foundation
import Work42PluginKit

nonisolated extension MailCtl {

    /// Where a file called `name` goes when saved into `directory`, or `path_not_allowed`: `directory` must be inside one of
    /// `folders.roots`, or be a folder `<prefix>…` made directly inside one of `folders.children`' parents (not a link, no `..`).
    /// Nothing is created. The result is the resolved path (symbolic links resolved): write there, not to the path as given.
    static func containedSave(directory: URL, name: String, folders: SaveFolders) throws -> URL {
        let file = directory.appendingPathComponent(name)
        if let inside = try? containedOutput(file, roots: folders.roots) { return inside }
        let parts = directory.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let last = parts.last, !parts.contains("..") {
            let parent = URL(fileURLWithPath: "/" + parts.dropLast().joined(separator: "/"), isDirectory: true)
            var info = Darwin.stat()
            let isLink = lstat(directory.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
            for child in folders.children where !isLink && last.hasPrefix(child.prefix) && last.count > child.prefix.count
                && parent.resolvingSymlinksInPath().path == child.parent.resolvingSymlinksInPath().path {
                return try containedOutput(file, roots: [directory])
            }
        }
        return try containedOutput(file, roots: [])      // refused, with the reason `path_not_allowed` carries
    }
}

nonisolated final class MailCtlDirectTransport: MailTransport, Sendable {

    private let controller: MailCtl.Controller
    private let pollInterval: Duration
    private let saveFolders: MailCtl.SaveFolders
    private let streams = Streams()
    private let beforeSaveOpen: (@Sendable (URL) -> Void)?

    /// - Parameters:
    ///   - controller: the session's controller.
    ///   - pollInterval: how often `changes()` looks at the mailbox counters while someone is consuming it.
    ///   - saveFolders: where `attachment save` may write (nowhere by default).
    ///   - beforeSaveOpen: a test hook, called with the validated folder after `attachment save` checked it and before it is opened.
    init(
        controller: MailCtl.Controller, pollInterval: Duration = .seconds(4), saveFolders: MailCtl.SaveFolders = MailCtl.SaveFolders(),
        beforeSaveOpen: (@Sendable (URL) -> Void)? = nil
    ) {
        self.controller = controller
        self.pollInterval = pollInterval
        self.saveFolders = saveFolders
        self.beforeSaveOpen = beforeSaveOpen
    }

    convenience init(
        disk: any WidgetDiskReadService, automation: any WidgetAutomationService, directory: URL,
        configuration: MailCtl.Configuration = MailCtl.Configuration(), pollInterval: Duration = .seconds(4)
    ) {
        self.init(
            controller: MailCtl.Controller(disk: disk, automation: automation, directory: directory, configuration: configuration),
            pollInterval: pollInterval, saveFolders: configuration.saveFolders)
    }

    // MARK: MailTransport

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        try Task.checkCancellation()
        let json = arguments.contains("--json")
        do {
            return try await dispatch(arguments, json: json)
        } catch let escape as Escape {
            throw escape.failure
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            let failure = (MailCtl.failure(from: error) as? MailFailure) ?? MailFailure(code: "error", message: error.localizedDescription)
            return Self.failed(failure, json: json)
        }
    }

    /// A signal each time the mailbox changed: a counter moved, or Apple's index file did (a flag, or a read that leaves the unread
    /// counter alone). The first state is what is there now (the widget has just read it); each later different one is a change,
    /// and carries the mailbox signature. It is looked at only while the stream has a consumer.
    func changes() -> AsyncStream<String> {
        let controller = controller
        let interval = pollInterval
        let streams = streams
        return AsyncStream { continuation in
            let id = UUID()
            let task = Task {
                var last: MailCtl.ChangeToken?
                while !Task.isCancelled {
                    if let token = try? await controller.changeToken() {
                        if let last, token != last, !token.signature.isEmpty { continuation.yield(token.signature) }
                        last = token
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            streams.add(id, task)
            continuation.onTermination = { _ in
                task.cancel()
                streams.remove(id)
            }
        }
    }

    /// Ends every `changes()` stream and lets go of the open index. The transport can be used again.
    func close() {
        streams.cancelAll()
        let controller = controller
        Task { await controller.close() }
    }

    // MARK: Streams

    private final class Streams: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [UUID: Task<Void, Never>] = [:]

        func add(_ id: UUID, _ task: Task<Void, Never>) { lock.withLock { tasks[id] = task } }
        func remove(_ id: UUID) { lock.withLock { _ = tasks.removeValue(forKey: id) } }
        func cancelAll() {
            let all = lock.withLock { () -> [Task<Void, Never>] in
                let copy = Array(tasks.values)
                tasks = [:]
                return copy
            }
            for task in all { task.cancel() }
        }
    }

    /// A failure `run` throws instead of answering (a transport-level one, like the shell transport's `mac_unreachable`).
    private struct Escape: Error { let failure: MailFailure }

    // MARK: Dispatch

    private func dispatch(_ args: [String], json: Bool) async throws -> MailCLIResult {
        guard let verb = args.first else { throw Self.usage("usage: mail42 <verb> …") }
        let rest = Array(args.dropFirst())
        switch verb {
        case "mailbox": return try await mailbox(rest)
        case "envelope": return try await envelope(rest)
        case "message": return try await message(rest)
        case "attachment": return try await attachment(rest)
        case "mark", "move", "archive", "delete", "junk", "draft": return try await action(verb, rest)
        case "open": return try await open(rest)
        case "permissions": return try await permissions(rest)
        default: throw Self.usage("unknown command `\(verb)`")
        }
    }

    // MARK: mailbox

    private func mailbox(_ args: [String]) async throws -> MailCLIResult {
        guard Args.positionals(args).first == "list" else { throw Self.usage("usage: mailbox list [--json]") }
        let trees = try await controller.mailboxTree()
        return try Self.success(trees.map(JSON.tree))
    }

    // MARK: envelope

    private static let envelopeValueFlags: Set<String> = ["-m", "--mailbox", "--limit", "--before"]

    private func envelope(_ args: [String]) async throws -> MailCLIResult {
        let words = Args.positionals(args, valueFlags: Self.envelopeValueFlags)
        switch words.first {
        case "list":
            var options = MailCtl.ListOptions()
            options.limit = try Args.intFlag(args, "--limit", min: 1) ?? 50
            options.unreadOnly = args.contains("--unread")
            options.flaggedOnly = args.contains("--flagged")
            options.conversations = args.contains("--conversations")
            if let before = Args.value(args, "--before") {
                guard let id = Int64(before) else { throw Self.usage("--before takes an envelope id, not `\(before)`") }
                options.beforeID = id
            }
            if let mailbox = Args.value(args, "-m") ?? Args.value(args, "--mailbox") {
                options.mailbox = MailCtl.ListOptions.selector(mailbox)
            }
            return try Self.success(try await controller.list(options).map(JSON.envelope))
        case "search":
            // `envelope search from:alice is:unread` works unquoted too: the words are joined into one query.
            let query = words.dropFirst().joined(separator: " ")
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Self.usage("usage: envelope search \"<query>\" [--limit N]")
            }
            let limit = try Args.intFlag(args, "--limit", min: 1) ?? 50
            let outcome = try await controller.search(query, limit: limit, headersOnly: args.contains("--headers"))
            var result = try Self.success(outcome.records.map(JSON.envelope))
            // On stderr, so the JSON stays a plain array: how far back the message text was searched.
            if let note = outcome.note { result = MailCLIResult(status: 0, stdout: result.stdout, stderr: "mail42: \(note)\n") }
            return result
        default:
            throw Self.usage("usage: envelope list [-m <mailbox>] [--conversations] … | envelope search \"<query>\" [--limit N]")
        }
    }

    // MARK: message

    private func message(_ args: [String]) async throws -> MailCLIResult {
        let words = Args.positionals(args, valueFlags: ["--out", "--prefer-mailbox"])
        switch words.first {
        case "read": return try await read(args, words)
        case "thread":
            let id = try Args.messageID(words.dropFirst().first)
            return try Self.success(try await controller.thread(id).map(JSON.envelope))
        case "resolve":
            guard let text = words.dropFirst().first, MailCtl.Link(string: text) != nil else {
                throw Self.usage("usage: message resolve <mail42://message/\u{2026} link | id> [--prefer-mailbox <id>]")
            }
            var preferred: Int64?
            if let value = Args.value(args, "--prefer-mailbox") {
                guard let id = Int64(value) else { throw Self.usage("--prefer-mailbox takes a mailbox id, not `\(value)`") }
                preferred = id
            }
            return try Self.success(JSON.envelope(try await controller.resolve(text, preferMailbox: preferred)))
        default:
            throw Self.usage(
                "usage: message read <id> [--text|--html|--headers] [--out <file>] | message thread <id> | message resolve <link|id> [--prefer-mailbox <id>]")
        }
    }

    private func read(_ args: [String], _ words: [String]) async throws -> MailCLIResult {
        let id = try Args.messageID(words.dropFirst().first)
        let requested: [MailCtl.ReadMode] = [args.contains("--text") ? .text : nil, args.contains("--html") ? .html : nil,
                                             args.contains("--headers") ? .headers : nil].compactMap { $0 }
        guard requested.count <= 1 else { throw Self.usage("choose one of --text, --html, --headers") }
        let mode = requested.first ?? .text

        if let out = Args.value(args, "--out") {
            let file = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            let written = try await controller.read(id, mode: mode, out: file)
            return try Self.success(["path": JSON.orNull(written.path), "body_unavailable": written.bodyUnavailable] as [String: Any])
        }
        let message = try await controller.message(id, mode: mode)
        return try Self.success([
            "envelope": JSON.envelope(message.envelope),
            "headers": message.headers,
            "text": JSON.orNull(mode == .text ? message.content : nil),
            "html": JSON.orNull(mode == .html ? message.content : nil),
            "attachments": message.attachments.map(JSON.attachment),
            "body_unavailable": message.bodyUnavailable,
        ] as [String: Any])
    }

    // MARK: attachment

    private func attachment(_ args: [String]) async throws -> MailCLIResult {
        let words = Args.positionals(args, valueFlags: ["--to"])
        switch words.first {
        case "list":
            let id = try Args.messageID(words.dropFirst().first)
            return try Self.success(try await controller.attachments(id).map(JSON.attachment))
        case "save":
            #if os(iOS)
            throw MailFailure(
                code: "unsupported_in_extension",
                message: "The Mail plugin can\u{2019}t save an attachment on this device: there is no disk to write to.")
            #else
            return try await save(args, words)
            #endif
        default:
            throw Self.usage("usage: attachment list <id> | attachment save <id> <part> [--to <dir>]")
        }
    }

    #if !os(iOS)
    /// `attachment save <id> <part> --to <dir>`: the attachment's bytes in a file of `dir` that did not exist (`report.pdf`, then
    /// `report (1).pdf`, …), and `{"path","bytes"}` as the CLI printed. `dir` must be one `saveFolders` allows.
    private func save(_ args: [String], _ words: [String]) async throws -> MailCLIResult {
        let id = try Args.messageID(words.dropFirst().first)
        guard words.count >= 3 else { throw Self.usage("usage: attachment save <id> <part> --to <dir>") }
        let part = words[2]
        guard let to = Args.value(args, "--to") else { throw Self.usage("attachment save needs --to <dir>") }
        let directory = URL(fileURLWithPath: (to as NSString).expandingTildeInPath, isDirectory: true)
        // Refused before anything is read, whatever the message holds (the name is only known after the read).
        _ = try MailCtl.containedSave(directory: directory, name: "attachment", folders: saveFolders)
        let attachment = try await controller.attachmentData(id: id, part: part)
        let target = try MailCtl.containedSave(directory: directory, name: attachment.filename, folders: saveFolders)
        let folder = target.deletingLastPathComponent()      // resolved: a link made after the check does not lead the write elsewhere
        beforeSaveOpen?(folder)
        // From here on nothing is addressed by path: the folder is walked from the allowed root one component at a time with
        // descriptors (no link is followed), and the file is made and, if need be, removed relative to the folder's descriptor.
        let folderDescriptor = try Self.openContainedFolder(folder.path, shown: directory, folders: saveFolders)
        defer { Darwin.close(folderDescriptor) }
        for attempt in 0..<1000 {
            let name = MailBodyAttachment.numberedName(attachment.filename, attempt: attempt)
            guard !name.contains("/") else {
                throw MailFailure(code: "write_failed", message: "Couldn\u{2019}t write \(name) in \(directory.path): the name has a `/`.")
            }
            let descriptor = Darwin.openat(folderDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw MailFailure(code: "write_failed", message: "Couldn\u{2019}t write \(name) in \(directory.path): \(String(cString: strerror(errno))).")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: attachment.data)
                try handle.close()
            } catch {
                _ = Darwin.unlinkat(folderDescriptor, name, 0)
                throw MailFailure(code: "write_failed", message: "Couldn\u{2019}t write \(name) in \(directory.path): \(error.localizedDescription)")
            }
            return try Self.success(["path": directory.appendingPathComponent(name).path, "bytes": attachment.data.count] as [String: Any])
        }
        throw MailFailure(code: "write_failed", message: "Couldn\u{2019}t find a free name for \(attachment.filename) in \(directory.path).")
    }

    /// `path` with its symbolic links resolved (`realpath`) as far as it exists, the part not there yet appended as it is. Nil when
    /// nothing of it can be resolved.
    private static func realResolving(_ path: String) -> String? {
        var head = path
        var rest: [String] = []
        while true {
            if let real = realpath(head, nil) {
                defer { free(real) }
                var resolved = String(cString: real)
                for part in rest.reversed() { resolved += (resolved == "/" ? "" : "/") + part }
                return resolved
            }
            guard errno == ENOENT, head != "/", let slash = head.lastIndex(of: "/") else { return nil }
            rest.append(String(head[head.index(after: slash)...]))
            head = slash == head.startIndex ? "/" : String(head[..<slash])
        }
    }

    /// The components of `path` below `root` (none when they are the same folder), or nil when `path` is not inside it.
    private static func components(of path: String, below root: String) -> [String]? {
        if path == root { return [] }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// The real path of an open descriptor (`F_GETPATH`).
    private static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// A descriptor on `path`, a folder `saveFolders` allows, opened without going through any link below the allowed root: the
    /// root is opened and checked to be the folder the validation resolved, then each component below it is opened with
    /// `openat(…, O_NOFOLLOW)` (made with `mkdirat` when missing). Whatever another process renames or replaces by a link after
    /// the validation is met with `O_NOFOLLOW` and refused (`path_not_allowed`); nothing is written. The caller closes it.
    private static func openContainedFolder(_ path: String, shown: URL, folders: MailCtl.SaveFolders) throws -> Int32 {
        func refused(_ why: String) -> MailFailure {
            MailFailure(code: "path_not_allowed", message: "Won\u{2019}t write in \(shown.path): \(why).")
        }
        // `path` is the folder as `containedSave` resolved it. It is not resolved again here (that would look through whatever
        // was swapped in since): it is split below a root, and that part is walked with descriptors. A root is known by the
        // spellings the validation may have used for it (`realpath`, and Foundation's, which leaves out `/private`).
        func spellings(_ url: URL) -> (real: String, forms: [String])? {
            guard let real = realResolving(url.standardizedFileURL.path) else { return nil }
            return (real, [real, url.standardizedFileURL.resolvingSymlinksInPath().path])
        }
        var chosen: (root: String, below: [String])?
        for root in folders.roots.compactMap(spellings) {
            if let below = root.forms.lazy.compactMap({ components(of: path, below: $0) }).first { chosen = (root.real, below); break }
        }
        if chosen == nil {
            // A folder made for one use: `<prefix>…` directly in its parent, nothing deeper.
            for child in folders.children {
                guard let parent = spellings(child.parent),
                      let below = parent.forms.lazy.compactMap({ components(of: path, below: $0) }).first, below.count == 1,
                      let name = below.first, name.hasPrefix(child.prefix), name.count > child.prefix.count else { continue }
                chosen = (parent.real, below)
                break
            }
        }
        guard let (root, below) = chosen else { throw refused("it is outside the folders the Mail plugin writes in") }

        var current = Darwin.open(root, O_RDONLY | O_DIRECTORY)
        guard current >= 0 else { throw refused("the folder it belongs in can\u{2019}t be opened") }
        guard Self.path(of: current) == root else {
            Darwin.close(current)
            throw refused("the folder it belongs in changed while it was checked")
        }
        for name in below {
            var next = Darwin.openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0, errno == ENOENT {
                if Darwin.mkdirat(current, name, 0o755) != 0, errno != EEXIST {
                    let reason = String(cString: strerror(errno))
                    Darwin.close(current)
                    throw MailFailure(code: "write_failed", message: "Couldn\u{2019}t make the folder \(shown.path): \(reason).")
                }
                next = Darwin.openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else {
                if failure == ELOOP || failure == ENOTDIR { throw refused("a folder on the way is a link, or changed while it was checked") }
                throw MailFailure(code: "write_failed", message: "Couldn\u{2019}t open the folder \(shown.path): \(String(cString: strerror(failure))).")
            }
            current = next
        }
        // The descriptor held is, as the system sees it now, inside the root.
        guard let held = Self.path(of: current), components(of: held, below: root) != nil else {
            Darwin.close(current)
            throw refused("the folder is not inside the allowed folder")
        }
        return current
    }
    #endif

    // MARK: Actions

    private static let actionValueFlags: Set<String> = ["--color", "--to", "--cc", "--subject", "--body"]

    private func action(_ verb: String, _ args: [String]) async throws -> MailCLIResult {
        let words = Args.positionals(args, valueFlags: Self.actionValueFlags)
        switch verb {
        case "mark":
            guard words.count >= 2 else {
                throw Self.usage("usage: mark <id|link> read|unread|flagged|unflagged [--color red|orange|yellow|green|blue|purple|gray]")
            }
            let state = words[1].lowercased()
            var color: MailAct.FlagColor?
            switch state {
            case "read", "unread", "unflagged": break
            case "flagged":
                if let name = Args.value(args, "--color") {
                    guard let known = MailAct.FlagColor(rawValue: name.lowercased()) else {
                        throw Self.usage("--color is one of \(MailAct.FlagColor.allCases.map(\.rawValue).joined(separator: ", ")), not `\(name)`")
                    }
                    color = known
                }
            default:
                throw Self.usage("mark takes read, unread, flagged or unflagged, not `\(words[1])`")
            }
            let target = try await controller.resolve(words[0])
            let result: MailActionResult
            switch state {
            case "read": result = try await controller.mark(target.id, read: true)
            case "unread": result = try await controller.mark(target.id, read: false)
            case "flagged": result = try await controller.flag(target.id, color: color)
            default: result = try await controller.unflag(target.id)
            }
            return try Self.done("mark", id: target.id, result)
        case "move":
            guard words.count >= 2 else { throw Self.usage("usage: move <id|link> <mailbox id|name>") }
            let target = try await controller.resolve(words[0])
            return try Self.done("move", id: target.id, try await controller.move(target.id, to: words[1]))
        case "archive", "delete", "junk":
            let target = try await controller.resolve(words.first ?? "")
            let result: MailActionResult
            switch verb {
            case "archive": result = try await controller.archive(target.id)
            case "delete": result = try await controller.delete(target.id)
            default: result = try await controller.junk(target.id)
            }
            return try Self.done(verb, id: target.id, result)
        default:
            return try await draft(args, words)
        }
    }

    private func draft(_ args: [String], _ words: [String]) async throws -> MailCLIResult {
        let usage = "usage: draft reply|reply-all|forward <id|link> | draft new [--to <addr>] [--cc <addr>] [--subject <text>] [--body <text>]"
        guard let kind = words.first else { throw Self.usage(usage) }
        switch kind {
        case "new":
            let result = try await controller.draft(.new(
                to: Args.values(args, "--to"), cc: Args.values(args, "--cc"), subject: Args.value(args, "--subject"),
                body: Args.value(args, "--body")))
            return try Self.done("draft new", id: nil, result)
        case "reply", "reply-all", "forward":
            let target = try await controller.resolve(words.dropFirst().first ?? "")
            let draft: MailAct.Draft = kind == "forward" ? .forward : (kind == "reply" ? .reply : .replyAll)
            return try Self.done("draft \(kind)", id: target.id, try await controller.draft(draft, of: target.id))
        default:
            throw Self.usage(usage)
        }
    }

    private func open(_ args: [String]) async throws -> MailCLIResult {
        let id = try Args.messageID(Args.positionals(args).first)
        let envelope = try await controller.resolve(String(id))
        _ = try await controller.open(envelope.id)
        let url = envelope.messageID.flatMap { MailAct.messageURL(messageID: $0) }
        // `ok` is what `MailActionResult` (the widget's decode of an action's answer) requires.
        return try Self.success(["ok": true, "url": JSON.orNull(url), "opened": true] as [String: Any])
    }

    // MARK: permissions

    private func permissions(_ args: [String]) async throws -> MailCLIResult {
        switch args.first(where: { !$0.hasPrefix("-") }) {
        case nil:
            let report = await controller.permissions()
            let state: String
            switch report.access {
            case .granted: state = "granted"
            case .denied: state = "denied"
            case .noMailData: state = "noMailData"
            case .notInstalled: state = "denied"
            case .unreachable(let text):
                throw Escape(failure: MailFailure(code: MailCtl.lacksHost(text) ? MailCtl.hostUnsupportedCode : "mail_unreachable", message: text))
            }
            let result = try Self.success(["fullDiskAccess": state, "mailRoot": JSON.orNull(report.mailRoot)] as [String: Any])
            return MailCLIResult(status: state == "granted" ? 0 : 1, stdout: result.stdout, stderr: "")
        case "open", "automation":
            throw MailFailure(
                code: "unsupported_in_extension",
                message: "The Mail plugin can\u{2019}t do that itself. Open System Settings \u{203A} Privacy & Security \u{203A} Full Disk Access (and Automation), and turn on Work 42.")
        case let other?:
            throw Self.usage("unknown permissions subcommand `\(other)` (try `permissions`)")
        }
    }

    // MARK: Results

    private static func usage(_ text: String) -> MailFailure { MailFailure(code: "usage", message: text) }

    /// 1 when Mail cannot be read or acted on, 2 for everything else (usage, not found, bad query): the CLI's own split.
    static func exitStatus(forCode code: String) -> Int32 {
        let unreadable: Set<String> = [
            "fda_denied", "no_mail_data", "schema_unsupported", "automation_denied", "mail_timeout", "mail_not_running",
            "no_archive_mailbox", "action_failed", "unsupported_by_automation", "unsupported_in_extension",
            "write_failed", MailCtl.hostUnsupportedCode,
        ]
        return unreadable.contains(code) ? 1 : 2
    }

    private static func done(_ action: String, id: Int64?, _ result: MailActionResult) throws -> MailCLIResult {
        var object: [String: Any] = ["ok": result.ok, "action": action]
        if let id { object["id"] = id }
        if let link = result.link { object["link"] = link }
        return try success(object)
    }

    private static func data(_ object: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return body + Data("\n".utf8)
    }

    private static func success(_ object: Any) throws -> MailCLIResult {
        MailCLIResult(status: 0, stdout: try data(object), stderr: "")
    }

    /// `{"error":{"code","message"}}` on stdout with `--json`, else the CLI's one line on stderr.
    private static func failed(_ failure: MailFailure, json: Bool) -> MailCLIResult {
        let status = exitStatus(forCode: failure.code)
        guard json else { return MailCLIResult(status: status, stdout: Data(), stderr: "mail42: \(failure.message) (\(failure.code))\n") }
        let envelope: [String: Any] = ["error": ["code": failure.code, "message": failure.message]]
        return MailCLIResult(status: status, stdout: (try? data(envelope)) ?? Data(), stderr: "")
    }
}

// MARK: - Arguments, as the CLI read them (Shared.swift)

private nonisolated enum Args {

    static func value(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Every value of a repeatable flag, each also split on commas.
    static func values(_ args: [String], _ name: String) -> [String] {
        var found: [String] = []
        for (index, arg) in args.enumerated() where arg == name && index + 1 < args.count {
            found += args[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return found
    }

    static func positionals(_ args: [String]) -> [String] { args.filter { !$0.hasPrefix("-") } }

    /// Non-flag arguments, skipping the value that follows each flag in `valueFlags`.
    static func positionals(_ args: [String], valueFlags: Set<String>) -> [String] {
        var result: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(arg) { skipNext = true; continue }
            if !arg.hasPrefix("-") { result.append(arg) }
        }
        return result
    }

    static func intFlag(_ args: [String], _ name: String, min: Int) throws -> Int? {
        guard let raw = value(args, name) else { return nil }
        guard let number = Int(raw), number >= min else {
            throw MailFailure(code: "usage", message: "\(name) takes a whole number of \(min) or more, not `\(raw)`")
        }
        return number
    }

    static func messageID(_ raw: String?) throws -> Int64 {
        guard let raw, let id = Int64(raw), id > 0 else {
            throw MailFailure(code: "usage", message: "expected a message id (a number from `envelope list`)")
        }
        return id
    }
}

// MARK: - The JSON the CLI printed (Presentation.swift), built from dictionaries so an absent value is an explicit null

private nonisolated enum JSON {

    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    static func person(_ person: MailPerson) -> [String: Any] {
        ["name": orNull(person.name.flatMap { $0.isEmpty ? nil : $0 }), "addr": orNull(person.addr)]
    }

    static func envelope(_ e: MailEnvelope) -> [String: Any] {
        var object: [String: Any] = [
            "id": e.id,
            "message_id": orNull(e.messageID),
            "conversation_id": orNull(e.conversationID),
            "account": ["id": e.account.id, "name": e.account.name, "email": orNull(e.account.email)] as [String: Any],
            "mailbox": ["id": e.mailbox.id, "name": e.mailbox.name, "role": e.mailbox.role] as [String: Any],
            "from": person(e.from),
            "to": e.to.map(person),
            "cc": e.cc.map(person),
            "subject": e.subject,
            "date": ISO8601DateFormatter().string(from: e.date),
            "snippet": orNull(e.snippet),
            "is_read": e.isRead,
            "is_flagged": e.isFlagged,
            "has_attachments": e.hasAttachments,
            "link": orNull(e.link),
        ]
        // A conversation is its newest message plus the size of the conversation and who wrote in it.
        if let count = e.conversationCount {
            object["conversation_count"] = count
            object["participants"] = e.participants ?? []
        }
        return object
    }

    static func attachment(_ a: MailAttachment) -> [String: Any] {
        ["part": a.part, "filename": a.filename, "mime": a.mime, "size": a.size]
    }

    static func tree(_ t: MailAccountTree) -> [String: Any] {
        [
            "account": ["id": t.account.id, "name": t.account.name, "email": orNull(t.account.email), "kind": t.account.kind] as [String: Any],
            "mailboxes": t.mailboxes.map { m in
                ["id": m.id, "name": m.name, "role": m.role, "total": m.total, "unread": m.unread] as [String: Any]
            },
        ]
    }
}
