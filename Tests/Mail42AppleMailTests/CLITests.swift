import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport

/// End-to-end tests of the real `mail42` binary (built by `swift build`), run against a sandbox: a temp folder
/// for mail.db and trace.jsonl (`MAIL42_ROOT`) and a synthetic Apple Mail library (`MAIL42_MAIL_LIBRARY`).
/// Every run sets both overrides, so none of these tests can touch the user's real ~/.work42/mail42 or mail.
@Suite struct CLITests {

    private struct Run {
        let status: Int32
        let out: String
        let err: String
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] }
        var errorCode: String? { (json?["error"] as? [String: Any])?["code"] as? String }
    }

    private final class Sandbox {
        let root: URL
        let library: URL
        private let folder: URL

        init(library: URL? = nil) {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("mail42-cli-\(UUID().uuidString)", isDirectory: true)
            root = folder.appendingPathComponent("root", isDirectory: true)
            self.library = library ?? folder.appendingPathComponent("no-mail-here", isDirectory: true)
        }

        var dbURL: URL { root.appendingPathComponent("mail.db") }
        var traceURL: URL { root.appendingPathComponent("trace.jsonl") }

        func cleanup() { try? FileManager.default.removeItem(at: folder) }
    }

    private static let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/mail42")

    private static var available: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    private func run(_ args: [String], in sandbox: Sandbox) throws -> Run {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "MAIL42_NO_REEXEC")
        env.removeValue(forKey: "MAIL42_REEXEC")
        env[Mail42Paths.Override.root] = sandbox.root.path
        env[Mail42Paths.Override.mailLibrary] = sandbox.library.path
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

    /// Three real messages dated a few minutes ago (the CLI uses the real clock).
    private func seedMail(_ mail: EnvelopeIndexBuilder) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 3, unread: 2)
        try mail.addMessage(.init(rowid: 10, subject: "plain zebrafish", senderAddress: "p@example.com",
                                  mailboxID: 1, dateReceived: now - 300, messageIDHeader: "<plain-1@example.com>"))
        try mail.addMessage(.init(rowid: 11, subject: "html hostile", senderAddress: "h@example.com",
                                  mailboxID: 1, dateReceived: now - 400, read: true, messageIDHeader: "<html-1@example.com>"))
        try mail.addMessage(.init(rowid: 12, subject: "attachment", senderAddress: "a@example.com",
                                  mailboxID: 1, dateReceived: now - 500, messageIDHeader: "<attach-1@example.com>"))
        try mail.writeEmlx(rowid: 10, data: MailFixtures.emlx(MailFixtures.plain()))
        try mail.writeEmlx(rowid: 11, data: MailFixtures.emlx(MailFixtures.htmlWithInlineImage()))
        try mail.writeEmlx(rowid: 12, data: MailFixtures.emlx(MailFixtures.withAttachment()))
    }

    // MARK: - config

    @Test func configReadsAndWritesTheWindow() throws {
        guard Self.available else { return }
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }

        let initial = try run(["config", "get", "--json"], in: sandbox)
        #expect(initial.status == 0 && initial.json?["window_days"] as? Int == 90)
        #expect(try run(["config", "get", "window_days"], in: sandbox).out == "90\n")
        #expect(try run(["config", "get"], in: sandbox).out == "window_days=90\n")

        let set = try run(["config", "set", "window_days", "30", "--json"], in: sandbox)
        #expect(set.status == 0 && set.json?["window_days"] as? Int == 30)
        #expect(try run(["config", "get", "window_days"], in: sandbox).out == "30\n")
        #expect(try run(["config", "get", "--json"], in: sandbox).json?["window_days"] as? Int == 30)
        #expect(try MailStore(path: sandbox.dbURL).windowDays() == 30)       // it really is in the sandbox's mail.db

        let all = try run(["config", "set", "window_days", "0"], in: sandbox)
        #expect(all.status == 0 && all.out.contains("all mail"))
    }

    @Test(arguments: [
        ["config"],
        ["config", "frobnicate"],
        ["config", "get", "nope"],
        ["config", "set"],
        ["config", "set", "window_days"],
        ["config", "set", "nope", "5"],
        ["config", "set", "window_days", "abc"],
        ["config", "set", "window_days", "-3"],
        ["config", "set", "window_days", "1.5"],
    ])
    func configRejectsBadInput(_ args: [String]) throws {
        guard Self.available else { return }
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        let result = try run(args + ["--json"], in: sandbox)
        #expect(result.status == 2)
        #expect(result.errorCode == "usage")
        // Rejected input never changes the stored value.
        #expect(try run(["config", "get", "window_days"], in: sandbox).out == "90\n")
    }

    // MARK: - sync

    @Test func syncIndexesThenReportsNothingNew() throws {
        guard Self.available else { return }
        let mail = try EnvelopeIndexBuilder()
        defer { mail.cleanup() }
        try seedMail(mail)
        let sandbox = Sandbox(library: mail.library)
        defer { sandbox.cleanup() }

        let first = try run(["sync", "--json"], in: sandbox)
        #expect(first.status == 0)
        #expect(first.json?["added"] as? Int == 3 && first.json?["updated"] as? Int == 0 && first.json?["removed"] as? Int == 0)
        #expect(first.json?["ms"] is Int)
        #expect(try MailStore(path: sandbox.dbURL).envelopeCount() == 3)

        let again = try run(["sync", "--json"], in: sandbox)
        #expect(again.json?["added"] as? Int == 0 && again.json?["updated"] as? Int == 0 && again.json?["removed"] as? Int == 0)

        let human = try run(["sync"], in: sandbox)
        #expect(human.status == 0)
        #expect(human.out.hasPrefix("Synced: +0 ~0 -0 in "))

        let full = try run(["sync", "--full", "--json"], in: sandbox)
        #expect(full.status == 0 && full.json?["added"] as? Int == 0)

        // One trace line per sync, all successes.
        let lines = try String(contentsOf: sandbox.traceURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.contains("\"sync-ok\"") })
    }

    @Test func syncPicksUpChangesMadeInMail() throws {
        guard Self.available else { return }
        let mail = try EnvelopeIndexBuilder()
        defer { mail.cleanup() }
        try seedMail(mail)
        let sandbox = Sandbox(library: mail.library)
        defer { sandbox.cleanup() }
        _ = try run(["sync"], in: sandbox)

        try mail.setRead(rowid: 10, true)
        try mail.deleteMessage(rowid: 12)
        let result = try run(["sync", "--json"], in: sandbox)
        #expect(result.json?["updated"] as? Int == 1 && result.json?["removed"] as? Int == 1 && result.json?["added"] as? Int == 0)
        #expect(try MailStore(path: sandbox.dbURL).knownIDs() == [10, 11])
    }

    @Test func theWindowSettingAppliesToTheNextSync() throws {
        guard Self.available else { return }
        let mail = try EnvelopeIndexBuilder()
        defer { mail.cleanup() }
        try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]))
        let now = Int64(Date().timeIntervalSince1970)
        try mail.addMessage(.init(rowid: 1, subject: "recent", senderAddress: "a@b.com", mailboxID: 1, dateReceived: now - 3_600))
        try mail.addMessage(.init(rowid: 2, subject: "ten days", senderAddress: "a@b.com", mailboxID: 1, dateReceived: now - 10 * 86_400))
        let sandbox = Sandbox(library: mail.library)
        defer { sandbox.cleanup() }

        _ = try run(["config", "set", "window_days", "7"], in: sandbox)
        #expect(try run(["sync", "--json"], in: sandbox).json?["added"] as? Int == 1)
        _ = try run(["config", "set", "window_days", "30"], in: sandbox)
        #expect(try run(["sync", "--json"], in: sandbox).json?["added"] as? Int == 1)
        #expect(try MailStore(path: sandbox.dbURL).knownIDs() == [1, 2])
    }

    @Test func syncWithoutAppleMailDataExitsOneAndCreatesNothing() throws {
        guard Self.available else { return }
        let sandbox = Sandbox()                                     // library folder doesn't exist
        defer { sandbox.cleanup() }
        let result = try run(["sync", "--json"], in: sandbox)
        #expect(result.status == 1)
        #expect(result.errorCode == "no_mail_data")
        #expect(!FileManager.default.fileExists(atPath: sandbox.dbURL.path))
        let plain = try run(["sync"], in: sandbox)
        #expect(plain.status == 1)
        #expect(plain.err.contains("no_mail_data"))
    }

    @Test func syncWithoutFullDiskAccessExitsOneAndLeavesMailDBAlone() throws {
        guard Self.available, getuid() != 0 else { return }
        let mail = try EnvelopeIndexBuilder()
        defer { mail.cleanup() }
        try seedMail(mail)
        let sandbox = Sandbox(library: mail.library)
        defer { sandbox.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mail.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mail.library.path) }

        let result = try run(["sync", "--json"], in: sandbox)
        #expect(result.status == 1)
        #expect(result.errorCode == "fda_denied")
        #expect((result.json?["error"] as? [String: Any])?["message"] as? String == Mail42Error.fdaDenied.errorDescription)
        #expect(!FileManager.default.fileExists(atPath: sandbox.dbURL.path))
    }

    @Test func syncRefusesAnIndexItDoesNotUnderstand() throws {
        guard Self.available else { return }
        let mail = try EnvelopeIndexBuilder(schemaOmitting: ["messages.size"])
        defer { mail.cleanup() }
        try seedMail(mail)
        let sandbox = Sandbox(library: mail.library)
        defer { sandbox.cleanup() }
        let result = try run(["sync", "--json"], in: sandbox)
        #expect(result.status == 1)
        #expect(result.errorCode == "schema_unsupported")
        let message = (result.json?["error"] as? [String: Any])?["message"] as? String
        #expect(message?.contains("size") == true && message?.contains("messages") == true)
        #expect(!FileManager.default.fileExists(atPath: sandbox.dbURL.path))
    }

    // MARK: - general

    @Test func unknownCommandsExitTwo() throws {
        guard Self.available else { return }
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        #expect(try run(["frobnicate"], in: sandbox).status == 2)
        let help = try run(["help"], in: sandbox)
        #expect(help.status == 0 && help.out.contains("sync [--full]") && help.out.contains("config set window_days"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path))   // help and errors create nothing
    }
}
