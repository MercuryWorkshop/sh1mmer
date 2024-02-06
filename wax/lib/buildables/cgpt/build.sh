#!/usr/bin/env bash

set -e

CROSS=
STRIP=strip
if ! [ -z "$1" ]; then
	CROSS="CC=${1}-gcc"
	STRIP="${1}-strip"
fi
if ! [ -d vboot_reference ]; then
	git clone -n https://chromium.googlesource.com/chromiumos/platform/vboot_reference
	cd vboot_reference
	git checkout 39fb62013e4019575ed2ff7f5114058639f7f4e7
else
	cd vboot_reference
	make clean
fi
make cgpt STATIC=1 USE_FLASHROM=0 "${CROSS:-ASDFGHJKLQWER=stfu}"
"$STRIP" -s build/cgpt/cgpt
cp build/cgpt/cgpt ..
