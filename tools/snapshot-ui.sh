#!/usr/bin/env bash
# U-0: renders every Earl screen with made-up data to PNG files.
# Builds the debug binary and runs it in demo mode; never touches your
# meetings, settings or the installed app.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/snapshot-ui.sh <out-dir> [--dark] [--only <name>]

Builds the debug binary (swift build) and renders each screen with made-up
data to <out-dir>/<name>.png: the main window at 1180×760, panels at their
natural size, all at 2×.

  --dark         Render the dark appearance.
  --only <name>  Render one screen only.

Screens:
  library-meeting     Meetings window with a finished meeting (Summary tab)
  meeting-transcript  The same meeting on the Transcript tab
  meeting-processing  A meeting being transcribed, with live turns
  meeting-failed      A meeting that failed to process
  recording           The recording screen with the live speaker stage
  todos               The To-dos page (yours, everyone else, done)
  engine              Under the Hood, full height
  engine-ollama       D-3: the same with Ollama writing the notes
  engine-none         D-3: the same with nothing to write notes yet (the
                      built-in note writer offered for download)
  engine-builtin      D-3: the built-in note writer downloaded and in use
  engine-builtin-downloading
                      D-3: the built-in note writer downloading
  empty               The Meetings window with no meetings
  menubar             The menu bar panel, idle, with the next meeting
  menubar-recording   The menu bar panel while recording
  offer               The floating call offer panel
  components          U-1: every shared paper piece on one sheet
  search              U-3: ⌘K search filtering the sidebar (S-3: a question,
                      so the Ask Earl row leads)
  ask                 S-3: the meeting page with Ask Earl's answer drawer
  ask-all             S-3: the Ask page, questions across all meetings
  brief               S-2: Earl's brief before the next meeting of a series
  series              S-2: a series page with nothing coming
  meeting-daily       S-1: a daily stand-up with "Since last time"
  meeting-townhall    K-1: a town hall's notes: announcements, for you, Q&A
  meeting-reading     The product sync in one column, conversation hidden
  upnext              The sidebar's next meeting: soon, armed, in progress, recording
  onboarding-welcome  D-2: the first-run window: welcome with the three features
  onboarding-models   Download Listening Tools, before the download
  onboarding-downloading
                      The same while downloading (progress in the button slot)
  onboarding-failed   A failed download: the reason, Use a File I Have…, Try Again,
                      Not Now
  onboarding-import-failed
                      A chosen file that didn't work: why, nothing about a download
  onboarding-microphone
                      Allow Microphone Access, with macOS's question sketched
  onboarding-microphone-off
                      The microphone turned down once: the System Settings switch
  onboarding-admin    Microphone managed by the organisation, note for IT copied
  onboarding-screenaudio
                      Hear the Other Side: the Screen & System Audio switch
  onboarding-relaunch Restart Earl
  onboarding-done     You're All Set
  onboarding-done-where
                      The same after "Show Me Where Earl Lives"
  onboarding-notes    D-3: Notes, Written on Your Mac (the built-in note writer)
  onboarding-notes-downloading
                      The same while its model downloads
  onboarding-notes-queued
                      Download pressed while the tools still download: it waits
  onboarding-notes-failed
                      The note writer's download failed: Use a File I Have…
  onboarding-relaunch-downloading
                      Restart Earl while the tools still download
  onboarding-relaunch-waiting
                      The same after Restart After Download: Earl waits

What doesn't render faithfully (it's drawn offscreen with cacheDisplay):
  - Liquid Glass: glass buttons and panels (Record, Stop and Take Notes,
    Start Recording, the sidebar, toolbar platters) are flat grey capsules
    with a hairline. Their tint (accent, red) doesn't show, and in dark mode
    a prominent glass button's label is dim. Blurs are plain background.
  - The offer panel is drawn without glass (its glass: false test mode).
  - The window draws as inactive: segmented pickers, progress bars and the
    sidebar selection are grey instead of the accent colour.
  - Sidebar list text is vibrant; in dark mode it's re-lightened to
    approximate the blend, so its greys are close but not exact.
  - Rows under the sidebar's Under the Hood button end at a hard edge
    instead of the scroll-edge blur.
  - The menu bar panel is drawn on the window background, without the
    menu bar extra's material and rounded corners.
  - Faces on the live stage sway and blink with the clock, so two runs can
    differ by a pixel or two there. Dates and times are relative to now.

Safety: the binary runs as "EarlDemo", so its settings go to the EarlDemo
defaults domain (wiped before and after). Meetings and models live in a
throwaway folder under $TMPDIR. The network is blocked and no service
(shortcut, call detection, calendar, notifications, LM Studio, recorder)
starts. Windows stay offscreen and transparent.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

OUT="$1"
shift
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dark) ARGS+=(--dark) ;;
        --only) [[ $# -ge 2 ]] || { echo "--only needs a screen name" >&2; exit 1; }
                ARGS+=(--only "$2"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" >&2
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"

# A copy named EarlDemo: an unbundled binary's settings domain is its name.
cp -c "$BIN/Earl" "$BIN/EarlDemo" 2>/dev/null || cp "$BIN/Earl" "$BIN/EarlDemo"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STATUS=0
"$BIN/EarlDemo" --demo "$OUT" --icon "$ROOT/Resources/AppIcon.icns" ${ARGS[@]+"${ARGS[@]}"} || STATUS=$?
# The demo empties its defaults domain on exit; cfprefsd leaves the empty file.
rm -f "$HOME/Library/Preferences/EarlDemo.plist"
exit $STATUS
