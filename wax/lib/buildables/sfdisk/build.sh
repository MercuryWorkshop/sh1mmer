#!/usr/bin/env bash

set -e

CROSS=
STRIP=strip
if ! [ -z "$1" ]; then
	CROSS="--host=${1}"
	STRIP="${1}-strip"
fi
if ! [ -d util-linux ]; then
	git clone -n https://github.com/util-linux/util-linux
	cd util-linux
	git checkout v2.39.3
else
	cd util-linux
	make clean
fi
./autogen.sh
./configure --enable-static-programs=sfdisk "$CROSS"
make sfdisk.static
"$STRIP" -s sfdisk.static
cp sfdisk.static ../sfdisk
