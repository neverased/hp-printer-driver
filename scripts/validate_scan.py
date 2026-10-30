#!/usr/bin/env python3
"""Validate a complete, non-interlaced 8-bit scanner PNG without modifying it."""
import argparse
import json
from pathlib import Path
import struct
import sys
import zlib


class InvalidScan(ValueError):
    pass


def validate_png(path):
    data = Path(path).read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise InvalidScan("not a PNG file")
    position = 8
    header = None
    physical = None
    compressed = bytearray()
    seen_idat = False
    idat_closed = False
    ended = False
    while position < len(data):
        if position + 12 > len(data):
            raise InvalidScan("truncated PNG chunk")
        size = struct.unpack_from(">I", data, position)[0]
        kind = data[position + 4:position + 8]
        end = position + 12 + size
        if end > len(data):
            raise InvalidScan("truncated PNG chunk data")
        payload = data[position + 8:position + 8 + size]
        recorded_crc = struct.unpack_from(">I", data, position + 8 + size)[0]
        if zlib.crc32(kind + payload) != recorded_crc:
            raise InvalidScan(f"CRC mismatch in {kind.decode('ascii', errors='replace')}")
        if header is None and kind != b"IHDR":
            raise InvalidScan("IHDR must be the first chunk")
        if kind == b"IHDR":
            if header is not None or size != 13:
                raise InvalidScan("invalid or repeated IHDR")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            if idat_closed:
                raise InvalidScan("IDAT chunks must be consecutive")
            seen_idat = True
            compressed.extend(payload)
        elif kind == b"pHYs":
            if size != 9 or physical is not None or seen_idat:
                raise InvalidScan("invalid, repeated, or misplaced pHYs")
            physical = struct.unpack(">IIB", payload)
            if physical[2] not in (0, 1):
                raise InvalidScan("invalid pHYs unit")
        elif kind == b"IEND":
            if size != 0 or end != len(data):
                raise InvalidScan("invalid IEND or trailing data")
            ended = True
        elif not kind[0] & 0x20 and kind != b"PLTE":
            raise InvalidScan(f"unsupported critical chunk {kind.decode('ascii', errors='replace')}")
        if seen_idat and kind != b"IDAT":
            idat_closed = True
        position = end
    if not ended or header is None or not compressed:
        raise InvalidScan("missing IHDR, image data, or IEND")
    width, height, depth, color, compression, filtering, interlace = header
    if width == 0 or height == 0:
        raise InvalidScan("image dimensions must be positive")
    if (depth, compression, filtering, interlace) != (8, 0, 0, 0) or color not in (0, 2):
        raise InvalidScan("only non-interlaced RGB8 or Gray8 PNG scans are supported")
    channels = 3 if color == 2 else 1
    expected = (width * channels + 1) * height
    if expected > 512 * 1024 * 1024:
        raise InvalidScan("decoded scan exceeds the 512 MiB validation limit")
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(compressed, expected + 1)
    except zlib.error as error:
        raise InvalidScan(f"invalid zlib image stream: {error}") from error
    if not decoder.eof:
        raise InvalidScan("incomplete zlib image stream")
    if decoder.unused_data or decoder.unconsumed_tail:
        raise InvalidScan("extra compressed image data")
    if len(pixels) != expected:
        raise InvalidScan(f"scanline byte count is {len(pixels)}; expected {expected}")
    stride = width * channels + 1
    if any(pixels[offset] > 4 for offset in range(0, expected, stride)):
        raise InvalidScan("invalid scanline filter")
    dpi_x = dpi_y = None
    if physical is not None and physical[2] == 1:
        dpi_x, dpi_y = (round(value * 0.0254, 4) for value in physical[:2])
    return {"valid": True, "width": width, "height": height,
            "bit_depth": depth, "color_type": color, "pixel_bytes": width * height * channels,
            "dpi_x": dpi_x, "dpi_y": dpi_y}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        report = validate_png(args.path)
    except (OSError, InvalidScan) as error:
        print(f"Invalid scan: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
