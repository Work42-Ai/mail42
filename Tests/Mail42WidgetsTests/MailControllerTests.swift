// MailControllerTests.swift — the controller behind the Mail widget (WOR-900), run end to end over a synthetic Apple Mail store:
// a real Envelope Index and real .emlx files in a temp folder, a stand-in for `services.diskRead` that serves that folder, and a
// stand-in for `services.automation` that records the Apple Events.

import Darwin
import Foundation
import Mail42TestSupport
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

// MARK: - A stand-in for services.diskRead

/// `services.diskRead` over a real folder, counting what the tests want to watch.
nonisolated final class CtlBridge: WidgetDiskReadService, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: Int] = [:]
    /// When set, every call fails with it.
    var refuse: WidgetServiceError?
    /// When set, a call on a path it matches fails with a macOS refusal (EPERM), the others work.
    var refuseMatching: (@Sendable (String) -> Bool)?
    /// When set, the copy of the Envelope Index waits here until the test releases it.
    var gate: CtlGate?
    private var bytes: [String: Int] = [:]

    /// How many bytes were read (all calls) from paths containing `fragment`.
    func bytesRead(containing fragment: String) -> Int { lock.withLock { bytes.filter { $0.key.contains(fragment) }.values.reduce(0, +) } }

    private func check(_ path: String) throws {
        if let refuse { throw refuse }
        if let refuseMatching, refuseMatching(path) {
            throw WidgetServiceError(message: "could not read \(path): Operation not permitted (errno 1)")
        }
    }

    /// How many times a file was started to be COPIED (a read from offset 0 of more than the one proving byte): one per copy.
    func copyStarts(_ suffix: String) -> Int { lock.withLock { starts.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +) } }

    static func missing(_ path: String) -> WidgetServiceError {
        WidgetServiceError(message: "could not stat \(path): No such file or directory (errno 2)", suggestion: "check the path")
    }

    func stat(path: String) async throws -> DiskEntry {
        try check(path)
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw Self.missing(path) }
        let kind: DiskEntryKind = (info.st_mode & S_IFMT) == S_IFDIR ? .directory : ((info.st_mode & S_IFMT) == S_IFREG ? .file : .other)
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return DiskEntry(name: (path as NSString).lastPathComponent, kind: kind, size: kind == .file ? Int64(info.st_size) : 0,
                         modifiedAt: modified)
    }

    func list(path: String, cursor: String?, limit: Int?) async throws -> DiskListing {
        try check(path)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { throw Self.missing(path) }
        let sorted = names.sorted()
        let start = cursor.flatMap(Int.init) ?? 0
        let end = min(start + (limit ?? 200), sorted.count)
        var entries: [DiskEntry] = []
        for name in sorted[start..<end] { entries.append(try await stat(path: path + "/" + name)) }
        return DiskListing(entries: entries, nextCursor: end < sorted.count ? String(end) : nil)
    }

    func read(path: String, offset: Int64, length: Int) async throws -> DiskChunk {
        try check(path)
        if offset == 0, length > 1, path.hasSuffix("Envelope Index"), let gate { await gate.pass() }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Self.missing(path) }
        defer { try? handle.close() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(length, DiskReadLimits.maxReadLength)) ?? Data()
        lock.withLock { bytes[path, default: 0] += data.count }
        if offset == 0, length > 1 { lock.withLock { starts[path, default: 0] += 1 } }
        return DiskChunk(data: data, offset: offset, size: size, isEnd: offset + Int64(data.count) >= size)
    }
}

/// Holds a bridge call until the test lets it go.
nonisolated final class CtlGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var open = false
    private var arrived = false

    var hasEntered: Bool { lock.withLock { arrived } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                arrived = true
                if open { return true }
                waiting = continuation
                return false
            }
            if go { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            open = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

/// Lets a stand-in for Mail's automation change the synthetic index the way Mail would when an action arrives.
nonisolated final class CtlBuilderBox: @unchecked Sendable {
    let builder: EnvelopeIndexBuilder
    init(_ builder: EnvelopeIndexBuilder) { self.builder = builder }
}

/// Waits (a few seconds at most) for a condition the test cannot await directly.
func ctlEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 where !(await condition()) { try await Task.sleep(for: .milliseconds(25)) }
}

// MARK: - A Mail store, a bridge to it, and a controller over both

nonisolated let ctlBase: Int64 = 1_790_000_000
nonisolated let ctlInbox = EnvelopeIndexBuilder.mailboxURL(["INBOX"])

/// What is in the store (newest first in the all-inboxes list is 103, 102, 101, 104):
///
///     101  INBOX    "Quarterly roadmap"       Alice  +100  unread  conversation 7  plain text, body says "quokkabody"
///     102  INBOX    "Re: Quarterly roadmap"   Bo     +200  unread  conversation 7  HTML with a script and a cid: image
///     103  INBOX    "Invoice attached"        Carol  +300  read    conversation 8  report.pdf (part 2)
///     104  INBOX    "Lunch?"                  Dan    +50   unread, flagged         .partial.emlx with no body
///     105  Archive  "Old news"                Eve    +10   read                    no file on disk
final class CtlWorld {
    let builder: EnvelopeIndexBuilder
    let bridge = CtlBridge()
    let automation = FakeAutomation()
    let folder: URL
    let controller: MailCtl.Controller
    let transport: MailCtlDirectTransport

