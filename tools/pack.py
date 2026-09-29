#!/usr/bin/env python3
"""Packs the planes written by `face export` into the watch's raw resource formats (stdlib only).

Usage: pack.py <export dir> <resources dir> [platform]

With a platform (e.g. gabbro) every file is written with the SDK's platform tag (tex_sunny~gabbro.pl2),
which the SDK picks over the untagged PT2 file when it builds that platform. The moon is shared: its
disc is the same size everywhere, so a tagged export must match it and writes no copy.

Formats (all little endian), read by src/c/engine.h (planes, glyph maps), face.h (Layout) and
sky.h (SkyTables):

  *.pl2  2-bit palettised image: u16 w, u16 h, 4 x GColor8 palette (0b11RRGGBB, darkest first,
         unused entries repeat the last colour), then h rows of ceil(w/4) bytes, leftmost pixel in
         the two most significant bits.
  digit_N.bin  run-length glyph code map: u8 w, u8 h, u8 baseline row, then runs row by row, one
         byte each: code << 4 | (length - 1). A run never crosses a row end.
  layout.bin  int16: 100 x (left x of tens digit, left x of units digit) for pairs "00".."99",
         10 x left x of a single centred digit, then the two row baselines.
  sky.bin  u16 n_grad, u16 n_bloom, then n_grad + n_bloom u16 curve values in Q16 (65535 = 1):
         grad[i] = (i / (n_grad - 1)) ^ 1.3 for screen row i, and bloom[j] = 1 inside the 12 px sun
         disc, else 0.97 exp(-(d - 12) / 44) at d = j / 2 px (skyPlate3() in tools/face.swift).

It also prints what each texture would cost as a 2-bit PNG, for the storage budget.
"""
import json
import math
import os
import struct
import sys
import zlib


def read_u8(path):
    with open(path, "rb") as f:
        d = f.read()
    w, h = struct.unpack_from("<HH", d)
    assert len(d) == 4 + w * h, path
    return w, h, d[4:]


def lum(i):
    r, g, b = (i >> 4) * 85, ((i >> 2) & 3) * 85, (i & 3) * 85
    return 299 * r + 587 * g + 114 * b


def pack_pl2(w, h, px):
    colours = sorted(set(px), key=lambda i: (lum(i), i))
    assert len(colours) <= 4, f"{len(colours)} colours, need at most 4"
    pal = colours + [colours[-1]] * (4 - len(colours))
    index = {c: k for k, c in enumerate(colours)}
    stride = (w + 3) // 4
    rows = bytearray()
    for y in range(h):
        row = bytearray(stride)
        for x in range(w):
            row[x >> 2] |= index[px[y * w + x]] << (6 - 2 * (x & 3))
        rows += row
    return struct.pack("<HH4B", w, h, *[0xC0 | c for c in pal]) + bytes(rows), colours


def png_size(w, h, px, colours):
    """Size of the same image as a minimal 2-bit palettised PNG (no ancillary chunks)."""
    index = {c: k for k, c in enumerate(colours)}
    stride = (w + 3) // 4
    raw = bytearray()
    for y in range(h):
        row = bytearray(stride)
        for x in range(w):
            row[x >> 2] |= index[px[y * w + x]] << (6 - 2 * (x & 3))
        raw += b"\0" + row
    plte = b"".join(bytes(((c >> 4) * 85, ((c >> 2) & 3) * 85, (c & 3) * 85)) for c in colours)
    body = zlib.compress(bytes(raw), 9)
    return 8 + (12 + 13) + (12 + len(plte)) + (12 + len(body)) + 12


def pack_rle(w, h, baseline, codes):
    assert w < 256 and h < 256 and baseline < 256
    out = bytearray(struct.pack("<BBB", w, h, baseline))
    for y in range(h):
        x = 0
        while x < w:
            c = codes[y * w + x]
            n = 1
            while x + n < w and n < 16 and codes[y * w + x + n] == c:
                n += 1
            out.append(c << 4 | (n - 1))
            x += n
    return bytes(out)


