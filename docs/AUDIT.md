# Audit record

## Archive checks

`effects_replacement_new_effects_fix95.zip` passed `unzip -tq`. Its current FIX95 source assembled successfully with both the supplied build script and `acme --strict-segments`.

The verified input PRG was 21,984 bytes, loaded at `$0801`, and ended at `$5DDF`—well below the bank-2 bitmap memory used at runtime.

## Issues found

1. The archive preserved 33 byte-identical copies of the same 2,793-line source file (`FIX70` through `FIX95`, plus release aliases). None was a distinct release or compatibility implementation.
2. Its root contained multiple equivalent build/run wrappers and mutually stale FIX92–FIX95 documentation.
3. Builds did not use ACME strict segment checks, had no source-level invariant test, and wrote the PRG beside the source.
4. The public-facing README referred to a transient “FIX95” delivery name instead of a stable project identity.

## Corrections

- Reduced the project to one source of truth: `c64_u83r_effects_megademo.s`.
- Replaced duplicated wrappers with `make build`, `make check`, and `make run`.
- Added static validation for 16-part dispatch tables, IRQ/VIC restoration, the character-ROM copy path, and bitmap-bank boundaries.
- Added strict assembly, PRG loader verification, a runtime memory guard, current documentation, and a `.gitignore` for generated files.
- Renamed the project to **C64 U83R Effects Megademo v1.0.0**.

## Existing-repository comparison

The existing `djayuffe/c64-u83r-rul3z-new-effects` repository is a four-effect text-mode program with its own source and source-material bundle. This archive instead contains a single 16-effect program with two bitmap-bank effects. The two are not safe to merge, and this project remains an independent repository.

## Verification after cleanup

```text
PASS: source defines 16 dispatchable effects and preserves the IRQ/VIC-bank safety contract.
PASS: build/c64_u83r_effects_megademo.prg is 21984 bytes, loads at $0801, SYSes $4000, and ends at $5ddf.
```

VICE was not used as a pass/fail check because its macOS graphics backend cannot initialize an unattended display in this environment. Assembly and the source/PRG checks are reproducible; visual timing should be inspected interactively in VICE or on C64 hardware.
