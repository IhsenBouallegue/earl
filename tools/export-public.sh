#!/usr/bin/env bash
# Builds the public copy of Earl from an allowlist of paths, checks it, and
# commits it to a separate repo that has none of the private history.
#
# Usage: tools/export-public.sh [--copy-only <dir>] | [public-repo-dir]
#   default public repo: ../earl-public
# Plans, design notes and product docs stay in the private repo: they hold
# the real-world context examples tend to be copied from.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PUBLIC_PATHS=(
    Sources Tests Resources tools
    Package.swift Package.resolved build.sh setup.sh test.sh release.env VERSION
    README.md PRIVACY.md CLAUDE.md .gitignore .githooks
    docs/INSTALL.md docs/benchmarks.md
)
# Public author identity: a neutral address, never a work one.
PUBLIC_NAME="Ihsen Bouallegue"
PUBLIC_EMAIL="bouallegueihsen@gmail.com"

copy_tree() {
    local out="$1"
    mkdir -p "$out"
    for p in "${PUBLIC_PATHS[@]}"; do
        [ -e "$ROOT/$p" ] || continue
        git -C "$ROOT" ls-files -z -- "$p" | while IFS= read -r -d '' f; do
            mkdir -p "$out/$(dirname "$f")"
            cp -p "$ROOT/$f" "$out/$f"
        done
    done
}

if [ "${1:-}" = "--copy-only" ]; then copy_tree "$2"; exit 0; fi

OUT="${1:-$ROOT/../earl-public}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
copy_tree "$STAGE"
"$ROOT/tools/check-public.sh" "$STAGE"

mkdir -p "$OUT"
[ -d "$OUT/.git" ] || git -C "$OUT" init -q -b main
# Replace the working tree with the staged files, keep only .git.
find "$OUT" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
cp -a "$STAGE"/. "$OUT"/
git -C "$OUT" config user.name "$PUBLIC_NAME"
git -C "$OUT" config user.email "$PUBLIC_EMAIL"
git -C "$OUT" add -A
if git -C "$OUT" diff --cached --quiet; then echo "Nothing new to publish."; exit 0; fi
VERSION="$(cat "$ROOT/VERSION")"
git -C "$OUT" commit -q -m "${EARL_PUBLIC_MESSAGE:-Earl $VERSION}"
echo "Committed to $OUT as $(git -C "$OUT" log -1 --format='%h %an <%ae>'). Push it yourself or with gh."
