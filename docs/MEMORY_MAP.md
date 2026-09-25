# Memory map

| Address range | Purpose |
| --- | --- |
| `$0801–$080F` | BASIC loader (`10 SYS 16384`) |
| `$2000–$27FF` | Generated text charset in VIC bank 0 |
| `$4000–$5DDF` | Program code, state, dispatch tables, and effect data in the verified v1.0.0 build |
| `$8400–$87E7` | Hires bitmap screen memory in VIC bank 2 |
| `$A000–$BFFF` | Hires bitmap pixels in VIC bank 2 |
| `$D000–$D7FF` | VIC-II and SID registers / character-ROM window during initialization |
| `$D800–$DBE7` | Colour RAM |

The two final effects select VIC bank 2 using CIA2. The CPU can write the bitmap RAM under BASIC ROM while `$01` is `$37`; the VIC reads the underlying RAM. `ExitRiskyModeClean` restores the text configuration before any normal text effect is initialized.

`scripts/verify_prg.py` rejects a build that reaches `$8000`, preventing accidental overlap with bitmap-bank memory.
