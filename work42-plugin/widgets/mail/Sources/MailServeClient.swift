// MailServeClient.swift — the Mac widget's connection to the `mail42 serve` daemon (docs/serve-protocol.md in mail42).
//
// One Unix socket, one JSON object per line, requests answered by id. Nothing here ever parks a thread: the socket is
// read and written with DispatchIO (callbacks), the daemon is started with a `Process` whose termination is a callback,
// and every wait is an `await` on a continuation or a `Task.sleep`. A request that is cancelled sends `cancel` to the
// daemon and ends at once with `CancellationError`.
//
// The client connects when it is first asked, starts the daemon if none answers (`mail42 serve --detach`), says
// `hello` with its version (a daemon of another version steps aside or refuses, see the protocol), and reconnects by
// itself, telling `changes()` listeners that something may have been missed.

#if os(macOS)

import Darwin
import Foundation

nonisolated final class MailServeClient: MailTransport, @unchecked Sendable {

    /// The mail42 version this widget was built with (`work42-plugin/plugin.yaml`); a test keeps the two equal.
    static let version = "0.3.0"

    private let version: String
    private let directory: URL
    private let executable: @Sendable () -> URL?
    private let startupWait: Duration

    private let lock = NSLock()
    private var connection: Connection?
    private var connecting: Task<Connection, Error>?
    private var listeners: [UUID: AsyncStream<String>.Continuation] = [:]
    private var reconnect: Task<Void, Never>?
    private var closed = false

    /// - Parameters:
    ///   - directory: where `serve.sock` lives (`~/.work42/mail42`).
    ///   - executable: the `mail42` that can start the daemon (`~/.work42/bin/mail42`); nil when it isn't installed.
    ///   - startupWait: how long to wait for a daemon we started to listen.
    init(
        version: String = MailServeClient.version,
        directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".work42/mail42", isDirectory: true),
        executable: @escaping @Sendable () -> URL? = { MailCLI.executableURL() },
        startupWait: Duration = .seconds(2)
    ) {
        self.version = version
        self.directory = directory
        self.executable = executable
        self.startupWait = startupWait
    }

    private var socketPath: String { directory.appendingPathComponent("serve.sock").path }

    // MARK: - MailTransport

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        var attempt = 0
        while true {
            let live = try await connect()
            do {
                return try await live.request(arguments)
            } catch let failure as MailFailure where failure.code == Connection.droppedCode && attempt == 0 {
                attempt += 1                                  // the daemon went away between connect and answer: once more
                forget(live)
            }
        }
    }

    func changes() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            if closed { lock.unlock(); continuation.finish(); return }
            listeners[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock(); self?.listeners[id] = nil; self?.lock.unlock()
            }
            Task { [weak self] in try? await self?.subscribe() }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let live = connection
        connection = nil
        connecting?.cancel(); connecting = nil
        reconnect?.cancel(); reconnect = nil
        let all = listeners.values
        listeners = [:]
        lock.unlock()
        live?.close()
        for continuation in all { continuation.finish() }
        lock.lock(); closed = false; lock.unlock()                // usable again: the next request connects afresh
    }

    // MARK: - Connecting

    /// The live connection, made (and the daemon started) if there is none. Concurrent callers share one attempt.
    private func connect() async throws -> Connection {
        enum Step { case live(Connection), join(Task<Connection, Error>), start(Task<Connection, Error>) }
        let step: Step = locked {
            if let live = connection, !live.isClosed { return .live(live) }
            if let attempt = connecting { return .join(attempt) }
            let attempt = Task { try await self.establish() }
            connecting = attempt
            return .start(attempt)
        }
        switch step {
        case .live(let live): return live
        case .join(let attempt): return try await attempt.value
        case .start(let attempt):
            defer { locked { connecting = nil } }
            return try await attempt.value
        }
    }

    /// Runs `body` holding the lock. (Locking inline in an `async` function is not allowed; this is the sync way.)
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func establish() async throws -> Connection {
        var startedDaemon = false
        for round in 0..<2 {
            var fd = Self.openSocket(path: socketPath)
            if fd == nil {
                guard let mail42 = executable() else { throw MailFailure.notInstalled }
                if !startedDaemon { try await Self.startDaemon(mail42); startedDaemon = true }
                fd = try await waitForSocket()
            }
            guard let fd else {
                throw MailFailure(code: "service_unavailable", message: "The mail42 service didn\u{2019}t start.")
            }
            let live = Connection(fd: fd) { [weak self] signature in self?.deliver(signature) }
                onClose: { [weak self] closing in self?.connectionClosed(closing) }
            let greeting = await live.greet(version: version)
            switch greeting {
            case .ok:
                locked { connection = live }
                return live
            case .refused(let daemonVersion):
                live.close()
                if Self.isNewer(version, than: daemonVersion), round == 0 {
                    // Our version is newer: that daemon is stepping aside. Wait for it to go, then start our own.
                    try await waitForSocketToGo()
                    startedDaemon = false
                    continue
                }
                throw MailFailure(
                    code: "service_version",
                    message: "Work42\u{2019}s mail42 (\(daemonVersion)) is newer than this widget (\(version)). Update Work42.")
            case .none:
                live.close()
                throw MailFailure(code: "service_unavailable", message: "The mail42 service didn\u{2019}t answer.")
            }
        }
        throw MailFailure(code: "service_unavailable", message: "The mail42 service didn\u{2019}t start.")
    }

    /// Retries the connect every 100 ms until the daemon we started is listening.
    private func waitForSocket() async throws -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: startupWait)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let fd = Self.openSocket(path: socketPath) { return fd }
            try await Task.sleep(for: .milliseconds(100))
        }
        return Self.openSocket(path: socketPath)
    }

    private func waitForSocketToGo() async throws {
        let deadline = ContinuousClock.now.advanced(by: startupWait)
        while ContinuousClock.now < deadline, FileManager.default.fileExists(atPath: socketPath) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A connected socket to `path`, or nil when nobody listens there. `connect` on a Unix socket answers at once.
    static func openSocket(path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    /// `mail42 serve --detach`: starts the daemon in the background and returns at once. Waits for that with a
    /// termination callback, never with `waitUntilExit`.
    private static func startDaemon(_ executable: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["serve", "--detach"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: MailFailure.notInstalled)
            }
        }
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        func parts(_ version: String) -> [Int] { version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [] }
        let (a, b) = (parts(lhs), parts(rhs))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Listening for changes

    /// Subscribes the live connection to `changes` (connecting first when needed).
    private func subscribe() async throws {
        let live = try await connect()
        live.subscribe()
    }

    private var isListening: Bool { locked { !listeners.isEmpty && !closed } }

    private func reconnectEnded() { locked { reconnect = nil } }

    private func deliver(_ signature: String) {
        lock.lock()
        let all = Array(listeners.values)
        lock.unlock()
        for listener in all { listener.yield(signature) }
    }

    private func forget(_ dropped: Connection) {
        lock.lock()
        if connection === dropped { connection = nil }
        lock.unlock()
    }

    /// The connection ended. If anyone is listening, reconnect with a growing pause and tell them to look again: a change
    /// may have happened while the connection was down.
    private func connectionClosed(_ ended: Connection) {
        lock.lock()
        if connection === ended { connection = nil }
        let listening = !listeners.isEmpty && !closed
        let alreadyReconnecting = reconnect != nil
        lock.unlock()
        guard listening, !alreadyReconnecting else { return }
        let task = Task { [weak self] in
            var pause = Duration.seconds(1)
            while !Task.isCancelled, let self {
                guard self.isListening else { break }
                try? await Task.sleep(for: pause)
                if (try? await self.subscribe()) != nil {
                    self.deliver("")                         // reconnected: ask again for what you show
                    break
                }
                pause = min(pause * 2, .seconds(10))
            }
            self?.reconnectEnded()
        }
        lock.lock(); reconnect = task; lock.unlock()
    }
}

