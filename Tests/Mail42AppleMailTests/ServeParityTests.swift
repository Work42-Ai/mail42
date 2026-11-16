import Foundation
import Testing
import Mail42Kit
import Mail42TestSupport
@testable import mail42

/// The real verbs through the real daemon, against a synthetic Apple Mail library (WOR-828: AC6, AC7, AC9).
///
/// Every test points this process at the fixture through the same environment overrides the CLI tests use, and
/// `MAIL42_NO_REEXEC=1` (a test process must never re-launch itself), so the user's real mail is never touched.
extension ProcessWide {
    @Suite struct ServeParityTests {

        private typealias Fixture = ServeFixture

        private static let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/mail42")

        private static let sandboxVariables = [
            Mail42Paths.Override.mailLibrary, Mail42Paths.Override.accountsDatabase,
            "MAIL42_NO_REEXEC", "MAIL42_ACTIONS_DRY_RUN", "MAIL42_OPEN_DRY_RUN",
        ]

        /// Runs `body` with this process pointed at `fixture`.
        private func sandboxed<T>(_ fixture: ReadVerbsCLITests.Fixture, _ body: () async throws -> T) async rethrows -> T {
            setenv(Mail42Paths.Override.mailLibrary, fixture.mail.library.path, 1)
            setenv(Mail42Paths.Override.accountsDatabase, fixture.accountsDB.path, 1)
            setenv("MAIL42_NO_REEXEC", "1", 1)
            setenv("MAIL42_ACTIONS_DRY_RUN", "1", 1)
            setenv("MAIL42_OPEN_DRY_RUN", "1", 1)
            VerbRunner.version = "0.3.0"
            defer { for name in Self.sandboxVariables { unsetenv(name) } }
            return try await body()
        }

        private struct Answer: Equatable {
            let stdout: String
            let stderr: String
            let status: Int
        }

        private func inProcess(_ words: [String]) -> Answer {
            let result = VerbRunner.run(command: words[0], args: Array(words.dropFirst()))
            return Answer(stdout: String(decoding: result.stdout, as: UTF8.self), stderr: result.stderr, status: Int(result.status))
        }

        private func throughTheDaemon(_ client: TestClient, _ id: Int, _ words: [String]) -> Answer? {
            client.request(id, words[0], Array(words.dropFirst()))
            guard let reply = client.reply(timeout: 10) else { return nil }
            return Answer(stdout: reply.stdout, stderr: reply.stderr, status: reply.status)
        }

        // MARK: - Every verb the widget uses answers the same bytes through the daemon

