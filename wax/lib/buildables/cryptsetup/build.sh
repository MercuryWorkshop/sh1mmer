#!/usr/bin/env bash

# this script is finicky but known to work on Debian 12, assuming you have all the libs installed
# see https://gitlab.com/cryptsetup/cryptsetup/-/issues/386 :)

set -e

CROSS=
STRIP=strip
if ! [ -z "$1" ]; then
	CROSS="--host=${1}"
	STRIP="${1}-strip"
fi

rm -rf libdevmapper
mkdir libdevmapper
DEVMAPPERDIR="$(realpath libdevmapper)"

if ! [ -d lvm2 ]; then
	git clone -n https://gitlab.com/lvmteam/lvm2
	cd lvm2
	git checkout v2_03_22
else
	cd lvm2
	make clean
fi

./configure --enable-static-link --enable-pkgconfig --disable-selinux --prefix="$DEVMAPPERDIR" "$CROSS"
make install_device-mapper
cd ..

if ! [ -d cryptsetup-repo ]; then
	git clone -n https://gitlab.com/cryptsetup/cryptsetup cryptsetup-repo
	cd cryptsetup-repo
	git checkout v2.7.0
else
	cd cryptsetup-repo
	make clean
fi

./autogen.sh
./configure --enable-static-cryptsetup --disable-selinux --disable-asciidoc PKG_CONFIG_PATH="$DEVMAPPERDIR/lib/pkgconfig" CFLAGS="-I$DEVMAPPERDIR/include" LDFLAGS="-Wl,-rpath-link,$DEVMAPPERDIR/lib" "$CROSS"
make cryptsetup.static
"$STRIP" -s cryptsetup.static
cp cryptsetup.static ../cryptsetup
