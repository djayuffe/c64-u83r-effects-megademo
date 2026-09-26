.PHONY: all build check run capture clean

all: build

build:
	sh scripts/build.sh

check:
	python3 scripts/validate_source.py

run: build
	x64sc build/c64_u83r_effects_megademo.prg

capture:
	python3 scripts/capture_previews.py

clean:
	rm -rf build