        @Test func everyVerbTheWidgetUsesAnswersTheSameBytesAndStatusThroughTheDaemon() async throws {
            let fixture = try ReadVerbsCLITests.Fixture()
            defer { fixture.cleanup() }
            let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("m42-parity-\(UUID().uuidString.prefix(8)).html").path
            defer { try? FileManager.default.removeItem(atPath: outFile) }

            try await sandboxed(fixture) {
                let daemon = try Fixture.daemon()
                defer { Fixture.cleanup(daemon) }
                let client = try #require(TestClient(socket: daemon.socketURL))
                #expect(client.hello() == true)

                let verbs: [[String]] = [
                    // reading: lists, pages, search
                    ["mailbox", "list"], ["mailbox", "list", "--json"],
                    ["envelope", "list"], ["envelope", "list", "--json"], ["envelope", "list", "--unread", "--json"],
                    ["envelope", "list", "--conversations", "--limit", "50", "-m", "all", "--json"],
                    ["envelope", "list", "--conversations", "--limit", "50", "-m", "flagged", "--json"],
                    ["envelope", "list", "--conversations", "--limit", "50", "-m", "1", "--json"],
                    ["envelope", "list", "--conversations", "--limit", "2", "-m", "all", "--before", "12", "--json"],
                    ["envelope", "search", "zebrafish", "--headers", "--limit", "50", "--json"],
                    ["envelope", "search", "xylophone", "--json"], ["envelope", "search", "from:qa-attach has:attachment", "--json"],
                    // reading: one message
                    ["message", "read", "10"], ["message", "read", "10", "--json"], ["message", "read", "11", "--html", "--json"],
                    ["message", "read", "12", "--headers"], ["message", "read", "13", "--json"], ["message", "read", "14", "--json"],
                    ["message", "read", "10", "--html", "--out", outFile, "--json"],
                    ["message", "thread", "10", "--json"], ["message", "thread", "10"],
                    ["message", "resolve", "10", "--json"], ["message", "resolve", "mail42://message/11", "--json"],
                    ["attachment", "list", "12", "--json"], ["attachment", "list", "12"],
                    // failing the way the command line fails
                    ["message", "read", "999", "--json"], ["message", "resolve", "999", "--json"], ["message", "read", "x"],
                    ["attachment", "list", "999"], ["attachment", "save", "12", "99", "--json"], ["envelope", "search"],
                    ["mailbox"], ["frobnicate"], ["permissions", "bogus", "--json"],
                    // access
                    ["permissions", "--json"], ["permissions"],
                    // acting (dry run: the scripts that would be sent)
                    ["mark", "10", "read", "--json"], ["mark", "10", "unread"], ["mark", "12", "flagged", "--color", "red", "--json"],
                    ["mark", "12", "unflagged", "--json"], ["move", "10", "Sent Messages", "--json"], ["archive", "10", "--json"],
                    ["delete", "10", "--json"], ["junk", "10", "--json"], ["draft", "reply", "10", "--json"],
                    ["draft", "reply-all", "10", "--json"], ["draft", "forward", "10", "--json"],
                    ["draft", "new", "--to", "a@example.com", "--subject", "hi", "--body", "hello", "--json"],
                    ["open", "10"], ["open", "10", "--json"], ["mark", "10"],
                ]
                for (index, words) in verbs.enumerated() {
                    let expected = inProcess(words)
                    let actual = try #require(throughTheDaemon(client, index + 1, words), "no answer to mail42 \(words.joined(separator: " "))")
                    #expect(actual == expected, "mail42 \(words.joined(separator: " "))")
                }
            }
        }

        @Test func savingAnAttachmentAnswersTheSameThroughTheDaemon() async throws {
            let fixture = try ReadVerbsCLITests.Fixture()
            defer { fixture.cleanup() }
            let here = FileManager.default.temporaryDirectory.appendingPathComponent("m42-save-a-\(UUID().uuidString.prefix(8))")
            let there = FileManager.default.temporaryDirectory.appendingPathComponent("m42-save-b-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: here); try? FileManager.default.removeItem(at: there) }

            try await sandboxed(fixture) {
                let daemon = try Fixture.daemon()
                defer { Fixture.cleanup(daemon) }
                let client = try #require(TestClient(socket: daemon.socketURL))
                client.hello()
                let viaDaemon = try #require(throughTheDaemon(client, 1, ["attachment", "save", "12", "2", "--to", here.path, "--json"]))
                let direct = inProcess(["attachment", "save", "12", "2", "--to", there.path, "--json"])
                // The two runs save into different folders; everything but the folder must match.
                #expect(viaDaemon.status == 0 && direct.status == 0)
                #expect(viaDaemon.stdout.replacingOccurrences(of: here.path, with: "<dir>")
                        == direct.stdout.replacingOccurrences(of: there.path, with: "<dir>"))
                #expect(FileManager.default.fileExists(atPath: here.appendingPathComponent("report.pdf").path))
            }
        }

        @Test func theDaemonReadsThroughOneSharedIndexAndSeesNewMailWithoutRestarting() async throws {
            let fixture = try ReadVerbsCLITests.Fixture()
            defer { fixture.cleanup() }
            try await sandboxed(fixture) {
                let daemon = try Fixture.daemon()
                defer { Fixture.cleanup(daemon) }
                let client = try #require(TestClient(socket: daemon.socketURL))
                client.hello()
                let before = try #require(throughTheDaemon(client, 1, ["envelope", "list", "--json"]))
                #expect(!before.stdout.contains("arrived later"))

                try fixture.mail.addMessage(.init(
                    rowid: 90, subject: "arrived later", senderAddress: "late@example.com", mailboxID: 1,
                    dateReceived: Int64(Date().timeIntervalSince1970)))
                let after = try #require(throughTheDaemon(client, 2, ["envelope", "list", "--json"]))
                #expect(after.stdout.contains("arrived later"))           // the shared connection reads live, not a copy
            }
        }

