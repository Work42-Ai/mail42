// MailTransport.swift — how the widget's requests reach mail42.
//
// The widget asks mail42 for everything it shows. `MailTransport` is the one place that says how: on the Mac, over the
// `mail42 serve` daemon's socket (MailServeClient: no process per request, no thread waiting); on the iPad, as shell
// calls the paired Mac runs (MailShellTransport). `MailStore` sits above it and is the same on both.

import Foundation
import Work42PluginKit

nonisolated protocol MailTransport: Sendable {

    /// Runs `mail42 <arguments>` and returns what it printed. Cancelling the task that runs this cancels the request
    /// (the daemon is told, and the call ends with `CancellationError`).
    func run(_ arguments: [String]) async throws -> MailCLIResult

    /// A signal each time Apple Mail's mailboxes changed (new mail, something read, flagged, moved or deleted). The value
    /// is the daemon's signature of the mailbox counters, or empty when the stream restarted and a change may have been
    /// missed. The widget answers a signal by asking again for what it shows.
    func changes() -> AsyncStream<String>

    /// Lets go of the connection and ends every `changes()` stream.
    func close()
}

#if os(iOS)

/// The iPad: each request is a shell command the Mac runs (`services.shell`, built-in widgets only, no shell
/// metacharacters). A change is told by the Mac: its Work42 holds the one subscription to the mail42 service and pushes
/// `widget:mail/changes` (`{"signature","tree"}`) to every iPad that watches, so nothing is polled. Only a Mac whose Work42
/// has no such stream (an older one) is asked for the mailbox counters every few seconds, the way it used to be.
nonisolated final class MailShellTransport: MailTransport, @unchecked Sendable {

    private let shell: any WidgetShellService
    private let pollInterval: Duration
    /// The Mac's `changes` stream, or nil when there is none to ask for.
    private let changeStream: (@Sendable () async -> AsyncStream<Data>)?

    init(
        shell: any WidgetShellService,
        pollInterval: Duration = .seconds(6),
        changeStream: (@Sendable () async -> AsyncStream<Data>)? = nil
    ) {
        self.shell = shell
        self.pollInterval = pollInterval
        self.changeStream = changeStream
    }

    func run(_ arguments: [String]) async throws -> MailCLIResult {
        let command = (["mail42"] + arguments.map(MailCLI.quoted)).joined(separator: " ")
        let result: WidgetShellResult
        do {
            result = try await shell.run(command: command)
        } catch let error as WidgetServiceError {
            // A refusal names its reason (a character the link won't carry); anything else is the Mac not answering.
            throw MailFailure(
                code: error.isNotPermitted ? "not_permitted" : "mac_unreachable",
                message: error.isNotPermitted ? error.message : "Your Mac didn\u{2019}t answer: \(error.message)")
        }
        if result.exitCode == 127 { throw MailFailure.notInstalled }
        return MailCLIResult(status: result.exitCode, stdout: Data(result.stdout.utf8), stderr: result.stderr)
    }

    func changes() -> AsyncStream<String> {
        let interval = pollInterval
        return AsyncStream { continuation in
            let task = Task { [self] in
                // Follow the Mac's stream. Its first state is what is there now (the widget has just read it); each later one with
                // a new signature is a change. A stream that ends at once is a host without it: ask for the counters instead.
                if let changeStream {
                    var last: String?
                    var count = 0
                    for await data in await changeStream() {
                        count += 1
                        guard let signature = Self.signature(in: data) else { continue }
                        defer { last = signature }
                        if count > 1, !signature.isEmpty, signature != last { continuation.yield(signature) }
                    }
                    if Task.isCancelled { continuation.finish(); return }
                }
                var last: String?
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    guard let result = try? await run(["mailbox", "list", "--json"]), result.status == 0 else { continue }
                    let signature = String(decoding: result.stdout, as: UTF8.self)
                    defer { last = signature }
                    if let last, last != signature { continuation.yield(String(signature.hashValue)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() {}

    /// `signature` of a `widget:mail/changes` state; nil when the bytes are not one.
    static func signature(in data: Data) -> String? {
        struct State: Decodable { let signature: String }
        return (try? JSONDecoder().decode(State.self, from: data))?.signature
    }
}

/// There are no services to reach a Mac through (the tile isn't attached yet): every request fails the way an
/// unreachable Mac does.
nonisolated struct MailUnavailableTransport: MailTransport {
    func run(_ arguments: [String]) async throws -> MailCLIResult {
        throw MailFailure(code: "mac_unreachable", message: "Your Mac didn\u{2019}t answer.")
    }
    func changes() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func close() {}
}

#endif
