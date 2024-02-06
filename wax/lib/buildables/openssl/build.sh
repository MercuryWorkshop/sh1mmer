#!/usr/bin/env bash

set -e

CROSS=
STRIP=strip
if ! [ -z "$1" ]; then
	CROSS=("--cross-compile-prefix=${1}-" "linux-$(echo "$1" | cut -d- -f1)")
	STRIP="${1}-strip"
fi
if ! [ -d openssl-repo ]; then
	git clone -n https://github.com/openssl/openssl openssl-repo
	cd openssl-repo
	git checkout openssl-3.2.0
else
	cd openssl-repo
	make clean
fi

./Configure -static "${CROSS[@]}"
make build_generated
make apps/openssl
"$STRIP" -s apps/openssl
cp apps/openssl ..
