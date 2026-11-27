// ServeDaemon.swift — `mail42 serve`: one per-user process that answers every client that wants mail.
//
// The protocol is in docs/serve-protocol.md; read it first. In short: a Unix socket, one JSON object per line,
// `hello`, then requests (`{id, verb, args}` answered by `{id, stdout, stderr, status}`), `cancel`, and a `changes`
// subscription. Each request runs the very same verb the command line runs (`VerbRunner`), so the answer is the
// same bytes the command line prints.
//
//   reads    run at the same time on a small worker pool, all through one open `LiveMail` (`LiveMailPool`)
//   actions  ask Mail through Apple Events, so they run one at a time in arrival order (`ActionQueue`), on the
//            main thread (NSAppleScript's home), and a busy Mail never delays a read
//   changes  an `IndexWatcher` on Mail's files tells subscribers when a mailbox counter moved
//
// One daemon per user: an `flock` on `serve.lock` decides, and a socket only its owner can open.

import Darwin
import Foundation
import Mail42Actions
import Mail42AppleMail
import Mail42Kit

enum ServeError: Error, Equatable {
    case alreadyRunning
    case cannotListen(String)
}

final class ServeDaemon: @unchecked Sendable {

    struct Configuration {
        /// Where `serve.sock`, `serve.lock` and `serve.log` live.
        var directory: URL
        /// This daemon's mail42 version, compared with each client's `hello`.
        var version: String
        /// How long with no client and no request before the daemon exits.
        var idleSeconds: TimeInterval = 600
        /// How many read requests run at once.
        var readWorkers = 4
        /// Runs a verb. The real one is `VerbRunner`; tests substitute their own.
        var runVerb: @Sendable (String, [String]) -> VerbResult = { VerbRunner.run(command: $0, args: $1) }
        /// Where actions run. The real one is the main thread; tests use a background queue (a test process's main
        /// thread is busy running the tests).
        var actionExecutor: @Sendable (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }
        /// Whether to watch Mail's index for changes (off for tests that don't need it).
        var watchIndex = true
        /// How long Mail's files must be quiet before the counters are read.
        var debounce: TimeInterval = 0.3

        /// The daemon of the running CLI: the user's folder, or `$MAIL42_SERVE_DIR`.
        static func live(version: String) -> Configuration {
            let environment = ProcessInfo.processInfo.environment
            var configuration = Configuration(directory: ServeDaemon.directory(environment: environment), version: version)
            if let seconds = environment["MAIL42_SERVE_IDLE_SECONDS"].flatMap(TimeInterval.init), seconds > 0 {
                configuration.idleSeconds = seconds
            }
            return configuration
        }
    }

    /// The app group the daemon and Work42's mail42 widget share. The widget is a sandboxed ExtensionKit extension: it can connect
    /// to a socket in a group container it declares (`app_groups` in its plugin.yaml) and not to one in a home folder. mail42.app is
    /// signed with this group (`scripts/build-mail42.sh`), so macOS doesn't ask about "data from other apps".
    static let groupIdentifier = "74RFQFPVQ9.com.work42.mail42"

    /// `~/Library/Group Containers/74RFQFPVQ9.com.work42.mail42`, or `$MAIL42_SERVE_DIR` (tests, and anyone running a second,
    /// separate daemon). Built from the path rather than `containerURL(forSecurityApplicationGroupIdentifier:)`, which can create
    /// the container (and make macOS ask) for a process that isn't signed with the group, such as a development build.
    static func directory(environment: [String: String]) -> URL {
        if let path = environment["MAIL42_SERVE_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(groupIdentifier)", isDirectory: true)
    }

