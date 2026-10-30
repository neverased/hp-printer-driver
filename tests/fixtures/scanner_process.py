"""Offline subprocess fixture: never opens a scanner or invokes scanimage."""
import argparse
import json
from pathlib import Path
import signal
import sys
import time

parser = argparse.ArgumentParser()
for name in ("runtime", "output", "dpi", "mode", "paper"):
    parser.add_argument("--" + name, required=True)
args = parser.parse_args()

if args.paper == "Letter":
    print("Fixture error hp:/usb/Officejet_150_Mobile_L511?serial=PRIVATE", file=sys.stderr)
    sys.exit(2)

if args.paper == "Legal":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(130))
    Path(args.output + ".started").write_text("ready")
    while True:
        time.sleep(0.05)

if args.paper == "LateSuccess":
    # Publication has committed. A cancellation request cannot undo that result.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

Path(args.output).write_bytes(b"fixture-output")
print(json.dumps(dict(path=args.output, width=2480, height=3507, dpi=int(args.dpi))), flush=True)
if args.paper == "LateSuccess":
    Path(args.output + ".published").write_text("ready")
    time.sleep(5)
    sys.exit(3)  # The test must cancel explicitly, rather than merely wait.
