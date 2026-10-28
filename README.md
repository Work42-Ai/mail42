# mail42

Read-only local email for you and your agents. mail42 reads the mail that Apple Mail already keeps on your Mac,
indexes it into its own database, and exposes it through a small CLI (`--json` everywhere) and a Work42 widget.
It never changes Apple Mail and never sends mail.

It mirrors [meet42](https://github.com/Work42-Ai/meet42): a signed `mail42.app` (bundle id `com.work42.mail42`)
owns the privileged access and the database, and the Work42 plugin in `work42-plugin/` only talks to the CLI.

> Status: in progress (Linear WOR-438). Working today: the whole CLI (`permissions`, `sync`, `config`, `mailbox`,
> `envelope`, `message`, `attachment`, `open`). Still to come: the Work42 plugin and its skills.

## Install

Ask an agent in Work42 to "set up mail42" (the `mail42-setup` skill), or install by hand from the latest
release:

```bash
curl -LO https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip
curl -LO https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip.sha256
shasum -a 256 -c mail42.zip.sha256
ditto -x -k mail42.zip ~/.work42/   # creates ~/.work42/mail42.app
mkdir -p ~/.work42/bin && ln -sfn ~/.work42/mail42.app/Contents/MacOS/mail42 ~/.work42/bin/mail42
```

Work42 puts `~/.work42/bin` on your PATH.

## Full Disk Access

Apple Mail's store lives in `~/Library/Mail`, which macOS protects. mail42 needs **Full Disk Access**:

1. `mail42 permissions open` (or System Settings → Privacy & Security → Full Disk Access).
2. Turn on **mail42**. If it isn't listed, press **+** and choose `~/.work42/mail42.app`.
3. `mail42 permissions` should now say `granted`.

The grant belongs to the signed `mail42.app`, so it survives updates signed with the same Developer ID. Local
ad-hoc builds (`swift build`) have a different signature each time, so macOS may ask you to grant it again.

## Files

| Path | What |
|---|---|
| `~/.work42/mail42/mail.db` | mail42's own index (envelopes, recipients, attachments, full-text search) |
| `~/.work42/mail42/trace.jsonl` | one JSON line per sync outcome |
| `~/Library/Mail/V*/` | Apple Mail's own store. **Only ever read**, never written |

## Sync and settings

```bash
mail42 sync                      # copy new / changed / removed mail from Apple Mail into mail.db
mail42 sync --full               # re-index everything in the window
mail42 config get                # window_days=90
mail42 config set window_days 30 # index the last 30 days (0 = all mail); applies at the next sync
```

`sync` indexes messages received within `window_days` (default 90), one per Message-ID (Gmail's label copies
collapse to one), with their bodies in a full-text index. It exits 1 when mail42 can't read Apple Mail (no Full
Disk Access, or an Apple Mail index this version doesn't understand) and leaves `mail.db` untouched.

## Reading mail

Every verb takes `--json` (errors are `{"error":{"code","message"}}`; exit 1 = can't read Apple Mail, 2 = usage,
not found or bad query). Read verbs only use `mail.db`, except `message read` and `attachment save`, which open
the message's file under `~/Library/Mail` and so need Full Disk Access.

An **envelope** is the cheap summary of a message (sender, subject, date, flags, snippet); a **message** is the
full thing. Scan envelopes first, then read only the few that matter.

```bash
mail42 mailbox list                           # accounts and mailboxes, with counts
mail42 envelope list                          # newest first; every inbox (-m all)
mail42 envelope list -m flagged --unread      # -m: all | flagged | <mailbox id> | <name or role>
mail42 envelope list --limit 20 --before 4211 # next page: pass the last id you saw
mail42 envelope search 'from:alice is:unread date:2w..'
mail42 message read 4211                      # plain text; --html = sanitised HTML; --headers
mail42 message read 4211 --html --out /tmp/m.html   # write to a file, print the path
mail42 message thread 4211                    # the whole conversation, oldest first
mail42 attachment list 4211
mail42 attachment save 4211 2 --to ~/Downloads      # never overwrites: report (1).pdf …
mail42 open 4211                              # show it in Mail.app (to reply, archive, …)
```

### Search terms

| Term | Matches |
|---|---|
| `word`, `"a phrase"` | subject, sender, recipients and body together (full-text, ranked) |
| `from:alice` `to:bo` | sender / To+Cc, by name or address (substring) |
| `subject:"q4 roadmap"` `body:invoice` | that part only |
| `in:inbox` `in:sent` `in:Acme` `in:3` | mailbox by role, name (or its last part) or id |
| `is:unread` `is:read` `is:flagged` | state |
| `has:attachment` | has at least one attachment |
| `date:2w..` `date:3d` `date:1m..` | newer than 2 weeks / 3 days / 1 month ago |
| `date:2026-10-01..2026-10-15` `date:2026-10-01..` `date:..2026-10-15` `date:2026-10-26` | a date range; the last day is included whole |
| `and` `or` `not` `( )` | combine terms; terms next to each other mean AND |

`or` binds looser than `and`, so `a or b c` means `a or (b and c)`. Quote a word that is also an operator
(`"or"`). Search ignores accents and capitalisation.

## Develop

```bash
swift build
swift test
scripts/install-local.sh        # sign with your Developer ID and install to ~/.work42/mail42.app
```

Two environment variables redirect mail42 for testing (`$HOME` is **not** honoured): `MAIL42_ROOT` replaces
`~/.work42/mail42` (mail.db, trace.jsonl) and `MAIL42_MAIL_LIBRARY` replaces `~/Library/Mail`. The end-to-end
tests set both, so they can never touch your real mail or index:

```bash
MAIL42_ROOT=/tmp/m42 MAIL42_MAIL_LIBRARY=/tmp/fake-mail mail42 sync
```

`scripts/build-mail42.sh` builds the signed app bundle (ad-hoc when `DEVELOPER_ID` is unset).

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
