import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "validate_scan.py"
SIGNATURE = b"\x89PNG\r\n\x1a\n"


def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data)))


def fixture(*, height=2, compressed=None, raw=None):
    # Two RGB8 pixels per row, filter 0: two rows contain 12 pixel bytes.
    if raw is None:
        raw = b"\0\xff\0\0\0\xff\0\0\0\0\xff\xff\xff\xff"
    if compressed is None:
        compressed = zlib.compress(raw)
    return (SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", compressed) + chunk(b"IEND", b""))


class ScanValidationTests(unittest.TestCase):
    def validate(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scan.png"
            path.write_bytes(data)
            return subprocess.run([sys.executable, str(SCRIPT), str(path)],
                                  text=True, capture_output=True)

    def test_complete_rgb_scan_is_accepted_with_dimensions(self):
        result = self.validate(fixture())
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual((report["width"], report["height"]), (2, 2))
        self.assertEqual(report["pixel_bytes"], 12)

    def test_crc_valid_png_with_iend_but_truncated_zlib_is_rejected(self):
        raw = b"\0" + b"\xff\0\0" * 2 + b"\0" + b"\0\xff\0" * 2
        result = self.validate(fixture(compressed=zlib.compress(raw)[:-2]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete zlib", result.stderr)

    def test_bad_chunk_crc_is_rejected(self):
        data = bytearray(fixture())
        data[29] ^= 1  # IHDR CRC only; pixel data and header are unchanged.
        result = self.validate(data)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CRC", result.stderr)

    def test_complete_zlib_with_missing_advertised_row_is_rejected(self):
        result = self.validate(fixture(height=3))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scanline byte count", result.stderr)

    def test_gray_scan_with_physical_resolution_is_accepted(self):
        data = (SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 0, 0, 0, 0))
                + chunk(b"pHYs", struct.pack(">IIB", 11811, 11811, 1))
                + chunk(b"IDAT", zlib.compress(b"\0\0\xff\0\x80\x40"))
                + chunk(b"IEND", b""))
        result = self.validate(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["color_type"], 0)
        self.assertEqual(report["pixel_bytes"], 4)
        self.assertAlmostEqual(report["dpi_x"], 300, places=2)
        self.assertAlmostEqual(report["dpi_y"], 300, places=2)

    def test_invalid_scanline_filter_is_rejected(self):
        result = self.validate(fixture(raw=b"\xff" + b"\0" * 13))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scanline filter", result.stderr)

    def test_unknown_critical_chunk_is_rejected(self):
        data = fixture()
        result = self.validate(data[:33] + chunk(b"ABCD", b"") + data[33:])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("critical chunk", result.stderr)

    def test_nonconsecutive_idat_chunks_are_rejected(self):
        header = fixture()[:33]
        compressed = zlib.compress(b"\0" * 14)
        data = (header + chunk(b"IDAT", compressed[:4]) + chunk(b"tEXt", b"note\0text")
                + chunk(b"IDAT", compressed[4:]) + chunk(b"IEND", b""))
        result = self.validate(data)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("consecutive", result.stderr)


if __name__ == "__main__":
    unittest.main()
