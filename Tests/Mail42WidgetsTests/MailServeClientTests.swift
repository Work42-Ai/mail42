// MailServeClientTests.swift — the Mac widget's socket client, against a small fake `mail42 serve` (POSIX, in-process).

#if os(macOS)

import Darwin
import Foundation
import Testing
@testable import Mail42MailWidget

/// Listens on a Unix socket in a short temp folder and speaks just enough of docs/serve-protocol.md.
nonisolated final class FakeDaemon: @unchecked Sendable {
    let directory: URL
    private let listener: Int32
    private let lock = NSLock()
    private var clients: [Int32] = []
    private var cancelIDs: [Int] = []
    private var subscribers: [Int32] = []
    private var stopped = false
    private let daemonVersion: String
    private let acceptVersions: (String) -> Bool
    /// Verbs that get no answer (so a test can cancel them).
    private let silent: Set<String>

    init(version: String = "0.3.0", accepts: @escaping (String) -> Bool = { _ in true }, silent: Set<String> = []) throws {
        daemonVersion = version
        acceptVersions = accepts
        self.silent = silent
        directory = URL(fileURLWithPath: "/tmp/m42s-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("serve.sock").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var cancels: [Int] { lock.withLock { cancelIDs } }

    func stop() {
        lock.withLock { stopped = true }
        Darwin.close(listener)
        for fd in lock.withLock({ clients }) { Darwin.shutdown(fd, SHUT_RDWR) }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Tells every subscribed client the mailboxes changed.
    func announceChange(_ signature: String) {
        for fd in lock.withLock({ subscribers }) { write(fd, ["event": "changed", "signature": signature]) }
    }

    /// Drops every connection, as a daemon that exits would.
    func dropClients() {
        for fd in lock.withLock({ clients }) { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { return }
            // A write to a client that has gone must fail, not kill the test process with SIGPIPE.
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { clients.append(fd) }
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { handle(object, on: fd) }
            }
        }
    }

    private func handle(_ object: [String: Any], on fd: Int32) {
        if let hello = object["hello"] as? [String: Any] {
            let ok = acceptVersions(hello["version"] as? String ?? "")
            write(fd, ["hello": ["version": daemonVersion, "ok": ok]])
        } else if object["subscribe"] != nil {
            lock.withLock { subscribers.append(fd) }
            write(fd, ["subscribed": "changes", "signature": "1:1:1"])
        } else if let id = object["cancel"] as? Int {
            lock.withLock { cancelIDs.append(id) }
        } else if let id = object["id"] as? Int, let verb = object["verb"] as? String {
            if silent.contains(verb) { return }
            let args = (object["args"] as? [String]) ?? []
            let out = Data("{\"verb\":\"\(verb)\",\"args\":\"\(args.joined(separator: " "))\"}".utf8)
            write(fd, ["id": id, "stdout": out.base64EncodedString(), "stderr": "", "status": verb == "fail" ? 3 : 0])
        }
    }

    private func write(_ fd: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    }
}

/// What a `changes()` stream has delivered so far, collected by a task so a test never waits on the stream itself.
nonisolated final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<String>) {
        task = Task { [self] in
            for await value in stream { lock.withLock { collected.append(value) } }
        }
    }

    deinit { task?.cancel() }

    var values: [String] { lock.withLock { collected } }
}

@Suite("MailServeClient")
struct MailServeClientTests {

    private func client(_ daemon: FakeDaemon, version: String = "0.3.0") -> MailServeClient {
        MailServeClient(version: version, directory: daemon.directory, startDaemon: { throw MailFailure.notInstalled }, startupWait: .milliseconds(200))
    }

