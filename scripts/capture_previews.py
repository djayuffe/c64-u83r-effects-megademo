#!/usr/bin/env python3
"""Capture one genuine VICE framebuffer PNG for every compiled demo effect.

Requires VICE x64sc with the binary monitor (VICE 3.6+) and Python 3.
The script builds a preview PRG with START_PART set, waits for it to run, then
gets VICE's indexed framebuffer and palette over a localhost-only connection.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
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


def query_display(
    port: int, addresses: dict[str, int]
) -> tuple[bytes, list[tuple[int, int, int]], tuple[int, int, int, int], dict[str, int]]:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.settimeout(10)
        connection.sendall(packet(0x82, b"", 1))
        bank_reply = response(connection, 0x82, 1)
        bank_count = struct.unpack_from("<H", bank_reply, 0)[0]
        offset = 2
        banks: dict[str, int] = {}
        for _ in range(bank_count):
            item_size = bank_reply[offset]
            bank_id = struct.unpack_from("<H", bank_reply, offset + 1)[0]
            name_length = bank_reply[offset + 3]
            name = bank_reply[offset + 4:offset + 4 + name_length].decode("ascii")
            banks[name.lower()] = bank_id
            offset += item_size + 1
        if "io" not in banks:
            raise RuntimeError(f"VICE did not expose an I/O memory bank: {sorted(banks)}")

        def read_byte(address: int, request_id: int, bank: int = 0) -> int:
            body = b"\x00" + struct.pack("<HHB", address, address, 0) + struct.pack("<H", bank)
            connection.sendall(packet(0x01, body, request_id))
            reply = response(connection, 0x01, request_id)
            if struct.unpack_from("<H", reply, 0)[0] != 1:
                raise RuntimeError(f"VICE did not return one byte from ${address:04x}")
            return reply[2]

        io_registers = {"vic_irq_enable", "ctrl1", "ctrl2", "memptr", "cia2_pra", "cia2_ddr"}
        runtime = {
            name: read_byte(address, request_id, banks["io"] if name in io_registers else 0)
            for request_id, (name, address) in enumerate(addresses.items(), start=2)
        }
        request_id = len(runtime) + 2
        connection.sendall(packet(0x84, b"\x01\x00", request_id))
        display = response(connection, 0x84, request_id)
        request_id += 1
        connection.sendall(packet(0x91, b"\x01", request_id))
        palette_reply = response(connection, 0x91, request_id)

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
    return bytes(cropped), palette, (inner_width, inner_height, debug_width, debug_height), runtime


def symbol_address(label_file: Path, symbol: str) -> int:
    match = re.search(rf"^\s*{re.escape(symbol)}\s*=\s*\$([0-9a-fA-F]+)", label_file.read_text(), re.MULTILINE)
    if not match:
        raise RuntimeError(f"missing {symbol} in {label_file}")
    return int(match.group(1), 16)


def verify_runtime(effect_index: int, runtime: dict[str, int], irq_address: int) -> None:
    """Assert the C64 state that protects boot, IRQ, VIC mode, and bank use."""
    if runtime["part"] != effect_index:
        raise RuntimeError(f"preview selected part {runtime['part']}, expected {effect_index}")
    if runtime["frame"] == 0 or runtime["local_tick"] == 0:
        raise RuntimeError(
            "preview did not advance its IRQ/effect loop: "
            f"frame={runtime['frame']}, local_tick={runtime['local_tick']}"
        )
    if runtime["cpu_port"] != 0x37:
        raise RuntimeError(f"CPU port is ${runtime['cpu_port']:02x}, expected $37")
    vector = runtime["irq_vector_lo"] | (runtime["irq_vector_hi"] << 8)
    if vector != irq_address:
        raise RuntimeError(f"IRQ vector is ${vector:04x}, expected ${irq_address:04x}")
    if runtime["vic_irq_enable"] & 0x01 == 0:
        raise RuntimeError("raster IRQ is not enabled in $d01a")
    if runtime["cia2_ddr"] & 0x03 != 0x03:
        raise RuntimeError(f"CIA2 bank-select pins are not outputs: $dd02=${runtime['cia2_ddr']:02x}")

    text_mode = effect_index < 14 or (effect_index == 15 and runtime["local_tick"] & 0x08)
    expected_bank = 0x03 if text_mode else 0x01
    expected_ctrl1 = 0x1B if text_mode else 0x3B
    expected_vic_mode = 0x00 if text_mode else 0x01
    mode_name = "text bank 0" if text_mode else "bitmap bank 2"
    if runtime["vic_mode"] != expected_vic_mode:
        raise RuntimeError(f"{mode_name} has VICMode=${runtime['vic_mode']:02x}")
    if runtime["cia2_pra"] & 0x03 != expected_bank:
        raise RuntimeError(f"{mode_name} selected CIA2 bank ${runtime['cia2_pra'] & 0x03:02x}")
    if runtime["ctrl1"] & 0x7F != expected_ctrl1:
        raise RuntimeError(f"{mode_name} selected $d011=${runtime['ctrl1']:02x}")
    # VICE exposes undocumented/read-only bits in VIC registers.  Only mask
    # the bits that select the display mode and memory pointers.
    if runtime["ctrl2"] & 0x18 != 0x08 or runtime["memptr"] & 0xF8 != 0x18:
        raise RuntimeError(
            f"{mode_name} selected $d016/${runtime['ctrl2']:02x} and $d018/${runtime['memptr']:02x}"
        )


def load_and_run_preview(port: int, program: Path) -> None:
    """Load a PRG and enter its documented BASIC SYS command in VICE.

    Starting at $4000 by changing the CPU's program counter bypasses BASIC's
    normal JSR frame.  That frame matters because the program chains its IRQ
    through the KERNAL.  Feed the same `SYS 16384` command as a real user
    instead, so the preview exercises the actual boot and interrupt contract.
    """
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
        command = b"SYS 16384\r"
        connection.sendall(packet(0x72, bytes((len(command),)) + command, request_id))
        response(connection, 0x72, request_id)
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
    labels = ROOT / "build" / "previews" / f"effect-{effect_index}.labels"
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
        addresses = {
            "part": symbol_address(labels, "Part"),
            "frame": symbol_address(labels, "Frame"),
            "local_tick": symbol_address(labels, "LocalTick"),
            "vic_mode": symbol_address(labels, "VICMode"),
            "cpu_port": 0x0001,
            "irq_vector_lo": 0x0314,
            "irq_vector_hi": 0x0315,
            "vic_irq_enable": 0xD01A,
            "ctrl1": 0xD011,
            "ctrl2": 0xD016,
            "memptr": 0xD018,
            "cia2_pra": 0xDD00,
            "cia2_ddr": 0xDD02,
        }
        pixels, palette, dimensions, runtime = query_display(port, addresses)
        verify_runtime(effect_index, runtime, symbol_address(labels, "IRQ_Main"))
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