        // MARK: - Telling subscribers (AC9)

        @Test func subscribersAreToldWhenACounterMovesAndNotOtherwise() async throws {
            let mail = try EnvelopeIndexBuilder(wal: true)
            defer { mail.cleanup() }
            try mail.addMailbox(id: 1, url: EnvelopeIndexBuilder.mailboxURL(["INBOX"]), total: 10, unread: 4)
            try mail.addMailbox(id: 2, url: EnvelopeIndexBuilder.mailboxURL(["Sent"]), total: 3, unread: 0)

            setenv(Mail42Paths.Override.mailLibrary, mail.library.path, 1)
            setenv(Mail42Paths.Override.accountsDatabase, mail.library.deletingLastPathComponent().appendingPathComponent("none.sqlite").path, 1)
            setenv("MAIL42_NO_REEXEC", "1", 1)
            defer { for name in Self.sandboxVariables { unsetenv(name) } }

            let daemon = try Fixture.daemon(watchIndex: true, debounce: 0.1)
            defer { Fixture.cleanup(daemon) }
            let first = try #require(TestClient(socket: daemon.socketURL))
            let second = try #require(TestClient(socket: daemon.socketURL))
            first.hello(); second.hello()
            first.send(["subscribe": "changes"])
            second.send(["subscribe": "changes"])
            let ack = try #require(first.receive())
            #expect(ack["subscribed"] as? String == "changes")
            #expect(ack["signature"] as? String == "1:10:4,2:3:0")        // the counters now
            _ = second.receive()

            try mail.setMailboxCounts(id: 1, total: 11, unread: 5)        // mail arrived
            for client in [first, second] {                               // every subscriber, within a second
                let event = try #require(client.receive(timeout: 1.5))
                #expect(event["event"] as? String == "changed" && event["signature"] as? String == "1:11:5,2:3:0")
            }

            // A write that leaves every counter as it was: nothing is sent.
            try mail.addMessage(.init(rowid: 60, subject: "draft", senderAddress: "me@example.com", mailboxID: 1, dateReceived: 1_761_000_000))
            try mail.setMailboxCounts(id: 1, total: 11, unread: 5)
            #expect(first.receive(timeout: 0.8) == nil)

            try mail.setMailboxCounts(id: 2, total: 3, unread: 1)         // another change: another event, once
            let again = try #require(first.receive(timeout: 1.5))
            #expect(again["signature"] as? String == "1:11:5,2:3:1")
            #expect(first.receive(timeout: 0.5) == nil)
        }

        // MARK: - The command line's side (AC7)

