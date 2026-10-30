#!/bin/bash
# Compile the process service with an offline fixture; never launch the GUI or use USB.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo 'These tests require native ARM64 macOS.' >&2; exit 1;
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
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/hp150-process-tests.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$ROOT/app/Models/ScanSettings.swift" "$ROOT/app/Services/ScannerProcess.swift" \
    "$ROOT/tests/ScannerProcessTests.swift" -o "$TEMP/process-tests"
"$TEMP/process-tests" "$ROOT/tests/fixtures/scanner_process.py" "$PYTHON"
