// MailTransport.swift — how the widget's requests reach Apple Mail.
//
// The widget asks for everything it shows through one `MailTransport`: on the Mac `MailCtlDirectTransport` reads and acts in this
// process (Work42's Full Disk Access and Automation services); on the iPad `MailPluginToolsTransport` calls the plugin's `mail` tools
// on the paired Mac. `MailStore` sits above it and is the same on both.

import Foundation
import Work42PluginKit

nonisolated protocol MailTransport: Sendable {

    /// Runs one request (a verb and its arguments, in the vocabulary of `MailStore`) and returns what it answered. Cancelling the
    /// task that runs this cancels the request (the call ends with `CancellationError`).
    func run(_ arguments: [String]) async throws -> MailCLIResult

    /// A signal each time Apple Mail's mailboxes changed (new mail, something read, flagged, moved or deleted). The value is a
    /// signature of the mailbox counters, or empty when the stream restarted and a change may have been missed. The widget answers a
    /// signal by asking again for what it shows.
    func changes() -> AsyncStream<String>

    /// Lets go of the open index and ends every `changes()` stream.
    func close()
}

/// There is nothing to read mail with (no services yet: the tile isn't attached, or the model was made headless): every request
/// fails with `failure`, which by default says Mail needs Work 42.
nonisolated struct MailUnavailableTransport: MailTransport {
    static let code = "needs_work42"

    var failure = MailFailure(code: Self.code, message: "Mail needs Work 42 to read your mail. Open it from Work 42.")

    func run(_ arguments: [String]) async throws -> MailCLIResult { throw failure }
    func changes() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func close() {}
}
