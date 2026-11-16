import Foundation
import Testing
import Mail42TestSupport
@testable import mail42

/// The daemon against docs/serve-protocol.md, with fake verbs so no mail is needed (WOR-828: AC3, AC4, AC5, AC8, AC9).
extension ProcessWide {
    @Suite struct ServeProtocolTests {

        private typealias Fixture = ServeFixture

        // MARK: - The folder, the lock, the socket (AC3)

        @Test func theFolderAndTheSocketAreOwnerOnly() throws {
            let daemon = try Fixture.daemon()
            defer { Fixture.cleanup(daemon) }
            let folder = try FileManager.default.attributesOfItem(atPath: daemon.configuration.directory.path)
            let socket = try FileManager.default.attributesOfItem(atPath: daemon.socketURL.path)
            #expect((folder[.posixPermissions] as? Int) == 0o700)
            #expect((socket[.posixPermissions] as? Int) == 0o600)
        }

        @Test func onlyOneDaemonServesAFolderAndTheOtherStepsAside() throws {
            let first = try Fixture.daemon()
            defer { Fixture.cleanup(first) }
            #expect(throws: ServeError.alreadyRunning) { _ = try Fixture.daemon(directory: first.configuration.directory) }

            // The first still answers, and its socket was not touched by the second.
            let client = try #require(TestClient(socket: first.socketURL))
            #expect(client.hello() == true)
        }

        @Test func aSocketFileLeftByAKilledDaemonIsReplaced() throws {
            let directory = Fixture.directory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("serve.sock").path, contents: Data())
            let daemon = try Fixture.daemon(directory: directory)
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            #expect(client.hello() == true)
        }

        // MARK: - hello and versions (AC5)

        @Test func aClientOfTheSameVersionIsServed() throws {
            let daemon = try Fixture.daemon(version: "0.3.0")
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.send(["hello": ["version": "0.3.0"]])
            let reply = try #require(client.receive())
            let hello = try #require(reply["hello"] as? [String: Any])
            #expect(hello["ok"] as? Bool == true && hello["version"] as? String == "0.3.0")
        }

        @Test func aNewerClientIsRefusedAndTheDaemonStepsAside() async throws {
            let directory = Fixture.directory()
            let old = try Fixture.daemon(directory: directory, version: "0.3.0")
            defer { Fixture.cleanup(old) }
            let client = try #require(TestClient(socket: old.socketURL))
            #expect(client.hello("0.4.0") == false)

            await Fixture.wait { old.isStopped }
            #expect(old.isStopped)
            #expect(!FileManager.default.fileExists(atPath: old.socketURL.path))

            // The folder is free: a daemon of the client's version can take over.
            let replacement = try Fixture.daemon(directory: directory, version: "0.4.0")
            defer { Fixture.cleanup(replacement) }
            let next = try #require(TestClient(socket: replacement.socketURL))
            #expect(next.hello("0.4.0") == true)
        }

        @Test func anOlderClientIsRefusedAndTheDaemonStays() async throws {
            let daemon = try Fixture.daemon(version: "0.3.0")
            defer { Fixture.cleanup(daemon) }
            let old = try #require(TestClient(socket: daemon.socketURL))
            #expect(old.hello("0.2.0") == false)
            #expect(old.isClosed())

            try await Task.sleep(for: .milliseconds(400))
            #expect(!daemon.isStopped)
            let current = try #require(TestClient(socket: daemon.socketURL))
            #expect(current.hello("0.3.0") == true)
        }

        @Test func aDaemonThatIsRetiringFinishesWhatItIsDoing() async throws {
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            let daemon = try Fixture.daemon(runVerb: { verb, _ in
                if verb == "slow" { started.signal(); release.wait() }
                return Fixture.result("done \(verb)")
            })
            defer { Fixture.cleanup(daemon) }
            let busy = try #require(TestClient(socket: daemon.socketURL))
            busy.hello()
            busy.request(1, "slow")
            blockUntil(started)

            let newer = try #require(TestClient(socket: daemon.socketURL))
            #expect(newer.hello("0.4.0") == false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!daemon.isStopped)                                // still has a request in flight

            release.signal()
            let reply = try #require(busy.reply())
            #expect(reply.id == 1 && reply.stdout == "done slow")     // it was answered
            await Fixture.wait { daemon.isStopped }
            #expect(daemon.isStopped)                                 // and only then did the daemon go
        }

        @Test func nothingIsServedBeforeAHello() throws {
            let daemon = try Fixture.daemon(runVerb: { _, _ in Fixture.result("should not run") })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.request(1, "mailbox", ["list"])
            #expect(client.isClosed())
        }

