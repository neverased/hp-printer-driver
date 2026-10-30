#!/usr/bin/env python3
"""Use the native driver for existing HP Officejet 150 USB queues."""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
PPD = Path("/Library/Printers/HP150/HP-Officejet-150.ppd")


def matching_queues(text):
    queues = []
    for line in text.splitlines():
        match = re.fullmatch(r"device for ([^:]+): (\S+)", line)
        if not match:
            continue
        name, uri = match.groups()
        parsed = urlsplit(uri)
        if (parsed.scheme == "usb" and parsed.netloc.lower() == "hp"
                and unquote(parsed.path).lower() == "/officejet 150 mobile l511"):
            queues.append(name)
    return queues


def run(*args):
    return subprocess.check_output(args, text=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Back up PPDs, then apply the native model driver and A4.")
    args = parser.parse_args()
    os.environ["LC_ALL"] = "C"
    queues = matching_queues(run("/usr/bin/lpstat", "-v"))
    if not queues:
        parser.error("No existing HP Officejet 150 Mobile L511 USB queues found.")
    print("Queues: " + ", ".join(queues))
    print(f"Driver: {PPD}; paper: A4")
    if not args.apply:
        print("Preview only. Pass --apply after installing the native renderer.")
        return
    if not PPD.is_file():
        parser.error("Install the native renderer first.")
    for queue in queues:
        if run("/usr/bin/lpstat", "-W", "not-completed", "-o", queue).strip():
            parser.error(f"Queue {queue} has unfinished jobs; wait before reconfiguration.")
    backup = ROOT / "reports" / ("queues-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
    backup.mkdir(parents=True, mode=0o700)
    for queue in queues:
        shutil.copy2(Path("/etc/cups/ppd") / f"{queue}.ppd", backup / f"{queue}.ppd")
    print(f"Original PPDs: {backup}")
    for queue in queues:
        subprocess.run(["/usr/sbin/lpadmin", "-p", queue, "-P", str(PPD), "-o", "PageSize=A4"],
                       check=True, timeout=30)
        print(f"Configured: {queue}")
    print("Default printer, device connections and other queues were preserved.")


if __name__ == "__main__":
    main()
