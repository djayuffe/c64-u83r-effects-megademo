.PHONY: all build check run clean

all: build

build:
	sh scripts/build.sh

check:
	python3 scripts/validate_source.py

run: build
	x64sc build/c64_u83r_effects_megademo.prg

clean:
	rm -rf build
