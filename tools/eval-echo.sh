#!/usr/bin/env bash
# R2-4: evaluates echo removal on T-1's synthetic meetings (the `speakers`
# preset has the call's echo on the mic; `realistic` has none). Runs the
# installed Whisper model on temporary files; meetings are cached in
# $TMPDIR/earl-echo-eval.
#
#   tools/eval-echo.sh                 # seeds 1,2,3, 5 minutes each
#   tools/eval-echo.sh --prompt        # with the participants' names in Whisper's prompt
#   tools/eval-echo.sh --long          # also times the gate on an hour (release build)
#
# EARL_ECHO_SEEDS, EARL_SYNTH_MINUTES, EARL_ECHO_VERBOSE=1 and
# EARL_ECHO_NO_WHISPER=1 are passed through.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export EARL_ECHO_EVAL=1
LONG=0
for arg in "$@"; do
    case "$arg" in
        --prompt) export EARL_ECHO_PROMPT=1 ;;
        --long) LONG=1 ;;
        *) echo "usage: $0 [--prompt] [--long]" >&2; exit 2 ;;
    esac
done

"$ROOT/test.sh" --filter EchoEvalTests 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]|Compiling|Building|Write swift' || true
if [[ $LONG == 1 ]]; then
    EARL_ECHO_LONG=1 "$ROOT/test.sh" -c release -Xswiftc -enable-testing --filter echoGateOnAnHour 2>&1 \
        | grep -E "hour|✘|error" || true
fi
