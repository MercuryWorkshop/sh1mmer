#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -eE

SCRIPT_DATE="2025-12-13"

echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ Welcome to wax, a shim modifying automation tool                │"
echo "│ Credits: CoolElectronics, Sharp_Jack, r58playz, Rafflesia, OlyB │"
echo "│ Script date: $SCRIPT_DATE                                         │"
echo "└─────────────────────────────────────────────────────────────────┘"

[ "$EUID" -ne 0 ] && fail "Please run as root"
missing_deps=$(check_deps partx sgdisk mkfs.ext4 mkfs.ext2 tune2fs e2fsck resize2fs file numfmt pv tar)
[ -n "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

cleanup() {
	[ -d "$MNT_ROOT" ] && umount "$MNT_ROOT" && rmdir "$MNT_ROOT"
	[ -d "$MNT_BOOTLOADER" ] && umount "$MNT_BOOTLOADER" && rmdir "$MNT_BOOTLOADER"
	[ -d "$MNT_SH1MMER" ] && umount "$MNT_SH1MMER" && rmdir "$MNT_SH1MMER"
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	trap - EXIT INT
}

detect_arch() {
	MNT_ROOT=$(mktemp -d)
	mount -o ro "${LOOPDEV}p3" "$MNT_ROOT"

	TARGET_ARCH=x86_64
	if [ -f "$MNT_ROOT/bin/bash" ]; then
		case "$(file -b "$MNT_ROOT/bin/bash" | awk -F ', ' '{print $2}' | tr '[:upper:]' '[:lower:]')" in
			# for now assume arm has aarch64 kernel
			*aarch64* | *armv8* | *arm*) TARGET_ARCH=aarch64 ;;
		esac
	fi
	log_info "Detected architecture: $TARGET_ARCH"

	umount "$MNT_ROOT"
	rmdir "$MNT_ROOT"
}

patch_bootloader() {
	log_info "Creating bootloader partition ($(format_bytes $BOOTLOADER_PART_SIZE))"
	local sector_size=$(get_sector_size "$LOOPDEV")
	cgpt_add_auto "$IMAGE" "$LOOPDEV" 4 $((BOOTLOADER_PART_SIZE / sector_size)) -t rootfs -l ROOT-A
	suppress mkfs.ext2 -F -b 4096 -L ROOT-A "${LOOPDEV}p4"

	safesync

	MNT_BOOTLOADER=$(mktemp -d)
	mount "${LOOPDEV}p4" "$MNT_BOOTLOADER"

	mkdir -p "$MNT_BOOTLOADER/bin" "$MNT_BOOTLOADER/root" "$MNT_BOOTLOADER/etc/init"

	log_info "Copying bootloader payload"
	[ -d "$BOOTLOADER_DIR/noarch" ] && cp -R "$BOOTLOADER_DIR/noarch/"* "$MNT_BOOTLOADER"
	[ -d "$BOOTLOADER_DIR/$TARGET_ARCH" ] && cp -R "$BOOTLOADER_DIR/$TARGET_ARCH/"* "$MNT_BOOTLOADER"
	chmod -R +x "$MNT_BOOTLOADER"

	umount "$MNT_BOOTLOADER"
	rmdir "$MNT_BOOTLOADER"
}

