#!/usr/bin/env bash
# Q-1: replays Earl's real processing (transcribe, diarize, guess speaker
# names, write notes) on a copy of a meeting folder, so before/after
# transcript-hygiene changes can be compared. Writes transcript.json,
# speakers.json, meeting.json, summary.md and transcript.md into the folder,
# the same files the app would write.
#
#   tools/reprocess.sh <meeting-folder-copy> [--no-notes]
#
# The test process has its own settings: set EARL_REPROCESS_MODEL (notes
# model id) and EARL_REPROCESS_USER (your name) to match the app.
#
# Never point this at a real meeting: it refuses anything under ~/Meetings,
# and only runs on a copy under $TMPDIR or /tmp.
set -euo pipefail

usage() { echo "usage: $0 <meeting-folder-copy> [--no-notes]" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
FOLDER="$1"; shift
NO_NOTES=0
if [[ $# -gt 0 ]]; then
    [[ "$1" == "--no-notes" ]] || usage
    NO_NOTES=1
    shift
fi
[[ $# -eq 0 ]] || usage

[[ -d "$FOLDER" ]] || { echo "No such folder: $FOLDER" >&2; exit 1; }
ABS="$(cd "$FOLDER" && pwd)"

MEETINGS_ROOT="$HOME/Meetings"
if [[ "$ABS" == "$MEETINGS_ROOT" || "$ABS" == "$MEETINGS_ROOT"/* ]]; then
    echo "Refusing to reprocess anything under ~/Meetings." >&2
    exit 1
fi

TMP="${TMPDIR:-/tmp}"
TMP_REAL="$(cd "$TMP" && pwd)"
case "$ABS" in
    "$TMP_REAL"|"$TMP_REAL"/*|/tmp|/tmp/*) ;;
    *) echo "reprocess.sh only runs on a copy under \$TMPDIR or /tmp (got $ABS)." >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export EARL_REPROCESS="$ABS"
[[ $NO_NOTES == 1 ]] && export EARL_REPROCESS_NO_NOTES=1

"$ROOT/test.sh" --filter ReprocessTool
