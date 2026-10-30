#!/bin/bash
# Build a native local app; the SANE runtime remains in the repository.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/.build/hplip-native-scan"
APP="$ROOT/.build/HP150 Scanner.app"

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'Build this app on an Apple Silicon Mac in a native arm64 shell.' >&2; exit 1;
}
for source in scan-native.py validate_scan.py; do
  [[ -f "$ROOT/scripts/$source" ]] || { echo "Missing scripts/$source" >&2; exit 1; }
done
[[ -x "$RUNTIME/prefix/bin/scanimage" ]] || {
  echo 'Build the scanner runtime first: scripts/build-sane.sh' >&2; exit 1;
}
PYTHON=''
for candidate in /opt/homebrew/bin/python3 /usr/bin/python3; do
  if [[ -x "$candidate" ]] && /usr/bin/arch -arm64 "$candidate" -c \
      'import platform,sys; assert platform.machine() == "arm64" and sys.version_info >= (3,9)' 2>/dev/null; then
    PYTHON="$candidate"
    break
  fi
done
[[ -n "$PYTHON" ]] || { echo 'Native Python 3.9 or newer is required.' >&2; exit 1; }

mkdir -p "$ROOT/.build"
STAGE="$(mktemp -d "$ROOT/.build/scanner-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
CONTENTS="$STAGE/HP150 Scanner.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
SOURCES=("$ROOT"/app/*.swift "$ROOT"/app/Models/*.swift "$ROOT"/app/Services/*.swift \
         "$ROOT"/app/Stores/*.swift "$ROOT"/app/Views/*.swift)
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "${SOURCES[@]}" -o "$CONTENTS/MacOS/HP150Scanner"
[[ "$(lipo -archs "$CONTENTS/MacOS/HP150Scanner")" == arm64 ]] || {
  echo 'Unexpected app architecture.' >&2; exit 1;
}
cp "$ROOT/scripts/scan-native.py" "$ROOT/scripts/validate_scan.py" "$CONTENTS/Resources/"
"$PYTHON" - "$CONTENTS" "$RUNTIME" "$PYTHON" <<'PY'
import json
from pathlib import Path
import plistlib
import sys
contents = Path(sys.argv[1])
info = {
    "CFBundleExecutable": "HP150Scanner",
    "CFBundleIdentifier": "local.hp150.Scanner",
    "CFBundleName": "HP150 Scanner",
    "CFBundleDisplayName": "HP150 Scanner",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "0.1",
    "CFBundleDevelopmentRegion": "pl",
    "LSMinimumSystemVersion": "14.0",
    "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
(contents / "Resources/runtime.json").write_text(json.dumps({
    "runtimePath": sys.argv[2], "pythonPath": sys.argv[3],
}, indent=2) + "\n")
PY
codesign --force --sign - "$STAGE/HP150 Scanner.app"
codesign --verify --strict "$STAGE/HP150 Scanner.app"
if [[ -e "$APP" ]]; then
  rm -rf "$APP"
fi
mv "$STAGE/HP150 Scanner.app" "$APP"
echo "Built native ARM64 app: $APP"
echo "Local runtime: $RUNTIME"
echo 'The app was not launched and no scanner was accessed.'
