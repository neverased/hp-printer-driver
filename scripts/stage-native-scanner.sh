#!/bin/bash
# Extract two unchanged HP bundles for a native ARM64 scanner installation.
# Nothing in this script installs software or runs the HP package installer.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=hp-printer-essentials-R-5_20_0_1.pkg
SHA256=22d7c4029fbfe335fb63528bdadd02c0a471017e159c472c0c8d276caf78db2f
OUTPUT="$ROOT/.build/native-scanner"
PACKAGE=""

die() { printf '%s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 && -n "$2" ]] || die '--output requires a directory.'
            OUTPUT="$2"; shift 2 ;;
        -h|--help)
            printf 'Usage: %s [HP-package.pkg] [--output directory]\n' "$0"
            exit 0 ;;
        -*) die "Unknown option: $1" ;;
        *)
            [[ -z "$PACKAGE" ]] || die 'Only one source package is accepted.'
            PACKAGE="$1"; shift ;;
    esac
done

[[ "$(/usr/bin/uname -s)" == Darwin && "$(/usr/bin/uname -m)" == arm64 ]] ||
    die 'Staging requires a native Apple Silicon macOS shell.'
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || die "Refusing to overwrite: $OUTPUT"
if [[ -z "$PACKAGE" ]]; then
    if [[ -f "$ROOT/.cache/$NAME" ]]; then
        PACKAGE="$ROOT/.cache/$NAME"
    elif [[ -f "/tmp/hp-package-audit-artifacts/$NAME" ]]; then
        PACKAGE="/tmp/hp-package-audit-artifacts/$NAME"
    else
        die 'No HP package found. Run scripts/prepare-driver.sh or pass its path.'
    fi
fi
[[ -f "$PACKAGE" ]] || die "Package not found: $PACKAGE"

# Work on a private snapshot. In particular, a privileged installer must not
# validate one user-writable file and then extract a subsequently changed file.
PRIVATE="$(/usr/bin/mktemp -d /private/tmp/hp150-scanner-stage.XXXXXX)"
cleanup() {
    STATUS=$?
    if [[ $STATUS -ne 0 && -f "$PRIVATE/result/verification.log" ]]; then
        /usr/bin/tail -n 12 "$PRIVATE/result/verification.log" >&2
    fi
    # HP's archive includes read-only directories. Make only our temporary
    # extraction writable before removing it; staged bundles stay unchanged.
    /bin/chmod -R u+w "$PRIVATE"
    /bin/rm -r "$PRIVATE"
    return "$STATUS"
}
trap cleanup EXIT
/bin/cp "$PACKAGE" "$PRIVATE/source.pkg"
ACTUAL="$(/usr/bin/shasum -a 256 "$PRIVATE/source.pkg" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL" == "$SHA256" ]] || die 'HP package SHA-256 mismatch; nothing was staged.'
/bin/mkdir "$PRIVATE/result" "$PRIVATE/raw" "$PRIVATE/scanner" "$PRIVATE/device-model"
LOG="$PRIVATE/result/verification.log"
/usr/sbin/pkgutil --check-signature "$PRIVATE/source.pkg" > "$LOG" 2>&1
/usr/bin/grep -Fq 'Developer ID Installer: HP Inc. (6HB5Y2QTA3)' "$LOG" ||
    die 'The source package does not have the expected HP installer identity.'
/usr/sbin/spctl --assess --type install --verbose "$PRIVATE/source.pkg" >> "$LOG" 2>&1
(
    cd "$PRIVATE/raw"
    /usr/bin/xar -xf "$PRIVATE/source.pkg" \
        com.hp.scan.ica.module3.pkg com.hp.DeviceModel.5.pkg
)
/usr/bin/tar --no-same-owner -xpf "$PRIVATE/raw/com.hp.scan.ica.module3.pkg/Payload" -C "$PRIVATE/scanner"
/usr/bin/tar --no-same-owner -xpf "$PRIVATE/raw/com.hp.DeviceModel.5.pkg/Payload" -C "$PRIVATE/device-model"
/usr/bin/ditto "$PRIVATE/scanner/Library/Image Capture/Devices/HP Scanner 3.app" \
    "$PRIVATE/result/HP Scanner 3.app"
/usr/bin/ditto "$PRIVATE/device-model/hp/Frameworks/HPDM.framework" \
    "$PRIVATE/result/HPDM.framework"

REQUIREMENT='=anchor apple generic and certificate leaf[subject.OU] = "6HB5Y2QTA3"'
for BUNDLE in "$PRIVATE/result/HP Scanner 3.app" "$PRIVATE/result/HPDM.framework"; do
    /usr/bin/codesign --verify --deep --strict -R "$REQUIREMENT" "$BUNDLE" >> "$LOG" 2>&1
done

SCANNER="$PRIVATE/result/HP Scanner 3.app/Contents"
SERVICES="$SCANNER/Frameworks/HPScanServices.framework/Versions/A"
DOT4="$SERVICES/PlugIns/HPDOT4Scan.bundle/Contents"
HPDM="$PRIVATE/result/HPDM.framework/Versions/5.0"
for BINARY in \
    "$SCANNER/MacOS/HP Scanner 3" \
    "$SERVICES/HPScanServices" \
    "$DOT4/MacOS/HPDOT4Scan" \
    "$DOT4/PlugIns/HPAiOTulip.bundle/Contents/MacOS/HPAiOTulip" \
    "$HPDM/HPDM" \
    "$HPDM/Runtime/hpdot4d.app/Contents/MacOS/hpdot4d" \
    "$HPDM/Runtime/HPIOPrinterClassDriver.plugin/Contents/MacOS/HPIOPrinterClassDriver" \
    "$HPDM/XPCServices/com.hp.dm.5.TransportProxy.xpc/Contents/MacOS/com.hp.dm.5.TransportProxy"; do
    /usr/bin/lipo -verify_arch arm64 "$BINARY" >> "$LOG" 2>&1
done

# This probe is built for arm64 only. It checks the dependency graph without
# starting the scanner or a scan. No Intel executable is invoked.
/usr/bin/xcrun clang -arch arm64 "$ROOT/scripts/scanner-load-check.c" \
    -o "$PRIVATE/result/scanner-load-check" >> "$LOG" 2>&1
DYLD_FRAMEWORK_PATH="$PRIVATE/result:$SCANNER/Frameworks" \
    "$PRIVATE/result/scanner-load-check" \
    "$SERVICES/HPScanServices" \
    "$DOT4/MacOS/HPDOT4Scan" \
    "$DOT4/PlugIns/HPAiOTulip.bundle/Contents/MacOS/HPAiOTulip" \
    "$HPDM/HPDM" >> "$LOG" 2>&1

printf 'Source: HP Printer Essentials R 5.20.0.1\nSHA-256: %s\nScanner: com.hp.scan.ica.module3.pkg 4.28.1.210907\nTransport: com.hp.DeviceModel.5.pkg 5.17.0.210923\nValidation: HP signatures, ARM64 slices, native dependency preflight\nHardware scanning: not tested by staging\n' \
    "$SHA256" > "$PRIVATE/result/source.txt"
/bin/mkdir -p "$(/usr/bin/dirname "$OUTPUT")"
# A concurrent stage must not turn mv into an unintended directory merge.
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || die "Output appeared while staging: $OUTPUT"
/bin/mv "$PRIVATE/result" "$OUTPUT"
printf 'Native scanner staged: %s\nSignatures and ARM64 dependency preflight passed. No system installation performed.\n' "$OUTPUT"
