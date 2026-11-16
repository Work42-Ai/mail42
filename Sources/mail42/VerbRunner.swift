// VerbRunner.swift — the one place a verb runs, for the CLI and for the `serve` daemon.
//
// `VerbRunner.run` runs a verb and returns what it wrote and how it ended instead of printing and exiting. The CLI
// writes those bytes to the real stdout and stderr and exits with the status (main.swift); the daemon sends them
// back to its client. Because both go through here, a verb's output is the same either way.

import Foundation

struct VerbResult: Sendable {
    let stdout: Data
    let stderr: String
    /// The exit status: 0 when the verb returned, else the status of the `VerbExit` that ended it.
    let status: Int32
}

enum VerbRunner {

    /// The version `version` and `help` print. `main.swift` sets it once at start (the constant lives there so the
    /// release script can read it); it is a value here because top-level code in main.swift doesn't run when tests
    /// import this module.
    nonisolated(unsafe) static var version = "dev"

    /// Runs `command args…` (the same words as on the command line, without `mail42`) and returns its output.
    /// The caller is responsible for being the right permission principal first (`Mail42Daemon.reexecIfNeeded`).
    static func run(command: String, args: [String]) -> VerbResult {
        let sink = OutputSink()
        var status: Int32 = 0
        Output.$sink.withValue(sink) {
            do {
                try dispatch(command: command, args: args)
            } catch let exit as VerbExit {
                status = exit.status
            } catch {
                CLI.warn("mail42: \(error.localizedDescription)")
                status = 2
            }
        }
        return VerbResult(stdout: sink.stdout, stderr: sink.stderr, status: status)
    }

    private static func dispatch(command: String, args: [String]) throws {
        switch command {
        case "mailbox":
            try MailboxCommand.run(args: args)
        case "envelope":
            try EnvelopeCommand.run(args: args)
        case "message":
            try MessageCommand.run(args: args)
        case "attachment":
            try AttachmentCommand.run(args: args)
        case "open":
            try OpenCommand.run(args: args)
        case "mark", "move", "archive", "delete", "junk", "draft":
            try ActionCommand.run(command: command, args: args)
        case "permissions":
            try PermissionsCommand.run(args: args)
        case "version", "--version", "-v":
            print("mail42 v\(version)")
        case "help", "--help", "-h", "":
            printUsage()
        default:
            CLI.warn("mail42: unknown command: \(command)")
            printUsage()
            throw VerbExit(status: 2)
        }
    }

    static func printUsage() {
        print("""
        mail42 v\(version) — read-only local email for you and your agents (Apple Mail)

        Usage: mail42 <command> [options]

        Every verb accepts --json. mail42 reads live from Apple Mail's own data and keeps no copy of your mail. It
        never edits Apple Mail's files and never sends mail: anything that changes mail is asked of Mail itself.
        Errors with --json are {"error":{"code","message"}}. Exit codes: 0 ok, 1 failed or not granted (Full Disk
        Access, Automation, Mail timed out), 2 usage / not found / bad query.

        Mail:
          mailbox list [--json]
                Accounts (named as in Mail) and their mailboxes, with total and unread counts.
          envelope list [-m <mailbox-id|name|all|flagged>] [--unread] [--flagged] [--conversations] [--limit N] [--before <id>] [--json]
                Message summaries, newest first (default: every inbox, 50 per page). Every one carries a `link`
                (mail42://message/…). --conversations gives one row per conversation: its newest message in the view,
                conversation_count (the whole conversation, Sent included) and participants.
          envelope search "<query>" [--limit N] [--headers] [--json]
                Search with from: to: subject: body: in: is:unread|read|flagged has:attachment
                date:2w.. date:2026-10-01..2026-10-15, plus and / or / not and plain words.
                A word is found at once in the subject, sender and recipients; only then is the text of the newest
                other messages read (and it says when that isn't all). --headers stops after the instant part.
          message read <id> [--text|--html|--headers] [--out <file>] [--json]
                The full message: plain text by default, sanitised HTML with --html.
          message thread <id> [--json]
                Every message in the same conversation (all mailboxes), oldest first.
          message resolve <link|id> [--prefer-mailbox <id>] [--json]
                The message a mail42:// link points at. The row id is tried first; if Mail moved the message, it is
                found again by its Message-ID.
          attachment list <id> [--json]
          attachment save <id> <part> [--to <dir>] [--json]
                List a message's attachments, or copy one out (default ~/Downloads).
          open <id>
                Open the message in Mail.app.

        Act (through Apple Mail; a message is an id or a mail42://message/… link; the first one asks macOS to let
        mail42 control Mail):
          mark <id> read|unread|flagged|unflagged [--color red|orange|yellow|green|blue|purple|gray]
          move <id> <mailbox id|name>        (a mailbox of the message's own account)
          archive <id>                       (to the account's Archive; Gmail: removes it from the Inbox)
          delete <id>                        (to the Trash)
          junk <id>                          (marks it junk and moves it to Junk)
          draft reply|reply-all|forward <id>
          draft new [--to <addr>] [--cc <addr>] [--subject <text>] [--body <text>]
                Drafts open Mail's compose window, filled in. mail42 never sends: you press Send in Mail.

        Access:
          permissions [--json]
                Full Disk Access status. Exit 0 when granted.
          permissions open
                Open System Settings → Privacy & Security → Full Disk Access.

        Service:
          serve [--detach]
                The background service the Mail widget and Work42 use: one process that keeps Mail's index open and
                answers every client, and tells them when Mail changed. --detach starts it in the background and
                returns. Every other verb uses it when it is running and works alone when it isn't.

        Other:
          version        Print the version.
          help           Print this text.
        """)
    }
}
