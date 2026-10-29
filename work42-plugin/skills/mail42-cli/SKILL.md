---
name: mail42-cli
description: |
  Read and act on the user's email through the mail42 command-line tool, which works with Apple Mail: list mailboxes
  and conversations, search (from:, is:unread, date:2w.. and plain words), read a message or thread, save
  attachments, link to a message, and, when asked, mark, flag, move, archive, delete or junk it or open a reply
  draft in Mail. Use it whenever the user asks about their email, an inbox, a sender, a thread or an attachment, or
  mentions a mail42:// link. If `mail42` is missing use the mail42-setup skill.
---

# mail42-cli — the user's email, through Apple Mail

`mail42` reads the mail Apple Mail already keeps on this Mac, live (it keeps no copy), and asks Apple Mail itself to
change things. **Never read `~/Library/Mail` yourself**; every fact comes from the CLI. If `command -v mail42` prints
nothing, or a command fails with `fda_denied`, use the `mail42-setup` skill. Always pass `--json` when you will parse
the output.

## Naming a message

Every message has an id (`id` in `envelope list`) and a **link**, `mail42://message/<id>?mid=<Message-ID>` (the
`link` field of every envelope). **Share the link when you point the user at a message**: clicking it in Work42
opens that exact message in the Mail42 tile. Every command that takes `<id>` also takes a link. Mail gives a message a
new id when it moves it (archive, move); a link carries the Message-ID too, so it still finds the message, and
`mail42 message resolve <link>` returns where it is now. Comments from the Mail42 tile are labelled
`Mail42 · <subject> · <sender> (<link>)`.

## Reading

| Goal | Command |
|---|---|
| Accounts and mailboxes with counts | `mail42 mailbox list --json` |
| Newest messages (all inboxes) | `mail42 envelope list --limit 20 --json` |
| One row per conversation | `mail42 envelope list --conversations --json` (adds `conversation_count`, `participants`) |
| One mailbox / flagged / unread | `mail42 envelope list -m <mailbox-id\|name\|all\|flagged> [--unread] --json` |
| Next page | add `--before <last id>` |
| Search | `mail42 envelope search "from:alice is:unread date:2w.." --json` |
| Read (plain text) | `mail42 message read <id> --json` |
| Read headers / HTML | `mail42 message read <id> --headers` / `--html --out file.html` |
| Whole conversation (every mailbox, Sent included) | `mail42 message thread <id> --json` |
| Find a message from a link or an old id | `mail42 message resolve <link\|id> --json` |
| Attachments | `mail42 attachment list <id> --json`, `mail42 attachment save <id> <part> --to <dir> --json` |
| Show it in Mail.app | `mail42 open <id>` |

### Search language

Plain words match subject, sender, recipients and the text of the message. Combine with `and`, `or`, `not` and
parentheses (adjacent terms are `and`). Quote phrases: `"quarterly report"`.

| Term | Matches |
|---|---|
| `from:x` `to:x` `subject:x` `body:x` | substring of the name or address / that field |
| `in:inbox` `in:<mailbox-id>` `in:<name>` | a mailbox by role, id or name |
| `is:unread` `is:read` `is:flagged` | state |
| `has:attachment` | has an attachment |
| `date:2w..` `date:..3d` `date:2026-10-01..2026-10-15` | relative (`d` days, `w` weeks, `m` months ago) or absolute range |

Searches on the headers (from, to, subject, dates, state) are instant. Words and `body:` read the text of the newest
matching messages, which takes a few seconds on a big mailbox: if it could not read them all it says so on **stderr**
(`Read the text of the newest 20,000…`). Add `from:`, `in:` or `date:` to narrow it and reach further back. Text
matching ignores capitals but not accents (`café` ≠ `cafe`). A malformed query fails with `bad_query` and a position.

## Acting (through Apple Mail)

These change the user's real mail. **Do them only when the user asked for that action**, and say what you did
(subject and link). The first one makes macOS ask once whether mail42 may control Mail.

| Goal | Command |
|---|---|
| Read / unread | `mail42 mark <id> read` / `unread` |
| Flag | `mail42 mark <id> flagged [--color red\|orange\|yellow\|green\|blue\|purple\|gray]`, `unflagged` |
| Move to a mailbox of the same account | `mail42 move <id> <mailbox id\|name>` |
| Archive | `mail42 archive <id>` (Gmail: removes it from the Inbox) |
| Delete (to Trash) | `mail42 delete <id>` |
| Junk | `mail42 junk <id>` |
| Reply / reply all / forward | `mail42 draft reply\|reply-all\|forward <id>` |
| New message | `mail42 draft new [--to a@b.c] [--cc …] [--subject …] [--body …]` |

Each prints `{"ok":true,"id":…,"link":…}`; after a move the `link` is the message's new one. Moves and deletes can be
undone with `move <link> INBOX`; check Mail's Trash and Junk before telling the user something is gone.

**Drafts are never sent.** `draft …` opens Mail's own compose window, pre-filled (recipients, `Re:` subject, the
quoted original, the user's signature). The user reads it and presses Send in Mail. mail42 has no way to send, and
you must not script Mail's `send` either. Tell the user the draft is open and what it says.

## JSON and errors

Envelopes carry `id`, `link`, `message_id`, `conversation_id`, `account`, `mailbox`, `from`, `to`, `cc`, `subject`,
`date` (ISO 8601), `snippet`, `is_read`, `is_flagged`, `has_attachments`. `message read` adds the body;
`body_unavailable: true` means Apple Mail has not downloaded it (open it in Mail).

With `--json` a failure prints `{"error":{"code","message"}}` and exits non-zero (1 failed or not granted; 2 usage,
not found or bad query). Codes you will meet:

| Code | Meaning |
|---|---|
| `fda_denied` | mail42 can't read Apple Mail: Full Disk Access (`mail42-setup`) |
| `no_mail_data` | Apple Mail has no accounts yet |
| `not_found` | no such message or mailbox (a link whose message was deleted for good) |
| `bad_query` | the search didn't parse |
| `automation_denied` | macOS doesn't let mail42 control Mail: System Settings › Privacy & Security › Automation › mail42 › Mail (`mail42 permissions automation` checks) |
| `mail_timeout` | Mail didn't answer in 20 s; the action may or may not have happened, so look before retrying |
| `no_archive_mailbox` | the account has no Archive mailbox |
| `action_failed` | Mail refused; the message is Mail's own words |

## Etiquette

Email is private. Quote only what the task needs, do not paste whole threads into files in the repo, and say which
messages (by link and subject) your answer is based on.
