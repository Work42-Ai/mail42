# mail42

Read-only local email for you and your agents. mail42 reads the mail that Apple Mail already keeps on your Mac,
indexes it into its own database, and exposes it through a small CLI (`--json` everywhere) and a Work42 widget.
It never changes Apple Mail and never sends mail.

It mirrors [meet42](https://github.com/Work42-Ai/meet42): a signed `mail42.app` (bundle id `com.work42.mail42`)
owns the privileged access and the database, and the Work42 plugin in `work42-plugin/` only talks to the CLI.

> Status: the repo scaffold is in place (`mail42 version` / `mail42 help`). The reader, sync, read verbs, plugin
> and skills land in the following changes tracked in Linear WOR-438.

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

## Develop

```bash
swift build
swift test
scripts/install-local.sh        # sign with your Developer ID and install to ~/.work42/mail42.app
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
