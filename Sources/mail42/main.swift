// mail42 — the standalone macOS CLI that reads Apple Mail's local store, read-only, for you and your agents.
//
// Manual arg dispatch (no ArgumentParser), like meet42. stdout carries verb output (JSON with `--json`, else
// human text); all diagnostics go to stderr. mail42 never writes to Apple Mail and never sends mail, and it keeps
// no copy of the user's mail: every answer is read live from Apple Mail's own data.
//
// This file only gets the process into the right shape (permission identity, stale files) and hands the verb to
// `VerbRunner`, which runs it and returns its output; the verbs themselves never print or exit on their own.

import Foundation
import Mail42AppleMail

let mail42Version = "0.2.0"

// `--reexec` is the internal marker of the permission-identity re-launch (Mail42Daemon); verbs never see it.
let argv = Mail42Daemon.strippingReexec(CommandLine.arguments)
let command = argv.count > 1 ? argv[1] : "help"
let rest = Array(argv.dropFirst(2))

Dispatcher.run(command: command, args: rest)

enum Dispatcher {

    /// The verbs that read Apple Mail's files, so they must run as mail42's own permission principal (the one the
    /// user grants Full Disk Access to), not as whatever launched them.
    private static let readVerbs: Set<String> = [
        "mailbox", "envelope", "message", "attachment", "open",
        // The action verbs ask Mail to do things, so they need mail42's own identity too: macOS then asks whether
        // *mail42* may control Mail.
        "mark", "move", "archive", "delete", "junk", "draft",
    ]

    static func run(command: String, args: [String]) -> Never {
        VerbRunner.version = mail42Version
        if readVerbs.contains(command) {
            Mail42Daemon.reexecIfNeeded(arguments: [command] + args)
        }
        // A run that was killed before it could close leaves its fallback copy of the index in $TMPDIR.
        EnvelopeIndexSnapshot.removeStaleCopies()

        let result = VerbRunner.run(command: command, args: args)
        FileHandle.standardOutput.write(result.stdout)
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        exit(result.status)
    }
}
