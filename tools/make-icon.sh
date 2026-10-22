#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from tools/make-icon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$ROOT/tools/make-icon.swift" "$TMP/main.swift"
swiftc -O -o "$TMP/make-icon" "$TMP/main.swift"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
mkdir -p "$ROOT/Resources"
iconutil -c icns -o "$ROOT/Resources/AppIcon.icns" "$TMP/AppIcon.iconset"
cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" "$ROOT/Resources/AppIcon.png"
echo "Wrote Resources/AppIcon.icns"
