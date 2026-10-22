#!/usr/bin/env bash
# Builds a release zip for colleagues: tests, signed build, zip, checksum.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Leaf hash of the Earl Local Signing certificate. Every colleague's privacy
# permissions are tied to it, so a release signed by anything else is refused.
EXPECTED_LEAF="829887ff8454c821e1e4400e7fefc6fb7e57330d"

if [ "$(git -C "$ROOT" branch --show-current)" != "main" ]; then
    echo "error: releases are cut from main (you are on $(git -C "$ROOT" branch --show-current))." >&2
    exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "error: commit or stash your changes first; a release must match a commit." >&2
    exit 1
fi
"$ROOT/tools/check-public.sh"
"$ROOT/test.sh"
EARL_RELEASE=1 "$ROOT/build.sh"

APP="$ROOT/build/Earl.app"
for h in "$APP"/Contents/Helpers/*; do
    LINKS="$(otool -L "$h" | tail -n +2)"
    if printf '%s\n' "$LINKS" | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/' | grep -q .; then
        echo "error: $(basename "$h") links non-system libraries:" >&2
        printf '%s\n' "$LINKS" >&2
        exit 1
    fi
done
if ! codesign -dr - "$APP" 2>&1 | grep -q "certificate leaf = H\"$EXPECTED_LEAF\""; then
    echo "error: $APP is not signed with the Earl Local Signing certificate ($EXPECTED_LEAF)" >&2
    exit 1
fi
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/Earl-$VERSION-$BUILD.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")
TAG="v$VERSION-$BUILD"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    if [ "$(git -C "$ROOT" rev-parse "$TAG^{commit}")" != "$(git -C "$ROOT" rev-parse HEAD)" ]; then
        echo "error: tag $TAG already exists at another commit." >&2
        exit 1
    fi
else
    git -C "$ROOT" tag "$TAG"
fi

# D-4: the signed appcast. Settings come from release.env (env vars win).
_env_url="${EARL_FEED_URL-}"; _env_base="${EARL_DOWNLOAD_BASE-}"
source "$ROOT/release.env"
EARL_FEED_URL="${_env_url:-${EARL_FEED_URL:-}}"
EARL_DOWNLOAD_BASE="${_env_base:-${EARL_DOWNLOAD_BASE:-}}"
if [ -n "$EARL_FEED_URL" ]; then
    [ -n "$EARL_DOWNLOAD_BASE" ] || { echo "error: EARL_DOWNLOAD_BASE is empty (release.env)." >&2; exit 1; }
    # generate_appcast lists every archive in the folder; keep only the newest.
    mkdir -p "$ROOT/dist/old"
    for z in "$ROOT"/dist/Earl-*.zip; do
        [ "$z" = "$ZIP" ] || mv "$z" "${z%.zip}.zip.sha256" "$ROOT/dist/old/" 2>/dev/null || true
    done
    # Optional release notes shown in the update dialog: docs/release-notes/<version>.html
    cp "$ROOT/docs/release-notes/$VERSION.html" "$ROOT/dist/Earl-$VERSION-$BUILD.html" 2>/dev/null || true
    KEYARGS=()
    [ -z "${EARL_SPARKLE_KEY_FILE:-}" ] || KEYARGS=(--ed-key-file "$EARL_SPARKLE_KEY_FILE")
    "$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" ${KEYARGS[@]+"${KEYARGS[@]}"} \
        --download-url-prefix "${EARL_DOWNLOAD_BASE//\{TAG\}/$TAG}/" --maximum-versions 1 "$ROOT/dist"
    echo "Upload dist/$(basename "$ZIP") and dist/appcast.xml to GitHub Releases (tag $TAG): gh release create $TAG dist/Earl-$VERSION-$BUILD.zip dist/appcast.xml"
else
    echo "No EARL_FEED_URL in release.env: no appcast (colleagues update by hand)."
fi
echo "Release: $ZIP"
