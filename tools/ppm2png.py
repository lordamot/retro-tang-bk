#!/usr/bin/env python3
"""The simulation's frames (sim/out/frame_NNNN.ppm, P6) as PNGs, so a
screen can be looked at.  No PIL: a PNG is zlib and a few struct.packs.

  ppm2png.py sim/out/frame_0072.ppm [...]     -> the same names with .png
  ppm2png.py -s 2 ...                         -> scaled down by 2
"""
import struct, sys, zlib

def read_ppm(path):
    d = open(path, "rb").read()
    parts = d.split(maxsplit=4)
    assert parts[0] == b"P6"
    w, h = int(parts[1]), int(parts[2])
    pix = parts[4] if len(parts) > 4 else b""
    # the split ate one whitespace after the maxval; the data starts right after it
    hdr_len = len(d) - w * h * 3
    return w, h, d[hdr_len:]

def png(path, w, h, rgb, scale):
    ow, oh = w // scale, h // scale
    raw = bytearray()
    for y in range(oh):
        raw.append(0)
        row = rgb[y * scale * w * 3:(y * scale + 1) * w * 3]
        for x in range(ow):
            raw += row[x * scale * 3:x * scale * 3 + 3]
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ow, oh, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(out)

def main():
    a = sys.argv[1:]
    scale = 1
    if a and a[0] == "-s":
        scale = int(a[1]); a = a[2:]
    for f in a:
        w, h, rgb = read_ppm(f)
        png(f[:-4] + ".png", w, h, rgb, scale)
        print(f"{f}: {w}x{h} -> {f[:-4]}.png")

if __name__ == "__main__":
    main()
