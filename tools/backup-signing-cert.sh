#!/usr/bin/env bash
# Exports (or restores) the Earl Local Signing identity. Every update must be
# signed with it: a new certificate resets colleagues' privacy permissions and
# breaks updates. Keep the .p12 and its password in a password manager.
# export-sparkle / restore-sparkle do the same for the update-signing EdDSA key.
set -euo pipefail
NAME="Earl Local Signing"
case "${1:-export}" in
export)
    OUT="${2:-$HOME/Desktop/earl-signing.p12}"
    TMP="$OUT.tmp"
    trap 'rm -f "$TMP"' EXIT
    read -rsp "Password for the backup: " PASS; echo
    [ -n "$PASS" ] || { echo "error: the backup password can't be empty" >&2; exit 1; }
    security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 -P "" -o "$TMP" >/dev/null
    # The keychain exports every identity; keep only Earl's. Each item starts at
    # "Bag Attributes", so a bag without a friendlyName is dropped, never inherited.
    PEM="$(openssl pkcs12 -in "$TMP" -passin pass: -nodes 2>/dev/null \
        | awk -v n="$NAME" '/^Bag Attributes/ {keep = 0} /friendlyName/ {keep = index($0, n) > 0} keep')"
    if ! printf '%s\n' "$PEM" | grep -q "PRIVATE KEY" || ! printf '%s\n' "$PEM" | grep -q "BEGIN CERTIFICATE"; then
        echo "error: couldn't find both the private key and certificate for \"$NAME\"." >&2
        echo "Export it from Keychain Access (My Certificates) instead." >&2
        exit 1
    fi
    export PASS
    if ! printf '%s\n' "$PEM" | openssl pkcs12 -export -name "$NAME" -out "$OUT" -passout env:PASS; then
        rm -f "$OUT"; echo "error: couldn't write $OUT" >&2; exit 1
    fi
    echo "Saved $OUT"
    ;;
restore)
    [ -n "${2:-}" ] || { echo "usage: $0 restore file.p12" >&2; exit 2; }
    security import "$2" -k "$HOME/Library/Keychains/login.keychain-db" -T /usr/bin/codesign
    ;;
export-sparkle)
    # The EdDSA key that signs updates. Lose it and installed copies can never update.
    OUT="${2:-$HOME/Desktop/earl-sparkle-key}"
    "$(dirname "$0")/../.build/artifacts/sparkle/Sparkle/bin/generate_keys" -x "$OUT"
    chmod 600 "$OUT"
    echo "Saved $OUT. Put it in a password manager, then delete the file."
    ;;
restore-sparkle)
    [ -n "${2:-}" ] || { echo "usage: $0 restore-sparkle keyfile" >&2; exit 2; }
    "$(dirname "$0")/../.build/artifacts/sparkle/Sparkle/bin/generate_keys" -f "$2"
    ;;
*)
    echo "usage: $0 [export [file.p12] | restore file.p12 | export-sparkle [file] | restore-sparkle file]" >&2; exit 2
    ;;
esac
