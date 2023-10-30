#!/usr/bin/env bash
# wax common file, this should be sourced

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

get_final_sector() {
	local part_table=$("$SFDISK" -l "$1" | grep "^$1")
	part_table="${part_table//$1/}"
	awk '{print $3}' <<<"$part_table" | sort -nr | head -n 1
}
