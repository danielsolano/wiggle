#!/usr/bin/env python3
"""Regenerates the app icons from assets/wiggle-app.png.

Run this only after changing the logo; the generated icons are committed so a
normal build never needs it. macOS only (uses sips and iconutil), and it relies
on nothing beyond the Python standard library.

Outputs:
  macOS/Resources/AppIcon.icns
  Windows/Resources/Wiggle.ico
"""
import os
import struct
import subprocess
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "assets", "wiggle-app.png")
ICNS = os.path.join(ROOT, "macOS", "Resources", "AppIcon.icns")
ICO = os.path.join(ROOT, "Windows", "Resources", "Wiggle.ico")

ICO_SIZES = [16, 24, 32, 48, 64, 256]


def resize(size, destination):
    subprocess.run(["sips", "-z", str(size), str(size), SOURCE, "--out", destination],
                   check=True, stdout=subprocess.DEVNULL)


def read_rgba(path):
    """Decodes an 8-bit RGBA, non-interlaced PNG into (width, height, rows)."""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG file"
    pos, idat, header = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    width, height, depth, color_type, _, _, interlace = header
    assert (depth, color_type, interlace) == (8, 6, 0), "expected 8-bit RGBA, non-interlaced"

    raw = zlib.decompress(idat)
    bpp, stride = 4, width * 4
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        filter_type = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = row[i - bpp] if i >= bpp else 0
            up = previous[i]
            upper_left = previous[i - bpp] if i >= bpp else 0
            if filter_type == 1:
                row[i] = (row[i] + left) & 0xFF
            elif filter_type == 2:
                row[i] = (row[i] + up) & 0xFF
            elif filter_type == 3:
                row[i] = (row[i] + (left + up) // 2) & 0xFF
            elif filter_type == 4:
                p = left + up - upper_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upper_left)
                predictor = left if pa <= pb and pa <= pc else (up if pb <= pc else upper_left)
                row[i] = (row[i] + predictor) & 0xFF
        rows.append(row)
        previous = row
    return width, height, rows


def bmp_entry(path):
    """Builds the classic 32-bit bitmap payload used for the small ICO sizes."""
    width, height, rows = read_rgba(path)
    pixels = bytearray()
    for row in reversed(rows):  # bitmap rows are stored bottom-up, as BGRA
        for x in range(width):
            r, g, b, a = row[x * 4:x * 4 + 4]
            pixels += bytes((b, g, r, a))
    # 1-bit AND mask, rows padded to 32 bits; all zero because alpha decides.
    mask = bytes(((width + 31) // 32) * 4 * height)
    header = struct.pack("<IiiHHIIiiII", 40, width, height * 2, 1, 32, 0,
                         len(pixels) + len(mask), 0, 0, 0, 0)
    return header + bytes(pixels) + mask


def make_ico(work):
    payloads = []
    for size in ICO_SIZES:
        png = os.path.join(work, "ico-%d.png" % size)
        resize(size, png)
        if size >= 256:
            with open(png, "rb") as f:  # large sizes are stored as PNG
                payloads.append(f.read())
        else:
            payloads.append(bmp_entry(png))

    out = struct.pack("<HHH", 0, 1, len(ICO_SIZES))
    offset = 6 + 16 * len(ICO_SIZES)
    for size, payload in zip(ICO_SIZES, payloads):
        dimension = 0 if size >= 256 else size  # 0 means 256 in the directory
        out += struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(payload), offset)
        offset += len(payload)
    os.makedirs(os.path.dirname(ICO), exist_ok=True)
    with open(ICO, "wb") as f:
        f.write(out + b"".join(payloads))


def make_icns(work):
    iconset = os.path.join(work, "AppIcon.iconset")
    os.makedirs(iconset)
    for points in (16, 32, 128, 256, 512):
        resize(points, os.path.join(iconset, "icon_%dx%d.png" % (points, points)))
        resize(points * 2, os.path.join(iconset, "icon_%dx%d@2x.png" % (points, points)))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", ICNS], check=True)


def main():
    with tempfile.TemporaryDirectory() as work:
        make_icns(work)
        make_ico(work)
    print("Wrote", os.path.relpath(ICNS, ROOT))
    print("Wrote", os.path.relpath(ICO, ROOT))


if __name__ == "__main__":
    main()
