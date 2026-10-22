#!/usr/bin/env bash
# Builds Earl.app and installs it to ~/Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Earl.app"
DEST="$HOME/Applications/Earl.app"

swift build -c release --package-path "$ROOT"

VERSION="$(cat "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
WHISPER_VERSION="$(cat "$ROOT/tools/whisper.version")"
WHISPER="$ROOT/vendor/bin/whisper-cli"
if [ ! -x "$WHISPER" ] || [ "$(cat "$ROOT/vendor/whisper-version" 2>/dev/null)" != "$WHISPER_VERSION" ]; then
    "$ROOT/tools/build-whisper.sh"
fi
# D-3: the built-in notes engine.
LLAMA_VERSION="$(cat "$ROOT/tools/llama.version")"
LLAMA="$ROOT/vendor/bin/llama-server"
if [ ! -x "$LLAMA" ] || [ "$(cat "$ROOT/vendor/llama-version" 2>/dev/null)" != "$LLAMA_VERSION" ]; then
    "$ROOT/tools/build-llama.sh"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Earl" "$APP/Contents/MacOS/Earl"
[ -f "$ROOT/Resources/AppIcon.icns" ] || "$ROOT/tools/make-icon.sh"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Helpers"
cp "$WHISPER" "$APP/Contents/Helpers/whisper-cli"
cp "$LLAMA" "$APP/Contents/Helpers/llama-server"

# D-4: Sparkle. The app links it, so it is always embedded (dev builds too);
# it stays inert unless Info.plist has SUFeedURL. Take the framework from the
# binary artifact itself (the macOS slice of the xcframework).
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "error: Sparkle.framework not found at $SPARKLE" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# Update feed (release.env). Values already in the environment win over the
# file, so a test build can point at a local feed without editing anything.
_env_url="${EARL_FEED_URL-}"; _env_key="${EARL_SPARKLE_PUBLIC_KEY-}"; _env_base="${EARL_DOWNLOAD_BASE-}"
source "$ROOT/release.env"
EARL_FEED_URL="${_env_url:-${EARL_FEED_URL:-}}"
EARL_SPARKLE_PUBLIC_KEY="${_env_key:-${EARL_SPARKLE_PUBLIC_KEY:-}}"
EARL_DOWNLOAD_BASE="${_env_base:-${EARL_DOWNLOAD_BASE:-}}"
# Only builds with a feed look for updates, so dev builds never self-update.
FEED_KEYS=""
if [ -n "$EARL_FEED_URL" ]; then
    [ -n "$EARL_SPARKLE_PUBLIC_KEY" ] || { echo "error: EARL_FEED_URL is set but EARL_SPARKLE_PUBLIC_KEY is empty (release.env)." >&2; exit 1; }
    FEED_KEYS="<key>SUFeedURL</key>
    <string>$EARL_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$EARL_SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.earl.app</string>
    <key>CFBundleName</key>
    <string>Earl</string>
    <key>CFBundleDisplayName</key>
    <string>Earl</string>
    <key>CFBundleExecutable</key>
    <string>Earl</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>EarlWhisperVersion</key>
    <string>$WHISPER_VERSION</string>
    <key>EarlLlamaVersion</key>
    <string>$LLAMA_VERSION</string>
    $FEED_KEYS
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Earl records your voice during meetings so it can transcribe them.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Earl records the other participants' audio so it can transcribe your meetings.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Earl names your recordings after the calendar event and knows who was invited. Nothing leaves your Mac.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Earl names your recordings after the calendar event and knows who was invited. Nothing leaves your Mac.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Earl adds your action items to Reminders when you ask it to.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Earl meeting link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>earl</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Sign with the stable local certificate (tools/make-signing-cert.sh) so macOS keeps
# Earl's privacy permissions across rebuilds. The certificate is self-signed and
# not trusted system-wide, so look it up by hash rather than as a "valid" identity.
IDENTITY="$(security find-identity -p codesigning | awk '/"Earl Local Signing"/ { print $2; exit }')"
if [ -z "$IDENTITY" ]; then
    if [ "${EARL_RELEASE:-0}" = 1 ]; then
        echo "error: no Earl Local Signing certificate. Restore it (tools/backup-signing-cert.sh restore) — never ship ad-hoc." >&2
        exit 1
    fi
    echo "warning: no Earl Local Signing certificate; signing ad-hoc (permissions reset on every build). Run tools/make-signing-cert.sh once to fix that."
    IDENTITY="-"
fi
# Inside out: Sparkle's parts (Earl isn't sandboxed, so its XPC services go),
# then the framework, then the helpers, then the app.
F="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$F/Versions/B/XPCServices" "$F/XPCServices"
codesign --force --sign "$IDENTITY" "$F/Versions/B/Autoupdate"
codesign --force --sign "$IDENTITY" "$F/Versions/B/Updater.app"
codesign --force --sign "$IDENTITY" "$F"
for h in "$APP"/Contents/Helpers/*; do
    codesign --force --sign "$IDENTITY" --identifier "local.earl.app.$(basename "$h")" "$h"
done
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if [ "${EARL_RELEASE:-0}" != 1 ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed $DEST"
fi