    @Test("the widget's mail42 version is the plugin's")
    func versionMatchesPlugin() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work42-plugin/plugin.yaml")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("version:") })
        let version = line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        #expect(MailServeClient.version == version)
    }

    @Test("a request goes over the socket and its answer comes back")
    func roundTrip() async throws {
        let daemon = try FakeDaemon()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        let result = try await client.run(["envelope", "list", "--json"])
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "{\"verb\":\"envelope\",\"args\":\"list --json\"}")
        let failed = try await client.run(["fail"])
        #expect(failed.status == 3)
    }

    @Test("requests made together are each answered by their own id")
    func concurrent() async throws {
        let daemon = try FakeDaemon()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        let tasks = (0..<20).map { index in
            Task { String(decoding: try await client.run(["echo", "\(index)"]).stdout, as: UTF8.self) }
        }
        var answers: [String] = []
        for task in tasks { answers.append(try await task.value) }
        for index in 0..<20 { #expect(answers.contains("{\"verb\":\"echo\",\"args\":\"\(index)\"}")) }
    }

    @Test("cancelling a request sends cancel to the daemon and ends the call at once")
    func cancel() async throws {
        let daemon = try FakeDaemon(silent: ["hang"])
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        _ = try await client.run(["warm"])                      // connected, so the id of `hang` is the next one
        let task = Task { try await client.run(["hang"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { daemon.cancels == [2] })
    }

    @Test("a change the daemon announces reaches the listener")
    func changeEvents() async throws {
        let daemon = try FakeDaemon()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        let events = Events(client.changes())
        // Announce until the subscription is in place (how long that takes depends on the machine's load).
        let seen = await eventually(within: .seconds(60)) {
            daemon.announceChange("5:10:2")
            return events.values.contains("5:10:2")
        }
        #expect(seen)
    }

    @Test("a dropped connection makes the next request reconnect, and listeners are told to look again")
    func reconnects() async throws {
        let daemon = try FakeDaemon()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        let events = Events(client.changes())
        _ = try await client.run(["one"])
        // Wait until the client has subscribed (an announced change arrives), then drop the connection.
        #expect(await eventually(within: .seconds(60)) {
            daemon.announceChange("1:1:1")
            return events.values.contains("1:1:1")
        })
        daemon.dropClients()
        // Reconnecting takes a second or more (a growing pause); the listener is then told to look again.
        let told = await eventually(within: .seconds(60)) { events.values.contains("") }
        #expect(told)
        let result = try await client.run(["two"])
        #expect(result.status == 0)
    }

    @Test("a newer daemon than the widget is refused with an update message")
    func newerDaemon() async throws {
        let daemon = try FakeDaemon(version: "0.4.0", accepts: { _ in false })
        defer { daemon.stop() }
        let client = client(daemon, version: "0.3.0")
        defer { client.close() }
        do {
            _ = try await client.run(["x"])
            Issue.record("expected a refusal")
        } catch let failure as MailFailure {
            #expect(failure.code == "service_version")
        }
    }

    @Test("no daemon and no mail42 installed is the not-installed failure")
    func notInstalled() async throws {
        let directory = URL(fileURLWithPath: "/tmp/m42s-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MailServeClient(version: "0.3.0", directory: directory, startDaemon: { throw MailFailure.notInstalled }, startupWait: .milliseconds(100))
        await #expect(throws: MailFailure.self) { try await client.run(["x"]) }
    }

    @Test("version comparison reads dotted numbers")
    func versions() {
        #expect(MailServeClient.isNewer("0.3.1", than: "0.3.0"))
        #expect(MailServeClient.isNewer("0.10.0", than: "0.9.0"))
        #expect(!MailServeClient.isNewer("0.3.0", than: "0.3.0"))
        #expect(!MailServeClient.isNewer("0.2.9", than: "0.3.0"))
    }
}

// MARK: - The app group and starting the daemon (WOR-889)

import Work42PluginKit

private struct ScriptedShell: WidgetShellService {
    let result: WidgetShellResult?
    let ran: Ran
    final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(String, Duration?)] = []
        var commands: [(String, Duration?)] { lock.withLock { seen } }
        func add(_ command: String, _ timeout: Duration?) { lock.withLock { seen.append((command, timeout)) } }
    }
    func run(command: String) async throws -> WidgetShellResult { try await run(command: command, timeout: .seconds(10)) }
    func run(command: String, timeout: Duration) async throws -> WidgetShellResult {
        ran.add(command, timeout)
        guard let result else { throw WidgetServiceError(message: "timed out") }
        return result
    }
}

@Suite("MailServeClient: app group and daemon start")
struct MailServeClientGroupTests {

    @Test("the socket is looked for in the app group's container, not in a home folder")
    func groupDirectory() {
        #expect(MailServeClient.groupIdentifier == "74RFQFPVQ9.com.work42.mail42")
        #expect(MailServeClient.groupDirectory.lastPathComponent == "74RFQFPVQ9.com.work42.mail42")
        #expect(MailServeClient.groupDirectory.path.contains("/Library/Group Containers/"))
        #expect(!MailServeClient.groupDirectory.path.contains("/.work42/"))
    }

    @Test("starting the daemon runs `mail42 serve --detach` through the shell with a timeout")
    func startsThroughTheShell() async throws {
        let ran = ScriptedShell.Ran()
        let start = MailServeClient.startDaemonCommand(
            shell: ScriptedShell(result: WidgetShellResult(stdout: "", stderr: "", exitCode: 0), ran: ran))
        try await start()
        #expect(ran.commands.map(\.0) == ["mail42 serve --detach"])
        #expect(ran.commands.first?.1 == .seconds(15))
    }

    @Test("a shell that cannot find mail42 (127) means it is not installed")
    func notInstalled() async {
        let start = MailServeClient.startDaemonCommand(
            shell: ScriptedShell(result: WidgetShellResult(stdout: "", stderr: "mail42: command not found", exitCode: 127), ran: .init()))
        await #expect(throws: MailFailure.self) { try await start() }
        do { try await start() } catch let failure as MailFailure { #expect(failure.code == MailFailure.notInstalled.code) } catch {}
    }

    @Test("any other failure is service_unavailable and carries what mail42 said; a timeout is service_unavailable too")
    func otherFailures() async {
        let failing = MailServeClient.startDaemonCommand(
            shell: ScriptedShell(result: WidgetShellResult(stdout: "", stderr: "can't listen\n", exitCode: 1), ran: .init()))
        do { try await failing() } catch let failure as MailFailure {
            #expect(failure.code == "service_unavailable" && failure.message == "can't listen")
        } catch { Issue.record("unexpected \(error)") }
        let timedOut = MailServeClient.startDaemonCommand(shell: ScriptedShell(result: nil, ran: .init()))
        do { try await timedOut() } catch let failure as MailFailure { #expect(failure.code == "service_unavailable") } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

#endif
