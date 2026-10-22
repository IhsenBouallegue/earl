#!/usr/bin/env bash
# Builds a self-contained llama-server for Earl.app's built-in notes engine:
# static libraries, Metal shaders embedded, so it runs without Homebrew.
# Local only, so no HTTPS (LLAMA_OPENSSL=OFF: else it links Homebrew's OpenSSL).
# Build machine only. The version pin (a release tag) lives in tools/llama.version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/tools/llama.version")"
SRC="$ROOT/vendor/src/llama.cpp"
OUT="$ROOT/vendor/bin"

if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi
# Only touch the network when the checkout isn't already at the tag.
if [ "$(git -C "$SRC" rev-parse -q --verify "refs/tags/$VERSION^{commit}" || true)" != "$(git -C "$SRC" rev-parse HEAD)" ] \
    || ! git -C "$SRC" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    git -C "$SRC" fetch --depth 1 origin tag "$VERSION"
    git -C "$SRC" checkout -q "$VERSION"
fi

cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF
cmake --build "$SRC/build" --config Release --target llama-server -j

# Check the build-tree binary first: a failure must leave nothing in vendor/.
BIN="$SRC/build/bin/llama-server"
LINKS="$(otool -L "$BIN" | tail -n +2)"
if printf '%s\n' "$LINKS" | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/' | grep -q .; then
    echo "error: llama-server links non-system libraries:" >&2
    printf '%s\n' "$LINKS" >&2
    exit 1
fi

mkdir -p "$OUT"
cp "$BIN" "$OUT/llama-server"
echo "$VERSION" > "$ROOT/vendor/llama-version"
echo "Built $OUT/llama-server ($VERSION)"
