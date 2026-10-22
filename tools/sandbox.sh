#!/usr/bin/env bash
# Runs a copy of Earl with data of its own, beside the real one: its own
# settings, meetings and Application Support, and none of the system-wide
# things (record shortcut, call detection, calendar reminders, notifications,
# update checks). Start as many as you like, each with its own name.
#
# Usage: tools/sandbox.sh [--name <name>] [--reset] [--no-build] [-- <Earl arguments>]
#   --name <name>  which sandbox (default: default); lives in $TMPDIR/earl-sandbox/<name>
#   --reset        wipe that sandbox first
#   --no-build     reuse build/Earl.app as it is
# Examples:
#   tools/sandbox.sh --name a --reset
#   tools/sandbox.sh --name b -- --rehearse-setup=download-fails
# Microphone and screen-audio permissions belong to the app, not to a copy;
# tools/rehearse-setup.sh pretends them instead.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME=default RESET=0 BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="${2:?--name needs a value}"; shift 2 ;;
        --reset) RESET=1; shift ;;
        --no-build) BUILD=0; shift ;;
        --) shift; break ;;
        -h | --help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
done
case "$NAME" in *[!A-Za-z0-9._-]* | "") echo "Name: letters, digits, . _ - only." >&2; exit 2 ;; esac
DIR="${TMPDIR:-/tmp}/earl-sandbox/$NAME"
[ "$RESET" = 1 ] && rm -rf "$DIR"
mkdir -p "$DIR"
if [ "$BUILD" = 1 ]; then
    EARL_RELEASE=1 "$ROOT/build.sh" >/dev/null   # builds build/Earl.app, leaves ~/Applications alone
fi
echo "Sandbox '$NAME' in $DIR"
exec "$ROOT/build/Earl.app/Contents/MacOS/Earl" --sandbox "$DIR" "$@"
