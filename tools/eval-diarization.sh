#!/usr/bin/env bash
# R2-2: evaluates speaker separation on synthetic meetings (T-1). Runs the call
# track through whisper and diarization and scores it against the answer key.
# Downloads the speaker model into a temporary folder (not Earl's) unless
# EARL_EVAL_MODELS points elsewhere, and reads the installed Whisper model.
#
#   tools/eval-diarization.sh                          # the clean preset, seed 1, with targets
#   tools/eval-diarization.sh --presets clean,realistic,hard,german --seeds 1,2,3
#   tools/eval-diarization.sh --long                   # also times an hour of audio
#
# Options: --minutes M (default 5), --cache DIR (keeps meetings and whisper's
# output there; later runs only redo the diarization, for tuning with the
# EARL_EVAL_THRESHOLD, _STEP, _MINSEG, _FA, _FB, … knobs in DiarizationEvalTests).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export EARL_EVAL_MODELS="${EARL_EVAL_MODELS:-${TMPDIR:-/tmp}/earl-eval-speaker-models}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --long) export EARL_EVAL_LONG=1; shift ;;
        --presets) export EARL_EVAL_PRESETS="$2"; shift 2 ;;
        --seeds) export EARL_EVAL_SEEDS="$2"; shift 2 ;;
        --minutes) export EARL_EVAL_MINUTES="$2"; shift 2 ;;
        --cache) mkdir -p "$2"; export EARL_EVAL_CACHE="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "usage: $0 [--presets a,b] [--seeds 1,2] [--minutes M] [--cache DIR] [--long]" >&2; exit 2 ;;
    esac
done

"$ROOT/test.sh" --filter DiarizationEvalTests
