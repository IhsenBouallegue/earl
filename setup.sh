#!/usr/bin/env bash
# One-time setup: downloads the models and builds Earl (including its own
# whisper.cpp, so nothing is installed from Homebrew except cmake for building).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS="$HOME/Library/Application Support/Earl/models"

command -v cmake >/dev/null || brew install cmake

mkdir -p "$MODELS"
download() {
    local file="$1" url="$2"
    if [ ! -s "$MODELS/$file" ]; then
        echo "Downloading $file…"
        curl -fL --progress-bar -C - -o "$MODELS/$file" "$url"
    fi
}
download ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
download ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

"$ROOT/tools/make-signing-cert.sh"
"$ROOT/build.sh"
echo "Done. Open Earl from ~/Applications (it lives in the menu bar)."

# Turn on the commit check (real names, addresses and paths can't slip into the public files).
git -C "$(dirname "$0")" config core.hooksPath .githooks 2>/dev/null || true
