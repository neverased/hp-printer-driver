#!/usr/bin/env python3
"""Read-only checks for the HP Officejet 150 USB setup on macOS."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]


def is_hp150(name):
    return bool(re.search(r"officejet[ _]*150(?:\b|_)", name or "", re.I))


def assess(snapshot):
    """Evaluate collected evidence; readiness means prerequisites, not a paper test."""
    findings = []
    if not snapshot["usb_connected"]:
        findings.append({"code": "usb_not_detected", "detail": "HP Officejet 150 not found on USB."})
    if not snapshot["queues"]:
        findings.append({"code": "queue_missing", "detail": "No USB print queue for HP Officejet 150."})
    for queue in snapshot["queues"]:
        if not is_hp150(queue["model"]):
            findings.append({"code": "wrong_driver", "detail": f'{queue["name"]}: {queue["model"]}'})
        if queue["missing_filters"]:
            findings.append({"code": "filter_missing", "detail": f'{queue["name"]}: {queue["missing_filters"]}'})
        if not queue.get("filter_architectures") and not queue["missing_filters"]:
            findings.append({"code": "filter_architecture_unverified",
                             "detail": f'{queue["name"]}: No native ARM64 print filter was verified.'})
        for path, architectures in queue.get("filter_architectures", {}).items():
            if not {"arm64", "arm64e"}.intersection(architectures):
                findings.append({"code": "filter_not_native_arm64",
                                 "detail": f'{queue["name"]}: {path} has no verified ARM64 executable.'})
    if snapshot["scanners"] is None:
        findings.append({"code": "scanner_unverified", "detail": "Run with --scan to check Image Capture discovery."})
    elif snapshot.get("scanner_enumeration_complete") is not True:
        findings.append({"code": "scanner_discovery_incomplete",
                         "detail": "Image Capture did not finish local discovery; scanner availability is unverified."})
    elif not any(device.get("usbVendorID") == 0x03F0 and device.get("usbProductID") == 0x5012
                 for device in snapshot["scanners"]):
        findings.append({"code": "scanner_not_detected", "detail": "Image Capture did not discover an HP Officejet 150 scanner."})
    for error in snapshot["errors"]:
        findings.append({"code": "probe_failed", "detail": error})
    return {"ready": not findings,
            "meaning": "Discovery and filter architecture only; linked libraries, printing and scanning remain unverified.",
            "findings": findings}


def run(*args, timeout=30):
    return subprocess.run(args, capture_output=True, check=True, timeout=timeout).stdout


def collect(scan=False):
    snapshot = {"os": platform.mac_ver()[0], "architecture": platform.machine(),
                "usb_connected": False, "queues": [], "scanners": None,
                "scanner_enumeration_complete": None, "errors": []}
    try:
        devices = plistlib.loads(run("/usr/sbin/ioreg", "-a", "-r", "-c", "IOUSBHostDevice"))
        # IOUSBHostDevice roots carry the product name; do not persist serials or other USB devices.
        snapshot["usb_connected"] = any(
            device.get("idVendor") == 0x03F0 and is_hp150(device.get("USB Product Name", ""))
            for device in devices)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        snapshot["errors"].append(f"USB probe failed: {type(error).__name__}")
    try:
        queues = run("/usr/bin/lpstat", "-v").decode()
        for line in queues.splitlines():
            match = re.match(r"device for ([^:]+): (usb://\S+)", line)
            if not match:
                continue
            name, uri = match.groups()
            if not is_hp150(unquote(uri)):
                continue
            ppd = Path("/etc/cups/ppd") / f"{name}.ppd"
            content = ppd.read_text(errors="replace")
            model = re.search(r'^\*NickName: "(.*)"', content, re.M)
            filters = re.findall(r'^\*cupsFilter2?: "(.*)"', content, re.M)
            missing = []
            architectures = {}
            for entry in filters:
                executable = entry.split()[-1]
                if executable == "-":
                    continue
                path = Path(executable)
                if not path.is_absolute():
                    path = Path("/usr/libexec/cups/filter") / path
                if not os.access(path, os.X_OK):
                    missing.append(str(path))
                else:
                    try:
                        architectures[str(path)] = run("/usr/bin/lipo", "-archs", str(path)).decode().split()
                    except (OSError, ValueError, subprocess.SubprocessError):
                        # Shell wrappers and unreadable binaries require manual verification.
                        architectures[str(path)] = []
            if not filters:
                missing.append("PPD has no CUPS filter")
            snapshot["queues"].append({"name": name, "model": model.group(1) if model else "unknown",
                                       "missing_filters": missing, "filter_architectures": architectures})
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        snapshot["errors"].append(f"CUPS probe failed: {type(error).__name__}")
    if scan:
        try:
            result = json.loads(run("/usr/bin/xcrun", "swift", str(ROOT / "scripts/discover-scanners.swift"), timeout=120))
            snapshot["scanners"] = result["scanners"]
            snapshot["scanner_enumeration_complete"] = result["localEnumerationCompleted"]
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            snapshot["errors"].append(f"Scanner probe failed: {type(error).__name__}")
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan", action="store_true", help="Also probe local Image Capture scanners (requires Xcode CLI tools).")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Live diagnostics require macOS.")
    # Stable parsing of CUPS output regardless of the user's UI language.
    os.environ["LC_ALL"] = "C"
    snapshot = collect(args.scan)
    assessment = assess(snapshot)
    print(json.dumps({"evidence": snapshot, "assessment": assessment}, indent=2))
    return 0 if assessment["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