        @Test func theCommandLineUsesTheDaemonWhenOneOfItsVersionAnswers() throws {
            let daemon = try Fixture.daemon(runVerb: { verb, args in
                Fixture.result("from the daemon: \(verb) \(args.joined(separator: " "))\n", status: 3, stderr: "note\n")
            })
            defer { Fixture.cleanup(daemon) }
            let answer = try #require(ServeClient.forward(
                command: "mailbox", args: ["list", "--json"], version: "0.3.0",
                environment: ["MAIL42_SERVE_DIR": daemon.configuration.directory.path]))
            #expect(String(decoding: answer.stdout, as: UTF8.self) == "from the daemon: mailbox list --json\n")
            #expect(answer.stderr == "note\n" && answer.status == 3)
        }

        @Test func theCommandLineWorksAloneWhenNoDaemonAnswers() throws {
            let empty = Fixture.directory()
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            #expect(ServeClient.forward(command: "mailbox", args: ["list"], version: "0.3.0",
                                        environment: ["MAIL42_SERVE_DIR": empty.path]) == nil)

            // A socket file with nobody behind it (a daemon that was killed) is the same.
            let stale = Fixture.directory()
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stale) }
            let dead = try Fixture.daemon(directory: stale)
            let socketPath = dead.socketURL.path
            dead.stop()
            FileManager.default.createFile(atPath: socketPath, contents: Data())
            #expect(ServeClient.forward(command: "mailbox", args: ["list"], version: "0.3.0",
                                        environment: ["MAIL42_SERVE_DIR": stale.path]) == nil)
        }

        @Test func aDaemonOfAnotherVersionIsNotUsed() async throws {
            let older = try Fixture.daemon(version: "0.2.0", runVerb: { _, _ in Fixture.result("old daemon") })
            defer { Fixture.cleanup(older) }
            // The command line is newer: the daemon steps aside, and the verb runs in-process.
            #expect(ServeClient.forward(command: "mailbox", args: ["list"], version: "0.3.0",
                                        environment: ["MAIL42_SERVE_DIR": older.configuration.directory.path]) == nil)
            await Fixture.wait { older.isStopped }
            #expect(older.isStopped)

            let newer = try Fixture.daemon(version: "0.4.0", runVerb: { _, _ in Fixture.result("new daemon") })
            defer { Fixture.cleanup(newer) }
            // The command line is older: it must not take the newer daemon down.
            #expect(ServeClient.forward(command: "mailbox", args: ["list"], version: "0.3.0",
                                        environment: ["MAIL42_SERVE_DIR": newer.configuration.directory.path]) == nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!newer.isStopped)
        }

        @Test func anActionThatLosesItsDaemonIsReportedNotRunAgain() async throws {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let daemon = try Fixture.daemon(runVerb: { _, _ in started.signal(); release.wait(); return Fixture.result("") })
            defer { release.signal(); release.signal(); Fixture.cleanup(daemon) }      // two daemons' actions wait on it
            let environment = ["MAIL42_SERVE_DIR": daemon.configuration.directory.path]

            let plain = Recorded<VerbResult?>(), json = Recorded<VerbResult?>()
            let forwarding = Thread {
                plain.add(ServeClient.forward(command: "archive", args: ["5"], version: "0.3.0", environment: environment))
            }
            forwarding.start()
            blockUntil(started)
            daemon.stop()                                              // the daemon dies with the action in flight
            await Fixture.wait { !plain.values.isEmpty }
            let lost = try #require(plain.values.first ?? nil)
            #expect(lost.status == 1 && lost.stderr.contains("service_stopped") && lost.stdout.isEmpty)

            // As JSON the same failure is the usual error object.
            let second = try Fixture.daemon(directory: daemon.configuration.directory, runVerb: { _, _ in started.signal(); release.wait(); return Fixture.result("") })
            defer { Fixture.cleanup(second) }
            let again = Thread {
                json.add(ServeClient.forward(command: "archive", args: ["5", "--json"], version: "0.3.0", environment: environment))
            }
            again.start()
            blockUntil(started)
            second.stop()
            await Fixture.wait { !json.values.isEmpty }
            let lostJSON = try #require(json.values.first ?? nil)
            #expect(lostJSON.status == 1)
            #expect(String(decoding: lostJSON.stdout, as: UTF8.self).contains("\"service_stopped\""))
        }

        @Test func aReadThatLosesItsDaemonIsAskedAgainInProcess() async throws {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let daemon = try Fixture.daemon(runVerb: { _, _ in started.signal(); release.wait(); return Fixture.result("") })
            defer { release.signal(); Fixture.cleanup(daemon) }
            let environment = ["MAIL42_SERVE_DIR": daemon.configuration.directory.path]
            let outcome = Recorded<Bool>()                              // true: the client said "run it yourself"
            let forwarding = Thread {
                outcome.add(ServeClient.forward(command: "mailbox", args: ["list"], version: "0.3.0", environment: environment) == nil)
            }
            forwarding.start()
            blockUntil(started)
            daemon.stop()
            await Fixture.wait { !outcome.values.isEmpty }
            #expect(outcome.values == [true])
        }

        @Test func aRunAgainstASandboxNeverGoesToADaemon() throws {
            let local = ["serve", "version", "--version", "-v", "help", "--help", "-h", ""]
            for command in local { #expect(!ServeClient.shouldForward(command: command, environment: [:])) }
            #expect(ServeClient.shouldForward(command: "mailbox", environment: [:]))
            #expect(!ServeClient.shouldForward(command: "mailbox", environment: ["MAIL42_NO_SERVE": "1"]))
            // A test or a copy of a mail store must not be answered from the real mail.
            #expect(!ServeClient.shouldForward(command: "mailbox", environment: ["MAIL42_MAIL_LIBRARY": "/tmp/x"]))
            #expect(!ServeClient.shouldForward(command: "mailbox", environment: ["MAIL42_ACCOUNTS_DB": "/tmp/x"]))
            // ...unless the run also names the sandbox's own daemon.
            #expect(ServeClient.shouldForward(command: "mailbox", environment: ["MAIL42_MAIL_LIBRARY": "/tmp/x", "MAIL42_SERVE_DIR": "/tmp/s"]))
        }

        // MARK: - The real binary

        @Test func theBinaryStartsADetachedDaemonThatServesTheCommandLine() async throws {
            guard FileManager.default.isExecutableFile(atPath: Self.binary.path) else {
                Issue.record("the mail42 binary isn't built at \(Self.binary.path)")
                return
            }
            let fixture = try ReadVerbsCLITests.Fixture()
            defer { fixture.cleanup() }
            let folder = Fixture.directory()
            defer { try? FileManager.default.removeItem(at: folder) }

            var environment = ProcessInfo.processInfo.environment
            for name in ["MAIL42_NO_REEXEC", "MAIL42_REEXEC", "MAIL42_NO_SERVE"] { environment.removeValue(forKey: name) }
            environment[Mail42Paths.Override.mailLibrary] = fixture.mail.library.path
            environment[Mail42Paths.Override.accountsDatabase] = fixture.accountsDB.path
            environment["MAIL42_SERVE_DIR"] = folder.path
            environment["MAIL42_SERVE_IDLE_SECONDS"] = "3"

            func run(_ args: [String], extra: [String: String] = [:]) throws -> (status: Int32, out: String, err: String) {
                let process = Process()
                process.executableURL = Self.binary
                process.arguments = args
                process.environment = environment.merging(extra) { _, new in new }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                try process.run()
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
            }

            // `serve --detach` returns at once; the daemon appears by itself.
            let detach = try run(["serve", "--detach"])
            #expect(detach.status == 0)
            let socket = folder.appendingPathComponent("serve.sock")
            await Fixture.wait(8) { FileManager.default.fileExists(atPath: socket.path) }
            #expect(FileManager.default.fileExists(atPath: socket.path))
            let mode = (try? FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int) ?? 0
            #expect(mode == 0o600)

            // Starting it again changes nothing: one daemon.
            #expect(try run(["serve", "--detach"]).status == 0)

            // The command line is answered by it, with the same bytes it gives alone.
            let viaDaemon = try run(["mailbox", "list", "--json"])
            let alone = try run(["mailbox", "list", "--json"], extra: ["MAIL42_NO_SERVE": "1"])
            #expect(viaDaemon.status == 0 && viaDaemon.out == alone.out && viaDaemon.err == alone.err)
            #expect(viaDaemon.out.contains("INBOX"))
            let log = (try? String(contentsOf: folder.appendingPathComponent("serve.log"), encoding: .utf8)) ?? ""
            #expect(log.contains("request mailbox"), "the verb should have gone to the daemon: \(log)")
            #expect(try run(["message", "read", "999", "--json"]).status == 2)   // a failure keeps its status

            // And it goes away by itself when nobody needs it.
            await Fixture.wait(10) { !FileManager.default.fileExists(atPath: socket.path) }
            #expect(!FileManager.default.fileExists(atPath: socket.path))
        }
    }
}
