import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport

/// End-to-end tests of the real `mail42` binary (built by `swift build`), run against a synthetic Apple Mail library
/// (`MAIL42_MAIL_LIBRARY`) and Accounts database (`MAIL42_ACCOUNTS_DB`). Every run sets both overrides, so none of
/// these tests can touch the user's real mail.
@Suite struct CLITests {

    private struct Run {
        let status: Int32
        let out: String
        let err: String
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] }
        var errorCode: String? { (json?["error"] as? [String: Any])?["code"] as? String }
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

    private func run(_ args: [String], library: URL) throws -> Run {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "MAIL42_NO_REEXEC")
        env.removeValue(forKey: "MAIL42_REEXEC")
        env[Mail42Paths.Override.mailLibrary] = library.path
        env[Mail42Paths.Override.accountsDatabase] = library.deletingLastPathComponent().appendingPathComponent("none.sqlite").path
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
        return Run(
            status: process.terminationStatus,
            out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func missingLibrary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mail42-cli-\(UUID().uuidString)/no-mail-here")
    }

    private func seed(_ mail: EnvelopeIndexBuilder) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 1, unread: 1)
        try mail.addMessage(.init(rowid: 10, subject: "plain zebrafish", senderAddress: "p@example.com",
                                  mailboxID: 1, dateReceived: now - 300, messageIDHeader: "<plain-1@example.com>"))
        try mail.writeEmlx(rowid: 10, data: MailFixtures.emlx(MailFixtures.plain()))
    }

    // MARK: - Failing cleanly

    /// Every verb that reads Apple Mail, with arguments that are valid, so the failure is about the mail and not the arguments.
    private static let readVerbs: [[String]] = [
        ["mailbox", "list"], ["envelope", "list"], ["envelope", "search", "is:unread"], ["message", "read", "10"],
        ["message", "thread", "10"], ["attachment", "list", "10"], ["open", "10"],
    ]

    @Test(arguments: readVerbs)
    func withoutAppleMailDataEveryReadVerbExitsOneAndSaysSo(_ verb: [String]) throws {
        guard Self.requireBinary() else { return }
        let library = missingLibrary()
        let json = try run(verb + ["--json"], library: library)
        #expect(json.status == 1 && json.errorCode == "no_mail_data", "\(verb): \(json.out) \(json.err)")
        let plain = try run(verb, library: library)
        #expect(plain.status == 1 && plain.err.contains("no_mail_data"))
        #expect(!FileManager.default.fileExists(atPath: library.path))        // nothing was created
    }

    @Test(arguments: readVerbs)
    func withoutFullDiskAccessEveryReadVerbExitsOneWithTheFix(_ verb: [String]) throws {
        guard Self.requireBinary(), getuid() != 0 else { return }
        let mail = try EnvelopeIndexBuilder()
        defer { mail.cleanup() }
        try seed(mail)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mail.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mail.library.path) }

        let result = try run(verb + ["--json"], library: mail.library)
        #expect(result.status == 1 && result.errorCode == "fda_denied", "\(verb): \(result.out)")
        #expect((result.json?["error"] as? [String: Any])?["message"] as? String == Mail42Error.fdaDenied.errorDescription)
    }

    @Test func anIndexMail42DoesNotUnderstandIsRefusedNotGuessedAt() throws {
        guard Self.requireBinary() else { return }
        let mail = try EnvelopeIndexBuilder(schemaOmitting: ["messages.size"])
        defer { mail.cleanup() }
        try seed(mail)
        let result = try run(["envelope", "list", "--json"], library: mail.library)
        #expect(result.status == 1 && result.errorCode == "schema_unsupported")
        let message = (result.json?["error"] as? [String: Any])?["message"] as? String
        #expect(message?.contains("size") == true && message?.contains("messages") == true)
    }

    @Test func searchingInsideMessagesReadsTheirText() throws {
        guard Self.requireBinary() else { return }
        let mail = try EnvelopeIndexBuilder()
        defer { mail.cleanup() }
        try seed(mail)
        func ids(_ query: String) throws -> (ids: [Int], run: Run) {
            let result = try run(["envelope", "search", query, "--json"], library: mail.library)
            let rows = (try? JSONSerialization.jsonObject(with: Data(result.out.utf8))) as? [[String: Any]]
            return (rows?.compactMap { $0["id"] as? Int } ?? [], result)
        }
        let body = try ids("body:quokkabody")                  // a word that is only in the message text
        #expect(body.run.status == 0 && body.ids == [10])
        #expect(body.run.err.isEmpty)                          // everything was read: nothing to warn about
        #expect(try ids("quokkabody").ids == [10])
        #expect(try ids("from:p@example.com").ids == [10])     // searches that need no message text work too
        #expect(try ids("body:nothingmatchesthis").ids == [])
    }

    // MARK: - General

    @Test func versionHelpAndUnknownCommands() throws {
        guard Self.requireBinary() else { return }
        let library = missingLibrary()
        #expect(try run(["version"], library: library).out == "mail42 v0.1.0\n")
        #expect(try run(["--version"], library: library).status == 0)

        let help = try run(["help"], library: library)
        #expect(help.status == 0)
        for verb in ["mailbox list", "envelope list", "envelope search", "message read", "message thread",
                     "attachment list", "attachment save", "open <id>", "permissions"] {
            #expect(help.out.contains(verb), "help is missing `\(verb)`")
        }
        #expect(help.out.contains("keeps no copy"))

        // There is no sync any more, and no settings to change.
        for gone in ["sync", "config", "frobnicate"] {
            let result = try run([gone], library: library)
            #expect(result.status == 2, "`\(gone)` should be an unknown command")
        }
        #expect(!help.out.contains("sync") && !help.out.contains("window_days"))
        #expect(!FileManager.default.fileExists(atPath: library.path))
    }
}
