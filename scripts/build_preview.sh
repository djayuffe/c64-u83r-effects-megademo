#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ] || ! case "$1" in [0-9]|1[0-5]) true;; *) false;; esac; then
    echo "usage: build_preview.sh EFFECT_INDEX (0-15)" >&2
    exit 2
fi

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root_dir"
mkdir -p build/previews
acme --strict-segments -DSTART_PART="$1" -f cbm \
    -o "build/previews/effect-$1.prg" c64_u83r_effects_megademo.s
python3 scripts/verify_prg.py "build/previews/effect-$1.prg"
