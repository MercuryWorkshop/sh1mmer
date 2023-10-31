#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -e
if [ "$EUID" -ne 0 ]; then
	echo "Please run as root"
	exit
fi

echo "-------------------------------------------------------------------------------------------------------------"
echo "str1pper spash text"
echo "delete any and all payloads from p1 (stateful) on a rma image,"
echo "squash partitions"
echo "-------------------------------------------------------------------------------------------------------------"

recreate_stateful() {
	log_info "Recreating STATE"
	"$SFDISK" --delete "$loopdev" 1
	local final_sector=$(get_final_sector "$loopdev")
	"$SFDISK" -N 1 -a "$loopdev" <<<"$((final_sector + 1)),4M"
	"$SFDISK" --part-label "$loopdev" 1 STATE
	mkfs.ext4 -F -L STATE "${loopdev}p1"

	safesync

	MNT_STATE=$(mktemp -d)
	mount "${loopdev}p1" "$MNT_STATE"

	mkdir -p "$MNT_STATE/dev_image/etc"
	touch "$MNT_STATE/dev_image/etc/lsb-factory"

	umount "$MNT_STATE"
	rm -rf "$MNT_STATE"
}

squash_partitions() {
	log_info "Squashing partitions"

	for part in $(get_parts_physical_order "$loopdev"); do
		log_debug "$SFDISK" -N "$part" --move-data "$loopdev" '<<<"+,-"'
		"$SFDISK" -N "$part" --move-data "$loopdev" <<<"+,-" || :
	done
}

truncate_image() {
	local img="$1"
	local buffer=35 # magic number to ward off evil gpt corruption spirits
	local sector_size=$("$SFDISK" -l "$img" | grep "Sector size" | awk '{print $4}')
	local final_sector=$(get_final_sector "$img")
	local end_bytes=$(((final_sector + buffer) * sector_size))

	log_info "Truncating image to $(format_bytes ${end_bytes})"
	truncate -s "$end_bytes" "$img"

	# recreate backup gpt table/header
	sgdisk -e "$img" 2>&1 | sed 's/\a//g'
	# todo: this (sometimes) works: "$SFDISK" --relocate gpt-bak-std "$img"
}

log_info "Creating loop device"
loopdev=$(losetup -f)
losetup -P "$loopdev" "$1"

recreate_stateful

safesync

squash_partitions

losetup -d "$loopdev"
safesync
truncate_image "$1"
safesync

log_info "Done. Have fun!"
