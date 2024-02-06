#!/usr/bin/env bash

set -e

CROSS="CROSS="
[ -z "$1" ] || CROSS+="${1}-"
if ! [ -d vitetris-repo ]; then
	git clone -n https://github.com/vicgeralds/vitetris vitetris-repo
	cd vitetris-repo
	git checkout 9bbea4f5ab35d6fb8fe70c14daba19e7f35ab44e
	git apply ../vitetris.patch
else
	cd vitetris-repo
	make clean
fi
rm -f src/src-conf.mk
make "$CROSS"
cp vitetris ..
