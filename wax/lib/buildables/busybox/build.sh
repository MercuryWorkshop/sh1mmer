#!/usr/bin/env bash

set -e

if ! [ -f "$1" -a -r "$1" ]; then
	echo "$1 is not a config file or cannot read" >&2
	echo "optional 2nd argument: cross compile (e.g. aarch64-linux-gnu)" >&2
	exit 1
fi

CROSS="CROSS_COMPILE="
[ -z "$2" ] || CROSS+="${2}-"
[ -f busybox-1.36.1.tar.bz2 ] || wget 'https://busybox.net/downloads/busybox-1.36.1.tar.bz2'
rm -rf busybox-1.36.1
echo "extracting archive..."
tar -xf busybox-1.36.1.tar.bz2
echo "done"
cp "$1" busybox-1.36.1/.config
cd busybox-1.36.1
make busybox "LDFLAGS= -static " "$CROSS"
cp busybox ..
