---
name: widget-mail
description: How the mail42 Mail widget (session tab kindId widget:mail) works: a lightweight, read-only reader over every Apple Mail account, with a message list, a full-HTML reader, highlight-to-comment and a background sync. Use it to know what the user is looking at when they comment on an email, or when the widget shows a setup state.
---

# Mail widget

A read-only reader for the mail that Apple Mail already keeps on this Mac. It shows a searchable list of messages
on the left and the selected message, rendered as the sender wrote it, on the right. It never sends, replies to,
moves or changes mail.

- **Data source:** only the standalone `mail42` CLI (`mail42 envelope list|search`, `message read`,
  `attachment list|save`, `mailbox list`, `open`, `sync`). The widget never opens `~/Library/Mail` itself.
- **Toolbar (tab-bar row):** a mailbox menu (All Inboxes, Flagged, then each account's mailboxes with unread
  counts), an Unread-only toggle, Sync now, and **Open in Mail** (opens the selected message in Mail.app, where
  replying or archiving happens).
- **Search field:** accepts the `mail42 envelope search` language, e.g. `from:alice is:unread date:2w..`; plain
  words search subject, sender, recipients and body.
- **Reader:** the message's own HTML, sanitised by `mail42` (no scripts, no event handlers, inline images
  embedded, remote images load). Links open through Work42's Open Link. Attachment chips save the file to
  Downloads and reveal it in Finder.
- **Highlight-to-comment:** selecting text in the reader offers a comment. The comment arrives in the chat
  composer labelled `Mail · <subject> · <sender> (mail42 id <id>)`: run `mail42 message read <id>` for the full
  message.
- **Background sync:** while Work42 runs and Full Disk Access is granted, `mail42 sync` runs about every two
  minutes; the open list refreshes by itself.

## Setup states

| The tile says | Meaning | Fix |
|---|---|---|
| mail42 isn't installed | no `mail42` on PATH | ask the agent to set up mail42 (the `mail42-setup` skill) |
| Allow mail42 to read Mail | Full Disk Access isn't granted to mail42.app | **Open Settings**, turn on mail42, then **Check again** |
| No Mail accounts found | Apple Mail has no accounts, or the first sync hasn't run | open Mail and add an account, then Sync now |

## Notes for agents

- The reader files live under `~/.work42/mail42/reader/artifacts/mail42-reader/` (registered with the artifact
  server under mail42's own id, so the widget works in a session tab and on the session-less workspace home); they
  are disposable and only the latest few are kept.
- While a sync runs, the CLI keeps `~/.work42/mail42/sync-status.json` up to date and the tile shows "Loading your
  mail… N of M messages" instead of an empty state.
- Message ids in comments and in the CLI are mail42's own (`envelope list` shows them), not Mail.app's.