patch_sh1mmer() {
	log_info "Creating SH1MMER partition ($(format_bytes $SH1MMER_PART_SIZE))"
	local sector_size=$(get_sector_size "$LOOPDEV")
	cgpt_add_auto "$IMAGE" "$LOOPDEV" 1 $((SH1MMER_PART_SIZE / sector_size)) -t data -l SH1MMER
	suppress mkfs.ext4 -F -b 4096 -L SH1MMER "${LOOPDEV}p1"

	safesync

	MNT_SH1MMER=$(mktemp -d)
	mount "${LOOPDEV}p1" "$MNT_SH1MMER"

	mkdir -p "$MNT_SH1MMER/dev_image/etc" "$MNT_SH1MMER/dev_image/factory/sh"
	touch "$MNT_SH1MMER/dev_image/etc/lsb-factory"

	log_info "Copying main payload"
	[ -d "$PAYLOAD_DIR" ] && cp -R "$PAYLOAD_DIR/"* "$MNT_SH1MMER"
	chmod -R +x "$MNT_SH1MMER"

	if [ -n "$EXTRA_PAYLOAD_DIR" ]; then
		log_info "Copying extra payload"
		mkdir -p "$MNT_SH1MMER/root/noarch/payloads"
		cp -R "$EXTRA_PAYLOAD_DIR/"* "$MNT_SH1MMER/root/noarch/payloads"
	fi

	if [ -n "$FIRMWARE_DIR" ]; then
		log_info "Copying firmware"
		mkdir -p "$MNT_SH1MMER/root/noarch/lib/firmware"
		cp -R "$FIRMWARE_DIR/"* "$MNT_SH1MMER/root/noarch/lib/firmware"
	fi

	if [ -n "$MOUNTED_PAYLOAD_DIR" ] && compgen -G "$MOUNTED_PAYLOAD_DIR/"* >/dev/null; then
		log_info "Copying mounted payload"
		mkdir -p "$MNT_SH1MMER/mounted_payloads"
		cp -R "$MOUNTED_PAYLOAD_DIR/"* "$MNT_SH1MMER/mounted_payloads"
	fi

	if [ -n "$CHROMEBREW" ]; then
		log_info "Extracting chromebrew... increase sh1mmer part size if this fails"
		mkdir -p "$MNT_SH1MMER/chromebrew"
		pv "$CHROMEBREW" | tar -xzf - --strip-components=1 -C "$MNT_SH1MMER/chromebrew"
	fi

	umount "$MNT_SH1MMER"
	rmdir "$MNT_SH1MMER"
}

shrink_root() {
	log_info "Shrinking ROOT"

	enable_rw_mount "${LOOPDEV}p3"
	suppress e2fsck -fy "${LOOPDEV}p3"
	suppress resize2fs -M -p "${LOOPDEV}p3"
	disable_rw_mount "${LOOPDEV}p3"

	local sector_size=$(get_sector_size "$LOOPDEV")
	local block_size=$(tune2fs -l "${LOOPDEV}p3" | grep "Block size" | awk '{print $3}')
	local block_count=$(tune2fs -l "${LOOPDEV}p3" | grep "Block count" | awk '{print $3}')

	log_debug "sector size: ${sector_size}, block size: ${block_size}, block count: ${block_count}"

	local original_sectors=$("$CGPT" show -i 3 -s -n -q "$LOOPDEV")
	local original_bytes=$((original_sectors * sector_size))

	local resized_bytes=$((block_count * block_size))
	local resized_sectors=$((resized_bytes / sector_size))

	log_info "Resizing ROOT from $(format_bytes $original_bytes) to $(format_bytes $resized_bytes)"
	"$CGPT" add -i 3 -s "$resized_sectors" "$LOOPDEV"
	partx -u -n 3 "$LOOPDEV"
}

trap 'echo $BASH_COMMAND failed with exit code $?. THIS IS A BUG, PLEASE REPORT!' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

get_flags() {
	load_shflags

	FLAGS_HELP="Usage: $0 -i <path/to/image.bin> [flags]"

	DEFINE_string image "" "Path to factory shim image" "i"

	DEFINE_string payload "bw" "Main payload ('bw' or 'legacy')" "p"

	DEFINE_string payload_dir "" "Custom main payload dir" ""

	DEFINE_string sh1mmer_part_size "72M" "Partition size for payload(s)" "s"

	DEFINE_string extra_payload_dir "${SCRIPT_DIR}/payloads" "Extra payload dir" "e"

	DEFINE_string firmware_dir "${SCRIPT_DIR}/firmware" "Insert firmware from dir" ""

	DEFINE_string mounted_payload_dir "${SCRIPT_DIR}/mounted_payloads" "Mounted payload dir" "m"

	DEFINE_string chromebrew "" "Chromebrew payload (mounted)" ""

	DEFINE_string bootloader_dir "${SCRIPT_DIR}/bootstrap" "Path to bootloader data" ""

	DEFINE_string bootloader_part_size "4M" "Bootloader rootfs partition size" ""

	DEFINE_string arch "" "Force architecture for target device" ""

	DEFINE_boolean debug "$FLAGS_FALSE" "Print debug messages" "d"

	DEFINE_boolean fast "$FLAGS_FALSE" "Fast/dirty build, larger image size" ""

	DEFINE_string finalsizefile "" "Write final image size in bytes to this file" ""

	FLAGS "$@" || exit $?

	if [ -z "$FLAGS_image" ]; then
		flags_help || :
		exit 1
	fi
}

