---
name: mail42-cli
description: |
  Read the user's email with the mail42 command-line tool: list mailboxes and envelopes, search (from:, is:unread,
  date:2w.. and plain words), read a message or thread, list and save attachments, and hand a message to Mail.app for
  replying. Use it whenever the user asks about their email, an inbox, a sender, a thread or an attachment, or a
  comment mentions "mail42 id <n>". Read-only; if `mail42` is missing use the mail42-setup skill.
---

# mail42-cli — reading the user's email

`mail42` is a read-only view of the mail Apple Mail already keeps on this Mac. **Never read `~/Library/Mail` or
`~/.work42/mail42/mail.db` yourself**; every fact comes from the CLI. If `command -v mail42` prints nothing, or a command
fails with `fda_denied`, use the `mail42-setup` skill. Always pass `--json` when you will parse the output.

Message ids are mail42's own (`id` in `envelope list`), not Mail.app's. Comments from the Mail widget are labelled
`Mail · <subject> · <sender> (mail42 id <n>)`: `mail42 message read <n>` gives the whole message.

## Commands

| Goal | Command |
|---|---|
| Accounts and mailboxes with counts | `mail42 mailbox list --json` |
| Newest messages (all inboxes) | `mail42 envelope list --limit 20 --json` |
| One mailbox / flagged only / unread only | `mail42 envelope list -m <mailbox-id\|all\|flagged> [--unread] --json` |
| Next page | add `--before <last id>` |
| Search | `mail42 envelope search "from:alice is:unread date:2w.." --json` |
| Read (plain text) | `mail42 message read <id> --json` |
| Read headers / HTML | `mail42 message read <id> --headers` / `--html --out file.html` |
| Whole conversation | `mail42 message thread <id> --json` |
| Attachments | `mail42 attachment list <id> --json`, `mail42 attachment save <id> <part> --to <dir> --json` |
| Open in Mail.app | `mail42 open <id>` |
| Refresh the index | `mail42 sync --json` (the widget already does this every ~2 minutes) |
| How far back is indexed | `mail42 config get window_days`; `mail42 config set window_days N` (0 = all) |

## Search language

Plain words match subject, sender, recipients and body. Combine with `and`, `or`, `not` and parentheses (adjacent
terms are `and`). Quote phrases: `"quarterly report"`.

| Term | Matches |
|---|---|
| `from:x` `to:x` `subject:x` `body:x` | substring of the name or address / that field |
| `in:inbox` `in:<mailbox-id>` `in:<name>` | a mailbox by role, id or name |
| `is:unread` `is:read` `is:flagged` | state |
| `has:attachment` | has an attachment |
| `date:2w..` `date:..3d` `date:2026-10-01..2026-10-15` | relative (`d` days, `w` weeks, `m` months ago) or absolute date range |

A malformed query fails with code `bad_query` and a position: fix it and retry.

## JSON and errors

Envelopes carry `id`, `account`, `mailbox`, `from`, `to`, `cc`, `subject`, `date` (ISO 8601), `snippet`, `is_read`,
`is_flagged`, `has_attachments`. `message read` adds the body; `body_unavailable: true` means Apple Mail has not
downloaded it (open it in Mail, then sync).

With `--json` a failure prints `{"error":{"code","message"}}` and exits non-zero (1 failed or not granted; 2 usage, not
found or bad query). Codes you will meet: `fda_denied` (needs Full Disk Access: `mail42-setup`), `no_mail_data`,
`not_found`, `bad_query`, `attachment_not_downloaded`.

## Writing: not through mail42

mail42 cannot send, reply, move or delete. When the user wants a reply or an action, prepare it for them in
Mail.app, and do not send without their explicit ok:

1. `mail42 message read <id> --json` for the content, sender and `message_id`.
2. Create a **draft** with AppleScript so the user reviews it in Mail:

   ```bash
   osascript <<'EOF'
   tell application "Mail"
     set m to make new outgoing message with properties {subject:"Re: <subject>", content:"<body>", visible:true}
     tell m to make new to recipient with properties {address:"<sender address>"}
     activate
   end tell
   EOF
   ```

   Escape quotes in the text. Never call `send`. For other changes use `mail42 open <id>` and let the user act in Mail.

## Etiquette

Email is private. Quote only what the task needs, do not paste whole threads into files in the repo, and say which
messages (by id and subject) your answer is based on.
