#!/usr/bin/env bash
# release.sh — build, sign, notarize and (optionally) publish a mail42 release.
#
#   scripts/release.sh <version>             build + sign + notarize a candidate in dist/<version>/
#   scripts/release.sh <version> --check     report readiness only; changes nothing
#   scripts/release.sh <version> --publish   also create GitHub release v<version> with the assets
#
# The release is two assets, served from fixed URLs:
#   https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip
#   https://github.com/Work42-Ai/mail42/releases/latest/download/mail42.zip.sha256
# mail42.zip holds the signed, notarized mail42.app (a small window-less app bundle; the CLI is its executable).
#
# Credentials come from the environment or an untracked .env.release.local (see .env.release.example):
#   WORK42_DEVELOPER_ID_APPLICATION  a "Developer ID Application: …" identity in the login Keychain
#   WORK42_NOTARY_KEYCHAIN_PROFILE   a notarytool profile (xcrun notarytool store-credentials …)
#     or APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_SLUG="Work42-Ai/mail42"

die() { echo "error: $*" >&2; exit 1; }

version="" ; check_only=false ; publish=false
for arg in "$@"; do
  case "$arg" in
    --check) check_only=true ;;
    --publish) publish=true ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) die "unknown option $arg" ;;
    *) [[ -z "$version" ]] || die "only one version expected"; version="$arg" ;;
  esac
done
[[ -n "$version" ]] || die "usage: scripts/release.sh <version> [--check] [--publish]"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "version must look like 1.2.3"

if [[ -f .env.release.local ]]; then
  # shellcheck disable=SC1091
  set -a; source .env.release.local; set +a
fi

# ---- readiness checks ---------------------------------------------------------------------------

ready=0 ; blocked=0
check() { # check "<label>" <command…>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ready=$((ready + 1)); printf 'READY    %s\n' "$label"
  else blocked=$((blocked + 1)); printf 'BLOCKED  %s\n' "$label"; fi
}

