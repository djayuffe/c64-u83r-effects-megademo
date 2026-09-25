#!/usr/bin/env python3
"""Verify the ACME output's C64 BASIC loader and safe program extent."""

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: verify_prg.py PATH_TO_PRG")

payload = Path(sys.argv[1]).read_bytes()
expected = bytes((0x01, 0x08, 0x0C, 0x08, 0x0A, 0x00, 0x9E, 0x31, 0x36, 0x33, 0x38, 0x34, 0x00, 0x00, 0x00))
if not payload.startswith(expected):
    raise SystemExit("FAIL: expected a BASIC $0801 loader for SYS 16384")
load_address = int.from_bytes(payload[:2], "little")
end_address = load_address + len(payload) - 2
if end_address >= 0x8000:
    raise SystemExit(f"FAIL: assembled program crosses into VIC bank 2 (${end_address:04x})")
if len(payload) < 20000:
    raise SystemExit(f"FAIL: assembled program is unexpectedly small ({len(payload)} bytes)")
print(f"PASS: {sys.argv[1]} is {len(payload)} bytes, loads at $0801, SYSes $4000, and ends at ${end_address:04x}.")
