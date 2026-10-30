#!/bin/bash
# Install only the native-capable HP scanner and its USB transport framework.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if [[ $EUID -ne 0 ]]; then
    printf 'This installer requires root. Review it, then run with sudo.\n' >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_DEST='/Library/Image Capture/Devices/HP Scanner 3.app'
HPDM_DEST='/Library/Printers/hp/Frameworks/HPDM.framework'
LINK_DEST='/Library/Printers/hp/hpio/HPIOPrinterClassDriver.plugin'
LINK_TARGET='/Library/Printers/hp/Frameworks/HPDM.framework/Runtime/HPIOPrinterClassDriver.plugin'
MANIFEST='/Library/Printers/hp/hp150-native-scanner-manifest.txt'
REQUIREMENT='=anchor apple generic and certificate leaf[subject.OU] = "6HB5Y2QTA3"'

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || die "Usage: $0 [HP-package.pkg]"
[[ "$(/usr/bin/uname -s)" == Darwin && "$(/usr/bin/uname -m)" == arm64 ]] ||
    die 'Installation requires a native Apple Silicon macOS shell.'

# Refuse existing bundles, receipts and even dangling links. This installer
# intentionally cannot upgrade or replace someone else's HP installation.
for DEST in "$SCANNER_DEST" "$HPDM_DEST" "$LINK_DEST" "$MANIFEST"; do
    [[ ! -e "$DEST" && ! -L "$DEST" ]] || die "Refusing to overwrite: $DEST"
done
PARENTS=(
    '/Library'
    '/Library/Printers'
    '/Library/Printers/hp'
    '/Library/Printers/hp/Frameworks'
    '/Library/Printers/hp/hpio'
    '/Library/Image Capture'
    '/Library/Image Capture/Devices'
)
for DIRECTORY in "${PARENTS[@]}"; do
    [[ ! -L "$DIRECTORY" ]] || die "Refusing a symlinked parent: $DIRECTORY"
    [[ ! -e "$DIRECTORY" || -d "$DIRECTORY" ]] || die "Not a directory: $DIRECTORY"
done

umask 022
PRIVATE="$(/usr/bin/mktemp -d /private/tmp/hp150-scanner-install.XXXXXX)"
cleanup() {
    STATUS=$?
    /bin/chmod -R u+w "$PRIVATE"
    /bin/rm -r "$PRIVATE"
    if [[ $STATUS -ne 0 && -f "$MANIFEST" ]]; then
        printf 'Installation did not finish. Created paths are recorded in %s\n' "$MANIFEST" >&2
    fi
    return "$STATUS"
}
trap cleanup EXIT

# Never trust a previous user-writable stage when writing system files.
# Re-extract from a private copy of the pinned, signed original package.
if [[ $# -eq 1 ]]; then
    /bin/bash "$ROOT/scripts/stage-native-scanner.sh" "$1" --output "$PRIVATE/stage"
else
    /bin/bash "$ROOT/scripts/stage-native-scanner.sh" --output "$PRIVATE/stage"
fi

CREATED=()
for DIRECTORY in "${PARENTS[@]}"; do
    if [[ ! -d "$DIRECTORY" ]]; then
        /bin/mkdir -m 755 "$DIRECTORY"
        /usr/sbin/chown root:wheel "$DIRECTORY"
        CREATED+=("$DIRECTORY")
    fi
done

# The receipt lists only newly created paths. A bundle entry includes its
# contents; existing parent directories are never included in the receipt.
CREATED+=("$MANIFEST")
printf '%s\n' "${CREATED[@]}" > "$MANIFEST"
/usr/sbin/chown root:wheel "$MANIFEST"
/bin/chmod 644 "$MANIFEST"

copy_bundle() {
    local SOURCE="$1" DEST="$2"
    # Recheck just before mutation; mkdir fails rather than replacing a path
    # which appeared since the initial preflight.
    [[ ! -e "$DEST" && ! -L "$DEST" ]] || die "Destination appeared: $DEST"
    /bin/mkdir -m 755 "$DEST"
    printf '%s\n' "$DEST" >> "$MANIFEST"
    /usr/bin/ditto "$SOURCE" "$DEST"
    /usr/sbin/chown -R root:wheel "$DEST"
    /bin/chmod 755 "$DEST"
    /usr/bin/codesign --verify --deep --strict -R "$REQUIREMENT" "$DEST"
}
copy_bundle "$PRIVATE/stage/HPDM.framework" "$HPDM_DEST"
copy_bundle "$PRIVATE/stage/HP Scanner 3.app" "$SCANNER_DEST"

# This is the sole action of HP's DeviceModel component postinstall script.
[[ -d "$LINK_TARGET" ]] || die "Missing native USB transport plug-in: $LINK_TARGET"
/bin/ln -s "$LINK_TARGET" "$LINK_DEST"
printf '%s\n' "$LINK_DEST" >> "$MANIFEST"
/usr/sbin/chown -h root:wheel "$LINK_DEST"

printf 'Installed native-capable HP scanner and USB transport; HP signatures verified.\nCreated paths: %s\nReconnect USB and reopen Image Capture to test scanning.\n' "$MANIFEST"
