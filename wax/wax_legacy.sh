#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -eE

echo "┌────────────────────────────────────────────────────────────────────────────────────┐"
echo "│ Welcome to wax, a shim modifying automation tool                                   │"
echo "│ Credits: CoolElectronics, Sharp_Jack, r58playz, Rafflesia, OlyB                    │"
echo "│ Prerequisites: gdisk, e2fsprogs must be installed, program must be run as root     │"
echo "└────────────────────────────────────────────────────────────────────────────────────┘"

[ "$EUID" -ne 0 ] && fail "Please run as root"
missing_deps=$(check_deps partx sgdisk mkfs.ext4 mkfs.ext2 e2fsck resize2fs file)
[ -n "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

SH1MMER_PART_SIZE=$((64 * 1024 * 1024)) # 64 MiB
BOOTLOADER_PART_SIZE=$((4 * 1024 * 1024)) # 4 MiB (we want this to be very small)
BOOTLOADER_DIR="${SCRIPT_DIR}/bootstrap"
PAYLOAD_DIR="${SCRIPT_DIR}/sh1mmer_legacy"

cleanup() {
	[ -d "$MNT_ROOT" ] && umount "$MNT_ROOT" && rmdir "$MNT_ROOT"
	[ -d "$MNT_BOOTLOADER" ] && umount "$MNT_BOOTLOADER" && rmdir "$MNT_BOOTLOADER"
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	trap - EXIT INT
}

detect_arch() {
	log_info "Detecting architecture"
	MNT_ROOT=$(mktemp -d)
	mount -o ro "${LOOPDEV}p3" "$MNT_ROOT"

	TARGET_ARCH=x86_64
	if [ -f "$MNT_ROOT/bin/bash" ]; then
		case "$(file -b "$MNT_ROOT/bin/bash" | awk -F ', ' '{print $2}')" in
			# for now assume arm has aarch64 kernel
			*aarch64* | *armv8* | *arm*) TARGET_ARCH=aarch64 ;;
		esac
	fi

	umount "$MNT_ROOT"
	rmdir "$MNT_ROOT"
}

patch_bootloader() {
	log_info "Creating bootloader partition"
	local final_sector=$(get_final_sector "$LOOPDEV")
	local sector_size=$(get_sector_size "$LOOPDEV")
	echo "$final_sector" "$sector_size" $((final_sector + 1)) $((BOOTLOADER_PART_SIZE / sector_size))
	"$CGPT" add "$LOOPDEV" -i 4 -b $((final_sector + 1)) -s $((BOOTLOADER_PART_SIZE / sector_size)) -t rootfs -l ROOT-A
	partx -u -n 4 "$LOOPDEV"
	mkfs.ext2 -F -L ROOT-A "${LOOPDEV}p4"

	safesync

	log_info "Mounting bootloader"
	MNT_BOOTLOADER=$(mktemp -d)
	mount "${LOOPDEV}p4" "$MNT_BOOTLOADER"

	log_info "Injecting payload (1/2)"
	[ -d "$BOOTLOADER_DIR/noarch" ] && cp -R "$BOOTLOADER_DIR/noarch/"* "$MNT_BOOTLOADER"
	[ -d "$BOOTLOADER_DIR/$TARGET_ARCH" ] && cp -R "$BOOTLOADER_DIR/$TARGET_ARCH/"* "$MNT_BOOTLOADER"
	chmod -R +x "$MNT_BOOTLOADER"

	umount "$MNT_BOOTLOADER"
	rmdir "$MNT_BOOTLOADER"
}

patch_sh1mmer() {
	log_info "Creating SH1MMER partition"
	local final_sector=$(get_final_sector "$LOOPDEV")
	local sector_size=$(get_sector_size "$LOOPDEV")
	"$CGPT" add "$LOOPDEV" -i 1 -b $((final_sector + 1)) -s $((SH1MMER_PART_SIZE / sector_size)) -t data -l SH1MMER
	partx -u -n 1 "$LOOPDEV"
	mkfs.ext4 -F -L SH1MMER "${LOOPDEV}p1"

	safesync

	log_info "Mounting SH1MMER"
	MNT_SH1MMER=$(mktemp -d)
	mount "${LOOPDEV}p1" "$MNT_SH1MMER"

	mkdir -p "$MNT_SH1MMER/dev_image/etc" "$MNT_SH1MMER/dev_image/factory/sh"
	touch "$MNT_SH1MMER/dev_image/etc/lsb-factory"

	log_info "Injecting payload (2/2)"
	[ -d "$PAYLOAD_DIR" ] && cp -R "$PAYLOAD_DIR/"* "$MNT_SH1MMER"
	chmod -R +x "$MNT_SH1MMER"

	umount "$MNT_SH1MMER"
	rmdir "$MNT_SH1MMER"
}

shrink_root() {
	log_info "Shrinking ROOT"

	enable_rw_mount "${LOOPDEV}p3"
	e2fsck -fy "${LOOPDEV}p3"
	resize2fs -M "${LOOPDEV}p3"
	disable_rw_mount "${LOOPDEV}p3"

	local sector_size=$(get_sector_size "$LOOPDEV")
	local block_size=$(tune2fs -l "${LOOPDEV}p3" | grep "Block size" | awk '{print $3}')
	local block_count=$(tune2fs -l "${LOOPDEV}p3" | grep "Block count" | awk '{print $3}')

	log_debug "sector size: ${sector_size}, block size: ${block_size}, block count: ${block_count}"

	local original_sectors=$("$CGPT" show -i 3 -s -n -q "$LOOPDEV")
	local original_bytes=$((original_sectors * sector_size))

	local resized_bytes=$((block_count * block_size))
	local resized_sectors=$((resized_bytes / sector_size))

	log_info "Resizing ROOT from $(format_bytes ${original_bytes}) to $(format_bytes ${resized_bytes})"
	"$CGPT" add -i 3 -s "$resized_sectors" "$LOOPDEV"
}

trap 'echo $BASH_COMMAND failed with exit code $?. THIS IS A BUG, PLEASE REPORT!' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

get_flags() {
	load_shflags

	FLAGS_HELP="Usage: $0 -i <path/to/image.bin> [flags]"

	DEFINE_string image "" "Path to factory shim image" "i"

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

if uname -r | grep -qi microsoft && realpath "$IMAGE" | grep -q "^/mnt"; then
	echo "You are attempting to run wax on a file in your windows filesystem."
	echo "Performance would suffer, so please move your file into your linux filesystem (e.g. ~/file.bin)"
	exit 1
fi

# todo: add option to use kern/root other than p2/p3 using sgdisk -r 2:X

delete_partitions_except "$IMAGE" 2 3
safesync

log_info "Creating loop device"
LOOPDEV=$(losetup -f)
losetup -P "$LOOPDEV" "$IMAGE"
safesync

detect_arch
safesync

shrink_root
safesync

squash_partitions "$LOOPDEV"
safesync

patch_bootloader
safesync

sgdisk -r 3:4 "$LOOPDEV"
safesync

patch_sh1mmer
safesync

losetup -d "$LOOPDEV"
safesync

truncate_image "$IMAGE"
safesync

log_info "Done. Have fun!"
trap - EXIT
