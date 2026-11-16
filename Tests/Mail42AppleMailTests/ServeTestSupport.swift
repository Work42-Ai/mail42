import Foundation
import Testing
@testable import mail42

/// Tests that change state the whole process shares (environment variables, `VerbRunner.version`, the shared
/// `LiveMail.pool` a running daemon installs) live in suites nested here. `.serialized` is applied recursively, so
/// none of them runs at the same time as another.
@Suite(.serialized) enum ProcessWide {}

/// A thread-safe list, for what a verb or a callback records.
final class Recorded<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Element] = []
    func add(_ value: Element) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Element] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// A client of the daemon, written the way the protocol document says: line in, line out.
final class TestClient {
    private let fd: Int32
    private var buffer = Data()

    /// Connects to `socket`; nil when nothing listens there.
    init?(socket: URL) {
        guard let fd = ServeSocket.connect(path: socket.path, timeoutMs: 1000) else { return nil }
        self.fd = fd
    }

    deinit { close(fd) }

    func send(_ object: [String: Any]) { ServeSocket.writeAll(fd, ServeSocket.line(object)) }
    func sendRaw(_ text: String) { ServeSocket.writeAll(fd, Data(text.utf8)) }

    /// The next message from the daemon, or nil on timeout or when the daemon closed the connection.
    func receive(timeout: TimeInterval = 3) -> [String: Any]? {
        guard let line = ServeSocket.readLine(fd, buffer: &buffer, timeoutMs: Int32(timeout * 1000)) else { return nil }
        return ServeSocket.object(line)
    }

    /// True when the daemon closed the connection (and sent nothing more) within `timeout`.
    func isClosed(within timeout: TimeInterval = 2) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return false }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) <= 0
    }

    /// `hello` with `version`; returns the daemon's `ok`, or nil when it didn't answer.
    @discardableResult
    func hello(_ version: String = "0.3.0") -> Bool? {
        send(["hello": ["version": version]])
        guard let reply = receive(), let hello = reply["hello"] as? [String: Any] else { return nil }
        return hello["ok"] as? Bool
    }

    func request(_ id: Int, _ verb: String, _ args: [String] = []) {
        send(["id": id, "verb": verb, "args": args])
    }

    func cancel(_ id: Int) { send(["cancel": id]) }

    /// A reply to a request, decoded: `(id, stdout, stderr, status)`.
    func reply(timeout: TimeInterval = 3) -> (id: Int, stdout: String, stderr: String, status: Int)? {
        guard let message = receive(timeout: timeout), let id = message["id"] as? Int, let status = message["status"] as? Int else { return nil }
        let stdout = Data(base64Encoded: message["stdout"] as? String ?? "").map { String(decoding: $0, as: UTF8.self) } ?? ""
        return (id, stdout, message["stderr"] as? String ?? "", status)
    }
}

enum ServeFixture {
    /// A short folder in the temp directory: a socket path must fit in 103 bytes, and a long temp path plus a UUID doesn't.
    static func directory() -> URL {
        let name = "m42s-" + UUID().uuidString.prefix(8).lowercased()
        return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    static func result(_ stdout: String, status: Int32 = 0, stderr: String = "") -> VerbResult {
        VerbResult(stdout: Data(stdout.utf8), stderr: stderr, status: status)
    }

    /// A daemon on its own folder that answers every verb with `runVerb` (a fake that needs no mail).
    static func daemon(
        directory: URL = ServeFixture.directory(), version: String = "0.3.0", idleSeconds: TimeInterval = 600,
        workers: Int = 4, watchIndex: Bool = false, debounce: TimeInterval = 0.1,
        runVerb: (@Sendable (String, [String]) -> VerbResult)? = nil
    ) throws -> ServeDaemon {
        var configuration = ServeDaemon.Configuration(directory: directory, version: version)
        configuration.idleSeconds = idleSeconds
        configuration.readWorkers = workers
        configuration.watchIndex = watchIndex
        configuration.debounce = debounce
        let actions = DispatchQueue(label: "test.serve.actions")
        configuration.actionExecutor = { work in actions.async(execute: work) }
        if let runVerb { configuration.runVerb = runVerb }
        let daemon = ServeDaemon(configuration)
        try daemon.start()
        return daemon
    }

    /// Polls until `condition` holds or `seconds` pass.
    static func wait(_ seconds: TimeInterval = 3, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static func cleanup(_ daemon: ServeDaemon) {
        daemon.stop()
        try? FileManager.default.removeItem(at: daemon.configuration.directory)
    }
}

/// Waits for `semaphore` from a test body. `DispatchSemaphore.wait` can't be called from async code directly, and a
/// few of these tests wait for a verb to have started before they go on.
func blockUntil(_ semaphore: DispatchSemaphore) { semaphore.wait() }
