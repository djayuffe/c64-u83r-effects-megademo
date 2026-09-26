#!/usr/bin/env python3
"""Capture one genuine VICE framebuffer PNG for every compiled demo effect.

Requires VICE x64sc with the binary monitor (VICE 3.6+) and Python 3.
The script builds a preview PRG with START_PART set, waits for it to run, then
gets VICE's indexed framebuffer and palette over a localhost-only connection.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "effects"
EFFECTS = [
    "01-tunnelvoyager",
    "02-perspective-corridor",
    "03-vector-starburst",
    "04-warp-grid",
    "05-gate-runner",
    "06-quantum-stars",
    "07-quantum-plasma",
    "08-neon-lightning",
    "09-hyper-warp-field",
    "10-fire-ice-moire",
    "11-raster-temple",
    "12-ocean-depth",
    "13-mirror-rune-tunnel",
    "14-sine-city-scanner",
    "15-hires-bitmap-plasma",
    "16-bitmap-text-bank-switch",
]


def packet(command: int, body: bytes, request_id: int) -> bytes:
    return b"\x02\x02" + struct.pack("<I", len(body)) + struct.pack("<I", request_id) + bytes((command,)) + body


def read_exact(connection: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = connection.recv(count - len(chunks))
        if not chunk:
            raise RuntimeError("VICE closed the binary-monitor connection")
        chunks.extend(chunk)
    return bytes(chunks)


def response(connection: socket.socket, expected_type: int, request_id: int) -> bytes:
    while True:
        header = read_exact(connection, 12)
        if header[:2] != b"\x02\x02":
            raise RuntimeError(f"invalid VICE monitor header: {header.hex()}")
        length = struct.unpack_from("<I", header, 2)[0]
        response_type, error = header[6], header[7]
        response_id = struct.unpack_from("<I", header, 8)[0]
        body = read_exact(connection, length)
        if response_id == request_id:
            if error:
                raise RuntimeError(f"VICE monitor error {error:#x} for command {expected_type:#x}")
            if response_type != expected_type:
                raise RuntimeError(f"VICE returned response {response_type:#x}, expected {expected_type:#x}")
            return body


def query_display(port: int) -> tuple[bytes, list[tuple[int, int, int]], tuple[int, int, int, int]]:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.settimeout(10)
        connection.sendall(packet(0x84, b"\x01\x00", 1))
        display = response(connection, 0x84, 1)
        connection.sendall(packet(0x91, b"\x01", 2))
        palette_reply = response(connection, 0x91, 2)

    fields = struct.unpack_from("<IHHHHHHBI", display, 0)
    field_len, debug_width, debug_height, x_offset, y_offset, inner_width, inner_height, bits, data_len = fields
    if bits != 8 or data_len != debug_width * debug_height:
        raise RuntimeError(f"unexpected VICE framebuffer: {debug_width}x{debug_height}, {bits}bpp, {data_len} bytes")
    image = display[field_len:field_len + data_len]
    if len(image) != data_len:
        raise RuntimeError(
            f"truncated VICE display response: fields={field_len}, bytes={len(display)}, expected={data_len}"
        )

    count = struct.unpack_from("<H", palette_reply, 0)[0]
    offset = 2
    palette: list[tuple[int, int, int]] = []
    for _ in range(count):
        item_size = palette_reply[offset]
        offset += 1
        if item_size != 3:
            raise RuntimeError(f"unexpected VICE palette item length {item_size}")
        palette.append(tuple(palette_reply[offset:offset + 3]))
        offset += item_size
    if len(palette) < 16:
        raise RuntimeError("VICE supplied an incomplete C64 palette")

    cropped = bytearray()
    for y_coord in range(y_offset, y_offset + inner_height):
        start = y_coord * debug_width + x_offset
        cropped.extend(image[start:start + inner_width])
    return bytes(cropped), palette, (inner_width, inner_height, debug_width, debug_height)


def query_memory(port: int, start: int, end: int) -> bytes:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.settimeout(10)
        body = b"\x00" + struct.pack("<HHB", start, end, 0) + b"\x00\x00"
        connection.sendall(packet(0x01, body, 1))
        reply = response(connection, 0x01, 1)
    length = struct.unpack_from("<H", reply, 0)[0]
    contents = reply[2:2 + length]
    if len(contents) != end - start + 1:
        raise RuntimeError(f"VICE returned {len(contents)} bytes for ${start:04x}-${end:04x}")
    return contents


def load_and_run_preview(port: int, program: Path) -> None:
    """Load a PRG through VICE's monitor and start it at its SYS entrypoint."""
    prg = program.read_bytes()
    load_address = struct.unpack_from("<H", prg, 0)[0]
    payload = prg[2:]
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.settimeout(10)
        request_id = 1
        for offset in range(0, len(payload), 4096):
            chunk = payload[offset:offset + 4096]
            start = load_address + offset
            end = start + len(chunk) - 1
            body = b"\x00" + struct.pack("<HHB", start, end, 0) + b"\x00\x00" + chunk
            connection.sendall(packet(0x02, body, request_id))
            response(connection, 0x02, request_id)
            request_id += 1
        # Main-memory PC is register ID 3 in VICE's C64 monitor. The program's
        # BASIC stub calls SYS 16384, so use that same verified entrypoint.
        set_pc = b"\x00" + struct.pack("<H", 1) + bytes((3, 3)) + struct.pack("<H", 0x4000)
        connection.sendall(packet(0x32, set_pc, request_id))
        response(connection, 0x31, request_id)
        request_id += 1
        connection.sendall(packet(0xAA, b"", request_id))
        response(connection, 0xAA, request_id)


