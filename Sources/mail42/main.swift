// mail42 — the standalone macOS CLI that reads Apple Mail's local store, read-only, for you and your agents.
//
// Manual arg dispatch (no ArgumentParser), like meet42. stdout carries verb output (JSON with `--json`, else
// human text); all diagnostics go to stderr. mail42 never writes to Apple Mail and never sends mail.

import Foundation
import Mail42AppleMail

let mail42Version = "0.1.0"

// `--reexec` is the internal marker of the permission-identity re-launch (Mail42Daemon); verbs never see it.
let argv = Mail42Daemon.strippingReexec(CommandLine.arguments)
let command = argv.count > 1 ? argv[1] : "help"
let rest = Array(argv.dropFirst(2))

Dispatcher.run(command: command, args: rest)

enum Dispatcher {

    /// Verbs that exist in the CLI surface but are implemented by later sub-issues of WOR-438.
    private static let notImplementedYet: Set<String> = [
        "mailbox", "envelope", "message", "attachment", "open",
    ]

    static func run(command: String, args: [String]) {
        switch command {
        case "permissions":
            PermissionsCommand.run(args: args)
        case "sync":
            SyncCommand.run(args: args)
        case "config":
            ConfigCommand.run(args: args)
        case "version", "--version", "-v":
            print("mail42 v\(mail42Version)")
        case "help", "--help", "-h", "":
            printUsage()
        case _ where notImplementedYet.contains(command):
            CLI.fail(code: "not_implemented", message: "`\(command)` is not implemented yet",
                     exit: 2, json: CLI.wantsJSON(args))
        default:
            CLI.warn("mail42: unknown command: \(command)")
            printUsage()
            exit(2)
        }
    }

    static func printUsage() {
        print("""
        mail42 v\(mail42Version) — read-only local email for you and your agents (Apple Mail)

        Usage: mail42 <command> [options]

        Every verb accepts --json. mail42 only reads: it never changes Apple Mail and never sends mail.
        Errors with --json are {"error":{"code","message"}}. Exit codes: 0 ok, 1 failed or not granted,
        2 usage / store / not found / bad query.

        Mail:
          mailbox list [--json]
                Accounts and their mailboxes, with total and unread counts.
          envelope list [-m <mailbox-id|all|flagged>] [--unread] [--flagged] [--limit N] [--before <id>] [--json]
                Message summaries, newest first (default: every inbox, 50 per page).
          envelope search "<query>" [--limit N] [--json]
                Search with from: to: subject: body: in: is:unread|read|flagged has:attachment
                date:2w.. date:2026-10-01..2026-10-15, plus and / or / not and plain words.
          message read <id> [--text|--html|--headers] [--out <file>] [--json]
                The full message: plain text by default, sanitised HTML with --html.
          message thread <id> [--json]
                Every message in the same conversation, oldest first.
          attachment list <id> [--json]
          attachment save <id> <part> [--to <dir>] [--json]
                List a message's attachments, or copy one out (default ~/Downloads).
          open <id>
                Open the message in Mail.app.

        Index:
          sync [--full] [--json]
                Copy new, changed and removed mail from Apple Mail into ~/.work42/mail42/mail.db.
          config get [window_days] [--json]
          config set window_days <N>
                How many days of mail to index (default 90, 0 = all).

        Access:
          permissions [--json]
                Full Disk Access status. Exit 0 when granted.
          permissions open
                Open System Settings → Privacy & Security → Full Disk Access.

        Other:
          version        Print the version.
          help           Print this text.
        """)
    }
}
