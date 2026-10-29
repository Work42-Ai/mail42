// mail42 — the standalone macOS CLI that reads Apple Mail's local store, read-only, for you and your agents.
//
// Manual arg dispatch (no ArgumentParser), like meet42. stdout carries verb output (JSON with `--json`, else
// human text); all diagnostics go to stderr. mail42 never writes to Apple Mail and never sends mail, and it keeps
// no copy of the user's mail: every answer is read live from Apple Mail's own data.

import Foundation
import Mail42AppleMail

let mail42Version = "0.1.0"

// `--reexec` is the internal marker of the permission-identity re-launch (Mail42Daemon); verbs never see it.
let argv = Mail42Daemon.strippingReexec(CommandLine.arguments)
let command = argv.count > 1 ? argv[1] : "help"
let rest = Array(argv.dropFirst(2))

Dispatcher.run(command: command, args: rest)

enum Dispatcher {

    /// The verbs that read Apple Mail's files, so they must run as mail42's own permission principal (the one the
    /// user grants Full Disk Access to), not as whatever launched them.
    private static let readVerbs: Set<String> = ["mailbox", "envelope", "message", "attachment", "open"]

    static func run(command: String, args: [String]) {
        if readVerbs.contains(command) {
            Mail42Daemon.reexecIfNeeded(arguments: [command] + args)
        }
        switch command {
        case "mailbox":
            MailboxCommand.run(args: args)
        case "envelope":
            EnvelopeCommand.run(args: args)
        case "message":
            MessageCommand.run(args: args)
        case "attachment":
            AttachmentCommand.run(args: args)
        case "open":
            OpenCommand.run(args: args)
        case "permissions":
            PermissionsCommand.run(args: args)
        case "version", "--version", "-v":
            print("mail42 v\(mail42Version)")
        case "help", "--help", "-h", "":
            printUsage()
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

        Every verb accepts --json. mail42 only reads, live, from Apple Mail's own data: it keeps no copy of your
        mail, never changes Apple Mail and never sends mail. Errors with --json are
        {"error":{"code","message"}}. Exit codes: 0 ok, 1 failed or not granted, 2 usage / not found / bad query.

        Mail:
          mailbox list [--json]
                Accounts (named as in Mail) and their mailboxes, with total and unread counts.
          envelope list [-m <mailbox-id|name|all|flagged>] [--unread] [--flagged] [--conversations] [--limit N] [--before <id>] [--json]
                Message summaries, newest first (default: every inbox, 50 per page). Every one carries a `link`
                (mail42://message/…). --conversations gives one row per conversation: its newest message in the view,
                conversation_count (the whole conversation, Sent included) and participants.
          envelope search "<query>" [--limit N] [--json]
                Search with from: to: subject: body: in: is:unread|read|flagged has:attachment
                date:2w.. date:2026-10-01..2026-10-15, plus and / or / not and plain words.
                Words and body: read the text of the newest matching messages (it says when that isn't all).
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
