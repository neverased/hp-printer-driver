#!/bin/bash
# Install the locally built ARM64 renderer. Does not change printer queues.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/.build/hplip-native-print/stage"
TARGET="/Library/Printers/HP150"
CHECK_ONLY=false
if [[ "${1:-}" == "--check" && $# == 1 ]]; then
    CHECK_ONLY=true
elif [[ $# != 0 ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 2
fi
if [[ "$CHECK_ONLY" == false && "$EUID" != 0 ]]; then
    echo "Installation requires administrator authentication (sudo)." >&2
    exit 1
fi
[[ -x "$SOURCE/filter/hpcups" ]] || { echo "Run scripts/build-hpcups.sh first." >&2; exit 1; }
[[ "$(/usr/bin/lipo -archs "$SOURCE/filter/hpcups")" == "arm64" ]] || {
    echo "Expected a native arm64-only renderer." >&2; exit 1;
}
# Only system dylibs are permitted; the build statically links libjpeg.
while IFS= read -r dependency; do
    case "$dependency" in
        /usr/lib/*|/System/Library/*) ;;
        *) echo "Unexpected runtime dependency: $dependency" >&2; exit 1 ;;
    esac
done < <(/usr/bin/otool -L "$SOURCE/filter/hpcups" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/hp150-print.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/filter"
/bin/cp "$SOURCE/filter/hpcups" "$TEMP/filter/hpcups"
/usr/bin/sed 's#application/vnd.cups-raster 0 hpcups#application/vnd.cups-raster 0 /Library/Printers/HP150/filter/hpcups#' \
    "$SOURCE/ppd/hp-officejet_150_mobile_l511.ppd" \
    > "$TEMP/HP-Officejet-150.ppd"
/usr/bin/grep -Fq '*cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/HP150/filter/hpcups"' "$TEMP/HP-Officejet-150.ppd"
/usr/bin/codesign --force --sign - "$TEMP/filter/hpcups"
/usr/bin/codesign --verify --strict "$TEMP/filter/hpcups"
printf 'HPLIP 3.26.6, locally built for ARM64; source and patches in hp-printer-driver.\n' > "$TEMP/SOURCE.txt"
/usr/bin/ditto "$SOURCE/licenses" "$TEMP/licenses"
/bin/cp "$SOURCE/manifest.json" "$TEMP/build-manifest.json"
if [[ "$CHECK_ONLY" == true ]]; then
    echo "Native print artifacts verified; no system files changed."
    exit 0
fi
[[ ! -e "$TARGET" && ! -L "$TARGET" ]] || {
    echo "Refusing to overwrite $TARGET. Review the existing installation first." >&2; exit 1;
}
# Claim the destination exclusively so a concurrent install cannot be merged.
/bin/mkdir -m 755 "$TARGET"
/usr/bin/ditto "$TEMP" "$TARGET"
/usr/sbin/chown -R root:wheel "$TARGET"
/bin/chmod -R go-w "$TARGET"
/bin/chmod 755 "$TARGET" "$TARGET/filter" "$TARGET/filter/hpcups"
/bin/chmod 644 "$TARGET/HP-Officejet-150.ppd" "$TARGET/SOURCE.txt"
/usr/bin/codesign --verify --strict "$TARGET/filter/hpcups"
echo "Installed native renderer and PPD in $TARGET."