    init(
        refreshInterval: TimeInterval = 60, poll: Duration = .milliseconds(30), schemaOmitting: Set<String> = [],
        library: String? = nil, maxMessageBytes: Int? = nil, maxAttachmentBytes: Int? = nil
    ) throws {
        builder = try EnvelopeIndexBuilder(schemaOmitting: schemaOmitting)
        folder = URL(fileURLWithPath: "/tmp/w900-ctl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var configuration = MailCtl.Configuration()
        configuration.library = library ?? builder.library.path
        configuration.accountsPath = builder.root.appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
        configuration.refreshInterval = refreshInterval
        if let maxMessageBytes { configuration.maxMessageBytes = maxMessageBytes }
        if let maxAttachmentBytes { configuration.maxAttachmentBytes = maxAttachmentBytes }
        controller = MailCtl.Controller(disk: bridge, automation: automation, directory: folder, configuration: configuration)
        transport = MailCtlDirectTransport(controller: controller, pollInterval: poll)
        if schemaOmitting.isEmpty { try populate() }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func message(
        _ rowid: Int64, _ subject: String, _ name: String, mailbox: Int64 = 1, at offset: Int64, read: Bool = false,
        flagged: Bool = false, conversation: Int64 = 0, summary: String? = nil
    ) -> EnvelopeIndexBuilder.Message {
        .init(rowid: rowid, subject: subject, senderAddress: "\(name.lowercased())@example.com", senderName: name, mailboxID: mailbox,
              dateReceived: ctlBase + offset, read: read, flagged: flagged, conversationID: conversation, summary: summary,
              messageIDHeader: "<\(name.lowercased())-\(rowid)@example.com>")
    }

    private func populate() throws {
        try builder.addMailbox(id: 1, url: ctlInbox, total: 4, unread: 3)
        try builder.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["Archive"]), total: 1)
        try builder.addMailbox(id: 3, url: EnvelopeIndexBuilder.mailboxURL(["Junk"]), total: 0)
        try builder.addMessage(message(101, "Quarterly roadmap", "Alice", at: 100, conversation: 7, summary: "Roadmap for Q4 planning"))
        try builder.addMessage(message(102, "Re: Quarterly roadmap", "Bo", at: 200, conversation: 7))
        try builder.addMessage(message(103, "Invoice attached", "Carol", at: 300, read: true, conversation: 8))
        try builder.addMessage(message(104, "Lunch?", "Dan", at: 50, flagged: true))
        try builder.addMessage(message(105, "Old news", "Eve", mailbox: 2, at: 10, read: true))
        try builder.addRecipient(messageRowid: 101, address: "yan@example.com", name: "Yan", type: 0, position: 0)
        try builder.addAttachment(messageRowid: 103, attachmentID: "2", name: "report.pdf")

        func emlx(_ rfc822: String) -> Data { MailFixtures.emlx(rfc822) }
        try builder.writeEmlx(rowid: 101, data: emlx(MailFixtures.plain(
            subject: "Quarterly roadmap", from: "Alice <alice@example.com>", messageID: "<alice-101@example.com>",
            body: "Hello Yan. The secret word is quokkabody.")))
        try builder.writeEmlx(rowid: 102, data: emlx(MailFixtures.htmlWithInlineImage(messageID: "<bo-102@example.com>")))
        try builder.writeEmlx(rowid: 103, data: emlx(MailFixtures.withAttachment(messageID: "<carol-103@example.com>")))
        try builder.writeEmlx(rowid: 104, data: emlx(MailFixtures.partialWithoutBody(messageID: "<dan-104@example.com>")), partial: true)
        try builder.writeAccountsDatabase([
            .init(pk: 1, identifier: EnvelopeIndexBuilder.accountUUID, username: "yan@example.com", description: "Work"),
        ])
    }

    /// A configuration that reads this world's store (for a second controller over the same bridge).
    func configuration(refreshInterval: TimeInterval = 60) -> MailCtl.Configuration {
        var configuration = MailCtl.Configuration()
        configuration.library = builder.library.path
        configuration.accountsPath = builder.root.appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
        configuration.refreshInterval = refreshInterval
        return configuration
    }

    private static func crlf(_ lines: [String]) -> String { lines.joined(separator: "\r\n") }

