#!/usr/bin/env python3
"""Acquire a validated PNG from the USB HP Officejet 150 without Rosetta."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

from validate_scan import validate_png


PAPERS = {"A4": (210, 297), "Letter": (215.9, 279.4), "Legal": (215.9, 355.6)}


def select_device(listing):
    """Select exactly one USB L511; never silently scan a different device."""
    matches = []
    for line in listing.splitlines():
        uri = line.strip()
        parsed = urlsplit(uri)
        if parsed.scheme == "hpaio" and not parsed.netloc and parsed.path.lower() == "/usb/officejet_150_mobile_l511":
            matches.append(uri)
    matches = list(dict.fromkeys(matches))
    if not matches:
        raise ValueError("HP Officejet 150 USB scanner not found. Connect USB and close Image Capture.")
    if len(matches) != 1:
        raise ValueError("Multiple HP Officejet 150 scanners found; connect only the intended device.")
    return matches[0]


def check_page(image, paper, dpi):
    """Reject material cropping while allowing up to 2 mm of ADF length variation."""
    width_mm, height_mm = PAPERS[paper]
    for key, millimeters in (("width", width_mm), ("height", height_mm)):
        expected = millimeters * dpi / 25.4
        # Unknown-length ADF output ends at the feeder's detected sheet edge.
        # The real L511 returned A4 1.34 mm shorter than its nominal length.
        # Retain measured pixels, never stretch or pad; width remains strict.
        tolerance = max(3, 2 * dpi / 25.4) if key == "height" else 3
        if abs(image[key] - expected) > tolerance:
            raise ValueError("Incomplete or unexpected page size: {} x {} pixels; expected {} at {} dpi."
                             .format(image["width"], image["height"], paper, dpi))
    for key in ("dpi_x", "dpi_y"):
        if image[key] is None or abs(image[key] - dpi) > 0.1:
            raise ValueError("Scan resolution metadata does not match the requested resolution.")


class ScanCancelled(Exception):
    pass


class ScannerProcess:
    def __init__(self):
        self.cancelled = False

    def cancel(self, _signum, _frame):
        self.cancelled = True

    def run(self, args, env, timeout):
        if self.cancelled:
            raise ScanCancelled()
        process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        def stop_group(signum):
            # A descendant may retain the pipes after the group leader exits.
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + timeout
        stopping = None
        try:
            while True:
                if (self.cancelled or time.monotonic() >= deadline) and stopping is None:
                    stop_group(signal.SIGINT)
                    stopping = time.monotonic()
                if stopping is not None and time.monotonic() - stopping > 5:
                    stop_group(signal.SIGKILL)
                try:
                    stdout, stderr = process.communicate(timeout=0.25)
                    break
                except subprocess.TimeoutExpired:
                    continue
            if self.cancelled:
                raise ScanCancelled()
            if stopping is not None:
                raise ValueError("Scanner timed out; no output file was published.")
            if process.returncode:
                detail = re.sub(r"serial=[^\s\]\"']+", "serial=<REDACTED>", stderr.strip())
                raise ValueError("Scanner failed (exit {}): {}".format(process.returncode, detail[-2000:]))
            return stdout
        finally:
            stop_group(signal.SIGKILL)
            if process.poll() is None:
                process.wait()


def acquire(args, runner):
    runtime = args.runtime.resolve()
    binary = runtime / "prefix/bin/scanimage"
    if not binary.is_file():
        raise ValueError("Native scanner runtime missing. Run scripts/build-sane.sh first.")
    architecture = subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", str(binary)],
                                  capture_output=True, timeout=10)
    if architecture.returncode:
        raise ValueError("Scanner executable has no ARM64 code; Rosetta is not permitted.")
    lock_path = Path.home() / "Library/Caches/local.hp150/scanner.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another scan is running. Wait for it to finish.")
        with tempfile.TemporaryDirectory(prefix="hp150-sane-") as config:
            Path(config, "dll.conf").write_text("hpaio\n")
            env = os.environ.copy()
            env["SANE_CONFIG_DIR"] = config
            listing = runner.run([str(binary), "--formatted-device-list=%d%n"], env, 30)
            device = select_device(listing)
            fd, temporary = tempfile.mkstemp(prefix=".hp150-scan-", suffix=".png", dir=str(args.output.parent))
            os.close(fd)
            try:
                width, height = PAPERS[args.paper]
                runner.run([str(binary), "--device-name", device, "--source=ADF",
                            "--mode=" + args.mode, "--resolution=" + str(args.dpi), "--compression=None",
                            "--length-measurement=Unknown", "-l", "0", "-t", "0",
                            "-x", str(width), "-y", str(height), "--format=png", "--output-file=" + temporary],
                           env, max(180, 120 * (args.dpi / 300) ** 2))
                image = validate_png(temporary)
                check_page(image, args.paper, args.dpi)
                if image["color_type"] != (2 if args.mode == "Color" else 0):
                    raise ValueError("The scan color mode does not match the requested mode.")
                if runner.cancelled:
                    raise ScanCancelled()
                # Publish atomically without replacing a file created during the scan.
                os.link(temporary, args.output)
                return {"path": str(args.output), "width": image["width"], "height": image["height"],
                        "dpi": args.dpi, "mode": args.mode, "paper": args.paper}
            finally:
                Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dpi", type=int, choices=[75, 100, 150, 200, 300, 600], default=300)
    parser.add_argument("--mode", choices=["Color", "Gray"], default="Color")
    parser.add_argument("--paper", choices=["A4", "Letter", "Legal"], default="A4")
    args = parser.parse_args()
    args.output = args.output.absolute()
    if os.path.lexists(args.output):
        parser.error("Output already exists; choose a new filename.")
    if args.output.suffix.lower() != ".png" or not args.output.parent.is_dir():
        parser.error("Choose a new .png file in an existing folder.")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Scanning requires native ARM64 macOS; Rosetta is not permitted.")
    runner = ScannerProcess()
    signal.signal(signal.SIGINT, runner.cancel)
    signal.signal(signal.SIGTERM, runner.cancel)
    try:
        print(json.dumps(acquire(args, runner)))
        return 0
    except ScanCancelled:
        print("Scan cancelled; no output file was published.", file=sys.stderr)
        return 130
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
