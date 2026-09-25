#!/usr/bin/env python3
"""Static invariants for the single-source C64 U83R effects megademo."""

from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
source = (root / "c64_u83r_effects_megademo.s").read_text()
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def byte_table_count(name: str) -> int:
    match = re.search(rf"^{name}:\s*!byte\s+([^\n]+)$", source, re.MULTILINE)
    if not match:
        errors.append(f"missing {name} table")
        return 0
    return len([item for item in match.group(1).split(",") if item.strip()])


require("!cpu 6502" in source, "6502 target declaration missing")
require("* = $0801" in source and "* = $4000" in source, "BASIC loader or $4000 runtime origin missing")
require("NUM_PARTS   = 16" in source, "demo must define 16 active effects")
require("RISKY_BITMAP_FIRST = 14" in source, "risky bitmap effects must be confined to parts 14 and 15")
require("BITMAP_SCREEN = $8400" in source and "BITMAP_BASE   = $a000" in source, "VIC bank-2 bitmap layout changed")
require("!if * > $8000" in source, "missing code/data guard below VIC bank 2")
require("sta CPU_PORT" in source and "lda #$33" in source, "character ROM copy mapping is missing")
require("jsr ExitRiskyModeClean" in source, "risky-mode exit contract is not used")
require("jsr ForceVICForCurrentPart" in source, "IRQ must restore the VIC setup for the active part")
require("jmp $ea31" in source, "IRQ must return through the KERNAL IRQ epilogue")

for table in ("InitLo", "InitHi", "UpdLo", "UpdHi", "DurLo", "DurHi", "MusicStart"):
    require(byte_table_count(table) == 16, f"{table} must have exactly 16 entries")

for label in ("TV_Init:", "CO_Init:", "BR_Init:", "WG_Init:", "GT_Init:", "QS_Init:", "PL_Init:", "NE_Init:", "HF_Init:", "FI_Init:", "RT_Init:", "OD_Init:", "MR_Init:", "SC_Init:", "BM_Init:", "BS_Init:"):
    require(label in source, f"missing effect initializer {label}")

if errors:
    print("FAIL")
    print("\n".join(f"- {error}" for error in errors))
    raise SystemExit(1)

print("PASS: source defines 16 dispatchable effects and preserves the IRQ/VIC-bank safety contract.")
