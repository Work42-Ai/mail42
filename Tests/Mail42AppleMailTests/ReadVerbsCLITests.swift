import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport

/// End-to-end tests of the read verbs: the real `mail42` binary reading a synthetic Apple Mail store live.
/// Every run is sandboxed (`MAIL42_MAIL_LIBRARY`, `MAIL42_ACCOUNTS_DB`) and forced into `MAIL42_OPEN_DRY_RUN`, so
/// nothing here can touch the user's mail or open Mail.app.
@Suite struct ReadVerbsCLITests {

    struct Run {
        let status: Int32
        let out: String
        let err: String
        var object: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] }
        var array: [[String: Any]]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] }
        var errorCode: String? { (object?["error"] as? [String: Any])?["code"] as? String }
        var errorMessage: String? { (object?["error"] as? [String: Any])?["message"] as? String }
        var ids: [Int64]? { array?.compactMap { ($0["id"] as? NSNumber)?.int64Value } }
    }

    private static let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/mail42")
    /// True when the built `mail42` binary is there. When it isn't, the test FAILS rather than passing without
    /// having tested anything (the test target depends on the executable, so it should always exist).
    private static func requireBinary() -> Bool {
        if FileManager.default.isExecutableFile(atPath: binary.path) { return true }
        Issue.record("the mail42 binary isn't built at \(binary.path): the end-to-end tests have nothing to run")
        return false
    }

    /// A mailbox with seven messages:
    ///   10 plain text, unread, conversation 5         11 hostile HTML + inline image, read, conversation 5
    ///   12 attachment (report.pdf), flagged            13 no file on disk (metadata only), Apple summary
    ///   14 partial file, attachment bytes not cached   15 partial file with no body at all
    ///   16 plain text in Sent, read
    final class Fixture {
        let mail: EnvelopeIndexBuilder
        let accountsDB: URL
        let attachmentsDir: URL
        private let folder: URL

        init() throws {
            mail = try EnvelopeIndexBuilder()
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-read-cli-\(UUID().uuidString)", isDirectory: true)
            attachmentsDir = folder.appendingPathComponent("saved", isDirectory: true)

            let now = Int64(Date().timeIntervalSince1970)
            try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 6, unread: 5)
            try mail.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["Sent Messages"]), total: 1, unread: 0)
            accountsDB = try mail.writeAccountsDatabase([
                .init(pk: 1, identifier: EnvelopeIndexBuilder.accountUUID, username: "yan@example.com",
                      description: "yan@example.com")])
            try mail.addAttachment(messageRowid: 12, attachmentID: "2", name: "report.pdf")
            try mail.addAttachment(messageRowid: 14, attachmentID: "2", name: "report.pdf")
            func add(_ id: Int64, _ subject: String, _ from: String, _ name: String, age: Int64, mailbox: Int64 = 1,
                     read: Bool = false, flagged: Bool = false, conversation: Int64 = 0, header: String?, summary: String? = nil) throws {
                try mail.addMessage(.init(rowid: id, subject: subject, senderAddress: from, senderName: name, mailboxID: mailbox,
                                          dateReceived: now - age, read: read, flagged: flagged, conversationID: conversation,
                                          summary: summary, messageIDHeader: header))
            }
            try add(10, "plain zebrafish", "qa-plain@example.com", "QA Plain", age: 300, conversation: 5, header: "<plain-1@example.com>")
            try add(11, "html hostile", "qa-html@example.com", "QA Html", age: 400, read: true, conversation: 5, header: "<html-1@example.com>")
            try add(12, "attachment", "qa-attach@example.com", "QA Attach", age: 500, flagged: true, header: "<attach-1@example.com>")
            try add(13, "metadata only xylophone", "ex@example.com", "Exchange", age: 600, header: nil, summary: "Apple's summary line")
            try add(14, "partial with attachment", "qa-partial@example.com", "QA Partial", age: 700, header: "<attach-2@example.com>")
            try add(15, "partial no body", "qa-empty@example.com", "QA Empty", age: 800, header: "<partial-2@example.com>")
            try add(16, "sent note", "yan@example.com", "Yan", age: 900, mailbox: 2, read: true, header: "<sent-1@example.com>")
            try mail.addRecipient(messageRowid: 10, address: "yan@example.com", name: "Yan", type: 0, position: 0)
            try mail.addRecipient(messageRowid: 11, address: "yan@example.com", name: "Yan", type: 0, position: 0)
            try mail.addRecipient(messageRowid: 11, address: "bo@example.com", name: "Bo", type: 1, position: 0)
            try mail.writeEmlx(rowid: 10, data: MailFixtures.emlx(MailFixtures.plain()))
            try mail.writeEmlx(rowid: 11, data: MailFixtures.emlx(MailFixtures.htmlWithInlineImage()))
            try mail.writeEmlx(rowid: 12, data: MailFixtures.emlx(MailFixtures.withAttachment()))
            try mail.writeEmlx(rowid: 14, data: MailFixtures.emlx(MailFixtures.partialWithAttachment()), partial: true)
            try mail.writeEmlx(rowid: 15, data: MailFixtures.emlx(MailFixtures.partialWithoutBody()), partial: true)
            try mail.writeEmlx(rowid: 16, data: MailFixtures.emlx(MailFixtures.plain(subject: "sent note", messageID: "<sent-1@example.com>")))
        }

        func cleanup() {
            mail.cleanup()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func run(_ args: [String], _ f: Fixture) throws -> Run {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "MAIL42_NO_REEXEC")
        env.removeValue(forKey: "MAIL42_REEXEC")
        env[Mail42Paths.Override.mailLibrary] = f.mail.library.path
        env[Mail42Paths.Override.accountsDatabase] = f.accountsDB.path
        env["MAIL42_OPEN_DRY_RUN"] = "1"                       // never launch Mail.app from a test
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            Issue.record("`mail42 \(args.joined(separator: " "))` did not finish within 30 s")
            return Run(status: -1, out: "", err: "timeout")
        }
        return Run(status: process.terminationStatus,
                   out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// The fixture, or `nil` when the binary isn't built. (Nothing to sync: the verbs read the store live.)
    private func synced() throws -> Fixture? {
        guard Self.requireBinary() else { return nil }
        return try Fixture()
    }

    // MARK: - mailbox list

    @Test func mailboxListShowsAccountsAndCounts() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let json = try run(["mailbox", "list", "--json"], f)
        #expect(json.status == 0)
        let account = try #require(json.array?.first)
        #expect((account["account"] as? [String: Any])?["email"] as? String == "yan@example.com")
        let boxes = try #require(account["mailboxes"] as? [[String: Any]])
        #expect(boxes.map { $0["name"] as? String } == ["INBOX", "Sent Messages"])
        #expect(boxes.first?["role"] as? String == "inbox" && boxes.first?["unread"] as? Int == 5 && boxes.first?["total"] as? Int == 6)

        let human = try run(["mailbox", "list"], f)
        #expect(human.out.contains("yan@example.com") && human.out.contains("INBOX") && human.out.contains("5 unread"))
        #expect(try run(["mailbox"], f).status == 2)
        #expect(try run(["mailbox", "frobnicate", "--json"], f).errorCode == "usage")
    }

    @Test func everyEnvelopeCarriesALinkThatResolves() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let list = try run(["envelope", "list", "--limit", "3", "--json"], f)
        let link = try #require(list.array?.first?["link"] as? String)
        #expect(link == "mail42://message/10?mid=plain-1%40example.com")

        let resolved = try run(["message", "resolve", link, "--json"], f)
        #expect(resolved.status == 0 && (resolved.object?["id"] as? NSNumber)?.int64Value == 10)
        #expect(resolved.object?["link"] as? String == link)
        #expect(try run(["message", "resolve", "11", "--json"], f).object?["id"] as? NSNumber == 11)     // a bare id works too

        // A message Mail moved (new id, same Message-ID) is found again from its old link.
        try f.mail.deleteMessage(rowid: 12)
        try f.mail.addMessage(.init(rowid: 77, subject: "attachment", senderAddress: "qa-attach@example.com", mailboxID: 1,
                                    dateReceived: Int64(Date().timeIntervalSince1970) - 500, messageIDHeader: "<attach-1@example.com>"))
        let moved = try run(["message", "resolve", "mail42://message/12?mid=attach-1%40example.com", "--json"], f)
        #expect(moved.status == 0 && (moved.object?["id"] as? NSNumber)?.int64Value == 77)

        let gone = try run(["message", "resolve", "mail42://message/999?mid=nowhere%40example.com", "--json"], f)
        #expect(gone.status == 2 && gone.errorCode == "not_found")
        #expect(try run(["message", "resolve", "nonsense", "--json"], f).errorCode == "usage")
        #expect(try run(["message", "resolve", "--json"], f).errorCode == "usage")
    }

    @Test func conversationsListsOneRowPerThread() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let rows = try #require(try run(["envelope", "list", "--conversations", "--json"], f).array)
        // Messages 10 and 11 are one conversation; the others have none.
        #expect(rows.compactMap { ($0["id"] as? NSNumber)?.int64Value } == [10, 12, 13, 14, 15])
        #expect((rows[0]["conversation_count"] as? NSNumber)?.intValue == 2)
        #expect(rows[0]["participants"] as? [String] == ["QA Plain", "QA Html"])
        #expect((rows[1]["conversation_count"] as? NSNumber)?.intValue == 1)
        #expect(rows[0]["link"] as? String == "mail42://message/10?mid=plain-1%40example.com")

        let paged = try run(["envelope", "list", "--conversations", "--limit", "1", "--before", "10", "--json"], f)
        #expect(paged.ids == [12])
        #expect(try run(["envelope", "list", "--conversations"], f).out.contains("plain zebrafish"))
    }

    @Test func anAccountIsNamedAsMailNamesIt() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let account = try #require(try run(["mailbox", "list", "--json"], f).array?.first?["account"] as? [String: Any])
        #expect(account["name"] as? String == "yan@example.com" && account["email"] as? String == "yan@example.com")
        #expect(account["id"] as? String == EnvelopeIndexBuilder.accountUUID)
    }

    // MARK: - envelope list

    @Test func envelopeListIsNewestFirstWithEveryField() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let list = try run(["envelope", "list", "--json"], f)
        #expect(list.status == 0 && list.ids == [10, 11, 12, 13, 14, 15])          // Sent (16) is not an inbox

        let first = try #require(list.array?.first)
        #expect(Set(first.keys) == ["id", "message_id", "conversation_id", "account", "mailbox", "from", "to", "cc",
                                    "subject", "date", "snippet", "is_read", "is_flagged", "has_attachments", "link"])
        #expect(first["message_id"] as? String == "<plain-1@example.com>")
        #expect(first["conversation_id"] as? Int == 5)
        #expect(first["subject"] as? String == "plain zebrafish")
        #expect(first["is_read"] as? Bool == false && first["is_flagged"] as? Bool == false && first["has_attachments"] as? Bool == false)
        #expect((first["from"] as? [String: Any])?["addr"] as? String == "qa-plain@example.com")
        #expect((first["from"] as? [String: Any])?["name"] as? String == "QA Plain")
        #expect(((first["to"] as? [[String: Any]])?.first)?["addr"] as? String == "yan@example.com")
        #expect((first["mailbox"] as? [String: Any])?["role"] as? String == "inbox")
        #expect((first["account"] as? [String: Any])?["email"] as? String == "yan@example.com")
        #expect(first["snippet"] is NSNull)                                       // only Apple's own summary is a snippet
        let date = try #require(first["date"] as? String)
        #expect(date.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil)

        let withNulls = try #require(list.array?.first { ($0["id"] as? Int) == 13 })
        #expect(withNulls["message_id"] is NSNull && withNulls["conversation_id"] is NSNull)       // explicit nulls
        #expect(withNulls["snippet"] as? String == "Apple's summary line")
        let attached = try #require(list.array?.first { ($0["id"] as? Int) == 12 })
        #expect(attached["has_attachments"] as? Bool == true && attached["is_flagged"] as? Bool == true)
        let cc = try #require(list.array?.first { ($0["id"] as? Int) == 11 })
        #expect((cc["cc"] as? [[String: Any]])?.first?["addr"] as? String == "bo@example.com")
    }

    @Test func envelopeListFilters() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        #expect(try run(["envelope", "list", "--unread", "--json"], f).ids == [10, 12, 13, 14, 15])
        #expect(try run(["envelope", "list", "--flagged", "--json"], f).ids == [12])
        #expect(try run(["envelope", "list", "-m", "flagged", "--json"], f).ids == [12])
        #expect(try run(["envelope", "list", "-m", "all", "--json"], f).ids == [10, 11, 12, 13, 14, 15])
        #expect(try run(["envelope", "list", "-m", "2", "--json"], f).ids == [16])                    // by id
        #expect(try run(["envelope", "list", "-m", "sent", "--json"], f).ids == [16])                 // by role
        #expect(try run(["envelope", "list", "-m", "Sent Messages", "--json"], f).ids == [16])        // by name
        #expect(try run(["envelope", "list", "-m", "1", "--unread", "--limit", "2", "--json"], f).ids == [10, 12])
        let missing = try run(["envelope", "list", "-m", "nope", "--json"], f)
        #expect(missing.status == 2 && missing.errorCode == "not_found")
    }

    @Test func envelopePaginationWalksEverythingOnce() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        var seen: [Int64] = []
        var cursor: String?
        for _ in 0..<5 {
            let page = try run(["envelope", "list", "--limit", "2", "--json"] + (cursor.map { ["--before", $0] } ?? []), f)
            guard let ids = page.ids, !ids.isEmpty else { break }
            seen += ids
            cursor = String(ids.last!)
        }
        #expect(seen == [10, 11, 12, 13, 14, 15])
    }

    @Test(arguments: [
        ["envelope", "list", "--limit", "0"], ["envelope", "list", "--limit", "abc"], ["envelope", "list", "--limit", "-1"],
        ["envelope", "list", "--before", "abc"], ["envelope"], ["envelope", "frobnicate"],
    ])
    func envelopeListRejectsBadFlags(_ args: [String]) throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let result = try run(args + ["--json"], f)
        #expect(result.status == 2 && result.errorCode == "usage")
    }

    @Test func aBeforeCursorForAnUnknownMessageIsNotFound() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let result = try run(["envelope", "list", "--before", "999", "--json"], f)
        #expect(result.status == 2 && result.errorCode == "not_found")
    }

    @Test func envelopeListTableIsReadable() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let table = try run(["envelope", "list"], f)
        #expect(table.status == 0)
        #expect(table.out.contains("SUBJECT") && table.out.contains("plain zebrafish") && table.out.contains("QA Plain"))
        #expect(table.out.contains("yan@example.com · INBOX"))
        #expect(table.out.contains("● unread"))
        let empty = try run(["envelope", "list", "-m", "sent", "--unread"], f)
        #expect(empty.out.contains("No messages."))
    }

    // MARK: - envelope search

    @Test func searchFindsByHeaderFieldsAndState() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        #expect(try run(["envelope", "search", "quokkabody", "--json"], f).ids == [10])           // body only
        #expect(try run(["envelope", "search", "Roadmap", "--json"], f).ids == [11])              // HTML body, converted
        #expect(try run(["envelope", "search", "xylophone", "--json"], f).ids == [13])            // subject, no file on disk
        #expect(try run(["envelope", "search", "from:qa-attach has:attachment", "--json"], f).ids == [12])
        #expect(try run(["envelope", "search", "is:flagged", "--json"], f).ids == [12])
        #expect(try run(["envelope", "search", "in:sent", "--json"], f).ids == [16])
        #expect(try run(["envelope", "search", "to:bo", "--json"], f).ids == [11])                // Cc
        #expect(Set(try run(["envelope", "search", "is:unread in:inbox", "--json"], f).ids ?? []) == [10, 12, 13, 14, 15])
        #expect(try run(["envelope", "search", "date:1d..", "is:flagged", "--json"], f).ids == [12])
        #expect(try run(["envelope", "search", "nothingmatchesthis", "--json"], f).ids == [])
    }

    @Test func searchAcceptsUnquotedWordsAndFlagsInAnyOrder() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        #expect(try run(["envelope", "search", "from:qa-html", "roadmap", "--json"], f).ids == [11])
        #expect(try run(["envelope", "search", "--limit", "1", "is:unread", "in:inbox", "--json"], f).ids?.count == 1)
        #expect(try run(["envelope", "search", "is:unread", "--limit", "1", "--json"], f).ids?.count == 1)
        #expect(try run(["--json", "envelope", "search", "quokkabody"], f).status == 2)           // flags before the verb aren't supported
    }

    @Test func searchReportsBadQueriesWithAPosition() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        for query in ["from:", "(is:unread", "is:unread)", "is:maybe", "date:yesterday", "not", "a or", "\"unclosed"] {
            let result = try run(["envelope", "search", query, "--json"], f)
            #expect(result.status == 2 && result.errorCode == "bad_query", "query: \(query) -> \(result.out)")
            #expect(result.errorMessage?.contains("position") == true, "query: \(query)")
        }
        let human = try run(["envelope", "search", "from:"], f)
        #expect(human.status == 2 && human.err.contains("bad_query"))
        #expect(try run(["envelope", "search", "--json"], f).errorCode == "usage")
        #expect(try run(["envelope", "search", "   ", "--json"], f).errorCode == "usage")
    }

    @Test func searchIsInjectionProof() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let result = try run(["envelope", "search", "from:\"x' OR 1=1 --\"", "--json"], f)
        #expect(result.status == 0 && result.ids == [])
        #expect(try run(["envelope", "list", "--json"], f).ids?.count == 6)       // still intact
    }

    // MARK: - message read

    @Test func readsAPlainMessage() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let json = try run(["message", "read", "10", "--json"], f)
        #expect(json.status == 0)
        let object = try #require(json.object)
        #expect(Set(object.keys) == ["envelope", "headers", "text", "html", "attachments", "body_unavailable"])
        #expect((object["envelope"] as? [String: Any])?["id"] as? Int == 10)
        #expect((object["text"] as? String)?.contains("quokkabody") == true)
        #expect(object["html"] is NSNull && object["body_unavailable"] as? Bool == false)
        #expect((object["headers"] as? [String: String])?["message-id"] == "<plain-1@example.com>")
        #expect((object["attachments"] as? [Any])?.isEmpty == true)

        let human = try run(["message", "read", "10"], f)
        #expect(human.status == 0)
        #expect(human.out.contains("Subject: plain zebrafish") && human.out.contains("From:") && human.out.contains("quokkabody"))
        #expect(human.out.contains("QA Plain <qa-plain@example.com>") && human.out.contains("To:      Yan <yan@example.com>"))
        #expect(try run(["message", "read", "10", "--text", "--json"], f).object?["text"] is String)
    }

    @Test func aHTMLOnlyMessageReadsAsText() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let json = try run(["message", "read", "11", "--json"], f)
        let text = try #require(json.object?["text"] as? String)
        #expect(text.contains("Roadmap headline") && text.contains("Click me paragraph"))
        #expect(!text.contains("<h1>") && !text.contains("SCRIPT RAN") && !text.contains("document.body"))   // no markup, no script
    }

    @Test func readsTheSanitisedHTML() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let json = try run(["message", "read", "11", "--html", "--json"], f)
        let html = try #require(json.object?["html"] as? String)
        #expect(json.object?["text"] is NSNull)
        #expect(html.contains("<body data-mail42-id=\"11\""))
        #expect(html.contains("Roadmap headline") && html.contains("safe link"))
        for forbidden in ["<script", "onclick", "javascript:", "SCRIPT RAN"] {
            #expect(!html.lowercased().contains(forbidden.lowercased()), "found \(forbidden)")
        }
        #expect(html.contains("data:image/png;base64,"))                         // the cid: image is inlined
        #expect(!html.contains("cid:logo1"))
        #expect(html.contains("https://img.example.com/p.png"))                  // remote images are left alone
        #expect(try run(["message", "read", "11", "--html"], f).out.contains("<body data-mail42-id=\"11\""))
    }

    @Test func writesTheBodyToAFile() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let out = f.attachmentsDir.appendingPathComponent("nested/message-11.html").path

        let json = try run(["message", "read", "11", "--html", "--out", out, "--json"], f)
        #expect(json.status == 0)
        #expect(json.object?["path"] as? String == out && json.object?["body_unavailable"] as? Bool == false)
        let html = try String(contentsOfFile: out, encoding: .utf8)
        #expect(html.contains("data-mail42-id=\"11\"") && !html.contains("<script"))

        let plainOut = f.attachmentsDir.appendingPathComponent("message-10.txt").path
        let human = try run(["message", "read", "10", "--out", plainOut], f)
        #expect(human.out == plainOut + "\n")
        #expect(try String(contentsOfFile: plainOut, encoding: .utf8).contains("quokkabody"))
    }

    @Test func readsHeadersOnly() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let json = try run(["message", "read", "10", "--headers", "--json"], f)
        #expect(json.object?["text"] is NSNull && json.object?["html"] is NSNull)
        #expect((json.object?["headers"] as? [String: String])?["subject"] == "mail42-qa plain zebrafish")
        let human = try run(["message", "read", "10", "--headers"], f)
        #expect(human.out.contains("message-id: <plain-1@example.com>") && !human.out.contains("quokkabody"))
    }

    @Test func aMessageWithoutAFileReportsTheBodyAsUnavailable() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let json = try run(["message", "read", "13", "--json"], f)
        #expect(json.status == 0 && json.object?["body_unavailable"] as? Bool == true)
        #expect(json.object?["text"] is NSNull)
        #expect((json.object?["envelope"] as? [String: Any])?["snippet"] as? String == "Apple's summary line")

        let human = try run(["message", "read", "13"], f)
        #expect(human.status == 0 && human.out.contains("Apple's summary line") && human.out.contains("mail42 open 13"))

        let out = f.attachmentsDir.appendingPathComponent("never.txt").path
        let file = try run(["message", "read", "13", "--out", out, "--json"], f)
        #expect(file.status == 0 && file.object?["path"] is NSNull && file.object?["body_unavailable"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @Test func partialMessagesAreUnavailableOnlyWhenTheyHaveNoBody() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        #expect(try run(["message", "read", "15", "--json"], f).object?["body_unavailable"] as? Bool == true)    // headers only
        let withText = try run(["message", "read", "14", "--json"], f)
        #expect(withText.object?["body_unavailable"] as? Bool == false)
        #expect((withText.object?["text"] as? String)?.contains("live in Mail's cache") == true)
    }

    @Test func readRejectsBadInput() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        #expect(try run(["message", "read", "9999", "--json"], f).errorCode == "not_found")
        #expect(try run(["message", "read", "9999", "--json"], f).status == 2)
        for args in [["message", "read"], ["message", "read", "abc"], ["message", "read", "0"], ["message", "read", "-5"],
                     ["message", "read", "10", "--text", "--html"], ["message", "read", "10", "--html", "--headers"], ["message"],
                     ["message", "frobnicate"]] {
            let result = try run(args + ["--json"], f)
            #expect(result.status == 2 && result.errorCode == "usage", "args: \(args)")
        }
    }

    @Test func readingWithoutFullDiskAccessIsNotMistakenForAMissingBody() throws {
        guard let f = try synced(), getuid() != 0 else { return }
        defer { f.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.mail.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.mail.library.path) }
        let result = try run(["message", "read", "10", "--json"], f)
        #expect(result.status == 1 && result.errorCode == "fda_denied")
        // Nothing can be read without it: the index is behind the same permission.
        #expect(try run(["envelope", "list", "--json"], f).errorCode == "fda_denied")
        #expect(try run(["attachment", "save", "12", "2", "--to", f.attachmentsDir.path, "--json"], f).errorCode == "fda_denied")
    }

    // MARK: - message thread

    @Test func threadsListTheConversationOldestFirst() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        #expect(try run(["message", "thread", "10", "--json"], f).ids == [11, 10])             // 11 is older
        #expect(try run(["message", "thread", "11", "--json"], f).ids == [11, 10])
        #expect(try run(["message", "thread", "12", "--json"], f).ids == [12])                 // no conversation: itself
        #expect(try run(["message", "thread", "9999", "--json"], f).errorCode == "not_found")
        #expect(try run(["message", "thread", "--json"], f).errorCode == "usage")
        #expect(try run(["message", "thread", "10"], f).out.contains("html hostile"))
    }

    // MARK: - attachments

    @Test func listsAttachments() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let list = try run(["attachment", "list", "12", "--json"], f)
        let item = try #require(list.array?.first)
        #expect(list.array?.count == 1)
        #expect(item["filename"] as? String == "report.pdf" && item["mime"] as? String == "application/pdf")
        #expect(item["part"] as? String == "2" && item["size"] as? Int == MailFixtures.attachmentBytes.count)
        #expect(try run(["attachment", "list", "10", "--json"], f).array?.isEmpty == true)
        #expect(try run(["attachment", "list", "10"], f).out == "No attachments.\n")
        #expect(try run(["attachment", "list", "12"], f).out.contains("report.pdf"))
        #expect(try run(["attachment", "list", "9999", "--json"], f).errorCode == "not_found")
        #expect(try run(["attachment", "list", "--json"], f).errorCode == "usage")
        #expect(try run(["attachment", "list", "14", "--json"], f).array?.first?["filename"] as? String == "report.pdf")
    }

    @Test func savesAnAttachmentWithoutOverwriting() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let dir = f.attachmentsDir.path
        let first = try run(["attachment", "save", "12", "2", "--to", dir, "--json"], f)
        #expect(first.status == 0 && first.object?["bytes"] as? Int == MailFixtures.attachmentBytes.count)
        let path = try #require(first.object?["path"] as? String)
        #expect(URL(fileURLWithPath: path).lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == MailFixtures.attachmentBytes)

        let second = try run(["attachment", "save", "12", "2", "--to", dir], f)
        #expect(second.status == 0 && second.out.hasSuffix("report (1).pdf\n"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == MailFixtures.attachmentBytes)     // the first copy is untouched
    }

    @Test func attachmentSaveReportsWhatWentWrong() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let dir = f.attachmentsDir.path
        #expect(try run(["attachment", "save", "12", "7", "--to", dir, "--json"], f).errorCode == "not_found")       // no such part
        #expect(try run(["attachment", "save", "12", "1", "--to", dir, "--json"], f).errorCode == "not_found")       // the text body isn't an attachment
        #expect(try run(["attachment", "save", "9999", "1", "--to", dir, "--json"], f).errorCode == "not_found")
        #expect(try run(["attachment", "save", "13", "1", "--to", dir, "--json"], f).errorCode == "emlx_not_found")  // no file on disk
        let notDownloaded = try run(["attachment", "save", "14", "2", "--to", dir, "--json"], f)
        #expect(notDownloaded.status == 2 && notDownloaded.errorCode == "attachment_not_downloaded")
        #expect(notDownloaded.errorMessage?.contains("mail42 open") == true)
        for args in [["attachment", "save"], ["attachment", "save", "12"], ["attachment", "save", "abc", "2"], ["attachment"]] {
            #expect(try run(args + ["--json"], f).errorCode == "usage", "args: \(args)")
        }
        #expect(!FileManager.default.fileExists(atPath: dir))                      // nothing was written
    }

    // MARK: - open

    @Test func openBuildsTheMessageURL() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let json = try run(["open", "10", "--json"], f)
        #expect(json.status == 0)
        #expect(json.object?["url"] as? String == "message://%3Cplain-1%40example.com%3E")
        #expect(json.object?["opened"] as? Bool == false)                           // dry run: nothing was launched
        #expect(try run(["open", "10"], f).out == "message://%3Cplain-1%40example.com%3E\n")
    }

    @Test func openRefusesWhatItCannotOpen() throws {
        guard let f = try synced() else { return }
        defer { f.cleanup() }
        let noID = try run(["open", "13", "--json"], f)                              // no Message-ID header anywhere
        #expect(noID.status == 2 && noID.errorCode == "no_message_id")
        #expect(try run(["open", "9999", "--json"], f).errorCode == "not_found")
        #expect(try run(["open", "--json"], f).errorCode == "usage")
        #expect(try run(["open", "abc", "--json"], f).errorCode == "usage")
    }
}
