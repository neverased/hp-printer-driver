#!/bin/bash
# Build native USB scanner tools in a fresh local directory; never access USB.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/hplip-native-scan"
HPLIP_VERSION=3.26.6
HPLIP_SHA256=5fb2235a9cb6ec07cb4786c4066b151359c301324d54aaabf69ae7eef35606b3
HPLIP_URL="https://downloads.sourceforge.net/project/hplip/hplip/$HPLIP_VERSION/hplip-$HPLIP_VERSION.tar.gz"
SANE_VERSION=1.4.0
SANE_SHA256=f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72
# Release asset and checksum published by sane-project/backends, release 1.4.0.
SANE_URL='https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-1.4.0.tar.gz'

die() { printf '%s\n' "$*" >&2; exit 1; }
if [[ $# == 2 && "$1" == --output && -n "$2" ]]; then
    WORK="$2"
elif [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]]; then
    echo "Usage: $0 [--output NEW-DIRECTORY]"
    echo 'Builds local ARM64 tools only. Existing output is never overwritten.'
    exit 0
elif [[ $# != 0 ]]; then
    die "Usage: $0 [--output NEW-DIRECTORY]"
fi
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] ||
    die 'Run in a native Apple Silicon macOS shell.'
[[ $EUID != 0 ]] || die 'Build as your normal user, without sudo.'
for tool in clang clang++ make python3 pkg-config curl shasum tar patch lipo otool; do
    command -v "$tool" >/dev/null || die "Missing build tool: $tool"
done
WORK="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).absolute())' "$WORK")"
[[ "$WORK" != *[[:space:]]* ]] || die 'The upstream build requires an output path without whitespace.'
[[ ! -e "$WORK" && ! -L "$WORK" ]] ||
    die "Refusing to overwrite $WORK. Choose a fresh --output directory."
for PATCH in hplip-adf-only-y-extent.patch sane-1.4.0-png-completeness.patch; do
    [[ -f "$ROOT/patches/$PATCH" ]] || die "Missing patch: $PATCH"
done
pkg-config --exists libusb-1.0 libjpeg libpng libtiff-4 ||
    die 'Existing native libusb, jpeg-turbo, libpng and libtiff development packages are required.'
PYTHON_INCLUDE="$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')"
[[ -f "$PYTHON_INCLUDE/Python.h" ]] || die 'Python development headers are required by HPLIP configure.'
PYTHON_INCLUDE_PARENT="$(dirname "$PYTHON_INCLUDE")"
USB_PREFIX="$(pkg-config --variable=prefix libusb-1.0)"
# libusb's header is also tested as <libusb-1.0/libusb.h> by HPLIP configure.
[[ -f "$USB_PREFIX/include/libusb-1.0/libusb.h" ]] || die 'Cannot find the libusb headers.'
for entry in 'libusb-1.0 libusb-1.0.dylib' 'libjpeg libjpeg.dylib' \
             'libpng libpng.dylib' 'libtiff-4 libtiff.dylib'; do
    read -r package library <<< "$entry"
    /usr/bin/lipo -verify_arch arm64 "$(pkg-config --variable=libdir "$package")/$library" ||
        die "$package does not provide a native ARM64 library."
done

mkdir -p "$(dirname "$WORK")"
mkdir "$WORK" # Exclusive claim: preserve any build created concurrently.
PREFIX="$WORK/prefix"
SANE_SOURCE="$WORK/sane-backends-$SANE_VERSION"
HPLIP_SOURCE="$WORK/hplip-$HPLIP_VERSION"

fetch() {
    local URL="$1" HASH="$2" DEST="$3"
    shift 3
    local CACHED
    for CACHED in "$@"; do
        if [[ -f "$CACHED" ]]; then
            cp "$CACHED" "$DEST.part"
            break
        fi
    done
    if [[ ! -f "$DEST.part" ]]; then
        curl --fail --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 20 --max-time 600 --retry 2 "$URL" -o "$DEST.part"
    fi
    printf '%s  %s\n' "$HASH" "$DEST.part" | shasum -a 256 -c -
    mv "$DEST.part" "$DEST"
}
logged() {
    local LOG="$WORK/$1.log"
    shift
    if ! "$@" > "$LOG" 2>&1; then
        tail -60 "$LOG" >&2
        die "Build failed; retained diagnostic log: $LOG"
    fi
}

fetch "$SANE_URL" "$SANE_SHA256" "$WORK/sane-backends-$SANE_VERSION.tar.gz" \
    "$ROOT/.cache/sane-backends-$SANE_VERSION.tar.gz" \
    "$ROOT/.build/hplip-native-scan/sane-backends-$SANE_VERSION.tar.gz"
fetch "$HPLIP_URL" "$HPLIP_SHA256" "$WORK/hplip-$HPLIP_VERSION.tar.gz" \
    "$ROOT/.cache/hplip-$HPLIP_VERSION.tar.gz" \
    "$ROOT/.build/hplip-native-print/hplip-$HPLIP_VERSION.tar.gz"
tar -xzf "$WORK/sane-backends-$SANE_VERSION.tar.gz" -C "$WORK"
tar -xzf "$WORK/hplip-$HPLIP_VERSION.tar.gz" -C "$WORK"

# Exact changes to the pinned sources; fail on unexpected upstream content.
python3 - "$HPLIP_SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
replacements = {
    "scan/sane/OrbliteScan/MacCommon.h": (
        b"#include <CoreFoundation/CFPlugInCOM.h>",
        b"#include <CoreFoundation/CFBase.h> /* Avoid conflicting COM ULONG typedef. */"),
    "scan/sane/hpaio.c": (
        b'#include "orblitei.h"', b'#include "orblitei.h"\n#include "orblite.h"'),
}
for name, (old, new) in replacements.items():
    path = source / name
    data = path.read_bytes()
    if data.count(old) != 1:
        raise SystemExit(f"Unexpected upstream include: {name}")
    path.write_bytes(data.replace(old, new))
for name, header in (("bb_ledm.c", "unistd.h"), ("http.c", "unistd.h"),
                     ("orblite.c", "dlfcn.h")):
    path = source / "scan/sane" / name
    data = path.read_bytes()
    include = f"#include <{header}>".encode()
    if include in data:
        raise SystemExit(f"Unexpected existing include: {name}")
    newline = b"\r\n" if b"\r\n" in data else b"\n"
    path.write_bytes(include + newline + data)
PY
(cd "$HPLIP_SOURCE" && patch --batch --forward -p1 < "$ROOT/patches/hplip-adf-only-y-extent.patch")
(cd "$SANE_SOURCE" && patch --batch --forward -p1 < "$ROOT/patches/sane-1.4.0-png-completeness.patch")

echo 'Building SANE frontend and local loader for ARM64...'
(
    cd "$SANE_SOURCE"
    logged sane-configure env CC=clang CXX=clang++ CFLAGS='-arch arm64 -O2' \
        CXXFLAGS='-arch arm64 -O2' BACKENDS=test \
        CPPFLAGS="$(pkg-config --cflags libpng libtiff-4 libjpeg)" \
        LDFLAGS="-arch arm64 $(pkg-config --libs-only-L libpng libtiff-4 libjpeg)" \
        ./configure --prefix="$PREFIX" --disable-static --disable-preload \
        --without-avahi --without-snmp --without-usb --without-gphoto2 --without-v4l
    logged sane-build make -j4
    # DESTDIR confines even unexpected upstream install destinations to this build.
    logged sane-install make "DESTDIR=$WORK/install-root" install
)
/usr/bin/ditto "$WORK/install-root$PREFIX" "$PREFIX"

echo 'Building the HPLIP USB backend for ARM64...'
(
    cd "$HPLIP_SOURCE"
    logged hplip-configure env CC=clang CXX=clang++ CFLAGS='-arch arm64 -O2' \
        CXXFLAGS='-arch arm64 -O2' \
        CPPFLAGS="-I$PREFIX/include -I$USB_PREFIX/include -I$PYTHON_INCLUDE_PARENT $(pkg-config --cflags libjpeg libusb-1.0)" \
        LDFLAGS="-arch arm64 -L$PREFIX/lib $(pkg-config --libs-only-L libjpeg libusb-1.0)" \
        ./configure --prefix="$PREFIX" --disable-network-build --disable-pp-build \
        --enable-scan-build --disable-gui-build --disable-fax-build --disable-dbus-build \
        --disable-doc-build --disable-hpcups-install --disable-hpijs-install \
        --disable-foomatic-drv-install --disable-foomatic-ppd-install \
        --disable-foomatic-rip-hplip-install --disable-cups-drv-install \
        --disable-cups-ppd-install --disable-imageProcessor-build
    logged hplip-build make -j4 "hplip_confdir=$PREFIX/etc/hp" libsane-hpaio.la
)

# Do not invoke HPLIP's broad installer: copy only the required local runtime.
mkdir -p "$PREFIX/lib/sane" "$PREFIX/etc/hp" "$PREFIX/share/hplip/data/models" \
    "$WORK/config" "$WORK/licenses"
for LIBRARY in libhpip.0.dylib libhpmud.0.dylib libhpipp.0.dylib; do
    cp "$HPLIP_SOURCE/.libs/$LIBRARY" "$PREFIX/lib/$LIBRARY"
done
cp "$HPLIP_SOURCE/.libs/libsane-hpaio.1.so" "$PREFIX/lib/sane/"
cp "$HPLIP_SOURCE/hplip.conf" "$PREFIX/etc/hp/hplip.conf"
cp "$HPLIP_SOURCE/data/models/models.dat" "$PREFIX/share/hplip/data/models/"
printf 'hpaio\n' > "$WORK/config/dll.conf"
printf 'hpaio\n' > "$PREFIX/etc/sane.d/dll.conf"
cp "$HPLIP_SOURCE/COPYING" "$WORK/licenses/HPLIP-COPYING"
cp "$SANE_SOURCE/COPYING" "$WORK/licenses/SANE-COPYING"

python3 - "$WORK" "$ROOT" "$SANE_URL" "$SANE_SHA256" "$HPLIP_URL" "$HPLIP_SHA256" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

work, root = map(Path, sys.argv[1:3])
relative_binaries = ("bin/scanimage", "lib/libsane.1.dylib", "lib/sane/libsane-dll.1.so",
                     "lib/sane/libsane-test.1.so", "lib/sane/libsane-hpaio.1.so",
                     "lib/libhpip.0.dylib", "lib/libhpipp.0.dylib", "lib/libhpmud.0.dylib")
binaries = {}
for relative in relative_binaries:
    path = work / "prefix" / relative
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).strip()
    if architecture != "arm64":
        raise SystemExit(f"Expected ARM64-only artifact: {path}: {architecture}")
    binaries[relative] = {
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "architecture": architecture,
        "dependencies": [line.strip().split(" (", 1)[0] for line in
                         subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True).splitlines()[1:]],
    }
