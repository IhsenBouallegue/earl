#!/bin/bash
# Installs or updates Earl in ~/Applications with one command:
#
#   curl -fsSL https://github.com/IhsenBouallegue/earl/releases/latest/download/install.sh | bash
#
# curl downloads are not marked "from the internet", so macOS opens the app
# without the Gatekeeper warning (Earl is not notarized). The release is found
# through the same feed Earl updates itself from.
set -euo pipefail

FEED="${EARL_FEED_URL:-https://github.com/IhsenBouallegue/earl/releases/latest/download/appcast.xml}"
RELEASES="https://github.com/IhsenBouallegue/earl/releases/download/"
# Leaf hash of the Earl Local Signing certificate (same as tools/release.sh).
EXPECTED_LEAF="829887ff8454c821e1e4400e7fefc6fb7e57330d"
DEST_DIR="${EARL_INSTALL_DIR:-$HOME/Applications}"
APP="$DEST_DIR/Earl.app"

die() { echo "Earl: $*" >&2; exit 1; }

[ "$(uname -m)" = "arm64" ] || die "needs a Mac with Apple silicon."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || die "needs macOS 26 or newer."
if pgrep -f "$APP/Contents/MacOS/Earl" >/dev/null 2>&1; then
    die "Earl is running. Quit it from the menu bar, then run this again."
fi

echo "Looking for the latest Earl…"
URL="$(curl -fsSL "$FEED" | sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' | head -1)"
case "$URL" in "$RELEASES"*) ;; *) die "could not find the download (got '$URL')." ;; esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "Downloading $(basename "$URL")…"
curl -fL --progress-bar -o "$WORK/Earl.zip" "$URL"
ditto -x -k "$WORK/Earl.zip" "$WORK/unzipped"
NEW="$WORK/unzipped/Earl.app"
[ -d "$NEW" ] || die "the download does not contain Earl.app."
codesign --verify --deep --strict "$NEW" 2>/dev/null || die "the download is damaged."
codesign -dr - "$NEW" 2>&1 | grep -q "certificate leaf = H\"$EXPECTED_LEAF\"" \
    || die "the download is not signed by Earl's certificate."

mkdir -p "$DEST_DIR"
[ ! -e "$APP" ] || mv "$APP" "$WORK/previous-Earl.app"
mv "$NEW" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Installed Earl $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) in $DEST_DIR."
[ -n "${EARL_NO_OPEN:-}" ] || open "$APP"
