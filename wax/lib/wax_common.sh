#!/usr/bin/env bash
# wax common file, this should be sourced

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

SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}

# todo: remove this, move load_shflags, enable_rw_mount, disable_rw_mount here
. "$SCRIPT_DIR/lib/common_minimal.sh"

SFDISK="${SCRIPT_DIR}/lib/sfdisk"
CGPT="${SCRIPT_DIR}/lib/cgpt"
chmod +x "$SFDISK" "$CGPT"

log_debug() {
	echo -e "\x1B[33mDebug: $*\x1b[39;49m" >&2
}

log_info() {
	echo -e "\x1B[32mInfo: $*\x1b[39;49m"
}

format_bytes() {
	numfmt --to=iec-i --suffix=B "$@"
}

check_file_rw() {
	[ -f "$1" -a -r "$1" -a -w "$1" ]
}

check_gpt_image() {
	"$SFDISK" -l "$1" 2>/dev/null | grep -q "Disklabel type: gpt"
}

safesync() {
	sync
	sleep 0.2
}

get_final_sector() {
	"$SFDISK" -l -o end "$1" | grep "^\s*[0-9]" | awk '{print $1}' | sort -nr | head -n 1
}

get_parts() {
	"$CGPT" show -q "$1" | awk '{print $3}'
}

get_parts_physical_order() {
	local part_table=$("$CGPT" show -q "$1")
	local physical_parts=$(awk '{print $1}' <<<"${part_table}" | sort -n)
	for part in $physical_parts; do
		grep "^\s*${part}\s" <<<"${part_table}" | awk '{print $3}'
	done
}

delete_partitions_except() {
	log_info "Deleting partitions"
	local img="$1"
	local to_delete=()
	shift

	for part in $(get_parts "$img"); do
		grep -qw "$part" <<<"$@" || to_delete+=("$part")
	done

	"$SFDISK" --delete "$img" "${to_delete[@]}"
}

squash_partitions() {
	log_info "Squashing partitions"

	for part in $(get_parts_physical_order "$1"); do
		log_debug "$SFDISK" -N "$part" --move-data "$1" '<<<"+,-"'
		"$SFDISK" -N "$part" --move-data "$1" <<<"+,-" || :
	done
}

truncate_image() {
	local buffer=35 # magic number to ward off evil gpt corruption spirits
	local sector_size=$("$SFDISK" -l "$1" | grep "Sector size" | awk '{print $4}')
	local final_sector=$(get_final_sector "$1")
	local end_bytes=$(((final_sector + buffer) * sector_size))

	log_info "Truncating image to $(format_bytes "$end_bytes")"
	truncate -s "$end_bytes" "$1"

	# recreate backup gpt table/header
	sgdisk -e "$1" 2>&1 | sed 's/\a//g'
	# todo: this (sometimes) works: "$SFDISK" --relocate gpt-bak-std "$1"
}