def png(path: Path, pixels: bytes, palette: list[tuple[int, int, int]], width: int, height: int) -> None:
    raw = bytearray()
    for row in range(height):
        raw.append(0)
        for pixel in pixels[row * width:(row + 1) * width]:
            raw.extend(palette[pixel])

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    content = b"\x89PNG\r\n\x1a\n"
    content += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    content += chunk(b"IDAT", zlib.compress(bytes(raw), level=9))
    content += chunk(b"IEND", b"")
    path.write_bytes(content)


def capture(effect_index: int, x64sc: str) -> Path:
    subprocess.run(["sh", "scripts/build_preview.sh", str(effect_index)], cwd=ROOT, check=True)
    port = 16502 + effect_index
    prg = ROOT / "build" / "previews" / f"effect-{effect_index}.prg"
    process = subprocess.Popen(
        [x64sc, "-sounddev", "dummy", "-binarymonitor", "-binarymonitoraddress",
         f"ip4://127.0.0.1:{port}"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        # VICE's binary monitor pauses emulation on connection. Let the C64
        # boot first, then place the checked PRG in RAM and use its SYS entry.
        time.sleep(1.0)
        if process.poll() is not None:
            raise RuntimeError(f"VICE exited with code {process.returncode}")
        load_and_run_preview(port, prg)
        time.sleep(3.0)
        state = query_memory(port, 0x53C9, 0x53CE)
        if state[3] == 0:
            raise RuntimeError(f"preview did not receive a raster IRQ: state={state.hex()}")
        pixels, palette, dimensions = query_display(port)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    width, height, _, _ = dimensions
    OUT.mkdir(parents=True, exist_ok=True)
    output = OUT / f"{EFFECTS[effect_index]}.png"
    png(output, pixels, palette, width, height)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--effect", type=int, action="append", help="zero-based effect index to capture; may be repeated")
    parser.add_argument("--x64sc", default=shutil.which("x64sc"), help="path to VICE x64sc")
    arguments = parser.parse_args()
    if not arguments.x64sc:
        raise SystemExit("x64sc was not found; install VICE or pass --x64sc PATH")
    indices = arguments.effect if arguments.effect is not None else list(range(len(EFFECTS)))
    if any(index < 0 or index >= len(EFFECTS) for index in indices):
        raise SystemExit("effect indexes must be in 0..15")
    for index in indices:
        print(capture(index, arguments.x64sc))


if __name__ == "__main__":
    main()
