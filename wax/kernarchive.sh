#!/usr/bin/env bash

set -e

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

missing_deps=$(check_deps sfdisk sgdisk tar)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

[ -z "$2" ] && fail "Usage: kernarchive.sh <device> <archive.tar>"
[ -b "$1" -o -f "$1" ] || fail "$1 doesn't exist or is not a file or block device"
[ -r "$1" ] || fail "Cannot read $1, try running as root?"
sfdisk -l "$1" 2>/dev/null | grep -q "Disklabel type: gpt" || fail "$1 is not GPT, or is corrupted"

sector_size=$(sfdisk -l "$1" 2>/dev/null | grep "Sector size" | awk '{print $4}')
table=$(sfdisk -d "$1" 2>/dev/null | grep "^$1")

out=$(mktemp -d)
[ -z "$SUDO_USER" ] || USER="$SUDO_USER"

for part in $(echo "$table" | awk '{print $1}'); do
	entry=$(echo "$table" | grep "^${part}\s")
	sectors=$(echo "$entry" | grep -o "size=[^,]*" | awk -F '[ =]' '{print $NF}')
	type=$(echo "$entry" | grep -o "type=[^,]*" | awk -F '[ =]' '{print $NF}' | tr '[:lower:]' '[:upper:]')
	if [ "$type" = "FE3A2A5D-4F32-41A7-B725-ACCC3285A309" ] && [ "$sectors" -gt 1 ]; then
		start=$(echo "$entry" | grep -o "start=[^,]*" | awk -F '[ =]' '{print $NF}')
		partnum=$(echo "$entry" | awk '{print $1}' | grep -o "[0-9]*$")
		name=$(echo "$entry" | grep -o "name=[^,]*" | awk -F '"' '{print $2}')
		[ -z "$name" ] || name+=.
		filename="${out}/${partnum}.${name}bin"
		touch "$filename"
		chown "$USER:$USER" "$filename"
		dd if="$1" of="$filename" bs="$sector_size" skip="$start" count="$sectors" status=progress
	fi
done

tar -cf "$2" -C "$out" .
rm -rf "$out"

echo "Done."