def check_round(glyphs, layout, size):
    """Round screens: every hour (00-23) and minute (00-59) keeps its ink at least 1 px inside the circle."""
    c = size / 2
    maps = {g["digit"]: g for g in glyphs}
    pairs, baselines = layout["pairs"], layout["baselines"]
    worst = 0.0
    for row, values in ((0, range(24)), (1, range(60))):
        for v in values:
            for which, d in ((0, v // 10), (1, v % 10)):
                g = maps[d]
                x0, y0 = pairs[v][which], baselines[row] - g["baseline"]
                for y in range(g["h"]):
                    for x in range(g["w"]):
                        if g["codes"][y * g["w"] + x] >= 13:
                            worst = max(worst, math.hypot(x0 + x + 0.5 - c, y0 + y + 0.5 - c))
    assert worst <= c - 1, f"digit ink reaches {worst:.1f} px from the centre of a {size} px round screen"
    print(f"round fit: ink at most {worst:.1f} px from the centre (edge {c:.0f})")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    tag = "~" + sys.argv[3] if len(sys.argv) > 3 else ""
    os.makedirs(dst, exist_ok=True)
    manifest = json.load(open(os.path.join(src, "manifest.json")))
    screen_w, screen_h = manifest["screen"]

    def tagged(name):
        base, ext = os.path.splitext(name)
        return base + tag + ext
    total = 0
    print(f"{'resource':<24}{'raw bytes':>10}{'as PNG':>10}  colours")
    assert manifest["moon"] == {"diameter": 300, "centre": 162}, "src/c/main.c assumes a 300 px disc on a 324 px canvas"
    planes = ["tex_%s.u8" % n for n in ("sunny", "partly", "cloudy", "rain", "snow", "storm", "fog", "partly_night",
                                         "cloudy_night")]
    if not tag:
        planes.append("moon.u8")
    for name in planes:
        w, h, px = read_u8(os.path.join(src, name))
        if name.startswith("tex_"):
            assert (w, h) == (screen_w + 32, screen_h + 32), f"{name}: {w}x{h} is not the screen plus the tilt margin"
        blob, colours = pack_pl2(w, h, px)
        out = tagged(name[:-3] + ".pl2")
        with open(os.path.join(dst, out), "wb") as f:
            f.write(blob)
        total += len(blob)
        hexes = " ".join("%02X%02X%02X" % ((c >> 4) * 85, ((c >> 2) & 3) * 85, (c & 3) * 85) for c in colours)
        print(f"{out:<24}{len(blob):>10}{png_size(w, h, px, colours):>10}  {hexes}")
    for g in manifest["glyphs"]:
        w, h, codes = read_u8(os.path.join(src, "digit_%d.u8" % g["digit"]))
        assert (w, h) == (g["w"], g["h"]) and max(codes) <= 15
        g["codes"] = codes
        blob = pack_rle(w, h, g["baseline"], codes)
        out = tagged("digit_%d.bin" % g["digit"])
        with open(os.path.join(dst, out), "wb") as f:
            f.write(blob)
        total += len(blob)
        print(f"{out:<24}{len(blob):>10}")
    lay = manifest["layout"]
    if tag == "~gabbro":
        assert screen_w == screen_h
        check_round(manifest["glyphs"], lay, screen_w)
    vals = [v for p in lay["pairs"] for v in p] + lay["singles"] + lay["baselines"]
    assert len(vals) == 212, "layout.bin must match sizeof(Layout) in src/c/face.h"
    blob = struct.pack("<%dh" % len(vals), *vals)
    with open(os.path.join(dst, tagged("layout.bin")), "wb") as f:
        f.write(blob)
    total += len(blob)
    print(f"{tagged('layout.bin'):<24}{len(blob):>10}")
    bloom_scale, max_d = 44.0, 360
    grad = [round(65535 * (i / screen_h) ** 1.3) for i in range(screen_h + 1)]
    bloom = [65535 if j / 2 < 12 else round(65535 * 0.97 * math.exp(-(j / 2 - 12) / bloom_scale)) for j in range(2 * max_d)]
    blob = struct.pack("<HH%dH" % (len(grad) + len(bloom)), len(grad), len(bloom), *(grad + bloom))
    with open(os.path.join(dst, tagged("sky.bin")), "wb") as f:
        f.write(blob)
    total += len(blob)
    print(f"{tagged('sky.bin'):<24}{len(blob):>10}")
    if tag:
        print(f"{'(moon.pl2, shared)':<24}{os.path.getsize(os.path.join(dst, 'moon.pl2')):>10}")
        total += os.path.getsize(os.path.join(dst, "moon.pl2"))
    print(f"{'total':<24}{total:>10}")


if __name__ == "__main__":
    main()
