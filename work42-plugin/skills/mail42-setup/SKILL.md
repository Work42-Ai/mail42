---
name: mail42-setup
description: |
  Install and set up the mail42 command-line tool: download the signed release, install it as ~/.work42/mail42.app with the command linked into ~/.work42/bin, verify it,
  guide the user through Full Disk Access and run the first sync. Use it whenever `command -v mail42` prints nothing, a
  mail42 command fails because the tool is missing, too old or not allowed to read Mail (`fda_denied`), or the user asks to set up or update mail42.
---

# mail42-setup — install and set up mail42

mail42 is a separate, signed and notarized command-line tool (github.com/Work42-Ai/mail42), not part of the
Work42 app. This plugin's Mail widget and skills call it. It only **reads** Apple Mail's local store; it never sends,
moves or changes mail. **Always ask the user first.** Before installing or updating anything, tell them what you are about
to do (download the signed mail42 app from github.com/Work42-Ai/mail42 into `~/.work42` and link it into `~/.work42/bin`) and wait
for a yes. If they decline, stop and carry on without mail42; do not install it later on your own. Then follow these steps
in order and stop at the first one that fails; say what failed instead of working around it.

## 1. Install or update the tool

1. Check what is there: `command -v mail42 && mail42 --version`. `~/.work42/bin` is on `PATH` in Work42 sessions.
   If it prints a version, only continue with this step to update; otherwise install.
2. Download, verify and install the latest release:

   ```bash
   mkdir -p ~/.work42/bin && cd "$(mktemp -d)"
   curl -fsSLO https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip
   curl -fsSLO https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip.sha256
   shasum -a 256 -c mail42.zip.sha256
   ```

   `shasum` must print `mail42.zip: OK`. If it does not, stop and tell the user; do not install the file.
3. Unpack it (a small app bundle, `mail42.app`) and check it is signed by Work42's Developer ID before trusting it:

   ```bash
   ditto -x -k mail42.zip .
   codesign --verify --deep --strict mail42.app
   codesign -dv --verbose=2 mail42.app 2>&1 | grep -E "Identifier=com.work42.mail42|TeamIdentifier=74RFQFPVQ9"
   ```

   Both `Identifier` and `TeamIdentifier` lines must print and `--verify` must print nothing. If not, stop and
   tell the user.
4. Put the app in place and link the command:

   ```bash
   rm -rf ~/.work42/mail42.app && mv mail42.app ~/.work42/mail42.app
   ln -sf ~/.work42/mail42.app/Contents/MacOS/mail42 ~/.work42/bin/mail42
   mail42 --version
   ```

   The app is what macOS lists as "mail42" in System Settings → Privacy & Security. Updating keeps the index
   (`~/.work42/mail42/mail.db`) and the Full Disk Access grant.

## 2. Full Disk Access

Apple Mail keeps its messages in a protected folder, so macOS must be told mail42 may read it. There is no prompt
macOS can show for this; the user switches it on by hand.

1. `mail42 permissions` exits 0 when granted. If it does, go to step 3.
2. Otherwise run `mail42 permissions open` (opens System Settings → Privacy & Security → Full Disk Access) and tell the
   user to add **mail42** (the `+` button, then `~/.work42/mail42.app`) and switch it on. They may be asked to quit
   and reopen mail42; the next command does that by itself.
3. Open the **Mail** widget for the user with `widget_open` (kind `widget:mail`) so its "Allow mail42 to read Mail"
   state can show **Open Settings** and **Check again**. Re-run `mail42 permissions` until it exits 0.

## 3. Load the mail

Run `mail42 sync` once. It copies the last 90 days (`mail42 config set window_days N` changes that; 0 = all) of
every Apple Mail account into the local index. A large mailbox can take a few minutes the first time; later syncs
are quick and the Mail widget keeps them going while Work42 runs. If it fails with `no_mail_data`, Apple Mail has no
accounts yet: ask the user to add one in Mail.

## Done

Tell the user what is installed (`mail42 --version`), whether Full Disk Access is granted, and how many messages
the first sync indexed. Point them at the `mail42-cli` skill for how to read their mail.
