#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -e

echo "-------------------------------------------------------------------------------------------------------------"
echo "str1pper spash text"
echo "delete any and all payloads from p1 (stateful) on a rma image,"
echo "squash partitions"
echo "-------------------------------------------------------------------------------------------------------------"

[ -z "$1" ] && fail "Usage: str1pper.sh <image.bin>"
[ "$EUID" -ne 0 ] && fail "Please run as root"
missing_deps=$(check_deps sgdisk mkfs.ext4)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"
check_file_rw "$1" || fail "$1 doesn't exist, isn't a file, or isn't RW"
check_gpt_image "$1" || fail "$1 is not GPT, or is corrupted"

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

	mkdir -p "$MNT_STATE/dev_image/etc" "$MNT_STATE/dev_image/factory/sh"
	touch "$MNT_STATE/dev_image/etc/lsb-factory"

	umount "$MNT_STATE"
	rm -rf "$MNT_STATE"
}

log_info "Creating loop device"
loopdev=$(losetup -f)
losetup -P "$loopdev" "$1"

recreate_stateful

safesync

squash_partitions "$loopdev"

losetup -d "$loopdev"
safesync
truncate_image "$1"
safesync

log_info "Done. Have fun!"
