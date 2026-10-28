# mail42

Read-only local email for you and your agents. mail42 reads the mail that Apple Mail already keeps on your Mac,
indexes it into its own database, and exposes it through a small CLI (`--json` everywhere) and a Work42 widget.
It never changes Apple Mail and never sends mail.

It mirrors [meet42](https://github.com/Work42-Ai/meet42): a signed `mail42.app` (bundle id `com.work42.mail42`)
owns the privileged access and the database, and the Work42 plugin in `work42-plugin/` only talks to the CLI.

> Status: in progress (Linear WOR-438). Working today: `permissions`, `sync` and `config`. Still to come: the
> read verbs (`mailbox`, `envelope`, `message`, `attachment`, `open`), the Work42 plugin and its skills.

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
