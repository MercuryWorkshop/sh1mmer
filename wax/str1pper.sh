#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -eE

echo "┌────────────────────────────────────────────────────────────────────────────────────┐"
echo "│ str1pper spash text                                                                │"
echo "│ delete any and all payloads from p1 (stateful) on a rma image, squash partitions   │"
echo "│ Credits: OlyB                                                                      │"
echo "│ Prerequisites: gdisk, e2fsprogs must be installed, program must be run as root     │"
echo "└────────────────────────────────────────────────────────────────────────────────────┘"

[ "$EUID" -ne 0 ] && fail "Please run as root"
missing_deps=$(check_deps partx sgdisk mkfs.ext4)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

STATEFUL_SIZE=$((4 * 1024 * 1024)) # 4 MiB

cleanup() {
	[ -d "$MNT_STATE" ] && umount "$MNT_STATE" && rmdir "$MNT_STATE"
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	trap - EXIT INT
}

recreate_stateful() {
	log_info "Recreating STATE"
	local final_sector=$(get_final_sector "$LOOPDEV")
	local sector_size=$(get_sector_size "$LOOPDEV")
	"$CGPT" add "$LOOPDEV" -i 1 -b $((final_sector + 1)) -s $((STATEFUL_SIZE / sector_size)) -t data -l STATE
	partx -u -n 1 "$LOOPDEV"
	suppress mkfs.ext4 -F -L STATE "${LOOPDEV}p1"

	safesync

	MNT_STATE=$(mktemp -d)
	mount "${LOOPDEV}p1" "$MNT_STATE"

	mkdir -p "$MNT_STATE/dev_image/etc" "$MNT_STATE/dev_image/factory/sh"
	touch "$MNT_STATE/dev_image/etc/lsb-factory"

	umount "$MNT_STATE"
	rmdir "$MNT_STATE"
}

trap 'echo $BASH_COMMAND failed with exit code $?. THIS IS A BUG, PLEASE REPORT!' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

get_flags() {
	load_shflags

	FLAGS_HELP="Usage: $0 -i <path/to/image.bin> [flags]"

	DEFINE_string image "" "Path to factory shim image" "i"

	DEFINE_boolean debug "$FLAGS_FALSE" "Print debug messages" "d"

	FLAGS "$@" || exit $?
	# eval set -- "$FLAGS_ARGV" # we don't need this

	if [ -z "$FLAGS_image" ]; then
		flags_help || :
		exit 1
	fi
}

get_flags "$@"
IMAGE="$FLAGS_image"

check_file_rw "$IMAGE" || fail "$IMAGE doesn't exist, isn't a file, or isn't RW"
check_gpt_image "$IMAGE" || fail "$IMAGE is not GPT, or is corrupted"
check_slow_fs "$IMAGE"

suppress "$SFDISK" --delete "$IMAGE" 1
safesync

log_info "Creating loop device"
LOOPDEV=$(losetup -f)
losetup -P "$LOOPDEV" "$IMAGE"
safesync

squash_partitions "$LOOPDEV"
safesync

recreate_stateful
safesync

losetup -d "$LOOPDEV"
safesync

truncate_image "$IMAGE"
safesync

log_info "Done. Have fun!"
trap - EXIT