// MARK: - One connection

private enum Greeting: Sendable {
    case ok
    /// The daemon said no: its own version.
    case refused(String)
    case none
}

nonisolated private final class Connection: @unchecked Sendable {

    /// The failure code when the connection ends under a request.
    static let droppedCode = "service_stopped"

    private let io: DispatchIO
    private let queue = DispatchQueue(label: "mail42.widget.serve-io")
    private let lock = NSLock()
    private let onEvent: @Sendable (String) -> Void
    private let onClose: @Sendable (Connection) -> Void

    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<MailCLIResult, Error>] = [:]
    private var greeting: CheckedContinuation<Greeting, Never>?
    private var nextID = 0
    private var ended = false
    private var subscribed = false

    init(fd: Int32, onEvent: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Connection) -> Void) {
        self.onEvent = onEvent
        self.onClose = onClose
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue, cleanupHandler: { _ in Darwin.close(fd) })
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.received(data) }
            if done || error != 0 { self.finish() }
        }
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    // MARK: Talking

    func greet(version: String) async -> Greeting {
        await withCheckedContinuation { (continuation: CheckedContinuation<Greeting, Never>) in
            lock.lock()
            if ended { lock.unlock(); continuation.resume(returning: .none); return }
            greeting = continuation
            lock.unlock()
            send(["hello": ["version": version]])
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.resolveGreeting(.none) }
        }
    }

    func subscribe() {
        lock.lock()
        let already = subscribed
        subscribed = true
        lock.unlock()
        if !already { send(["subscribe": "changes"]) }
    }

    /// Sends one request and waits for its answer. Cancelling the calling task sends `cancel` and ends this at once.
    func request(_ arguments: [String]) async throws -> MailCLIResult {
        guard let verb = arguments.first else { throw MailFailure(code: "usage", message: "No mail42 command.") }
        let id = takeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MailCLIResult, Error>) in
                lock.lock()
                if ended {
                    lock.unlock()
                    continuation.resume(throwing: MailFailure(code: Self.droppedCode, message: "The mail42 service stopped."))
                    return
                }
                pending[id] = continuation
                lock.unlock()
                if Task.isCancelled { cancel(id); return }
                send(["id": id, "verb": verb, "args": Array(arguments.dropFirst())])
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func takeID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func cancel(_ id: Int) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(throwing: CancellationError())
        send(["cancel": id])
    }

    func close() {
        io.close(flags: .stop)
        finish()
    }

    // MARK: Writing

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: payload, queue: queue) { [weak self] done, _, error in
            if done && error != 0 { self?.finish() }
        }
    }

    // MARK: Reading

    private func received(_ data: DispatchData) {
        var chunk = Data()
        data.enumerateBytes { bytes, _, _ in chunk.append(bytes) }
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let hello = object["hello"] as? [String: Any] {
            let ok = hello["ok"] as? Bool == true
            resolveGreeting(ok ? .ok : .refused(hello["version"] as? String ?? "?"))
        } else if object["event"] as? String == "changed" {
            onEvent(object["signature"] as? String ?? "")
        } else if let id = object["id"] as? Int, let status = object["status"] as? Int {
            lock.lock()
            let continuation = pending.removeValue(forKey: id)
            lock.unlock()
            let stdout = Data(base64Encoded: object["stdout"] as? String ?? "") ?? Data()
            continuation?.resume(returning: MailCLIResult(
                status: Int32(status), stdout: stdout, stderr: object["stderr"] as? String ?? ""))
        }
        // `subscribed` acknowledgements need no action.
    }

    private func resolveGreeting(_ value: Greeting) {
        lock.lock()
        let continuation = greeting
        greeting = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    /// The connection is over: whatever was waiting for an answer learns that the service stopped.
    private func finish() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        let waiting = pending
        pending = [:]
        let greeter = greeting
        greeting = nil
        lock.unlock()
        greeter?.resume(returning: .none)
        for continuation in waiting.values {
            continuation.resume(throwing: MailFailure(code: Self.droppedCode, message: "The mail42 service stopped."))
        }
        onClose(self)
    }
}

#endif
