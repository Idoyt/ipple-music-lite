"""Rebuild the login screen's original artwork (standard library only)."""
from pathlib import Path
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Sources/IppleMusicMac/Resources/LoginCovers"
PALETTES = [
    ("192a51", "477891", "ffbd80"), ("222849", "8069b2", "ffd4ad"),
    ("134752", "288978", "fbc888"), ("452646", "bd6469", "fce0a0"),
    ("192e42", "486bad", "ade8dc"), ("363243", "947455", "f5c894"),
    ("303751", "8884ad", "f4e4b0"), ("213d4d", "4d9894", "ffbd9e"),
]


def rgb(code):
    return bytes.fromhex(code)


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def chunk(name, data):
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))


def cover(index, colors):
    dark, light, accent = map(rgb, colors)
    side = 320
    scan = bytearray()
    for row in range(side):
        scan.append(0)
        y = row / side
        for col in range(side):
            x = col / side
            horizon = 0.58 + 0.07 * math.sin(5 * x + index)
            base = mix(dark, light, min(1, 0.15 + y * 0.8 + x * 0.05))
            radius = math.hypot(x - (0.35 + index % 3 * 0.11), y - 0.41)
            if radius < 0.26 and y < horizon:
                base = mix(accent, light, 0.32 * radius / 0.26)
            if y > horizon:
                ridge = 0.5 + 0.5 * math.cos((y - horizon) * 50 + x * 1.2)
                base = mix(dark, light, 0.18 + 0.55 * ridge ** 5)
            scan.extend(base)
    header = struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(scan, 9)) + chunk(b"IEND", b"")


if __name__ == "__main__":
    DEST.mkdir(parents=True, exist_ok=True)
    for index, palette in enumerate(PALETTES):
        name = f"cover-{index + 1:02}"
        (DEST / (name + ".png")).write_bytes(cover(index, palette))
