#!/usr/bin/env bash

set -e

BLOCK_SIZE=$((4 * 1024 * 1024)) # 4 MiB

fail() {
	printf "%s\n" "$*" >&2
	exit 1
}

readlink /proc/$$/exe | grep -q bash || fail "Please run with bash"

check_deps() {
	for dep in "$@"; do
		command -v "$dep" &>/dev/null || echo "$dep"
	done
}

missing_deps=$(check_deps sfdisk sgdisk)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

[ -z "$2" ] && fail "Usage: gpt2image.sh <device> <gpt_image.bin> [-y]"
[ -b "$1" ] || fail "$1 doesn't exist or is not a block device"
[ -r "$1" ] || fail "Cannot read $1, try running as root?"
sfdisk -l "$1" 2>/dev/null | grep -q "Disklabel type: gpt" || fail "$1 is not GPT, or is corrupted"

buffer=35 # magic number to ward off evil gpt corruption spirits
sector_size=$(sfdisk -l "$1" 2>/dev/null | grep "Sector size" | awk '{print $4}')
final_sector=$(sfdisk -l -o end "$1" 2>/dev/null | grep "^\s*[0-9]" | awk '{print $1}' | sort -nr | head -n 1)
end_bytes=$(((final_sector + buffer) * sector_size))
dd_count=$((((final_sector + 1) * sector_size + BLOCK_SIZE - 1) / BLOCK_SIZE))

echo "Image will be $(numfmt --to=iec-i --suffix=B "$end_bytes")"
if [ ! "$3" = "-y" ]; then
	read -p "Is this ok? (y/N): " confirm
	if [ ! "$(echo "$confirm" | tr "[:upper:]" "[:lower:]")" = "y" ]; then
		echo "Abort."
		exit
	fi
fi

touch "$2"
[ ! -z "$SUDO_USER" ] && USER="$SUDO_USER"
chown "$USER:$USER" "$2"

dd if="$1" of="$2" bs="$BLOCK_SIZE" count="$dd_count" conv=sync status=progress

truncate -s "$end_bytes" "$2"
sgdisk -e "$2" 2>&1 | sed 's/\a//g'

echo "Done."
