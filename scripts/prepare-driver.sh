#!/bin/bash
# Download the unmodified, signed HP package; do not install it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.cache"
NAME="hp-printer-essentials-R-5_20_0_1.pkg"
URL="https://ftp.hp.com/pub/softlib/software12/HP_Quick_Start/osx/Installations/Essentials/macOS26/$NAME"
SHA256="22d7c4029fbfe335fb63528bdadd02c0a471017e159c472c0c8d276caf78db2f"
mkdir -p "$DEST"
if [[ ! -f "$DEST/$NAME" ]]; then
    TEMP="$(mktemp "$DEST/download.XXXXXX")"
    trap 'rm -f "$TEMP"' EXIT
    /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 600 --retry 2 --output "$TEMP" "$URL"
    printf '%s  %s\n' "$SHA256" "$TEMP" | /usr/bin/shasum -a 256 -c -
    mv "$TEMP" "$DEST/$NAME"
    trap - EXIT
fi
printf '%s  %s\n' "$SHA256" "$DEST/$NAME" | /usr/bin/shasum -a 256 -c -
/usr/sbin/pkgutil --check-signature "$DEST/$NAME"
/usr/sbin/spctl --assess --type install --verbose "$DEST/$NAME"
printf '\nVerified HP package: %s\n' "$DEST/$NAME"
