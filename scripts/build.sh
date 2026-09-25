#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root_dir"

python3 scripts/validate_source.py
mkdir -p build
acme --strict-segments -f cbm -o build/c64_u83r_effects_megademo.prg c64_u83r_effects_megademo.s
python3 scripts/verify_prg.py build/c64_u83r_effects_megademo.prg
