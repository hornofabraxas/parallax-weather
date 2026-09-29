#!/usr/bin/env python3
"""Emulator screenshot: QEMU monitor screendump, then undo the unlit screen's dimming.

Usage: shot.py <out.png> [scale] [platform]   (finds the running qemu-pebble monitor port itself;
       with a platform, e.g. gabbro, only that emulator's)
`pebble screenshot` does not work with this emulator; the monitor socket does.
"""
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib


def monitor_port(platform=None):
    ps = subprocess.run(["ps", "axww", "-o", "command"], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        if "qemu-pebble" in line and "-monitor" in line and (not platform or f"-machine pebble-{platform} " in line):
            m = re.search(r"-monitor\s+tcp::(\d+)", line)
            if m:
                return int(m.group(1))
    sys.exit("no qemu-pebble with a monitor found")


def screendump(path, platform=None):
    s = socket.create_connection(("127.0.0.1", monitor_port(platform)), 5)
    s.settimeout(1)

    def drain():
        try:
            while s.recv(4096):
                pass
        except socket.timeout:
            pass

    drain()
    s.sendall(f"screendump {path}\n".encode())
    for _ in range(50):  # QEMU writes the file asynchronously
        time.sleep(0.1)
        if os.path.exists(path) and os.path.getsize(path) > 0:
            break
    time.sleep(0.2)
    drain()
    s.close()
    if not os.path.exists(path):
        sys.exit("screendump produced no file")


def read_ppm(path):
    d = open(path, "rb").read()
    # exactly one whitespace byte ends the header; the pixel data may itself start with whitespace
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", d)
    if not m:
        sys.exit("not a P6 screendump")
    w, h = int(m.group(1)), int(m.group(2))
    data = d[m.end():m.end() + w * h * 3]
    if len(data) != w * h * 3:
        sys.exit("truncated screendump")
    return w, h, data


def write_png(path, w, h, rgb, scale):
    rows = b""
    for y in range(h * scale):
        src = rgb[(y // scale) * w * 3:(y // scale + 1) * w * 3]
        row = b"".join(src[x * 3:x * 3 + 3] * scale for x in range(w))
        rows += b"\0" + row
    ch = lambda t, c: struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0))
                           + ch(b"IDAT", zlib.compress(rows, 9)) + ch(b"IEND", b""))


def main():
    out = os.path.abspath(sys.argv[1])
    scale = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    platform = sys.argv[3] if len(sys.argv) > 3 else None
    ppm = os.path.join(tempfile.mkdtemp(), "shot.ppm")
    screendump(ppm, platform)
    w, h, rgb = read_ppm(ppm)
    # the emulator dims the unlit display; scale so the brightest channel is 255 again,
    # then snap to the nearest Pebble level so colours compare exactly with the previews
    mx = max(rgb) or 255
    if mx < 255 and mx not in (100, 99, 101, 180):  # unlit: emery dims to about 100, gabbro to 180
        print("warning: brightest byte is %d, colours may be off by a level" % mx, file=sys.stderr)
    rgb = bytes(min(3, round(v * 255 / mx / 85)) * 85 for v in rgb)
    write_png(out, w, h, rgb, scale)
    print(out, w, h, "max byte", mx)


if __name__ == "__main__":
    main()
