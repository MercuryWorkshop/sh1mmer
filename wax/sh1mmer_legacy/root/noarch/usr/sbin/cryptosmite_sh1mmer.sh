#!/bin/bash

set -eE

SRC_PATH=/opt/cryptosmite.tar.xz.enc
DEST_PATH=/opt/cryptosmite
EXE="$DEST_PATH"/cryptosmite.sh

rmdir "$DEST_PATH" >/dev/null 2>&1 || :
if ! [ -d "$DEST_PATH" ]; then
	if ! [ -f "$SRC_PATH" ]; then
		echo "$SRC_PATH not found!"
		exit 1
	fi
	mkdir -p "$DEST_PATH"
	echo "Enter password to decrypt cryptosmite."
	echo "YOUR TYPING WILL NOT BE VISIBLE."
	openssl enc -d -aes-256-cbc -pbkdf2 -iter 20000 -in "$SRC_PATH" | tar -xJf - -C "$DEST_PATH" --checkpoint=.100
	echo ""
fi

if ! [ -f "$EXE" ]; then
	echo "$EXE not found!"
	exit 1
fi

chmod +x "$EXE"
cd "$DEST_PATH"
"$EXE" "$@"