patches = {}
for name in ("hplip-adf-only-y-extent.patch", "sane-1.4.0-png-completeness.patch"):
    patches[name] = hashlib.sha256((root / "patches" / name).read_bytes()).hexdigest()
manifest = {
    "sane_version": "1.4.0", "sane_source_url": sys.argv[3], "sane_source_sha256": sys.argv[4],
    "hplip_version": "3.26.6", "hplip_source_url": sys.argv[5], "hplip_source_sha256": sys.argv[6],
    "prefix": str(work / "prefix"), "config_directory": str(work / "config"),
    "patches_sha256": patches, "binaries": binaries,
    "development_dependencies": {package: subprocess.check_output(
        ["pkg-config", "--modversion", package], text=True).strip()
        for package in ("libusb-1.0", "libjpeg", "libpng", "libtiff-4")},
    "system_installed": False, "usb_accessed_by_build": False, "hardware_scan_verified_by_build": False,
    "runtime_requirement": "Keep this build directory and its native Homebrew dependencies in place.",
}
(work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
echo "Built native scanner tooling: $PREFIX/bin/scanimage"
echo "Local configuration: $WORK/config"
echo 'No system software was installed, no USB devices were queried, and no scan was started.'
echo 'Keep the build directory in place: library paths are absolute and use existing Homebrew dependencies.'