has_identity() {
  [[ "${WORK42_DEVELOPER_ID_APPLICATION:-}" == Developer\ ID\ Application:* ]] \
    && security find-identity -v -p codesigning | grep -Fq "\"$WORK42_DEVELOPER_ID_APPLICATION\""
}
notary_args() {
  if [[ -n "${WORK42_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    printf '%s\n' --keychain-profile "$WORK42_NOTARY_KEYCHAIN_PROFILE"
  else
    printf '%s\n' --apple-id "${APPLE_ID:-}" --team-id "${APPLE_TEAM_ID:-}" --password "${APPLE_APP_PASSWORD:-}"
  fi
}
has_notary_credentials() {
  if [[ -n "${WORK42_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool history --keychain-profile "$WORK42_NOTARY_KEYCHAIN_PROFILE"
  else
    [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]] \
      && xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
  fi
}
canonical_origin() {
  local url; url="$(git remote get-url origin)"
  [[ "$url" == *"$REPO_SLUG" || "$url" == *"$REPO_SLUG.git" ]]
}
clean_main() {
  [[ "$(git branch --show-current)" == main ]] && [[ -z "$(git status --porcelain)" ]]
}
synced_with_origin() {
  git fetch --quiet origin main && [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]]
}
version_in_source() { grep -Fq "let mail42Version = \"$version\"" Sources/mail42/main.swift; }
release_unused() { ! gh release view "v$version" --repo "$REPO_SLUG"; }

readiness_report() {
  printf 'mail42 %s release readiness\n' "$version"
  check "Developer ID Application identity in the login Keychain" has_identity
  check "Apple notarization credentials" has_notary_credentials
  check "GitHub authentication (gh)" gh auth status
  check "origin is $REPO_SLUG" canonical_origin
  check "clean checkout of main" clean_main
  check "main is up to date with origin" synced_with_origin
  check "Sources/mail42/main.swift says version $version" version_in_source
  check "release v$version does not exist yet" release_unused
  printf '\nSummary: %s ready, %s blocked\n' "$ready" "$blocked"
  [[ "$blocked" -eq 0 ]]
}

if [[ "$check_only" == true ]]; then readiness_report; exit $?; fi
readiness_report || die "not ready — fix the BLOCKED items above, or run --check to see them again"

# ---- build, sign, notarize ----------------------------------------------------------------------

out="dist/$version"
rm -rf "$out"; mkdir -p "$out"

echo "==> build + sign"
app="$(DEVELOPER_ID="$WORK42_DEVELOPER_ID_APPLICATION" scripts/build-mail42.sh | tail -n 1)"
ditto "$app" "$out/mail42.app"

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$out/mail42.app"
signature="$(codesign -dvv "$out/mail42.app" 2>&1)"
grep -Fq "Identifier=com.work42.mail42" <<<"$signature" || die "signed with the wrong identifier"
grep -Fq "Authority=Developer ID Application" <<<"$signature" || die "not signed with a Developer ID"
grep -Fq "flags=0x10000(runtime)" <<<"$signature" || die "Hardened Runtime is not enabled"

echo "==> package"
# --norsrc --noextattr: no `._*` AppleDouble entries in the zip. Without them, plain `unzip` extracts the app with extra
# files in it, which breaks the code seal and makes Gatekeeper call a notarised app "damaged".
(cd "$out" && ditto -c -k --keepParent --norsrc --noextattr mail42.app mail42.zip)

echo "==> notarize (waits for Apple)"
notary=()
while IFS= read -r line; do notary+=("$line"); done < <(notary_args)
submission="$(xcrun notarytool submit "$out/mail42.zip" "${notary[@]}" --wait 2>&1)" || { echo "$submission" >&2; die "notarization failed"; }
echo "$submission"
grep -Eq "status: Accepted" <<<"$submission" || die "notarization was not accepted"

echo "==> staple the ticket and repackage"
xcrun stapler staple "$out/mail42.app"
(cd "$out" && rm -f mail42.zip && ditto -c -k --keepParent --norsrc --noextattr mail42.app mail42.zip)

echo "==> checksum"
(cd "$out" && shasum -a 256 mail42.zip > mail42.zip.sha256 && shasum -a 256 -c mail42.zip.sha256)

echo "==> check the packaged app"
check_dir="$(mktemp -d)"; trap 'rm -rf "$check_dir"' EXIT
ditto -x -k "$out/mail42.zip" "$check_dir"
codesign --verify --deep --strict "$check_dir/mail42.app"
spctl --assess --type execute --verbose=2 "$check_dir/mail42.app"
"$check_dir/mail42.app/Contents/MacOS/mail42" --version

# People also unpack with plain `unzip` (curl | unzip): the seal must hold there too, and nothing may be added to the bundle.
echo "==> check a plain unzip too"
plain_dir="$(mktemp -d)"; trap 'rm -rf "$check_dir" "$plain_dir"' EXIT
unzip -q "$out/mail42.zip" -d "$plain_dir"
codesign --verify --deep --strict "$plain_dir/mail42.app" || die "the zip does not survive a plain unzip (code seal broken)"
spctl --assess --type execute --verbose=2 "$plain_dir/mail42.app" || die "Gatekeeper rejects the app after a plain unzip"

echo
echo "Candidate ready in $out/ (mail42.zip, mail42.zip.sha256)."
if [[ "$publish" != true ]]; then
  echo "Re-run with --publish to create GitHub release v$version."
  exit 0
fi

# ---- publish ------------------------------------------------------------------------------------

echo "==> publish v$version to $REPO_SLUG"
gh release create "v$version" "$out/mail42.zip" "$out/mail42.zip.sha256" \
  --repo "$REPO_SLUG" --target "$(git rev-parse HEAD)" \
  --title "mail42 $version" \
  --notes "Signed and notarized mail42 $version. Install with the steps in the README, or let the mail42 plugin's skill do it."
echo "Published: https://github.com/$REPO_SLUG/releases/tag/v$version"