    /// `~/.work42/mail42`: where a daemon before 0.4.0 listened. The command line still looks there, so it can use a daemon of
    /// the old version that is still running; nothing listens there any more once that one exits.
    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".work42/mail42", isDirectory: true)
    }

    let configuration: Configuration
    var socketURL: URL { configuration.directory.appendingPathComponent("serve.sock") }
    private var lockURL: URL { configuration.directory.appendingPathComponent("serve.lock") }
    private var logURL: URL { configuration.directory.appendingPathComponent("serve.log") }

    /// Called once when the daemon has stopped (idle, replaced by a newer version, or `stop()`).
    var onStop: (@Sendable () -> Void)?

    private let pool = LiveMailPool()
    private let readers: WorkerPool
    private let actions: ActionQueue<VerbResult>

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var subscribers: [ObjectIdentifier: Connection] = [:]
    private var inFlight = 0
    private var lastActivity = Date()
    private var retiring = false
    private var stopped = false        // `stop()` has begun (it only runs once)
    private var finished = false       // `stop()` has finished
    private var watcher: IndexWatcher?
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var logSize = 0

    init(_ configuration: Configuration) {
        self.configuration = configuration
        self.readers = WorkerPool(threads: max(1, configuration.readWorkers))
        self.actions = ActionQueue(executor: configuration.actionExecutor)
    }

    // MARK: - Lifecycle

    /// Takes the lock, opens the socket and starts serving (in the background; this returns).
    /// - Throws: `ServeError.alreadyRunning` when another daemon holds the lock.
    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        try prepareDirectory()
        try acquireLock()
        do { try listen() } catch { releaseLock(); throw error }

        LiveMail.pool = pool
        log("started version \(configuration.version) pid \(getpid())")
        startWatcher()
        startTimer()
        startAccepting()
    }

    /// Stops serving: closes every connection, removes the socket, lets go of the lock. Idempotent.
    func stop(reason: String = "stopped") {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let open = Array(connections.values)
        let accepting = acceptSource
        acceptSource = nil
        lock.unlock()

        log(reason)
        timer?.cancel(); timer = nil
        watcher?.stop(); watcher = nil
        accepting?.cancel()                              // its cancel handler closes the listening socket
        for connection in open { connection.close() }
        unlink(socketURL.path)
        releaseLock()
        if LiveMail.pool === pool { LiveMail.pool = nil }
        readers.stop()
        lock.lock(); finished = true; lock.unlock()
        onStop?()
    }

    /// True once the daemon has stopped for good: connections closed, socket removed, lock released.
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func prepareDirectory() throws {
        let path = configuration.directory.path
        do {
            try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        } catch {
            throw ServeError.cannotListen("can't create \(path): \(error.localizedDescription)")
        }
        chmod(path, 0o700)
    }

    private func acquireLock() throws {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ServeError.cannotListen("can't open \(lockURL.path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ServeError.alreadyRunning
        }
        lock.lock(); lockFD = fd; lock.unlock()
    }

    private func releaseLock() {
        lock.lock()
        let fd = lockFD
        lockFD = -1
        lock.unlock()
        if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
    }

    private func listen() throws {
        let path = socketURL.path
        guard let address = ServeSocket.address(for: path), path.utf8.count <= ServeSocket.maxPathLength else {
            throw ServeError.cannotListen("the socket path is too long: \(path)")
        }
        unlink(path)                                    // a socket file a killed daemon left behind
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServeError.cannotListen("socket: \(String(cString: strerror(errno)))") }
        let previous = umask(0o077)
        let bound = ServeSocket.withSockaddr(address) { Darwin.bind(fd, $0, $1) }
        umask(previous)
        guard bound == 0, Darwin.listen(fd, 64) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ServeError.cannotListen("can't listen on \(path): \(reason)")
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        lock.lock(); listenFD = fd; lock.unlock()
    }

    // MARK: - Accepting

    /// Accepts connections as they come. A dispatch source, not a thread blocked in `accept`: cancelling it is the
    /// one reliable way to stop accepting (closing a listening socket under a blocked `accept` doesn't wake it).
    private func startAccepting() {
        lock.lock()
        let fd = listenFD
        lock.unlock()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "mail42.serve.accept"))
        source.setEventHandler { [self] in
            while true {                                 // everything that is waiting
                let client = accept(fd, nil, nil)
                if client < 0 { return }                 // EAGAIN: no more for now
                admitConnection(client)
            }
        }
        source.setCancelHandler { close(fd) }
        lock.lock(); acceptSource = source; lock.unlock()
        source.resume()
    }

    private func admitConnection(_ client: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)   // accepted sockets inherit non-blocking on macOS

        let connection = Connection(fd: client, daemon: self)
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lastActivity = Date()
        lock.unlock()
        Thread.detachNewThread { connection.run() }
    }

    fileprivate func connectionClosed(_ connection: Connection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        subscribers[ObjectIdentifier(connection)] = nil
        lastActivity = Date()
        lock.unlock()
    }

    // MARK: - Version hand-over

    /// What `hello` answers: serve a client of the same version; refuse an older one and stay; for a newer one,
    /// refuse and retire (finish what is in flight, then exit, so the client can start a daemon of its own version).
    fileprivate func admit(clientVersion: String) -> Bool {
        let order = ServeVersion.compare(clientVersion, configuration.version)
        if order == 0 { return true }
        if order > 0 { retire(becauseOf: clientVersion) }
        return false
    }

    private func retire(becauseOf clientVersion: String) {
        lock.lock()
        if retiring || stopped { lock.unlock(); return }
        retiring = true
        let accepting = acceptSource
        acceptSource = nil
        let idle = inFlight == 0
        lock.unlock()
        log("retiring for the newer client \(clientVersion)")
        accepting?.cancel()                              // no new connections; the socket file goes when the daemon does
        if idle { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in stop(reason: "replaced by a newer version") } }
    }

    // MARK: - Requests

    fileprivate func beginRequest() {
        lock.lock(); inFlight += 1; lastActivity = Date(); lock.unlock()
    }

    fileprivate func endRequest() {
        lock.lock()
        inFlight -= 1
        lastActivity = Date()
        let finishRetiring = retiring && inFlight == 0 && !stopped
        lock.unlock()
        if finishRetiring { stop(reason: "replaced by a newer version") }
    }

    /// The verbs that ask Mail to do something (Apple Events) and so run one at a time.
    static func isAction(verb: String, args: [String]) -> Bool {
        switch verb {
        case "mark", "move", "archive", "delete", "junk", "draft", "open": return true
        case "permissions": return CLI.firstPositional(args) == "automation"
        default: return false
        }
    }

    /// Two `mark`s of one message that change the same thing are one request: `read`/`unread` are one thing,
    /// `flagged`/`unflagged` another. Nil for everything else (never coalesced).
    static func coalescingKey(verb: String, args: [String]) -> String? {
        guard verb == "mark" else { return nil }
        let words = CLI.positionals(args, valueFlags: ["--color"])
        guard words.count >= 2 else { return nil }
        switch words[1].lowercased() {
        case "read", "unread": return "mark:\(words[0]):read"
        case "flagged", "unflagged": return "mark:\(words[0]):flag"
        default: return nil
        }
    }

    fileprivate func submit(_ request: Request, on connection: Connection) {
        beginRequest()
        log("request \(request.verb)")
        let verb = request.verb, args = request.args
        let runVerb = configuration.runVerb

        if Self.isAction(verb: verb, args: args) {
            actions.submit(
                key: Self.coalescingKey(verb: verb, args: args),
                work: { runVerb(verb, args) },
                completion: { [self] result in
                    if request.complete() { connection.send(Self.reply(id: request.id, result)) }
                    connection.forget(request)
                    endRequest()
                })
        } else {
            readers.submit { [self] in
                guard request.begin() else { connection.forget(request); endRequest(); return }   // cancelled before it started: no reply
                let result = runVerb(verb, args)
                if request.complete() { connection.send(Self.reply(id: request.id, result)) }
                connection.forget(request)
                endRequest()
            }
        }
    }

    static func reply(id: Int, _ result: VerbResult) -> [String: Any] {
        ["id": id, "stdout": result.stdout.base64EncodedString(), "stderr": result.stderr, "status": Int(result.status)]
    }

    // MARK: - Subscriptions

    fileprivate func subscribe(_ connection: Connection) -> String {
        lock.lock(); subscribers[ObjectIdentifier(connection)] = connection; lock.unlock()
        return (try? pool.get().mailboxSignature()) ?? ""
    }

    private func broadcast(_ signature: String) {
        lock.lock()
        let targets = Array(subscribers.values)
        lock.unlock()
        let event = ["event": "changed", "signature": signature]
        for target in targets { target.send(event) }
    }

    // MARK: - Watching Mail

    private func startWatcher() {
        guard configuration.watchIndex, watcher == nil, let root = Mail42Paths.appleMailRoot() else { return }
        let pool = self.pool
        let watcher = IndexWatcher(
            mailRoot: root, debounce: configuration.debounce,
            signature: { try pool.get().mailboxSignature() },
            onChange: { [weak self] signature in
                pool.reload()
                self?.broadcast(signature)
            })
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Idle

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        lock.lock()
        ticks += 1
        let idleFor = Date().timeIntervalSince(lastActivity)
        let idle = connections.isEmpty && inFlight == 0 && !retiring && idleFor >= configuration.idleSeconds
        let needWatcher = watcher == nil && ticks % 5 == 0
        lock.unlock()
        if idle { stop(reason: "idle for \(Int(idleFor)) s"); return }
        // Without Full Disk Access there is no mail root to watch; once it is granted, start watching.
        if needWatcher { startWatcher() }
    }

    // MARK: - Log

    func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if logSize > 1 << 20 { try? FileManager.default.removeItem(at: logURL); logSize = 0 }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        logSize += data.count
    }
}

