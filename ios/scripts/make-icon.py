"""Draws the Pulse app icon (1024 x 1024 PNG) with nothing but the Python standard library.

The icon is the app's main idea in the Mono design: a recovery ring, about two thirds full,
white on black. Run it again after changing the numbers below:

    python ios/scripts/make-icon.py
"""
import math
import os
import struct
import zlib

SIZE = 1024
CENTER = SIZE / 2
RADIUS = 300          # middle of the ring
THICKNESS = 84
FILL = 0.68           # how much of the ring is drawn
TRACK = 38            # gray level of the empty part of the ring (0 = black)
OUT = os.path.join(os.path.dirname(__file__), "..", "Pulse", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset", "icon-1024.png")


def coverage(distance: float) -> float:
    """1 inside the stroke, 0 outside, with a one-pixel soft edge (anti-aliasing)."""
    return max(0.0, min(1.0, THICKNESS / 2 - distance + 0.5))


def pixel(x: int, y: int) -> int:
    dx, dy = x + 0.5 - CENTER, y + 0.5 - CENTER
    from_ring = abs(math.hypot(dx, dy) - RADIUS)
    if from_ring > THICKNESS / 2 + 1:
        return 0
    # Angle measured clockwise from 12 o'clock, 0...1.
    turn = (math.atan2(dx, -dy) / (2 * math.pi)) % 1.0
    white = coverage(from_ring) if turn <= FILL else 0.0
    # Round caps at both ends of the white arc.
    for end in (0.0, FILL):
        angle = end * 2 * math.pi
        cap_x, cap_y = CENTER + RADIUS * math.sin(angle), CENTER - RADIUS * math.cos(angle)
        white = max(white, coverage(math.hypot(x + 0.5 - cap_x, y + 0.5 - cap_y)))
    track = coverage(from_ring) * TRACK
    return int(round(track + (255 - track) * white))


def main() -> None:
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)                                   # PNG filter type "none" for this row
        for x in range(SIZE):
            gray = pixel(x, y)
            rows += bytes((gray, gray, gray))            # RGB, no transparency (App Store rule)

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    with open(OUT, "wb") as handle:
        handle.write(png)
    print(f"wrote {os.path.normpath(OUT)} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
