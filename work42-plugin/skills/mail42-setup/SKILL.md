---
name: mail42-setup
description: |
  Set up the mail42 command-line tool that ships with Work42: check it is there and guide the user through Full Disk Access
  (and, on first use, Automation). Use it whenever a mail42 command fails because the tool is missing, too old or not allowed
  to read Mail (`fda_denied`), or the user asks to set up mail42.
---

# mail42-setup — set up mail42

mail42 ships inside Work42: the app installs `~/.work42/mail42.app` (with the command linked at `~/.work42/bin/mail42`) at
every launch and updates it with the app. This plugin's Mail42 tile and skills call it. It reads Apple Mail's own files live
(it keeps no copy of the user's mail) and, when asked, has Apple Mail itself mark, move or draft messages; it never sends mail.
**Never download or install it yourself.** Follow these steps in order and stop at the first one that fails; say what failed
instead of working around it.

## 1. Check the tool

Run `command -v mail42 && mail42 --version`. `~/.work42/bin` is on `PATH` in Work42 sessions.

If it prints nothing, or a command says the tool is too old, Work42 has not installed or updated it yet. Tell the user to
quit and reopen Work42 (it installs mail42 at launch), or to update or reinstall Work42 if that does not help. Do not fetch
mail42 from anywhere else. The app is what macOS lists as "mail42" in System Settings → Privacy & Security, and an
update with Work42 keeps its Full Disk Access and Automation grants.

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
