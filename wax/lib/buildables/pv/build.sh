#!/usr/bin/env bash

set -e

CROSS=
STRIP=strip
if ! [ -z "$1" ]; then
	CROSS="--host=${1}"
	STRIP="${1}-strip"
fi
if ! [ -d pv-repo ]; then
	git clone -n https://codeberg.org/a-j-wood/pv pv-repo
	cd pv-repo
	git checkout v1.8.5
else
	cd pv-repo
	make clean || :
fi
autoreconf -is
./configure --enable-static "$CROSS"
make
"$STRIP" -s pv
cp pv ..
