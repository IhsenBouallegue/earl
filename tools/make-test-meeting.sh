#!/usr/bin/env bash
# Writes a synthetic test meeting (T-1) into a folder: system-16k.wav, mic-16k.wav,
# mix.wav, truth.json and README.txt. The same preset and seed give the same files.
#
#   tools/make-test-meeting.sh <preset> <output-dir> [--seed N] [--minutes M]
#
# Presets: clean, realistic, hard, speakers, german, backchannel, mixed. Defaults: seed 1, 5 minutes.
# The builder lives in the test target (Tests/EarlTests/Support/SyntheticMeeting.swift),
# so this runs one filtered test with the settings in environment variables.
set -euo pipefail

usage() {
    echo "usage: $0 <clean|realistic|hard|speakers|german|backchannel|mixed> <output-dir> [--seed N] [--minutes M]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
PRESET="$1"; OUT="$2"; shift 2
SEED=1; MINUTES=5
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) [[ $# -ge 2 ]] || usage; SEED="$2"; shift 2 ;;
        --minutes) [[ $# -ge 2 ]] || usage; MINUTES="$2"; shift 2 ;;
        *) usage ;;
    esac
done
case "$PRESET" in clean|realistic|hard|speakers|german|backchannel|mixed) ;; *) usage ;; esac
[[ "$SEED" =~ ^[0-9]+$ ]] || usage
[[ "$MINUTES" =~ ^[0-9]+([.][0-9]+)?$ ]] || usage

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EARL_SYNTH_PRESET="$PRESET" EARL_SYNTH_OUT="$OUT" EARL_SYNTH_SEED="$SEED" EARL_SYNTH_MINUTES="$MINUTES" \
    "$ROOT/test.sh" --filter "SyntheticMeetingTests/writeMeetingFolder" 2>&1 \
    | grep -E "Wrote |error|✘|failed" || true

[[ -f "$OUT/truth.json" ]] || { echo "No meeting was written." >&2; exit 1; }
echo
cat "$OUT/README.txt"
