import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import mail42

/// `VerbRunner.run` runs a verb in this process and returns what it wrote; the `mail42` binary prints exactly that.
/// These tests hold the two to the same bytes and the same exit status (WOR-827, AC6 for the CLI side), against a
/// synthetic Apple Mail library so the user's real mail is never touched.
///
/// The suite is serialized: it sets `VerbRunner.version` and the Mail42 path overrides (process-wide).
@Suite(.serialized) struct VerbRunnerTests {

    private static let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/mail42")

    private struct Run: Equatable {
        let status: Int32
        let out: String
        let err: String
    }

    private func inProcess(_ args: [String]) -> Run {
        let result = VerbRunner.run(command: args.first ?? "help", args: Array(args.dropFirst()))
        return Run(status: result.status, out: String(decoding: result.stdout, as: UTF8.self), err: result.stderr)
    }

    private func binary(_ args: [String], library: URL) throws -> Run {
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
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self))
    }

    /// Points this process's mail42 at `library` for the duration of `body`.
    private func withLibrary<T>(_ library: URL, _ body: () throws -> T) rethrows -> T {
        let accounts = library.deletingLastPathComponent().appendingPathComponent("none.sqlite").path
        setenv(Mail42Paths.Override.mailLibrary, library.path, 1)
        setenv(Mail42Paths.Override.accountsDatabase, accounts, 1)
        defer {
            unsetenv(Mail42Paths.Override.mailLibrary)
            unsetenv(Mail42Paths.Override.accountsDatabase)
        }
        return try body()
    }

    private func seed(_ mail: EnvelopeIndexBuilder) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 1, unread: 1)
        try mail.addMessage(.init(rowid: 10, subject: "plain zebrafish", senderAddress: "p@example.com",
                                  mailboxID: 1, dateReceived: now - 300, messageIDHeader: "<plain-1@example.com>"))
        try mail.writeEmlx(rowid: 10, data: MailFixtures.emlx(MailFixtures.plain()))
    }

    // MARK: - Nothing reaches the terminal

    @Test func versionIsReturnedNotPrinted() {
        VerbRunner.version = "9.9.9"
        let run = inProcess(["version"])
        #expect(run == Run(status: 0, out: "mail42 v9.9.9\n", err: ""))
        #expect(inProcess(["help"]).out.hasPrefix("mail42 v9.9.9 — read-only local email"))
    }

    @Test func aUsageErrorCarriesItsStatusAndMessage() {
        let plain = inProcess(["mailbox"])
        #expect(plain.status == 2 && plain.out.isEmpty)
        #expect(plain.err == "mail42: usage: mailbox list [--json] (usage)\n")

        let json = inProcess(["mailbox", "--json"])
        #expect(json.status == 2 && json.err.isEmpty)
        #expect(json.out.contains("\"code\" : \"usage\""))
    }

    @Test func anUnknownCommandPrintsTheUsageAndEndsWithTwo() {
        let run = inProcess(["frobnicate"])
        #expect(run.status == 2)
        #expect(run.err == "mail42: unknown command: frobnicate\n")
        #expect(run.out.contains("Usage: mail42 <command> [options]"))
    }

    @Test func aVerbExitThatReachesAnErrorHandlerPassesThroughUntouched() {
        // `open` ends the verb with status 1 from inside the `do` whose `catch` reports errors. That catch calls
        // `CLI.fail(error:)`, which must hand the same exit on, not report it as a second, generic error.
        let sink = OutputSink()
        Output.$sink.withValue(sink) {
            #expect(throws: VerbExit(status: 7)) { try CLI.fail(error: VerbExit(status: 7), json: true) }
        }
        #expect(sink.stdout.isEmpty && sink.stderr.isEmpty)
    }

    @Test func aFailureInTheMiddleOfAVerbKeepsWhatWasAlreadyWritten() {
        let sink = OutputSink()
        Output.$sink.withValue(sink) {
            Output.write("before\n")
            #expect(throws: VerbExit(status: 1)) { try CLI.fail("stopped", code: 1) }
        }
        #expect(String(decoding: sink.stdout, as: UTF8.self) == "before\n")
        #expect(sink.stderr == "stopped\n")
    }

    @Test func runsDoNotShareOutput() {
        VerbRunner.version = "1.0.0"
        let first = inProcess(["version"])
        let second = inProcess(["version"])
        #expect(first == second)
        #expect(second.out == "mail42 v1.0.0\n")
    }

    @Test func concurrentRunsEachGetTheirOwnOutput() {
        VerbRunner.version = "2.0.0"
        let outputs = LockedArray<String>()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let run = VerbRunner.run(command: index.isMultiple(of: 2) ? "version" : "frobnicate", args: [])
            outputs.append(
                (index.isMultiple(of: 2) ? "version:" : "unknown:") + "\(run.status):"
                    + String(decoding: run.stdout, as: UTF8.self).prefix(14) + "|" + run.stderr)
        }
        let all = outputs.values
        #expect(all.count == 64)
        #expect(all.filter { $0 == "version:0:mail42 v2.0.0\n|" }.count == 32)
        #expect(all.filter { $0 == "unknown:2:mail42 v2.0.0 |mail42: unknown command: frobnicate\n" }.count == 32)
    }

    // MARK: - The same bytes as the binary

    @Test func theBinaryPrintsExactlyWhatTheRunnerReturns() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.binary.path) else {
            Issue.record("the mail42 binary isn't built at \(Self.binary.path)")
            return
        }
        VerbRunner.version = "0.2.0"   // the binary reports its own; keep the comparison about everything else
        let mail = try EnvelopeIndexBuilder()
        defer { mail.cleanup() }
        try seed(mail)
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-runner-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: outFile) }

        let verbs: [[String]] = [
            ["help"], ["version"], ["frobnicate"], ["mailbox"], ["mailbox", "list"], ["mailbox", "list", "--json"],
            ["envelope", "list"], ["envelope", "list", "--json", "--conversations", "--limit", "5"],
            ["envelope", "search", "zebrafish", "--json"], ["envelope", "search"],
            ["message", "read", "10"], ["message", "read", "10", "--json"],
            ["message", "read", "10", "--html", "--out", outFile.path, "--json"],
            ["message", "read", "999", "--json"], ["message", "read", "x"],
            ["message", "thread", "10", "--json"], ["message", "resolve", "10", "--json"],
            ["attachment", "list", "10", "--json"], ["attachment", "list", "999"],
            ["permissions", "bogus"],
        ]
        for verb in verbs {
            let expected = try binary(verb, library: mail.library)
            let actual = withLibrary(mail.library) { inProcess(verb) }
            #expect(actual == expected, "mail42 \(verb.joined(separator: " "))")
        }
    }
}

/// A tiny thread-safe list for the concurrency test.
private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ element: Element) { lock.lock(); storage.append(element); lock.unlock() }
    var values: [Element] { lock.lock(); defer { lock.unlock() }; return storage }
}
