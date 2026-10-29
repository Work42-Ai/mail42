---
name: mail42-setup
description: |
  Install and set up the mail42 command-line tool: download the signed release, install it as ~/.work42/mail42.app with the command linked into ~/.work42/bin, verify it,
  guide the user through Full Disk Access (and, on first use, Automation). Use it whenever `command -v mail42` prints nothing, a
  mail42 command fails because the tool is missing, too old or not allowed to read Mail (`fda_denied`), or the user asks to set up or update mail42.
---

# mail42-setup — install and set up mail42

mail42 is a separate, signed and notarized command-line tool (github.com/Work42-Ai/mail42), not part of the
Work42 app. This plugin's Mail42 tile and skills call it. It reads Apple Mail's own files live (it keeps no copy of
the user's mail) and, when asked, has Apple Mail itself mark, move or draft messages; it never sends mail. **Always ask the user first.** Before installing or updating anything, tell them what you are about
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

   The app is what macOS lists as "mail42" in System Settings → Privacy & Security. Updating keeps the Full Disk
   Access and Automation grants (mail42 has nothing else to keep: no database, no copy of mail).

## 2. Full Disk Access (to read mail)

Apple Mail keeps its messages in a protected folder, so macOS must be told mail42 may read it. There is no prompt
macOS can show for this; the user switches it on by hand. The **Mail42** tile walks them through the same steps and
notices by itself when it is done.

1. `mail42 permissions` exits 0 when granted. If it does, go to step 3.
2. Otherwise run `mail42 permissions open` (opens System Settings → Privacy & Security → Full Disk Access) and tell the
   user to add **mail42** (the `+` button, then `~/.work42/mail42.app`) and switch it on.
3. Open the **Mail42** tile for the user with `widget_open` (kind `widget:mail`): until access is granted it shows the
   three steps, and it carries on to the inbox by itself. Re-run `mail42 permissions` until it exits 0.

## 3. Automation (to act on mail), the first time

The first time anyone marks, moves, archives, deletes or drafts a message, macOS asks whether **mail42** may control
**Mail**. The user answers **Allow** (the dialog can sit behind other windows: tell them to look for it).
`mail42 permissions automation` triggers and waits for that question (up to two minutes) and prints `granted` when it
is answered; `--check` only reports `granted`, `denied` or `not_determined`. If it says `denied`, the user can turn it on
under System Settings → Privacy & Security → Automation → mail42 → Mail. Reading mail never needs this.

## Done

Tell the user what is installed (`mail42 --version`), whether Full Disk Access (and, if they use it, Automation) is
granted, and that mail42 never sends mail: replies open as drafts in Mail. Point them at the `mail42-cli` skill for
how to read and act on their mail. If `mailbox list` is empty, Apple Mail has no accounts yet: ask them to add one.
