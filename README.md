# mail42

Apple Mail for you and your agents. mail42 works with the mail that Apple Mail already keeps on your Mac: it reads
it live (no copy, no database, no sync) and asks Apple Mail itself to mark, flag, move, archive, delete or draft.
It has a small CLI (`--json` everywhere) for agents and a Work42 widget, **Mail42**, for you. It never sends mail:
replies and new messages open as drafts in Mail's own compose window, and you press Send there.

It mirrors [meet42](https://github.com/Work42-Ai/meet42): a signed `mail42.app` (bundle id `com.work42.mail42`)
owns the permissions, and the Work42 plugin in `work42-plugin/` only talks to the CLI.

> Status: 0.1.0, not yet released. The CLI (`permissions`, `mailbox`, `envelope`, `message`, `attachment`, `open`,
> `mark`, `move`, `archive`, `delete`, `junk`, `draft`), the Mail42 widget and the `mail42-setup` / `mail42-cli` skills
> are built; the reading and acting verbs are tested against synthetic mailboxes and checked on a real one.

## Install

Ask an agent in Work42 to "set up mail42" (the `mail42-setup` skill), or install by hand from the latest release:

```bash
curl -LO https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip
curl -LO https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip.sha256
shasum -a 256 -c mail42.zip.sha256
ditto -x -k mail42.zip ~/.work42/   # creates ~/.work42/mail42.app
mkdir -p ~/.work42/bin && ln -sfn ~/.work42/mail42.app/Contents/MacOS/mail42 ~/.work42/bin/mail42
```

Work42 puts `~/.work42/bin` on your PATH.

### The Work42 plugin

The plugin adds the **Mail42** widget (`widget:mail`) and two skills for agents: `mail42-setup` (install and
permissions) and `mail42-cli` (how to read and act on mail). Install it with:

```bash
work42 plugin install https://github.com/Work42-Ai/mail42 --path work42-plugin
```

The widget only runs the `mail42` CLI; it never reads or scripts Apple Mail itself.

**Mail42 in Work42:**

- A list of **conversations** under date headers, with search (`from:`, `is:unread`, `date:2w..`, plain words).
- A reader that shows the open conversation (earlier messages folded to a line each), the message in Work42's theme,
  attachment cards with Quick Look and Save, and the full recipients under **Details**.
- The inbox switcher and **New** in the tab-bar row; Reply, Forward, Archive, Delete and a More menu (Reply All,
  read/unread, Flag colours, Move to, Junk, Copy Link, Open in Mail) in the widget header and on a row's right-click,
  with Mail's keyboard shortcuts.
- **mail42:// links**: `mail42://message/<id>?mid=<Message-ID>` opens that message in the tile from anywhere in
  Work42, even after Mail has moved it.
- Highlight text in the reader to turn it into a comment in the chat composer.

## Permissions

mail42 needs two macOS permissions, each asked for once. Both belong to the signed `mail42.app`, so they survive
updates signed with the same Developer ID. (Local ad-hoc builds from `swift build` have a different signature each
time, so macOS may ask again.)

**Full Disk Access** (to read Apple Mail's files in `~/Library/Mail`). macOS can't show a prompt for it; you switch it
on:

1. `mail42 permissions open` (or System Settings → Privacy & Security → Full Disk Access).
2. Turn on **mail42**. If it isn't listed, press **+** and choose `~/.work42/mail42.app`.
3. `mail42 permissions` should now say `granted`. The Mail42 tile shows the same three steps and carries on by itself.

**Automation** (to act on mail). The first time you or an agent marks, moves, archives, deletes or drafts a message,
macOS asks whether mail42 may control Mail: choose **Allow**. `mail42 permissions automation` triggers that question and
waits for the answer; `--check` only reports `granted`, `denied` or `not_determined`. Reading mail never needs it.

## What mail42 touches

| Path | What |
|---|---|
| `~/Library/Mail/V*/` | Apple Mail's own store. **Only ever read**, never written (mail42 reads a private snapshot of the index, so a running Mail is never disturbed) |
| `~/Library/Accounts/Accounts4.sqlite` | Read, to name accounts as Mail does |
| `~/.work42/mail42/reader/` | The Mail42 tile's disposable files (the message being shown); nothing else is kept |

Everything that changes mail goes through Mail.app as Apple Events: Mail does it, syncs it to the server and updates its
own index. mail42 holds no passwords and no copy of your mail.

## Reading mail

Every verb takes `--json` (errors are `{"error":{"code","message"}}`; exit 1 = failed or not granted, 2 = usage, not
found or bad query). An **envelope** is the cheap summary of a message (sender, subject, date, flags, snippet, `link`); a
**message** is the full thing. Scan envelopes first, then read only the few that matter.

```bash
mail42 mailbox list                           # accounts (named as in Mail) and mailboxes, with Apple's counts
mail42 envelope list                          # newest first; every inbox (-m all)
mail42 envelope list --conversations          # one row per conversation (conversation_count, participants)
mail42 envelope list -m flagged --unread      # -m: all | flagged | <mailbox id> | <name or role>
mail42 envelope list --limit 20 --before 4211 # next page: pass the last id you saw
mail42 envelope search 'from:alice is:unread date:2w..'
mail42 envelope search 'alice' --headers      # instant: subject, sender name/address, recipients, Apple's preview line only
mail42 message read 4211                      # plain text; --html = sanitised HTML; --headers
mail42 message read 4211 --html --out /tmp/m.html   # write to a file, print the path
mail42 message thread 4211                    # the whole conversation (every mailbox), oldest first
mail42 message resolve 'mail42://message/4211?mid=abc%40example.com'   # where is it now?
mail42 attachment list 4211
mail42 attachment save 4211 2 --to ~/Downloads      # never overwrites: report (1).pdf …
mail42 open 4211                              # show it in Mail.app
```

A message is named by its id or its link. Mail gives a message a new id when it moves it; a link also carries the
Message-ID, so `message resolve` still finds it.

### Search terms

| Term | Matches |
|---|---|
| `word`, `"a phrase"` | subject, sender, recipients and message text together |
| `from:alice` `to:bo` | sender / To+Cc, by name or address (substring) |
| `subject:"q4 roadmap"` `body:invoice` | that part only |
| `in:inbox` `in:sent` `in:Acme` `in:3` | mailbox by role, name (or its last part) or id |
| `is:unread` `is:read` `is:flagged` | state |
| `has:attachment` | has at least one attachment |
| `date:2w..` `date:3d` `date:1m..` | newer than 2 weeks / 3 days / 1 month ago |
| `date:2026-10-01..2026-10-15` `date:2026-10-01..` `date:..2026-10-15` `date:2026-10-26` | a date range; the last day is included whole |
| `and` `or` `not` `( )` | combine terms; terms next to each other mean AND |

`or` binds looser than `and`, so `a or b c` means `a or (b and c)`. Quote a word that is also an operator (`"or"`).
Searches on the headers answer instantly. Apple Mail's index holds no message text (and Spotlight doesn't index it), so
words and `body:` read the text of the newest matching messages (a few seconds on a big mailbox); if that wasn't all of
them, mail42 says so on stderr and `from:`, `in:` or `date:` narrow it. Text matching ignores capitals but not accents.

## Acting on mail

These change your real mail (through Apple Mail), so agents use them only when asked:

```bash
mail42 mark 4211 read|unread|flagged|unflagged [--color red|orange|yellow|green|blue|purple|gray]
mail42 move 4211 Receipts                     # a mailbox of the same account, by name or id
mail42 archive 4211                           # Gmail: removes it from the Inbox
mail42 delete 4211                            # to the Trash
mail42 junk 4211
mail42 draft reply 4211                       # opens Mail's compose window, filled in
mail42 draft reply-all 4211
mail42 draft forward 4211
mail42 draft new --to a@example.com --subject "Hello" --body "Hi"
```

Each prints `{"ok":true,"id":…,"link":…}` (after a move, `link` is the new one). **Nothing is ever sent**: drafts open in
Mail and you press Send. Errors you may see: `automation_denied` (allow mail42 under Privacy & Security › Automation),
`mail_timeout` (Mail didn't answer in 20 s; look before retrying), `no_archive_mailbox`, `not_found`.

## Develop

```bash
swift build
swift test
scripts/install-local.sh        # sign with your Developer ID and install to ~/.work42/mail42.app
```

Environment variables redirect mail42 for tests (`$HOME` is **not** honoured): `MAIL42_MAIL_LIBRARY` replaces
`~/Library/Mail` and `MAIL42_ACCOUNTS_DB` replaces the system Accounts database. `MAIL42_OPEN_DRY_RUN=1` makes `open`
print the Mail URL instead of opening Mail, and `MAIL42_ACTIONS_DRY_RUN=1` makes the acting verbs print the AppleScript
they would run instead of running it. The end-to-end tests set all of these, so they can never touch your real mail:

```bash
MAIL42_ACTIONS_DRY_RUN=1 mail42 archive 4211 --json   # shows the script; changes nothing
```

`scripts/build-mail42.sh` builds the signed app bundle (ad-hoc when `DEVELOPER_ID` is unset). The Mail42 widget is built
by Work42 itself when the plugin is installed: `work42 plugin install "$PWD" --path work42-plugin`.

## Release

```bash
cp .env.release.example .env.release.local   # then fill in the Developer ID and notary profile
scripts/release.sh 0.1.0 --check             # report readiness only
scripts/release.sh 0.1.0                     # build, sign, notarize a candidate in dist/0.1.0/
scripts/release.sh 0.1.0 --publish           # also create the GitHub release
```

## License

MIT, see [LICENSE](LICENSE). Third-party code and design references are credited in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