    /// Message 107 (the newest): a one-line text body that says `word`, then a 4 MiB attachment, so the file is over 4 MiB.
    func addLargeMessage(word: String) throws {
        try builder.addMessage(message(107, "Big file", "Hal", at: 500))
        let attachment = Data(repeating: 0x41, count: 4 * 1024 * 1024).base64EncodedString(options: .lineLength76Characters)
        let rfc822 = Self.crlf([
            "From: Hal <hal@example.com>", "To: Yan <yan@example.com>", "Subject: Big file",
            "Date: Mon, 27 Oct 2026 15:00:00 +0000", "Message-ID: <hal-107@example.com>", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"B4\"", "",
            "--B4", "Content-Type: text/plain; charset=utf-8", "", "The word is \(word).",
            "--B4", "Content-Type: application/octet-stream; name=\"big.bin\"", "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=\"big.bin\"", "", attachment,
            "--B4--", "",
        ])
        try builder.writeEmlx(rowid: 107, data: MailFixtures.emlx(rfc822))
    }

    /// Message 108: a partial download whose attachments (or, with `inline`, inline images) are all in Mail's cache, `size`
    /// bytes each, filled with a letter per file (A, B, C…). In the message the parts are 2, 3, 4… (part 1 is the HTML body).
    func addPartialWithCachedFiles(names: [String], inline: Bool, size: Int) throws {
        try builder.addMessage(message(108, "Many files", "Gus", at: 600))
        var lines = [
            "From: Gus <gus@example.com>", "To: Yan <yan@example.com>", "Subject: Many files",
            "Date: Mon, 27 Oct 2026 16:00:00 +0000", "Message-ID: <gus-108@example.com>", "MIME-Version: 1.0",
            "Content-Type: multipart/related; boundary=\"B5\"", "",
            "--B5", "Content-Type: text/html; charset=utf-8", "",
            "<html><body>" + names.map { "<img src=\"cid:\($0)\">" }.joined() + "</body></html>",
        ]
        for name in names {
            lines += ["--B5", "Content-Type: \(inline ? "image/png" : "application/pdf"); name=\"\(name)\""]
            if inline { lines.append("Content-ID: <\(name)>") }
            lines += ["Content-Disposition: \(inline ? "inline" : "attachment"); filename=\"\(name)\"", "", ""]
        }
        lines += ["--B5--", ""]
        try builder.writeEmlx(rowid: 108, data: MailFixtures.emlx(Self.crlf(lines)), partial: true)
        for (index, name) in names.enumerated() {
            try builder.writeAttachmentCache(
                rowid: 108, partID: String(index + 2), filename: name,
                data: Data(repeating: UInt8(ascii: "A") + UInt8(index), count: size))
        }
    }

    /// Message 106: a partial download whose attachment lives in Mail's cache (written when `cached`).
    func addPartialWithAttachment(cached: Bool) throws {
        try builder.addMessage(message(106, "Cached report", "Fay", at: 400, conversation: 9))
        try builder.writeEmlx(
            rowid: 106, data: MailFixtures.emlx(MailFixtures.partialWithAttachment(messageID: "<fay-106@example.com>")), partial: true)
        if cached {
            try builder.writeAttachmentCache(rowid: 106, partID: "2", filename: "report.pdf", data: MailFixtures.attachmentBytes)
        }
    }
}

/// The failure a call ends with, or nil when it succeeds.
func ctlFailure<T>(_ body: () async throws -> T) async -> MailFailure? {
    do { _ = try await body(); return nil } catch { return error as? MailFailure }
}

private func label(_ access: MailAccess) -> String {
    switch access {
    case .granted: return "granted"
    case .denied: return "denied"
    case .noMailData: return "noMailData"
    case .notInstalled: return "notInstalled"
    case .unreachable(let text): return "unreachable: \(text)"
    }
}

// MARK: - Tests

@Suite("Mail controller: the widget's backend without a CLI (WOR-900)")
struct MailControllerTests {

    // MARK: Access