// MARK: - A request

/// One request in flight. `begin` and `cancel` race with the worker that runs it; the state machine decides who answers.
final class Request: @unchecked Sendable {
    let id: Int
    let verb: String
    let args: [String]
    private let lock = NSLock()
    private enum State { case queued, running, cancelled, answered }
    private var state = State.queued

    init(id: Int, verb: String, args: [String]) { self.id = id; self.verb = verb; self.args = args }

    /// A read worker is about to run it. False when it was cancelled while it waited (it is dropped, no reply).
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .queued else { return false }
        state = .running
        return true
    }

    /// It finished. True when this is the answer to send; false when it was cancelled (it was already answered).
    func complete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .queued || state == .running else { return false }
        state = .answered
        return true
    }

    enum Cancellation { case dropped, interrupted, nothing }

    /// The client no longer wants the answer. A read that hasn't started is `dropped` (no reply); one that has, or an
    /// action (which still runs: it may be shared with other requests, and Mail may already have it), is `interrupted`
    /// and answered 130 at once.
    func cancel(isAction: Bool) -> Cancellation {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .queued:
            state = .cancelled
            return isAction ? .interrupted : .dropped
        case .running:
            state = .cancelled
            return .interrupted
        case .cancelled, .answered:
            return .nothing
        }
    }
}

