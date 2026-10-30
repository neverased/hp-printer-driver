"""Acquisition tests with a synthetic SANE process boundary; no scanner access."""
import argparse
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "scan-native.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("scan_acquisition", SCRIPT)
scanner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scanner)


def rgb_a4_png():
    """A complete RGB8 A4 image at 75 dpi, small after lossless compression."""
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))

    width, height = 620, 877
    raw = (b"\0" + b"\xff\xff\xff" * width) * height
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"pHYs", struct.pack(">IIB", 2953, 2953, 1))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


class SyntheticScanner:
    cancelled = False

    def __init__(self, png, requested_mode):
        self.png = png
        self.requested_mode = requested_mode

    def run(self, command, _environment, _timeout):
        if "--formatted-device-list=%d%n" in command:
            return "hpaio:/usb/Officejet_150_Mobile_L511?serial=SYNTHETIC\n"
        if "--mode=" + self.requested_mode not in command:
            raise AssertionError("The requested mode was not sent to the scanner boundary")
        output = next(arg.split("=", 1)[1] for arg in command if arg.startswith("--output-file="))
        Path(output).write_bytes(self.png)
        return ""


class ScanAcquisitionTests(unittest.TestCase):
    def test_gray_request_rejects_rgb_result_without_publishing_or_leaving_temporary_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime"
            binary = runtime / "prefix/bin/scanimage"
            binary.parent.mkdir(parents=True)
            binary.write_text("Synthetic runtime: never execute this file.\n")
            output_dir = root / "output"
            output_dir.mkdir()
            existing = output_dir / "keep.txt"
            existing.write_text("unrelated user file")
            output = output_dir / "gray.png"
            args = argparse.Namespace(runtime=runtime, output=output, mode="Gray", paper="A4", dpi=75)

            def architecture_check(command, **_kwargs):
                self.assertEqual(command, ["/usr/bin/lipo", "-verify_arch", "arm64", str(binary.resolve())])
                return subprocess.CompletedProcess(command, 0)

            with patch.object(scanner.Path, "home", return_value=root / "home"), \
                    patch.object(scanner.subprocess, "run", side_effect=architecture_check), \
                    patch.object(scanner.subprocess, "Popen", side_effect=AssertionError("No device processes allowed")):
                with self.assertRaisesRegex(ValueError, "color mode does not match"):
                    scanner.acquire(args, SyntheticScanner(rgb_a4_png(), "Gray"))

            self.assertFalse(output.exists())
            self.assertEqual(sorted(path.name for path in output_dir.iterdir()), ["keep.txt"])
            self.assertEqual(existing.read_text(), "unrelated user file")


if __name__ == "__main__":
    unittest.main()