    @Test("access is granted when the index can be read, denied when macOS refuses, and no_mail_data when Mail has none")
    func access() async throws {
        let world = try CtlWorld()
        #expect(label(await world.controller.access()) == "granted")

        world.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        #expect(label(await world.controller.access()) == "denied")
        world.bridge.refuse = WidgetServiceError(message: "boom")
        #expect(label(await world.controller.access()) == "unreachable: boom")

        let empty = try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))")
        #expect(label(await empty.controller.access()) == "noMailData")
    }

    @Test("a refusal is fda_denied, an absent Mail is no_mail_data, an index from another macOS is schema_unsupported")
    func failuresCarryTheCLIsCodes() async throws {
        let world = try CtlWorld()
        world.bridge.refuse = WidgetServiceError(message: "could not list: Operation not permitted (errno 1)")
        #expect(await ctlFailure { try await world.controller.mailboxTree() }?.code == "fda_denied")

        let empty = try CtlWorld(library: "/tmp/w900-no-such-mail-\(UUID().uuidString.prefix(8))")
        #expect(await ctlFailure { try await empty.controller.mailboxTree() }?.code == "no_mail_data")

        let odd = try CtlWorld(schemaOmitting: ["messages.size"])
        #expect(await ctlFailure { try await odd.controller.mailboxTree() }?.code == "schema_unsupported")
    }

    @Test("every lower-level error becomes a MailFailure with a code, and only cancellation stays itself")
    func failureMapping() {
        func code(_ error: any Error) -> String? { (MailCtl.failure(from: error) as? MailFailure)?.code }
        #expect(code(MailMirrorError.permission("no")) == "fda_denied")
        #expect(code(MailMirrorError.noMailData) == "no_mail_data")
        #expect(code(MailMirrorError.failed("x")) == "database_not_accessible")
        #expect(code(MailIndexError.database("x")) == "database_not_accessible")
        #expect(code(MailIndexError.schemaUnsupported(table: "messages", column: "size")) == "schema_unsupported")
        #expect(code(MailIndexError.notFound("message 5")) == "not_found")
        #expect(code(MailQueryError.bad("x", position: 3)) == "bad_query")
        #expect(code(MailBodyError.emlxParseFailed("x")) == "emlx_parse_failed")
        #expect(code(WidgetServiceError(message: "x (errno 13)")) == "fda_denied")
        #expect(code(MailFailure(code: "custom", message: "m")) == "custom")
        #expect(MailCtl.failure(from: CancellationError()) is CancellationError)
    }

    // MARK: Reading the index

    @Test("the mailbox tree names the account from the Accounts database and carries Apple's counters")
    func mailboxTree() async throws {
        let world = try CtlWorld()
        let trees = try await world.controller.mailboxTree()
        let tree = try #require(trees.first)
        #expect(trees.count == 1)
        #expect(tree.account.name == "Work" && tree.account.email == "yan@example.com" && tree.account.kind == "imap")
        #expect(tree.mailboxes.map(\.name) == ["INBOX", "Archive", "Junk"])
        #expect(tree.mailboxes.first?.total == 4 && tree.mailboxes.first?.unread == 3)
        #expect(try await world.controller.signature() == "1:4:3,2:1:0,3:0:0")
    }

    @Test("lists: all inboxes newest first, flat and as conversations, paged, by mailbox, flagged and unread")
    func lists() async throws {
        let world = try CtlWorld()
        let controller = world.controller
        var options = MailCtl.ListOptions()
        #expect(try await controller.list(options).map(\.id) == [103, 102, 101, 104])

        options.limit = 2
        #expect(try await controller.list(options).map(\.id) == [103, 102])
        options.beforeID = 102
        #expect(try await controller.list(options).map(\.id) == [101, 104])

        var conversations = MailCtl.ListOptions()
        conversations.conversations = true
        let all = try await controller.list(conversations)
        #expect(all.map(\.id) == [103, 102, 104])
        let roadmap = try #require(all.first { $0.id == 102 })
        #expect(roadmap.conversationCount == 2 && roadmap.participants == ["Bo", "Alice"])
        conversations.limit = 2
        #expect(try await controller.list(conversations).map(\.id) == [103, 102])
        conversations.beforeID = 102
        #expect(try await controller.list(conversations).map(\.id) == [104])

        var flagged = MailCtl.ListOptions()
        flagged.mailbox = MailCtl.ListOptions.selector("flagged")
        #expect(try await controller.list(flagged).map(\.id) == [104])
        var archive = MailCtl.ListOptions()
        archive.mailbox = MailCtl.ListOptions.selector("2")
        #expect(try await controller.list(archive).map(\.id) == [105])
        var unread = MailCtl.ListOptions()
        unread.unreadOnly = true
        #expect(try await controller.list(unread).map(\.id) == [102, 101, 104])
    }

    @Test("search: header terms from the index, body terms from the message files, headers-only skips the files")
    func search() async throws {
        let world = try CtlWorld()
        let controller = world.controller
        #expect(try await controller.search("from:alice").records.map(\.id) == [101])
        #expect(try await controller.search("subject:invoice").records.map(\.id) == [103])
        #expect(try await controller.search("roadmap").records.map(\.id) == [102, 101])

        // "quokkabody" is only in the text of 101; "headline" only in the HTML of 102.
        #expect(try await controller.search("quokkabody").records.map(\.id) == [101])
        #expect(try await controller.search("headline").records.map(\.id) == [102])
        #expect(try await controller.search("quokkabody", headersOnly: true).records.isEmpty)
        #expect(try await controller.search("from:alice quokkabody").records.map(\.id) == [101])
        #expect(try await controller.search("from:bo quokkabody").records.isEmpty)

        let bad = await ctlFailure { try await controller.search("from:") }
        #expect(bad?.code == "bad_query")
    }

    @Test("a thread is oldest first, and a link finds its message by Message-ID after Mail gave it another row")
    func threadAndResolve() async throws {
        let world = try CtlWorld()
        let controller = world.controller
        #expect(try await controller.thread(102).map(\.id) == [101, 102])
        #expect(await ctlFailure { try await controller.thread(999) }?.code == "not_found")

        let envelope = try await controller.resolve("101")
        let link = try #require(envelope.link)
        #expect(link == "mail42://message/101?mid=alice-101%40example.com")
        #expect(try await controller.resolve(link).id == 101)
        // The row id in the link is stale; the Message-ID still finds it.
        #expect(try await controller.resolve("mail42://message/9999?mid=alice-101%40example.com").id == 101)
        #expect(await ctlFailure { try await controller.resolve("mail42://message/9999?mid=nobody%40example.com") }?.code == "not_found")
        #expect(await ctlFailure { try await controller.resolve("not a link") }?.code == "usage")
    }

    // MARK: Reading a message

    @Test("the HTML is sanitised, the text is the text, a partial download with no body and a missing file are body_unavailable")
    func readingMessages() async throws {
        let world = try CtlWorld()
        let controller = world.controller

        let html = try await controller.message(102, mode: .html)
        let document = try #require(html.html)
        #expect(document.contains("Roadmap headline") && document.contains("data-mail42-id=\"102\""))
        #expect(!document.contains("SCRIPT RAN") && !document.contains("onclick") && !document.contains("javascript:"))
        #expect(document.contains("data:image/png;base64,"), "the cid: image is inlined from the message's own part")
        #expect(!html.bodyUnavailable && html.envelope.id == 102)

        let text = try await controller.message(101, mode: .text)
        #expect(text.text?.contains("quokkabody") == true && text.headers["subject"] == "Quarterly roadmap")

        let headers = try await controller.message(101, mode: .headers)
        #expect(headers.text == nil && headers.html == nil && !headers.headers.isEmpty)

        let partial = try await controller.message(104, mode: .html)
        #expect(partial.bodyUnavailable)
        let missing = try await controller.message(105, mode: .html)
        #expect(missing.bodyUnavailable && missing.html == nil)

        #expect(await ctlFailure { try await controller.message(999) }?.code == "not_found")
    }

    @Test("read(out:) writes the body to the file the caller names, and writes nothing when there is no body")
    func readOut() async throws {
        let world = try CtlWorld()
        let controller = world.controller
        let file = world.folder.appendingPathComponent("reader/m102.html")

        let written = try await controller.read(102, html: true, out: file)
        #expect(written.path == file.path && !written.bodyUnavailable && written.html == nil)
        let body = try String(contentsOf: file, encoding: .utf8)
        #expect(body.contains("Roadmap headline") && !body.contains("SCRIPT RAN"))

        let nothing = world.folder.appendingPathComponent("reader/m104.html")
        let none = try await controller.read(104, html: true, out: nothing)
        #expect(none.path == nil && none.bodyUnavailable && !FileManager.default.fileExists(atPath: nothing.path))

        let inline = try await controller.read(102, html: true)
        #expect(inline.path == nil && inline.html?.contains("Roadmap headline") == true)

        // Outside the folders it may write in is refused up front (a file inside them that cannot be made is write_failed).
        let unwritable = URL(fileURLWithPath: "/dev/null/m.html")
        #expect(await ctlFailure { try await controller.read(102, html: true, out: unwritable) }?.code == "path_not_allowed")
        let blocked = world.folder.appendingPathComponent("reader/m102.html/under.html")     // m102.html is a file by now
        #expect(await ctlFailure { try await controller.read(102, html: true, out: blocked) }?.code == "write_failed")
    }

    @Test("a message file over the cap is message_too_large, not read")
    func theCap() async throws {
        let world = try CtlWorld(maxMessageBytes: 100)
        #expect(await ctlFailure { try await world.controller.message(101) }?.code == "message_too_large")
    }

    // MARK: Attachments

    @Test("attachments are listed from the file, and their bytes come back with a safe name, never written anywhere")
    func attachments() async throws {
        let world = try CtlWorld()
        let controller = world.controller
        let listed = try await controller.attachments(103)
        #expect(listed == [MailAttachment(part: "2", filename: "report.pdf", mime: "application/pdf", size: Int64(MailFixtures.attachmentBytes.count))])

        let saved = try await controller.attachmentData(id: 103, part: "2")
        #expect(saved.filename == "report.pdf" && saved.mime == "application/pdf" && saved.data == MailFixtures.attachmentBytes)

        #expect(await ctlFailure { try await controller.attachmentData(id: 103, part: "9") }?.code == "not_found")
        #expect(await ctlFailure { try await controller.attachmentData(id: 105, part: "2") }?.code == "emlx_not_found")
        #expect(await ctlFailure { try await controller.attachmentData(id: 999, part: "2") }?.code == "not_found")
        #expect(try await controller.attachments(101).isEmpty)
        // No file: the names Apple's index holds (no type, no size).
        #expect(try await controller.attachments(105).isEmpty)
    }

    @Test("a partial download's attachment comes from Mail's attachment cache, or is attachment_not_downloaded")
    func cachedAttachments() async throws {
        let cached = try CtlWorld()
        try cached.addPartialWithAttachment(cached: true)
        let saved = try await cached.controller.attachmentData(id: 106, part: "2")
        #expect(saved.data == MailFixtures.attachmentBytes && saved.filename == "report.pdf")
        #expect(try await cached.controller.attachments(106).first?.size == Int64(MailFixtures.attachmentBytes.count))

        let bare = try CtlWorld()
        try bare.addPartialWithAttachment(cached: false)
        #expect(await ctlFailure { try await bare.controller.attachmentData(id: 106, part: "2") }?.code == "attachment_not_downloaded")
    }

    // MARK: The mirror

    @Test("a burst of calls, one after another or all at once, shares one refresh of the mirror")
    func aBurstSharesOneRefresh() async throws {
        let sequential = try CtlWorld(refreshInterval: 60)
        for _ in 0..<5 { _ = try await sequential.controller.mailboxTree() }
        #expect(await sequential.controller.refreshCount == 1)
        #expect(sequential.bridge.copyStarts("Envelope Index") == 1)

        let concurrent = try CtlWorld(refreshInterval: 60)
        let controller = concurrent.controller
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { (try? await controller.mailboxTree().count) ?? -1 } }
            var counts: [Int] = []
            for await count in group { counts.append(count) }
            return counts
        }
        #expect(counts == Array(repeating: 1, count: 8))
        #expect(await controller.refreshCount == 1)
        #expect(concurrent.bridge.copyStarts("Envelope Index") == 1)
    }

    @Test("the mirror is copied again only when the index changed on the Mac")
    func refreshOnlyWhenChanged() async throws {
        let world = try CtlWorld(refreshInterval: 0)
        let controller = world.controller
        #expect(try await controller.mailboxTree().first?.mailboxes.first?.unread == 3)
        #expect(try await controller.mailboxTree().first?.mailboxes.first?.unread == 3)
        #expect(await controller.refreshCount == 1, "the remote files did not move: only looked at, not copied")

        try world.builder.setMailboxCounts(id: 1, total: 5, unread: 4)
        #expect(try await controller.mailboxTree().first?.mailboxes.first?.unread == 4)
        #expect(await controller.refreshCount == 2)
        #expect(world.bridge.copyStarts("Envelope Index") == 2)

        // A new message shows up in the list after the next refresh.
        try world.builder.addMessage(.init(
            rowid: 110, subject: "Brand new", senderAddress: "zed@example.com", mailboxID: 1, dateReceived: ctlBase + 900))
        #expect(try await controller.list(MailCtl.ListOptions()).first?.id == 110)
    }

    @Test("close lets go of the index, and the controller opens it again when asked")
    func closeAndReopen() async throws {
        let world = try CtlWorld()
        _ = try await world.controller.mailboxTree()
        await world.controller.close()
        #expect(try await world.controller.mailboxTree().count == 1)
        #expect(await world.controller.refreshCount == 2)
    }

    // MARK: Review fixes

    // 1. read(out:) is contained
    @Test("read(out:) writes only inside the working folder or a configured root: outside, .., a symlinked parent and a symlinked file are refused before anything is created")
    func readOutIsContained() async throws {
        let world = try CtlWorld()
        let fm = FileManager.default
        let outside = URL(fileURLWithPath: "/tmp/w900-outside-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: world.folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        func refused(_ file: URL) async -> String? { await ctlFailure { try await world.controller.read(102, html: true, out: file) }?.code }

        // Outside every allowed folder: nothing is created, not even the parent.
        #expect(await refused(outside.appendingPathComponent("sub/m.html")) == "path_not_allowed")
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("sub").path))

        // `..` out of the working folder.
        let escape = URL(fileURLWithPath: world.folder.path + "/reader/../../\(outside.lastPathComponent)/esc.html")
        #expect(await refused(escape) == "path_not_allowed")
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("esc.html").path))

        // A symlink inside the working folder that points out of it.
        try fm.createSymbolicLink(at: world.folder.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(await refused(world.folder.appendingPathComponent("link/m.html")) == "path_not_allowed")
        #expect(await refused(world.folder.appendingPathComponent("link/new/m.html")) == "path_not_allowed")
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)

        // The destination itself a symlink (even one that points to a file inside the working folder).
        let target = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: world.folder.appendingPathComponent("dest.html"), withDestinationURL: target)
        #expect(await refused(world.folder.appendingPathComponent("dest.html")) == "path_not_allowed")
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")

        // Inside the working folder still works, and so does a root the configuration names.
        let inside = world.folder.appendingPathComponent("ok/m.html")
        #expect(try await world.controller.read(102, html: true, out: inside).path == inside.path)
        #expect(fm.fileExists(atPath: inside.path))
        var configuration = world.configuration()
        configuration.outputRoots = [outside]
        let widened = MailCtl.Controller(
            disk: world.bridge, automation: world.automation, directory: world.folder.appendingPathComponent("wide"), configuration: configuration)
        let extra = outside.appendingPathComponent("reader/m.html")
        #expect(try await widened.read(102, html: true, out: extra).path == extra.path)
        #expect(fm.fileExists(atPath: extra.path))
    }

    // 4. permission failures are not swallowed
    @Test("a refusal while reading message files fails the body search instead of answering without them")
    func searchPropagatesAReadRefusal() async throws {
        let world = try CtlWorld()
        world.bridge.refuseMatching = { $0.hasSuffix(".emlx") }
        #expect(await ctlFailure { try await world.controller.search("quokkabody") }?.code == "fda_denied")
        // A search that needs no message file still answers.
        #expect(try await world.controller.search("from:alice").records.map(\.id) == [101])
    }

    @Test("a refusal reading Mail's attachment cache is fda_denied for the attachment list and the bytes, not attachment_not_downloaded")
    func attachmentsPropagateAReadRefusal() async throws {
        let world = try CtlWorld()
        try world.addPartialWithAttachment(cached: true)
        world.bridge.refuseMatching = { $0.contains("Attachments") }
        #expect(await ctlFailure { try await world.controller.attachmentData(id: 106, part: "2") }?.code == "fda_denied")
        #expect(await ctlFailure { try await world.controller.attachments(106) }?.code == "fda_denied")
    }

    // 5. a big message is read from its start
    @Test("a word near the start of a message with a big attachment is found, a negated query leaves that message out, and the note says it was partly searched")
    func searchReadsTheStartOfALargeMessage() async throws {
        let world = try CtlWorld()
        try world.addLargeMessage(word: "zebraword")
        let found = try await world.controller.search("zebraword")
        #expect(found.records.map(\.id) == [107])
        #expect(found.note?.contains("partly searched") == true, "\(found.note ?? "no note")")

        let negated = try await world.controller.search("not zebraword")
        let ids = negated.records.map(\.id)
        #expect(!ids.contains(107) && ids.contains(101) && ids.contains(103), "\(ids)")

        // A store of small files has nothing to say about partly read messages.
        let small = try CtlWorld()
        #expect(try await small.controller.search("quokkabody").note == nil)
    }

    // 6. close() beats an in-flight refresh
    @Test("a refresh that is still copying when close() is called installs nothing afterwards")
    func closeBeatsAnInFlightRefresh() async throws {
        let world = try CtlWorld()
        let gate = CtlGate()
        world.bridge.gate = gate
        let call = Task { try? await world.controller.mailboxTree() }
        try await ctlEventually { gate.hasEntered }
        #expect(gate.hasEntered)
        await world.controller.close()
        gate.release()
        _ = await call.value

        #expect(await world.controller.isOpen == false)
        #expect(await world.controller.refreshCount == 0)
        let mirror = world.folder.appendingPathComponent("mirror")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: mirror.path)) ?? []
        #expect(left.filter { $0.hasSuffix(".part") }.isEmpty, "\(left)")

        // And the controller is usable again.
        gate.release()
        #expect(try await world.controller.mailboxTree().count == 1)
        #expect(await world.controller.isOpen)
    }

    // 7. an action invalidates the cached index
    @Test("after an action the next read looks at the mirror again, even inside the refresh interval")
    func anActionInvalidatesTheCache() async throws {
        let world = try CtlWorld(refreshInterval: 60)
        let box = CtlBuilderBox(world.builder)
        // Mail, as soon as it is told to set a property, has changed its index.
        let automation = FakeAutomation { request in
            if request.eventID == "setd" {
                try box.builder.setRead(rowid: 101, true)
                try box.builder.setMailboxCounts(id: 1, total: 4, unread: 2)
            }
            return AppleEventReply()
        }
        let controller = MailCtl.Controller(
            disk: world.bridge, automation: automation, directory: world.folder.appendingPathComponent("acted"),
            configuration: world.configuration(refreshInterval: 60))
        var unread = MailCtl.ListOptions()
        unread.unreadOnly = true
        #expect(try await controller.list(unread).map(\.id) == [102, 101, 104])

        _ = try await controller.mark(101, read: true)
        #expect(try await controller.list(unread).map(\.id) == [102, 104])
        #expect(await controller.refreshCount == 2, "one forced refresh, not one per call")
        _ = try await controller.list(unread)
        #expect(await controller.refreshCount == 2)
    }

    // 9. attachment bytes by part, within a budget
    @Test("the attachment list only stats the cache files, and attachmentData reads just the part it was asked for")
    func attachmentBytesAreLoadedByPart() async throws {
        let world = try CtlWorld()
        try world.addPartialWithCachedFiles(names: ["a.pdf", "b.pdf", "c.pdf"], inline: false, size: 1000)
        let listed = try await world.controller.attachments(108)
        #expect(listed.map(\.filename) == ["a.pdf", "b.pdf", "c.pdf"] && listed.allSatisfy { $0.size == 1000 }, "\(listed)")
        #expect(world.bridge.bytesRead(containing: "Attachments") == 0)

        let second = try await world.controller.attachmentData(id: 108, part: "3")
        #expect(second.filename == "b.pdf" && second.data == Data(repeating: UInt8(ascii: "B"), count: 1000))
        #expect(world.bridge.bytesRead(containing: "Attachments") == 1000)

        // Reading the text of the message loads no attachment at all.
        _ = try await world.controller.message(108, mode: .text)
        #expect(world.bridge.bytesRead(containing: "Attachments") == 1000)
    }

    @Test("what one call loads from the attachment cache stays within the budget: inline images stop at it, a requested part over it is message_too_large")
    func attachmentBytesStayInTheBudget() async throws {
        let world = try CtlWorld(maxAttachmentBytes: 100)
        try world.addPartialWithCachedFiles(names: ["i1.png", "i2.png", "i3.png"], inline: true, size: 60)
        let html = try await world.controller.message(108, mode: .html)
        #expect(!html.bodyUnavailable)
        #expect(world.bridge.bytesRead(containing: "Attachments") <= 100, "\(world.bridge.bytesRead(containing: "Attachments"))")

        let small = try CtlWorld(maxAttachmentBytes: 50)
        try small.addPartialWithCachedFiles(names: ["a.pdf"], inline: false, size: 60)
        #expect(await ctlFailure { try await small.controller.attachmentData(id: 108, part: "2") }?.code == "message_too_large")
        #expect(small.bridge.bytesRead(containing: "Attachments") == 0)
    }

    // MARK: Acting

    private static let work: AppleEventValue = .object(.init(desiredClass: "mact", form: "name", data: .string("Work")))
    private static func box(_ name: String) -> AppleEventValue {
        .object(.init(desiredClass: "mbxp", container: work, form: "name", data: .string(name)))
    }
    private static func message(_ id: Int, in box: AppleEventValue) -> AppleEventValue {
        .object(.init(desiredClass: "mssg", container: box, form: "ID  ", data: .int(id)))
    }
    private static func property(_ code: AppleEventCode, of message: AppleEventValue) -> AppleEventValue {
        .object(.init(desiredClass: "prop", container: message, form: "prop", data: .type(code)))
    }
    private static func request(_ eventClass: AppleEventCode, _ eventID: AppleEventCode, _ parameters: [AppleEventField]) -> AppleEventRequest {
        AppleEventRequest(target: "com.apple.mail", eventClass: eventClass, eventID: eventID, parameters: parameters, timeoutSeconds: 20)
    }

    @Test("mark read looks the message up in its account and mailbox, then sets its read status")
    func markRead() async throws {
        let world = try CtlWorld()
        let inbox101 = Self.message(101, in: Self.box("INBOX"))
        let result = try await world.controller.mark(101, read: true)
        #expect(result.ok && result.link == "mail42://message/101?mid=alice-101%40example.com")
        #expect(world.automation.requests == [
            Self.request("core", "getd", [.init(.directObject, Self.property("ID  ", of: inbox101))]),
            Self.request("core", "setd", [.init(.directObject, Self.property("isrd", of: inbox101)), .init("data", .bool(true))]),
        ])
    }

    @Test("archive moves to the account's Archive, junk to its Junk, and move finds a mailbox by name, role or id")
    func moves() async throws {
        let world = try CtlWorld()
        let inbox103 = Self.message(103, in: Self.box("INBOX"))
        _ = try await world.controller.archive(103)
        #expect(world.automation.requests.last == Self.request("core", "move", [
            .init(.directObject, inbox103), .init("insh", Self.box("Archive")),
        ]))

        _ = try await world.controller.move(103, to: "junk")
        #expect(world.automation.requests.last == Self.request("core", "move", [
            .init(.directObject, inbox103), .init("insh", Self.box("Junk")),
        ]))
        _ = try await world.controller.move(103, to: "2")
        #expect(world.automation.requests.last == Self.request("core", "move", [
            .init(.directObject, inbox103), .init("insh", Self.box("Archive")),
        ]))
        #expect(await ctlFailure { try await world.controller.move(103, to: "Nowhere") }?.code == "not_found")
    }

    @Test("an action on a message the index no longer has is not_found and sends nothing to Mail")
    func actionOnAMissingMessage() async throws {
        let world = try CtlWorld()
        #expect(await ctlFailure { try await world.controller.mark(999, read: true) }?.code == "not_found")
        #expect(world.automation.requests.isEmpty)
    }

    @Test("a refused Apple Event is automation_denied, and a new message with recipients is unsupported_by_automation")
    func refusals() async throws {
        let world = try CtlWorld()
        var configuration = MailCtl.Configuration()
        configuration.library = world.builder.library.path
        configuration.accountsPath = world.builder.root.appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
        let deniedController = MailCtl.Controller(
            disk: world.bridge, automation: FakeAutomation { _ in AppleEventReply(errorNumber: -1743, errorMessage: "not allowed") },
            directory: world.folder.appendingPathComponent("again"), configuration: configuration)
        #expect(await ctlFailure { try await deniedController.mark(101, read: true) }?.code == "automation_denied")
        #expect(await ctlFailure { try await world.controller.draft(.new(to: ["a@example.com"])) }?.code == "unsupported_by_automation")
    }

    @Test("open needs the Message-ID, and sends Mail its message:// link")
    func open() async throws {
        let world = try CtlWorld()
        _ = try await world.controller.open(101)
        let sent = try #require(world.automation.requests.last)
        #expect(sent.eventClass == "GURL" && sent.eventID == "GURL")
        #expect(sent.parameters == [.init(.directObject, .string("message://%3Calice-101%40example.com%3E"))])
    }
}
