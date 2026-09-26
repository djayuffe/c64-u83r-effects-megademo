# Changelog

## 1.0.1 — 2026-09-26

- Fixed the final bitmap/text switcher so the raster IRQ preserves its intended text phase instead of forcing bitmap mode each frame.
- Hardened the preview runner to boot through the real BASIC `SYS 16384` path and verify the IRQ vector, live update loop, CPU mapping, CIA2 bank pins, and VIC mode selection for every effect.
- Added a verified 16-effect screenshot gallery and `make capture` target.

## 1.0.0 — 2026-09-25

- First clean standalone release of the 16-effect U83R megademo.
- Removed duplicate historical source and wrapper files.
- Added strict build, source validation, PRG verification, documentation, and memory boundary enforcement.