// MARK: - A connection

final class Connection: @unchecked Sendable {
    private let fd: Int32
    private unowned let daemon: ServeDaemon
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var greeted = false
    private var closed = false

    fileprivate init(fd: Int32, daemon: ServeDaemon) { self.fd = fd; self.daemon = daemon }

    func send(_ object: [String: Any]) {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !ServeSocket.writeAll(fd, ServeSocket.line(object)) { shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    func run() {
        var buffer = Data()
        while let line = ServeSocket.readLine(fd, buffer: &buffer) {
            if line.isEmpty { continue }
            if !handle(line) { break }
        }
        finish()
    }

    /// The connection is over: whatever it still had waiting is dropped; whatever is running finishes unheard.
    private func finish() {
        lock.lock()
        closed = true
        let pending = Array(requests.values)
        requests = [:]
        lock.unlock()
        for request in pending { _ = request.cancel(isAction: ServeDaemon.isAction(verb: request.verb, args: request.args)) }
        Darwin.close(fd)
        daemon.connectionClosed(self)
    }

    /// False closes the connection.
    private func handle(_ line: Data) -> Bool {
        guard let object = ServeSocket.object(line) else { return false }

        if let hello = object["hello"] as? [String: Any] {
            let version = hello["version"] as? String ?? ""
            let ok = daemon.admit(clientVersion: version)
            send(["hello": ["version": daemon.configuration.version, "ok": ok]])
            lock.lock(); greeted = ok; lock.unlock()
            return ok
        }
        lock.lock(); let ready = greeted; lock.unlock()
        guard ready else { return false }                // anything before a successful hello

        if let id = object["cancel"] as? Int {
            cancel(id)
            return true
        }
        if let name = object["subscribe"] as? String {
            guard name == "changes" else { return false }
            let signature = daemon.subscribe(self)
            send(["subscribed": "changes", "signature": signature])
            return true
        }
        guard let id = object["id"] as? Int, let verb = object["verb"] as? String else { return false }
        let args = (object["args"] as? [Any])?.compactMap { $0 as? String }
        guard let args, args.count == (object["args"] as? [Any])?.count else { return false }

        let request = Request(id: id, verb: verb, args: args)
        lock.lock()
        let duplicate = requests[id] != nil
        if !duplicate { requests[id] = request }
        lock.unlock()
        guard !duplicate else { return false }
        daemon.submit(request, on: self)
        return true
    }

    /// The request is over (answered, or dropped): its id can be used again.
    fileprivate func forget(_ request: Request) {
        lock.lock()
        if requests[request.id] === request { requests[request.id] = nil }
        lock.unlock()
    }

    private func cancel(_ id: Int) {
        lock.lock(); let request = requests[id]; lock.unlock()
        guard let request else { return }
        switch request.cancel(isAction: ServeDaemon.isAction(verb: request.verb, args: request.args)) {
        case .dropped, .nothing: break
        case .interrupted: send(["id": id, "stdout": "", "stderr": "", "status": 130])
        }
    }
}

// MARK: - The read workers

/// A few threads taking jobs in the order they were submitted.
final class WorkerPool: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var stopping = false

    init(threads: Int) {
        for _ in 0..<threads {
            Thread.detachNewThread { [self] in work() }
        }
    }

    func submit(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()
    }

    private func work() {
        while true {
            condition.lock()
            while jobs.isEmpty && !stopping { condition.wait() }
            if stopping { condition.unlock(); return }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}
