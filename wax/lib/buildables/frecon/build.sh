#!/usr/bin/env bash

set -e

CROSS="CROSS_COMPILE="
[ -z "$1" ] || CROSS+="${1}-"
if ! [ -d frecon-repo ]; then
	git clone -n https://chromium.googlesource.com/chromiumos/platform/frecon frecon-repo
	cd frecon-repo
	git checkout 0860239744c1ec759d020d366498b80f029401d3
	git apply ../frecon.patch
else
	cd frecon-repo
	make clean
fi
make all "$CROSS"
cp frecon-lite ..
