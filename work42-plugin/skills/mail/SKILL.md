---
name: mail
description: Read and act on the person's email in Apple Mail through the Mail plugin's `mail` MCP tools. List mailboxes and messages, search (from:, is:unread, date:2w.., in:, body: and plain words), read a message or a whole thread, save attachments, link to a message (mail42://), and, only when asked, mark, flag, move, archive, delete or junk it or open a reply draft in Mail. Use it whenever the person asks about their email, an inbox, a sender, a thread or an attachment, or mentions a mail42:// link.
---

# Mail

The Mail plugin gives you the `mail` MCP tools over the person's Apple Mail on their Mac. They read Mail's own data live (there is
no copy and no sync) and act through Apple Mail itself. Nothing here ever sends an email: a reply is opened as a draft in Mail
and the person presses Send. There is no command-line tool to run and nothing to install: call the tools.

**Never read `~/Library/Mail` yourself and never script Mail with AppleScript.** Every fact comes from the tools.

## The tools

Reading (these change nothing):

| Tool | Use it to |
|---|---|
| `list_mailboxes` | See the accounts and their mailboxes: id, role (inbox, sent, archive, junk, trash…), total and unread counts. |
| `list_messages` | Page the newest messages: `mailbox` (`all` is the default, `flagged`, an id, or a name/role such as `inbox`), `unread_only`, `flagged_only`, `conversations`, `limit`, `before_id`. |
| `search_messages` | Search with the query language below; `headers_only` makes it instant. |
| `read_message` | Read one message: envelope, headers, body as text (or `format: "html"`) and its attachments. |
| `read_thread` | The whole conversation of a message, oldest first, from every mailbox (Sent included). |
| `list_attachments` | The attachments of a message: `part`, filename, type, size. |
| `get_message_link` | The `mail42://message/…` link of a message, and Mail's own `message://` URL. |
| `open_in_mail` | Bring the message forward in Mail (changes nothing in the mailbox). |

Acting (these change the person's mail or their screen):

| Tool | Does |
|---|---|
| `save_attachment` | Saves one attachment (by `part`) on the Mac, in `~/.work42/mail42/attachments`. |
| `mark_message` | Read/unread and/or flagged/unflagged (`color` with `flagged: true`). |
| `move_message` | Moves it to another mailbox of the same account (`mailbox`: id, name or role). |
| `archive_message` | Moves it to the account's Archive (for Gmail this removes it from the Inbox). |
| `delete_message` | **Destructive.** Moves it to the account's Trash. |
| `junk_message` | **Destructive.** Marks it as junk and moves it to the account's Junk. |
| `open_reply_draft` | Opens a reply, reply-all or forward (`mode`) in Mail's compose window, pre-filled. Never sent. |

## Finding a message

Start from the question. "What's new?" is `list_messages` with `unread_only` (use `conversations: true` for one row per
conversation). "Mail from Ada about the invoice" is `search_messages`. A list or search answer carries `next_before_id` when there
is more: pass it as `before_id` to get the next page. Prefer a small `limit` and narrow the query over paging through everything.

### The query language

Plain words match the subject, sender, recipients and the message text. Reading text is done on the newest messages and takes a few
seconds on a big mailbox: the answer's `note` says when it could not read them all. Narrow with `from:`, `in:` or `date:`, or set
`headers_only` to match only subject, sender, recipients and Apple's preview line.

| Term | Matches |
|---|---|
| `from:ada`, `to:ada`, `subject:invoice`, `body:"net 30"` | that field contains the text |
| `in:inbox`, `in:<mailbox id>`, `in:Receipts` | messages of that mailbox (a role, an id from `list_mailboxes`, or a name) |
| `is:unread`, `is:read`, `is:flagged` | state |
| `has:attachment` | has an attachment |
| `date:2w..`, `date:..3d`, `date:2026-10-01..2026-10-15` | received in a range (`d` days, `w` weeks, `m` months ago) |
| `and`, `or`, `not`, `( )`, `"a phrase"` | combine terms; a space between terms is `and` |

Examples: `from:ada is:unread date:2w..`, `in:inbox not is:read has:attachment`, `subject:"quarterly report" or body:forecast`.
A query that is not valid syntax is an error with a suggestion: fix it and try again.

## Reading

- `read_message` with the message's `id` or, better, its `mail42://` link (an id can change when Mail moves a message; the link
  still finds it). `body_unavailable: true` means Apple Mail has not downloaded the body yet: say so and offer `open_in_mail`.
  Long text is cut and says `truncated`.
- To read a thread: call `read_thread` for the conversation (envelopes, oldest first), then `read_message` for the messages you
  need the text of. Do not read every message of a long thread unless asked.

## Attachments

`list_attachments` for the parts, then `save_attachment` with the `id` and the `part`. The file is saved **on the Mac**, in
`~/.work42/mail42/attachments` (the only folder attachments can be saved to; a taken name gets a number: `report (1).pdf`). The answer
gives the saved path: read the file from there, or tell the person where it is. Saving writes a file on their machine, so only do
it when it helps the question.

## Links

Every message has a link, `mail42://message/<id>?mid=<Message-ID>`, from `get_message_link` (and in every list entry as `link`).
When you mention a message to the person, give its link: clicking it anywhere in Work 42 opens the message in the Mail tile, even
after Mail moved it. Say who it is from and the subject next to it so they know what they are clicking.

## Changing the person's mail

Actions change the person's real mailbox, which syncs to their mail server.

- **Ask before you archive, delete, junk or move** unless they told you to ("archive everything from the newsletter", "delete that").
  For a batch, say what the search matched (count and a few subjects) and confirm before doing it to all of them.
- `delete_message` and `junk_message` are destructive. A deleted message can be brought back from Trash with `move_message`, but do
  not rely on that, and never use either as a way to "clean up" on your own.
- `mark_message` is mild but still visible (the unread dot). Do not mark messages read just because you read them.
- After acting, say what you did with the subject and the link (the answer has the message's new link: Mail gives a moved message a
  new id).
- `open_reply_draft` opens a draft in Mail; you cannot send it. Tell the person the draft is open and that they send it.

## Permissions

The tools need two macOS permissions for **Work 42** (the app that runs the plugin), which the person grants once:

- **Full Disk Access**, to read Apple Mail's data.
- **Automation for Mail**, to let Work 42 control Mail (mark, move, archive, delete, drafts).

Work 42 asks the person itself, through its pill, the first time a tool needs one; they approve it there and in System Settings. If a
tool answers `fda_denied` or `automation_denied`, tell the person which permission is missing and that Work 42 will ask for it
(do not try to work around it); then try again once they say it is granted. `no_mail_data` means Apple Mail has no accounts or
has never been opened. The tools run on the Mac: if the Mac is asleep or Work 42 is not running there, they do not answer.
