#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -e

echo "----------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool"
echo "Credits: CoolElectronics, Sharp_Jack, r58playz, Rafflesia, OlyB"
echo "Prerequisites: gdisk, e2fsprogs must be installed, program must be ran as root"
echo "----------------------------------------------------------------------------------------------------"

[ -z "$1" ] && fail "Usage: wax_legacy.sh <image.bin>"
[ "$EUID" -ne 0 ] && fail "Please run as root"
missing_deps=$(check_deps sgdisk mkfs.ext4 e2fsck resize2fs)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"
check_file_rw "$1" || fail "$1 doesn't exist, isn't a file, or isn't RW"
check_gpt_image "$1" || fail "$1 is not GPT, or is corrupted"

SH1MMER_PART_SIZE="32M"
PAYLOAD_DIR="${SCRIPT_DIR}/sh1mmer_legacy"

patch_root() {
	log_info "Making ROOT mountable"
	enable_rw_mount "${loopdev}p3"

	safesync

	log_info "Mounting ROOT"
	MNT_ROOT=$(mktemp -d)
	mount "${loopdev}p3" "$MNT_ROOT"

	log_info "Injecting payload (1/2)"
	mv "$MNT_ROOT/usr/sbin/factory_install.sh" "$MNT_ROOT/usr/sbin/factory_install_backup.sh"
	cp "$PAYLOAD_DIR/factory_bootstrap.sh" "$MNT_ROOT/usr/sbin"
	chmod +x "$MNT_ROOT/usr/sbin/factory_bootstrap.sh"
	# ctrl+u boot unlock
	sed -i "s/exec/pre-start script\nvpd -i RW_VPD -s block_devmode=0\ncrossystem block_devmode=0\nend script\n\nexec/" "$MNT_ROOT/etc/init/startup.conf"

	umount "$MNT_ROOT"
	rm -rf "$MNT_ROOT"
}

patch_sh1mmer() {
	log_info "Creating SH1MMER partition"
	local final_sector=$(get_final_sector "$loopdev")
	"$SFDISK" -N 1 -a "$loopdev" <<<"$((final_sector + 1)),${SH1MMER_PART_SIZE}"
	"$SFDISK" --part-label "$loopdev" 1 SH1MMER
	mkfs.ext4 -F -L SH1MMER "${loopdev}p1"

	safesync

	log_info "Mounting SH1MMER"
	MNT_SH1MMER=$(mktemp -d)
	mount "${loopdev}p1" "$MNT_SH1MMER"

	mkdir -p "$MNT_SH1MMER/dev_image/etc" "$MNT_SH1MMER/dev_image/factory/sh"
	touch "$MNT_SH1MMER/dev_image/etc/lsb-factory"

	log_info "Injecting payload (2/2)"
	cp -r "$PAYLOAD_DIR/root" "$MNT_SH1MMER"
	chmod -R +x "$MNT_SH1MMER/root"

	umount "$MNT_SH1MMER"
	rm -rf "$MNT_SH1MMER"
}

shrink_root() {
	log_info "Shrinking ROOT"
	e2fsck -fy "${loopdev}p3"
	resize2fs -M "${loopdev}p3"

	local sector_size=$("$SFDISK" -l "$loopdev" | grep "Sector size" | awk '{print $4}')
	local block_size=$(tune2fs -l "${loopdev}p3" | grep "Block size" | awk '{print $3}')
	local block_count=$(tune2fs -l "${loopdev}p3" | grep "Block count" | awk '{print $3}')

	log_debug "sector size: ${sector_size}, block size: ${block_size}, block count: ${block_count}"

	local original_sectors=$("$CGPT" show -i 3 -s "$loopdev")
	local original_bytes=$((original_sectors * sector_size))

	local resized_bytes=$((block_count * block_size))
	local resized_sectors=$((resized_bytes / sector_size))

	log_info "Resizing ROOT from $(format_bytes ${original_bytes}) to $(format_bytes ${resized_bytes})"
	"$CGPT" add -i 3 -s "$resized_sectors" "$loopdev"
}

if uname -r | grep -qi microsoft && realpath "$1" | grep -q "^/mnt"; then
	echo "You are attempting to run wax on a file in your windows filesystem."
	echo "Performance would suffer, so please move your file into your linux filesystem (e.g. ~/file.bin)"
	exit 1
fi

# todo: add option to use kern/root other than p2/p3 using sgdisk -r 2:X

delete_partitions_except "$1" 2 3

log_info "Creating loop device"
loopdev=$(losetup -f)
losetup -P "$loopdev" "$1"

patch_root

safesync

shrink_root
squash_partitions "$loopdev"

safesync

patch_sh1mmer

losetup -d "$loopdev"
safesync
truncate_image "$1"
safesync

log_info "Done. Have fun!"
