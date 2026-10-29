#!/usr/bin/env bash
# build-mail42.sh — release build of mail42 as a small app bundle (mail42.app, the CLI is its executable), signed
# with a persistent Developer ID, the Hardened Runtime and mail42's own identifier and entitlements.
#
# Why this matters: mail42 is a plain command-line binary that reads Apple Mail's local store, which needs
# macOS Full Disk Access. There is no prompt API for it: the user turns it on in System Settings, and macOS keys
# the grant to the code-signing identity of the app. So a shippable mail42:
#   1. embeds Resources/mail42-Info.plist at link time (-sectcreate),
#   2. is signed with a PERSISTENT Developer ID (not the ad-hoc signature `swift build` applies, whose hash
#      changes on every build and makes macOS forget the user's grant),
#   3. uses the identifier com.work42.mail42, so the grant belongs to "mail42", and
#   4. carries Resources/mail42.entitlements (empty: Full Disk Access needs no entitlement) under the Hardened
#      Runtime, which notarization requires.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/build-mail42.sh [--configuration release]
# Prints the path of the built mail42.app as its last line. Without DEVELOPER_ID it signs ad-hoc.
set -euo pipefail

CONFIG="release"
if [[ "${1:-}" == "--configuration" && -n "${2:-}" ]]; then CONFIG="$2"; fi

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$PKG_DIR/Resources/mail42-Info.plist"
ENTITLEMENTS="$PKG_DIR/Resources/mail42.entitlements"
IDENTIFIER="com.work42.mail42"

cd "$PKG_DIR"

echo "==> swift build (-c $CONFIG)" >&2
# -file-prefix-map / -debug-prefix-map rewrite the build directory in every path the compiler embeds (assertion and
# diagnostic strings, debug info), so a shipped binary does not carry the builder's home directory or checkout name.
swift build -c "$CONFIG" --product mail42 \
  -Xswiftc -file-prefix-map -Xswiftc "$PKG_DIR=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$PKG_DIR=." \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" >&2

BIN="$(swift build -c "$CONFIG" --product mail42 --show-bin-path)/mail42"
echo "==> built $BIN" >&2

# Wrap the binary in mail42.app: macOS lists an app bundle (not a bare binary) under Full Disk Access.
# The app has no window and no Dock icon (LSUIElement); the CLI is its executable.
APP="$PKG_DIR/.build/bundle/mail42.app"
VERSION="$(sed -n 's/^let mail42Version = "\(.*\)"$/\1/p' "$PKG_DIR/Sources/mail42/main.swift")"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/mail42"
# Drop the symbol table and debug-map entries (they hold the absolute path of every object file).
strip -S -x "$APP/Contents/MacOS/mail42"
# The build must not leak where it was made: fail loudly if the builder's home directory is still in the binary.
if LC_ALL=C grep -a -F -q "$HOME" "$APP/Contents/MacOS/mail42"; then
  echo "ERROR: the built binary still contains the path $HOME; refusing to bundle it." >&2
  exit 1
fi
cp "$PLIST" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
  -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
echo "==> bundled $APP (version $VERSION)" >&2

if [[ -z "${DEVELOPER_ID:-}" ]]; then
  echo "WARNING: DEVELOPER_ID not set — signing ad-hoc." >&2
  echo "         macOS permission grants will NOT persist across rebuilds." >&2
  codesign --force --sign - --identifier "$IDENTIFIER" "$APP" >&2
  echo "$APP"
  exit 0
fi

echo "==> codesign ($IDENTIFIER, Hardened Runtime, entitlements)" >&2
codesign --force --options runtime --timestamp \
  --identifier "$IDENTIFIER" --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" "$APP" >&2
codesign -dv "$APP" 2>&1 | sed 's/^/    /' >&2
echo "$APP"