get_flags "$@"
IMAGE="$FLAGS_image"

if [ -b "$IMAGE" ]; then
	log_info "Image is a block device, performance may suffer..."
else
	check_file_rw "$IMAGE" || fail "$IMAGE doesn't exist, isn't a file, or isn't RW"
	check_slow_fs "$IMAGE"
fi
check_gpt_image "$IMAGE" || fail "$IMAGE is not GPT, or is corrupted"

BOOTLOADER_DIR="$FLAGS_bootloader_dir"
[ -d "$BOOTLOADER_DIR" ] || fail "$BOOTLOADER_DIR is not a directory"
log_info "Using bootloader: $BOOTLOADER_DIR"

if [ -n "$FLAGS_payload_dir" ]; then
	PAYLOAD_DIR="$FLAGS_payload_dir"
else
	case "$FLAGS_payload" in
		legacy) PAYLOAD_DIR="${SCRIPT_DIR}/sh1mmer_legacy" ;;
		bw) PAYLOAD_DIR="${SCRIPT_DIR}/sh1mmer_bw" ;;
		*) fail "Invalid payload '$FLAGS_payload'" ;;
	esac
fi
[ -d "$PAYLOAD_DIR" ] || fail "$PAYLOAD_DIR is not a directory"
log_info "Using main payload: $PAYLOAD_DIR"

if [ -n "$FLAGS_extra_payload_dir" ]; then
	EXTRA_PAYLOAD_DIR="$FLAGS_extra_payload_dir"
	[ -d "$EXTRA_PAYLOAD_DIR" ] || fail "$EXTRA_PAYLOAD_DIR is not a directory"
	log_info "Using extra payload: $EXTRA_PAYLOAD_DIR"
fi

if [ -n "$FLAGS_firmware_dir" ]; then
	FIRMWARE_DIR="$FLAGS_firmware_dir"
	[ -d "$FIRMWARE_DIR" ] || fail "$FIRMWARE_DIR is not a directory"
	log_info "Using firmware: $FIRMWARE_DIR"
fi

if [ -n "$FLAGS_mounted_payload_dir" ]; then
	MOUNTED_PAYLOAD_DIR="$FLAGS_mounted_payload_dir"
	[ -d "$MOUNTED_PAYLOAD_DIR" ] || fail "$MOUNTED_PAYLOAD_DIR is not a directory"
	log_info "Using mounted payload: $MOUNTED_PAYLOAD_DIR"
fi

if [ -n "$FLAGS_chromebrew" ]; then
	CHROMEBREW="$FLAGS_chromebrew"
	[ -f "$CHROMEBREW" ] || fail "$CHROMEBREW doesn't exist or isn't a file"
	log_info "Using chromebrew: $CHROMEBREW"
fi

SH1MMER_PART_SIZE=$(parse_bytes "$FLAGS_sh1mmer_part_size") || fail "Could not parse size '$FLAGS_sh1mmer_part_size'"
BOOTLOADER_PART_SIZE=$(parse_bytes "$FLAGS_bootloader_part_size") || fail "Could not parse size '$FLAGS_bootloader_part_size'"

# sane backup table
suppress sgdisk -e "$IMAGE" 2>&1 | sed 's/\a//g'

# todo: add option to use kern/root other than p2/p3 using sgdisk -r 2:X
delete_partitions_except "$IMAGE" 2 3
safesync

log_info "Creating loop device"
LOOPDEV=$(losetup -f)
losetup -P "$LOOPDEV" "$IMAGE"
safesync

if [ -n "$FLAGS_arch" ]; then
	TARGET_ARCH="$FLAGS_arch"
	log_info "Using specified architecture: $TARGET_ARCH"
else
	detect_arch
	safesync
fi

if [ "${FLAGS_fast:-0}" = "${FLAGS_TRUE:-1}" ]; then
	log_info "Fast mode on, skipping shrink/squash"
else
	shrink_root
	safesync

	squash_partitions "$LOOPDEV"
	safesync
fi

patch_bootloader
safesync

suppress sgdisk -r 3:4 "$LOOPDEV"
safesync

patch_sh1mmer
safesync

losetup -d "$LOOPDEV"
safesync

truncate_image "$IMAGE" "$FLAGS_finalsizefile"
safesync

log_info "Done. Have fun!"
trap - EXIT
