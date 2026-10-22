#!/usr/bin/env bash
# Walks through Earl's first-run window on a pretend Mac, in a sandbox copy:
# nothing is downloaded, no permission is asked, and your running Earl, its
# settings and its meetings are left alone (no need to quit it).
#
# Usage: tools/rehearse-setup.sh [fresh | download-fails | microphone-off | admin]
#   fresh           every step, every download works (default)
#   download-fails  the first download stops part-way; Try Again works
#   microphone-off  the microphone was turned down once
#   admin           an administrator blocks the microphone
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO="${1:-fresh}"
case "$SCENARIO" in fresh | download-fails | microphone-off | admin) ;; *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
exec "$ROOT/tools/sandbox.sh" --name "rehearse-$SCENARIO" --reset -- "--rehearse-setup=$SCENARIO"
