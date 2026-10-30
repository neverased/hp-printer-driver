#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify) ;;
  *) echo "Usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

# Quit gracefully so an active scan is cancelled before rebuilding the app.
if pgrep -x HP150Scanner >/dev/null; then
  osascript -e 'tell application id "local.hp150.Scanner" to quit'
  for attempt in {1..50}; do
    pgrep -x HP150Scanner >/dev/null || break
    sleep 0.2
  done
  if pgrep -x HP150Scanner >/dev/null; then
    echo 'The app is still cancelling a scan. Retry after it closes.' >&2
    exit 1
  fi
fi
"$ROOT/scripts/build-scanner-app.sh"
/usr/bin/open -n "$ROOT/.build/HP150 Scanner.app"
case "$MODE" in
  --debug) lldb -n HP150Scanner ;;
  --logs) /usr/bin/log stream --info --style compact --predicate 'process == "HP150Scanner"' ;;
  --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.hp150.Scanner"' ;;
  --verify) sleep 1; pgrep -x HP150Scanner >/dev/null ;;
esac