        // MARK: - Requests

        @Test func aRequestIsAnsweredWithTheVerbsOwnBytesAndStatus() throws {
            let daemon = try Fixture.daemon(runVerb: { verb, args in
                Fixture.result("out \(verb) \(args.joined(separator: "|"))\n", status: 2, stderr: "err\n")
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(7, "message", ["read", "123", "--html", "--json"])
            let reply = try #require(client.reply())
            #expect(reply.id == 7 && reply.status == 2)
            #expect(reply.stdout == "out message read|123|--html|--json\n")
            #expect(reply.stderr == "err\n")
        }

        @Test func outputThatIsNotTextSurvivesTheTrip() throws {
            let bytes = Data((0..<256).map { UInt8($0) } + [0x0A, 0x0A])
            let daemon = try Fixture.daemon(runVerb: { _, _ in VerbResult(stdout: bytes, stderr: "", status: 0) })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "x")
            let message = try #require(client.receive())
            #expect(Data(base64Encoded: message["stdout"] as? String ?? "") == bytes)
        }

        @Test func repliesToDifferentRequestsCanArriveOutOfOrder() throws {
            let release = DispatchSemaphore(value: 0)
            let daemon = try Fixture.daemon(runVerb: { verb, _ in
                if verb == "slow" { release.wait() }
                return Fixture.result(verb)
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "slow")
            client.request(2, "fast")
            #expect(try #require(client.reply()).id == 2)             // the fast one first
            release.signal()
            #expect(try #require(client.reply()).id == 1)
        }

        @Test func readsRunAtTheSameTimeUpToTheWorkerCount() async throws {
            let gate = DispatchSemaphore(value: 0)
            let running = Recorded<String>()
            let daemon = try Fixture.daemon(workers: 3, runVerb: { verb, _ in
                running.add(verb); gate.wait(); return Fixture.result(verb)
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            for id in 1...5 { client.request(id, "read\(id)") }
            await Fixture.wait { running.values.count >= 3 }
            try await Task.sleep(for: .milliseconds(200))
            #expect(running.values.count == 3)                       // three at once, two waiting their turn
            for _ in 1...5 { gate.signal() }
            var ids = Set<Int>()
            for _ in 1...5 { ids.insert(try #require(client.reply()).id) }
            #expect(ids == [1, 2, 3, 4, 5])
        }

        @Test func aMessageThatIsNotAProtocolMessageClosesTheConnection() throws {
            let daemon = try Fixture.daemon()
            defer { Fixture.cleanup(daemon) }
            let garbage = try #require(TestClient(socket: daemon.socketURL))
            garbage.hello()
            garbage.sendRaw("this is not json\n")
            #expect(garbage.isClosed())

            let badArgs = try #require(TestClient(socket: daemon.socketURL))
            badArgs.hello()
            badArgs.send(["id": 1, "verb": "x", "args": [1, 2]])
            #expect(badArgs.isClosed())
        }

        @Test func anIdThatIsStillInFlightCannotBeUsedAgain() throws {
            let release = DispatchSemaphore(value: 0)
            let daemon = try Fixture.daemon(runVerb: { _, _ in release.wait(); return Fixture.result("") })
            defer { release.signal(); Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "slow")
            client.request(1, "again")
            #expect(client.isClosed())
        }

        // MARK: - cancel

        @Test func aReadThatHasNotStartedIsDroppedWithoutAReply() async throws {
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            let ran = Recorded<String>()
            let daemon = try Fixture.daemon(workers: 1, runVerb: { verb, _ in
                ran.add(verb)
                if verb == "block" { started.signal(); release.wait() }
                return Fixture.result(verb)
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "block")
            blockUntil(started)
            client.request(2, "waiting")                              // behind the only worker
            client.cancel(2)
            try await Task.sleep(for: .milliseconds(100))
            release.signal()
            client.request(3, "after")

            var answered: [Int] = []
            while let reply = client.reply(timeout: 1) { answered.append(reply.id) }
            #expect(answered == [1, 3])                               // nothing for 2
            #expect(ran.values == ["block", "after"])                 // and it never ran
        }

        @Test func aReadThatIsRunningIsAnsweredWith130AtOnceAndItsResultDiscarded() async throws {
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            let daemon = try Fixture.daemon(runVerb: { _, _ in
                started.signal(); release.wait(); return Fixture.result("late")
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "slow")
            blockUntil(started)
            client.cancel(1)
            let cancelled = try #require(client.reply(timeout: 1))     // before the verb has finished
            #expect(cancelled.id == 1 && cancelled.status == 130 && cancelled.stdout.isEmpty)

            release.signal()
            #expect(client.reply(timeout: 0.5) == nil)                // the late answer is not sent
        }

        @Test func cancellingSomethingUnknownDoesNothing() throws {
            let daemon = try Fixture.daemon(runVerb: { _, _ in Fixture.result("fine") })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.cancel(99)
            client.request(1, "x")
            #expect(try #require(client.reply()).stdout == "fine")
        }

        @Test func whenAConnectionClosesItsWaitingReadsAreDropped() async throws {
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            let ran = Recorded<String>()
            let daemon = try Fixture.daemon(workers: 1, runVerb: { verb, _ in
                ran.add(verb)
                if verb == "block" { started.signal(); release.wait() }
                return Fixture.result(verb)
            })
            defer { Fixture.cleanup(daemon) }
            var leaving: TestClient? = try #require(TestClient(socket: daemon.socketURL))
            leaving?.hello()
            leaving?.request(1, "block")
            blockUntil(started)
            leaving?.request(2, "orphan")
            try await Task.sleep(for: .milliseconds(100))
            leaving = nil                                            // the client goes away
            try await Task.sleep(for: .milliseconds(200))
            release.signal()

            let stayer = try #require(TestClient(socket: daemon.socketURL))
            stayer.hello()
            stayer.request(1, "after")
            #expect(try #require(stayer.reply()).stdout == "after")
            #expect(ran.values == ["block", "after"])                // "orphan" never ran
        }

        // MARK: - Actions (AC8)

        @Test func actionsRunOneAtATimeInOrderAndNeverHoldUpReads() async throws {
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            let order = Recorded<String>()
            let daemon = try Fixture.daemon(runVerb: { verb, args in
                if verb == "archive" { started.signal(); release.wait() }
                order.add("\(verb) \(args.first ?? "")")
                return Fixture.result("\(verb) \(args.first ?? "")")
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "archive", ["5"])                       // an action, held up (Mail is slow)
            blockUntil(started)
            client.request(2, "move", ["6", "Trash"])                 // queued behind it
            client.request(3, "mailbox", ["list"])                    // a read: must not wait for any of that
            let read = try #require(client.reply(timeout: 1))
            #expect(read.id == 3 && read.stdout == "mailbox list")

            release.signal()
            var answered: [Int] = []
            while let reply = client.reply(timeout: 1) { answered.append(reply.id) }
            #expect(answered == [1, 2])
            #expect(order.values == ["mailbox list", "archive 5", "move 6"])
        }

        @Test func aWaitingMarkIsReplacedByALaterMarkOfTheSameThingAndBothAreAnswered() async throws {
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            let ran = Recorded<String>()
            let daemon = try Fixture.daemon(runVerb: { verb, args in
                if verb == "archive" { started.signal(); release.wait() }
                ran.add("\(verb) \(args.joined(separator: " "))")
                return Fixture.result("ran \(args.joined(separator: " "))")
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "archive", ["1"])
            blockUntil(started)
            client.request(2, "mark", ["7", "read"])
            client.request(3, "mark", ["7", "unread"])                // replaces 2: same message, same thing (read state)
            client.request(4, "mark", ["7", "flagged", "--color", "red"])   // a different thing: not folded
            client.request(5, "mark", ["8", "read"])                  // a different message: not folded
            try await Task.sleep(for: .milliseconds(150))
            release.signal()

            var answers: [Int: String] = [:]
            while let reply = client.reply(timeout: 1) { answers[reply.id] = reply.stdout }
            #expect(Set(answers.keys) == [1, 2, 3, 4, 5])              // every request got an answer
            #expect(answers[2] == "ran 7 unread" && answers[3] == "ran 7 unread")   // the replaced one got the later result
            #expect(ran.values == ["archive 1", "mark 7 unread", "mark 7 flagged --color red", "mark 8 read"])
        }

        @Test func aCancelledActionIsAnsweredAtOnceButStillRuns() async throws {
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            let ran = Recorded<String>()
            let daemon = try Fixture.daemon(runVerb: { verb, _ in
                if verb == "archive" { started.signal(); release.wait() }
                ran.add(verb)
                return Fixture.result(verb)
            })
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "archive")
            blockUntil(started)
            client.request(2, "delete")                               // waiting its turn
            client.cancel(2)
            let reply = try #require(client.reply(timeout: 1))
            #expect(reply.id == 2 && reply.status == 130)
            release.signal()
            await Fixture.wait { ran.values.count == 2 }
            #expect(ran.values == ["archive", "delete"])              // Mail may already have it: it still runs
        }

        @Test func whichVerbsAreActionsAndWhichMarksFold() {
            for verb in ["mark", "move", "archive", "delete", "junk", "draft", "open"] {
                #expect(ServeDaemon.isAction(verb: verb, args: ["1"]))
            }
            for verb in ["mailbox", "envelope", "message", "attachment", "frobnicate"] {
                #expect(!ServeDaemon.isAction(verb: verb, args: ["list"]))
            }
            #expect(ServeDaemon.isAction(verb: "permissions", args: ["automation"]))
            #expect(ServeDaemon.isAction(verb: "permissions", args: ["automation", "--json"]))
            #expect(!ServeDaemon.isAction(verb: "permissions", args: ["--json"]))
            #expect(!ServeDaemon.isAction(verb: "permissions", args: ["open"]))

            #expect(ServeDaemon.coalescingKey(verb: "mark", args: ["7", "read"]) == "mark:7:read")
            #expect(ServeDaemon.coalescingKey(verb: "mark", args: ["7", "UNREAD", "--json"]) == "mark:7:read")
            #expect(ServeDaemon.coalescingKey(verb: "mark", args: ["7", "flagged", "--color", "red"]) == "mark:7:flag")
            #expect(ServeDaemon.coalescingKey(verb: "mark", args: ["7", "unflagged"]) == "mark:7:flag")
            #expect(ServeDaemon.coalescingKey(verb: "mark", args: ["7", "read", "--json"]) != ServeDaemon.coalescingKey(verb: "mark", args: ["8", "read"]))
            #expect(ServeDaemon.coalescingKey(verb: "mark", args: ["7"]) == nil)
            #expect(ServeDaemon.coalescingKey(verb: "mark", args: ["7", "sideways"]) == nil)
            #expect(ServeDaemon.coalescingKey(verb: "move", args: ["7", "Trash"]) == nil)
        }

        // MARK: - Going idle (AC4)

        @Test func aDaemonWithNoClientAndNoRequestExitsAndRemovesItsSocket() async throws {
            let daemon = try Fixture.daemon(idleSeconds: 0.5)
            defer { Fixture.cleanup(daemon) }
            await Fixture.wait(5) { daemon.isStopped }
            #expect(daemon.isStopped)
            #expect(!FileManager.default.fileExists(atPath: daemon.socketURL.path))
        }

        @Test func aDaemonWithAConnectedClientIsNotIdle() async throws {
            let daemon = try Fixture.daemon(idleSeconds: 0.5)
            defer { Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            try await Task.sleep(for: .milliseconds(2500))
            #expect(!daemon.isStopped)
            client.request(1, "x")
            #expect(client.reply() != nil)                           // and it still answers
        }

        @Test func aDaemonThatIsBusyIsNotIdle() async throws {
            let release = DispatchSemaphore(value: 0)
            let daemon = try Fixture.daemon(idleSeconds: 0.5, runVerb: { _, _ in release.wait(); return Fixture.result("") })
            defer { release.signal(); Fixture.cleanup(daemon) }
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            client.request(1, "slow")
            try await Task.sleep(for: .milliseconds(2500))
            #expect(!daemon.isStopped)
        }

        @Test func stoppingClosesEveryConnectionAndTheLockIsFreeAgain() throws {
            let directory = Fixture.directory()
            let daemon = try Fixture.daemon(directory: directory)
            let client = try #require(TestClient(socket: daemon.socketURL))
            client.hello()
            daemon.stop()
            #expect(client.isClosed())
            let next = try Fixture.daemon(directory: directory)       // the lock was released
            Fixture.cleanup(next)
        }

        @Test func versionsCompareByTheirNumbers() {
            #expect(ServeVersion.compare("0.3.0", "0.3.0") == 0)
            #expect(ServeVersion.compare("0.3.1", "0.3.0") == 1)
            #expect(ServeVersion.compare("0.10.0", "0.9.0") == 1)       // numbers, not text
            #expect(ServeVersion.compare("0.2.0", "0.3.0") == -1)
            #expect(ServeVersion.compare("1.0", "1.0.0") == 0)          // a missing part is 0
            #expect(ServeVersion.compare("0.3.0-beta", "0.3.0") == 0)
            #expect(ServeVersion.compare("", "0.3.0") == -1)
        }
    }
}
