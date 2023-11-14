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

missing_deps=$(check_deps sfdisk sgdisk)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

truncate_image_verbose() {
	if ! [ -f "$1" -a -r "$1" -a -w "$1" ]; then
		echo "$1 doesn't exist, isn't a file, or isn't RW" >&2
		return 1
	fi
	if ! sfdisk -l "$1" 2>/dev/null | grep -q "Disklabel type: gpt"; then
		echo "$1 is not GPT, or is corrupted" >&2
		return 1
	fi

	local old_bytes=$(stat -c "%s" "$1")
	local buffer=35 # magic number to ward off evil gpt corruption spirits
	local sector_size=$(sfdisk -l "$1" | grep "Sector size" | awk '{print $4}')
	local final_sector=$(sfdisk -l -o end "$1" | grep "^\s*[0-9]" | awk '{print $1}' | sort -nr | head -n 1)
	local end_bytes=$(((final_sector + buffer) * sector_size))

	if [ "$old_bytes" -eq "$end_bytes" ]; then
		echo "$1 is already adequately truncated."
		return
	fi
	if [ "$old_bytes" -eq "$((end_bytes - sector_size))" ]; then
		echo "$1 is one sector smaller than the ideal size. Still safe."
		return
	fi
	[ "$old_bytes" -lt "$end_bytes" ] && echo "WARNING: the image is smaller than the ideal size. It may be corrupted." >&2

	echo "Truncating $1 to $(numfmt --to=iec-i --suffix=B "$end_bytes")"

	truncate -s "$end_bytes" "$1"
	sgdisk -e "$1" 2>&1 | sed 's/\a//g'
}

[ -z "$1" ] && fail "Usage: gpttruncate.sh <gpt_image.bin> [gpt_image_2.bin] [...]"

for file in "$@"; do
	truncate_image_verbose "$file" || echo "ERROR truncating ${file}" >&2
done

echo "Done."
