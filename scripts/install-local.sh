#!/usr/bin/env bash
# install-local.sh — build mail42 from this checkout, sign it with your Developer ID, and install it as
# ~/.work42/mail42.app (the app ~/.work42/bin/mail42 points at). For shipping a fix to your own Mac between
# releases; `scripts/release.sh` is the public, notarized path.
#
#   scripts/install-local.sh
#
# Signing: the same Developer ID as the installed app keeps macOS's Full Disk Access grant (it is keyed to the
# signing identity). The identity comes from
# WORK42_DEVELOPER_ID_APPLICATION (env or .env.release.local), else the single "Developer ID Application"
# identity in the login Keychain. Ad-hoc signing is refused: it would make macOS forget every grant.
#
# The swap is atomic and safe while mail42 is running (a running sync keeps the copy it loaded): the new app is
# copied beside the old one, then renamed into place. The previous build stays at ~/.work42/mail42.app.prev.
set -euo pipefail

cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }

if [[ -f .env.release.local ]]; then
  # shellcheck disable=SC1091
  set -a; source .env.release.local; set +a
fi

identity="${WORK42_DEVELOPER_ID_APPLICATION:-}"
if [[ -z "$identity" ]]; then
  matches="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sort -u)"
  [[ -n "$matches" ]] || die "no Developer ID Application identity in the login Keychain"
  [[ "$(wc -l <<<"$matches")" -eq 1 ]] || die "several Developer ID identities; set WORK42_DEVELOPER_ID_APPLICATION"
  identity="$matches"
fi
echo "==> signing with: $identity"

app="$(DEVELOPER_ID="$identity" scripts/build-mail42.sh | tail -n 1)"
codesign --verify --strict "$app"

dest="$HOME/.work42/mail42.app"
mkdir -p "$HOME/.work42/bin"
rm -rf "$dest.new"
ditto "$app" "$dest.new"
if [[ -d "$dest" ]]; then rm -rf "$dest.prev"; mv "$dest" "$dest.prev"; fi
mv "$dest.new" "$dest"
ln -sfn "$dest/Contents/MacOS/mail42" "$HOME/.work42/bin/mail42"

echo "==> installed $("$HOME/.work42/bin/mail42" --version) at $dest"
echo "    (previous build: $dest.prev)"
