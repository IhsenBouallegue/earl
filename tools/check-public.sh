#!/usr/bin/env bash
# Checks the files that go into the public repo for anything that could point
# at a real person, client, employer or machine. It works by allowlists, so it
# needs no list of the names to look for:
#   - mail domains and URL hosts must be in tools/public-allow-domains.txt
#   - "First Last" names in Tests/ and DemoData.swift must be in tools/public-allow-names.txt
#   - home paths may only name made-up users; no company suffixes except placeholders
#   - no audio, certificates, keys or env files
# Optionally ~/.config/earl/private-patterns (kept out of the repo) lists extra
# regexes, one per line, for names you know about.
#
# Usage: tools/check-public.sh [dir]     (default: the repo's public files)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-}"
if [ -z "$DIR" ]; then
    DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
    "$ROOT/tools/export-public.sh" --copy-only "$DIR" >/dev/null
fi
cd "$DIR"
FAIL=0
bad() { echo "✘ $1"; FAIL=1; }
TEXT=$(find . -type f \( -name '*.swift' -o -name '*.md' -o -name '*.sh' -o -name '*.json' -o -name '*.txt' \
        -o -name '*.env' -o -name '*.version' -o -name '*.plist' -o -name '*.swiftpm' -o -name VERSION \) \
        -not -path './.git/*' -not -path './.build/*' -not -name Package.resolved | sort)

# 1. Files that must never ship.
FORBID=$(find . -type f -not -path './.git/*' \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.p12' \
        -o -iname '*.pem' -o -iname '*.key' -o -iname '*.cer' -o -iname '*.mobileprovision' -o -iname '.env' \
        -o -iname '.env.*' -o -iname 'meeting.json' -not -path './Tests/*' \))
[ -z "$FORBID" ] || bad "files that must not ship: $FORBID"
# shellcheck disable=SC2086
grep -l -E "BEGIN [A-Z ]*PRIVATE KEY" $TEXT 2>/dev/null | while read -r f; do echo "✘ private key in $f"; done | grep . && FAIL=1

allowed() { # host-or-domain, allow file
    local h; h=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    while read -r d; do
        d=${d%%#*}; d=$(echo "$d" | tr -d ' '); [ -n "$d" ] || continue
        [ "$h" = "$d" ] || [[ "$h" == *".$d" ]] && return 0
    done < "$ROOT/tools/public-allow-domains.txt"
    return 1
}

# 2. Mail domains.
while IFS=: read -r file line dom; do
    case "$dom" in *.png|*.jpg|*.icns|*.json|*.swift|*.md|*.sh) continue ;; esac
    allowed "$dom" || bad "$file:$line mail domain '$dom' is not in public-allow-domains.txt"
done < <(grep -n -o -E "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+" $TEXT 2>/dev/null \
         | sed -E 's/^([^:]+):([0-9]+):[^@]*@(.*)$/\1:\2:\3/')

# 3. URL hosts (single-word hosts and .local are test fixtures).
while IFS=: read -r file line host; do
    case "$host" in *.*) ;; *) continue ;; esac
    case "$host" in *.local) continue ;; esac
    allowed "$host" || bad "$file:$line host '$host' is not in public-allow-domains.txt"
done < <(grep -n -o -E "https?://[A-Za-z0-9.-]+" $TEXT 2>/dev/null | sed -E 's#^([^:]+):([0-9]+):https?://(.*)$#\1:\2:\3#')

# 4. Home paths: made-up users only.
grep -n -E "/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+" $TEXT 2>/dev/null \
  | grep -v -E "/(Users|home)/(anna|bob|bobby|me|ben|alex|~|<name>|\\\\)" \
  | grep -v -E "\"/Users/\[" | while read -r l; do echo "✘ home path: $l"; done | grep . && FAIL=1

# 5. Company suffixes: only placeholders may carry one.
grep -n -o -E "[A-Z][A-Za-z&-]+ (GmbH|AG|SE|KG|Inc\.?|Ltd|LLC|Corp)\b" $TEXT 2>/dev/null \
  | grep -v -E ":(Example|Acme|Contoso|Beispiel|Muster) " | while read -r l; do echo "✘ organisation name: $l"; done | grep . && FAIL=1

# 6. Names in tests and demo data must come from the made-up roster.
NAMES=$(grep -v '^#' "$ROOT/tools/public-allow-names.txt" | sed '/^$/d')
while IFS=: read -r file line name; do
    printf '%s\n' "$NAMES" | grep -qxF "$name" || bad "$file:$line \"$name\" is not in public-allow-names.txt (made-up names only)"
done < <( { find ./Tests -name '*.swift' -not -path '*/Support/*'; echo ./Sources/Earl/DemoData.swift; } \
          | xargs grep -n -o -E "\"[A-ZÄÖÜ][a-zäöüßé'-]+ [A-ZÄÖÜ][a-zäöüßé'-]+\"" 2>/dev/null \
          | sed -E 's/^([^:]+):([0-9]+):"(.*)"$/\1:\2:\3/' | sort -t: -k3 -u )

# 7. Your own private list, if you keep one.
P="$HOME/.config/earl/private-patterns"
if [ -f "$P" ]; then
    # shellcheck disable=SC2086
    grep -n -i -E -f <(grep -v -E '^\s*(#|$)' "$P") $TEXT 2>/dev/null | while read -r l; do echo "✘ private pattern: $l"; done | grep . && FAIL=1
fi

if [ "$FAIL" = 0 ]; then echo "✔ public check passed"; else echo; echo "Fix these before committing or publishing. Examples use made-up names and example.* domains (see CLAUDE.md)."; fi
exit "$FAIL"
