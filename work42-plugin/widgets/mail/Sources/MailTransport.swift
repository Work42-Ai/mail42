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
/// metacharacters). The Mac has no daemon to subscribe to from here yet, so a change is found the old way, by asking
/// for the mailbox counters every few seconds while someone is listening.
nonisolated final class MailShellTransport: MailTransport, @unchecked Sendable {

    private let shell: any WidgetShellService
    private let pollInterval: Duration

    init(shell: any WidgetShellService, pollInterval: Duration = .seconds(6)) {
        self.shell = shell
        self.pollInterval = pollInterval
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
