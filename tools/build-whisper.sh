#!/usr/bin/env bash
# Builds a self-contained whisper-cli for Earl.app: static libraries, Metal
# shaders embedded, so it runs without Homebrew. Build machine only.
# The version pin lives in tools/whisper.version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/tools/whisper.version")"
SRC="$ROOT/vendor/src/whisper.cpp"
OUT="$ROOT/vendor/bin"

if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "v$VERSION" https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi
# Only touch the network when the checkout isn't already at the tag.
if [ "$(git -C "$SRC" rev-parse -q --verify "refs/tags/v$VERSION^{commit}" || true)" != "$(git -C "$SRC" rev-parse HEAD)" ] \
    || ! git -C "$SRC" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    git -C "$SRC" fetch --depth 1 origin tag "v$VERSION"
    git -C "$SRC" checkout -q "v$VERSION"
fi

cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build "$SRC/build" --config Release --target whisper-cli -j

# Check the build-tree binary first: a failure must leave nothing in vendor/.
BIN="$SRC/build/bin/whisper-cli"
LINKS="$(otool -L "$BIN" | tail -n +2)"
if printf '%s\n' "$LINKS" | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/' | grep -q .; then
    echo "error: whisper-cli links non-system libraries:" >&2
    printf '%s\n' "$LINKS" >&2
    exit 1
fi

mkdir -p "$OUT"
cp "$BIN" "$OUT/whisper-cli"
echo "$VERSION" > "$ROOT/vendor/whisper-version"
echo "Built $OUT/whisper-cli ($VERSION)"
