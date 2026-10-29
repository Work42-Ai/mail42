---
name: widget-mail
description: How the Mail42 widget (session tab kindId widget:mail) works: a mail client over Apple Mail with conversations, a themed reader, Reply/Forward/Archive/Delete/Move/Flag/Junk, mail42:// links and highlight-to-comment. Use it to know what the user is looking at when they comment on an email or click a mail42:// link, or when the tile shows a setup state.
---

# Mail42 widget

A mail client for the mail Apple Mail already keeps on this Mac. The list on the left shows **conversations** under
date headers (Today, Yesterday, a weekday, a month); the pane on the right shows the open conversation, one message
expanded and the others folded to a line. It works through Apple Mail: reads are live (no copy), and every change is
asked of Mail itself. Replies, forwards and new messages open Mail's own compose window; the user presses Send there.
Nothing here ever sends.

- **Data source:** only the standalone `mail42` CLI (`envelope list --conversations`, `envelope search`,
  `message read|thread|resolve`, `attachment list|save`, `mailbox list`, `mark`, `move`, `archive`, `delete`, `junk`,
  `draft`, `open`). The widget never opens `~/Library/Mail` or scripts Mail itself.
- **Tab-bar row (two controls):** the inbox switcher (All Inboxes, Flagged, each account's Inbox, with unread counts, and
  an Unread Only switch; its label is the current view and its unread count) and **New** (a new message in Mail).
- **Widget header:** the view's title and `N unread · M messages` on the left; on the right Reply, Forward, Archive,
  Delete and a **More** menu (Reply All, Mark as Read/Unread, Flag with a colour, Move to a mailbox of the same account,
  Junk, Copy Link to Message, Open in Mail). A row's right-click shows the same menu. Mail's shortcuts work: ⌘R reply,
  ⇧⌘R reply all, ⇧⌘F forward, ⌃⌘A archive, ⌘⌫ delete, ⇧⌘J junk, ⇧⌘L flag, ⇧⌘U read/unread, ⌘O open in Mail, ⌘N
  new; in the list ↑ ↓ move between conversations, ← → between the messages of the open one, Delete deletes.
- **Opening a message** clears its unread dot at once and marks it read in Mail. Archive, delete, junk and move take the
  conversation out of the list and open the next one; if Mail refuses, the list is reloaded and a one-line notice says why.
- **One header:** Back (while a message is open), the search field ("Search <folder> by name, email or subject") and the
  message actions; there is no second bar under it.
- **Search field:** in the header; accepts the `mail42 envelope search` language, e.g. `from:alice is:unread
  date:2w..`; plain words search subject, sender name and address, recipients and Apple's preview line (headers only,
  `--headers`: complete and instant, never the full message text), always within the view you are in. A query that
  isn't valid syntax is searched as literal words.
- **Reader:** the conversation is one page that scrolls, every message an accordion; reaching the bottom of the last
  open message opens the next one in order. The user's own messages and address show their Work42 name and photo
  instead of "You". Each message has an avatar (the same colours as Meet42 for the same person), sender, `mailbox · account`, date, subject,
  To/Cc and a **Details** toggle; attachment cards (Quick Look, Save to Downloads); the message in Work42's theme
  (ordinary mail takes the app's font, colours and accent; designed mail, such as newsletters, stays as designed on a
  light card), earlier quoted text folded behind "Show quoted text". Links open through Work42's Open Link.
- **mail42:// links:** clicking `mail42://message/<id>?mid=<Message-ID>` anywhere in Work42 reveals this tile and
  opens that message, even if Mail has moved it since. Outside the current list it shows `In <mailbox> · <account>`;
  if it is gone it says "This message is no longer in Mail".
- **Highlight-to-comment:** selecting text in the reader offers a comment. It arrives in the chat composer labelled
  `Mail42 · <subject> · <sender> (<link>)`: open the link or run `mail42 message read <id>` for the full message.

## Setup states

| The tile says | Meaning | Fix |
|---|---|---|
| mail42 isn't installed | no `mail42` on PATH | ask the agent to set up mail42 (the `mail42-setup` skill) |
| Let mail42 read your Mail (3 steps) | Full Disk Access isn't granted to mail42.app | **Open Settings**, turn on mail42; the tile continues by itself |
| No Mail accounts found | Apple Mail has no accounts | add an account in Mail; the tile shows it by itself |

The first action on a message (mark, move, …) makes macOS ask whether mail42 may control Mail: choose **Allow**.
Until then the list and reader keep working; actions show a notice saying what to turn on.

## Notes for agents

- The tile refreshes itself: every few seconds it re-reads Apple Mail's mailbox counters and reloads the list when
  they change (new mail, something read or flagged elsewhere).
- The reader files live under `~/.work42/mail42/reader/artifacts/mail42-reader/` (registered with the artifact
  server under mail42's own id, so the widget works in a session tab and on the session-less workspace home); they
  are disposable and only the latest few are kept.
- Message ids can change when Mail moves a message; use the link (`mail42 message resolve <link>`) rather than an id
  you saw earlier.
