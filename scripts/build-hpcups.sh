#!/bin/bash
# Build the Officejet 150 renderer for Apple Silicon; never install system files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/hplip-native-print"
VERSION=3.26.6
SOURCE_SHA256=5fb2235a9cb6ec07cb4786c4066b151359c301324d54aaabf69ae7eef35606b3
SOURCE_URL="https://downloads.sourceforge.net/project/hplip/hplip/$VERSION/hplip-$VERSION.tar.gz"
ARCHIVE="$WORK/hplip-$VERSION.tar.gz"
SOURCE="$WORK/hplip-$VERSION"
STAGE="$WORK/stage"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'Run this build on an Apple Silicon Mac in a native arm64 shell.' >&2
  exit 1
fi
for tool in clang clang++ make python3 curl shasum tar gzip lipo otool pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
JPEG_PREFIX="$(pkg-config --variable=prefix libjpeg)"
JPEG_STATIC="$JPEG_PREFIX/lib/libjpeg.a"
if [[ ! -f "$JPEG_STATIC" ]]; then
  echo 'An existing native jpeg-turbo development package with libjpeg.a is required.' >&2
  exit 1
fi
case " $(lipo -archs "$JPEG_STATIC") " in
  *' arm64 '*) ;;
  *) echo 'libjpeg.a does not contain arm64 code.' >&2; exit 1 ;;
esac

mkdir -p "$WORK"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 2 --max-time 180 "$SOURCE_URL" -o "$ARCHIVE.part"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$SOURCE_SHA256" ]]; then
  echo "HPLIP source checksum mismatch: $ARCHIVE" >&2
  exit 1
fi

# Restore the pinned upstream source before applying the portability changes.
tar -xzf "$ARCHIVE" -C "$WORK"
python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
files = (
    "HPCupsFilter.cpp", "SystemServices.cpp", "ModeJpeg.cpp", "ModeJbig.cpp",
    "Utils.cpp", "Hbpl1.cpp", "LJZjStream.cpp",
)
for name in files:
    path = source / "prnt/hpcups" / name
    text = path.read_text()
    old = '#include "utils.h"'
    assert text.count(old) == 1, f"Unexpected upstream include: {name}"
    # On case-insensitive APFS, utils.h incorrectly resolves to local Utils.h.
    path.write_text(text.replace(old, '#include "../../common/utils.h"'))
path = source / "prnt/hpcups/genJPEGStrips.cpp"
text = path.read_text()
assert text.count('#include <malloc.h>') == 1
# stdlib.h already declares the allocation functions used by this source.
path.write_text(text.replace('#include <malloc.h>', '#if !defined(__APPLE__)\n#include <malloc.h>\n#endif'))
# Patch the template before configure, so config.status cannot undo the fix.
path = source / "Makefile.in"
text = path.read_text()
assert "hpcups-utils" in text
path.write_text(text.replace("hpcups-utils", "hpcups-common-utils"))
PY

cd "$SOURCE"
echo "Configuring HPLIP $VERSION for native arm64 printing..."
if ! CC=clang CXX=clang++ CFLAGS='-arch arm64 -O2' CXXFLAGS='-arch arm64 -O2 -std=gnu++14' \
  CPPFLAGS="$(pkg-config --cflags libjpeg)" LDFLAGS="-arch arm64 $(pkg-config --libs-only-L libjpeg)" \
  ./configure --prefix="$WORK/prefix" --enable-hpcups-only-build \
  --disable-network-build --disable-scan-build --disable-gui-build \
  --disable-fax-build --disable-dbus-build --disable-doc-build \
  --disable-foomatic-drv-install --disable-foomatic-ppd-install \
  --disable-foomatic-rip-hplip-install --disable-cups-drv-install \
  --disable-cups-ppd-install --disable-imageProcessor-build \
  > "$WORK/configure.log" 2>&1; then
  tail -60 "$WORK/configure.log" >&2
  exit 1
fi

# The upstream link line includes a Linux-only optional image processor even
# when disabled. Officejet 150 uses pcl3gui, not its ljzjstream code path.
# Link JPEG statically so the installed renderer has no Homebrew dependency.
make clean > "$WORK/clean.log" 2>&1
echo 'Compiling hpcups...'
if ! make -j4 hpcups "hpcups_LDADD=$JPEG_STATIC -lcups -lz" > "$WORK/build.log" 2>&1; then
  tail -70 "$WORK/build.log" >&2
  exit 1
fi
[[ "$(lipo -archs hpcups)" == arm64 ]] || { echo 'Unexpected binary architecture.' >&2; exit 1; }

python3 - <<'PY'
import subprocess
dependencies = subprocess.check_output(["otool", "-L", "hpcups"], text=True).splitlines()[1:]
for line in dependencies:
    path = line.strip().split(" (", 1)[0]
    if not path.startswith(("/usr/lib/", "/System/Library/")):
        raise SystemExit(f"Unexpected non-system runtime dependency: {path}")
PY

mkdir -p "$STAGE/filter" "$STAGE/ppd" "$STAGE/licenses"
cp hpcups "$STAGE/filter/hpcups"
chmod 755 "$STAGE/filter/hpcups"
gzip -dc "ppd/hpcups/hp-officejet_150_mobile_l511.ppd.gz" > "$STAGE/ppd/hp-officejet_150_mobile_l511.ppd"
cp COPYING "$STAGE/licenses/HPLIP-COPYING"
cp "$JPEG_PREFIX/share/doc/libjpeg-turbo/LICENSE.md" "$STAGE/licenses/libjpeg-turbo-LICENSE.md"
cp "$JPEG_PREFIX/share/doc/libjpeg-turbo/README.ijg" "$STAGE/licenses/libjpeg-turbo-README.ijg"

python3 - "$STAGE" "$SOURCE_URL" "$SOURCE_SHA256" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

stage = Path(sys.argv[1])
binary = stage / "filter/hpcups"
ppd = stage / "ppd/hp-officejet_150_mobile_l511.ppd"
manifest = {
    "hplip_version": "3.26.6",
    "source_url": sys.argv[2],
    "source_sha256": sys.argv[3],
    "architecture": "arm64",
    "binary": "filter/hpcups",
    "ppd": "ppd/hp-officejet_150_mobile_l511.ppd",
    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "ppd_sha256": hashlib.sha256(ppd.read_bytes()).hexdigest(),
    "jpeg_version": subprocess.check_output(["pkg-config", "--modversion", "libjpeg"], text=True).strip(),
    "jpeg_linkage": "static",
    "runtime_dependencies": [line.strip().split(" (", 1)[0] for line in subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]],
    "system_installed": False,
    "hardware_print_verified": False,
    "changes": ["Explicit common/utils.h include paths", "Distinct common-utils object filename", "Exclude Linux malloc.h on macOS", "Disable optional ljzjstream ImageProcessor", "Link native system CUPS and static JPEG"],
}
(stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
echo "Built arm64 renderer and model PPD: $STAGE"
echo 'No system driver was installed and no print job was sent.'
