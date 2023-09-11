#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/common_minimal.sh"

set -e
if [ "$EUID" -ne 0 ]; then
		echo "Please run as root"
		exit
fi

echo "-------------------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool"
echo "Credits: CoolElectronics, Sharp_Jack, r58playz, Rafflesia, OlyB"
echo "Prerequisites: cgpt must be installed, program must be ran as root"
echo "-------------------------------------------------------------------------------------------------------------"
echo "Warning: this is a legacy version of wax. There may be unresolved issues"

PAYLOAD_DIR="sh1mmer_legacy"

SFDISK="lib/sfdisk"
CGPT="cgpt"

debug() {
	echo -e "\x1B[33mDebug: $*\x1b[39;49m" >&2
}

info() {
	echo -e "\x1B[32mInfo: $*\x1b[39;49m"
}

patch_root() {
	info "Making ROOT mountable"
	sh lib/ssd_util.sh --no_resign_kernel --remove_rootfs_verification -i "${loopdev}"

	sync
	sleep 0.2

	info "Mounting ROOT"
	MNT_ROOT=$(mktemp -d)
	mount "${loopdev}p3" "$MNT_ROOT"

	info "Injecting payload (1/2)"
	mv "$MNT_ROOT/usr/sbin/factory_install.sh" "$MNT_ROOT/usr/sbin/factory_install_backup.sh"
	cp "$PAYLOAD_DIR/factory_bootstrap.sh" "$MNT_ROOT/usr/sbin"
	chmod +x "$MNT_ROOT/usr/sbin/factory_bootstrap.sh"
	# ctrl+u boot unlock
	sed -i "s/exec/pre-start script\nvpd -i RW_VPD -s block_devmode=0\ncrossystem block_devmode=0\nend script\n\nexec/" "$MNT_ROOT/etc/init/startup.conf"

	umount "${loopdev}p3"
	rm -rf "$MNT_ROOT"
}

patch_sh1mmer() {
	info "Creating SH1MMER partition"
	local final_sector
	final_sector=$(fdisk -l "${loopdev}" | grep "${loopdev}p3[[:space:]]" | awk '{print $3}')
	"$SFDISK" -N 1 -a "${loopdev}" <<<"$((final_sector + 1)),32M"
	# label partition "SH1MMER"
	"$CGPT" add -i 1 -l SH1MMER "${loopdev}"
	mkfs.ext4 -L SH1MMER "${loopdev}p1" # maybe ext2?

	sync
	sleep 0.2

	info "Mounting SH1MMER"
	MNT_SH1MMER=$(mktemp -d)
	mount "${loopdev}p1" "$MNT_SH1MMER"

	info "Injecting payload (2/2)"
	mkdir -p "$MNT_SH1MMER/dev_image/etc"
	touch "$MNT_SH1MMER/dev_image/etc/lsb-factory"
	cp -r "$PAYLOAD_DIR/root" "$MNT_SH1MMER"
	chmod -R +x "$MNT_SH1MMER/root"

	umount "${loopdev}p1"
	rm -rf "$MNT_SH1MMER"
}

shrink_table() {
	local buffer=$((1024 * 1024)) # 1 MiB buffer. keeps things from breaking too much

	info "Shrinking RootFS"
	e2fsck -fy "${loopdev}p3"
	resize2fs -M "${loopdev}p3"
	local block_size
	block_size=$(tune2fs -l "${loopdev}p3" | grep -i "block size" | awk '{print $3}')
	local sector_size
	sector_size=$(fdisk -l "${loopdev}" | grep "Sector size" | awk '{print $4}')

	local block_count
	block_count=$(tune2fs -l "${loopdev}p3" | grep -i "block count" | awk '{print $3}')
	block_count=${block_count%%[[:space:]]*}

	debug "bs: $block_size, blocks: $block_count"

	local original_sectors=$("$CGPT" show -i 3 -s "${loopdev}")
	local original_bytes=$((original_sectors * sector_size))

	local raw_bytes=$((block_count * block_size))
	local resized_size=$((raw_bytes + buffer))
	local resized_sectors=$((resized_size / sector_size))

	info "Resizing ROOT from $(numfmt --to=iec-i --suffix=B ${original_bytes}) to $(numfmt --to=iec-i --suffix=B ${resized_size})"
	"$CGPT" add -i 3 -s "${resized_sectors}" "${loopdev}"

	info "Squashing partitions"

	local numparts=3
	local numtries=1

	i=0
	while [ $i -le $numtries ]; do
		j=2
		while [ $j -le $numparts ]; do
			debug "$SFDISK" -N $j --move-data "${loopdev}" '<<<"+,-"'
			"$SFDISK" -N $j --move-data "${loopdev}" <<<"+,-" || :
			j=$((j+1))
		done
		i=$((i+1))
	done
}

truncate_image() {
	local buffer=35 # magic number to ward off evil gpt corruption spirits
	local img=$1
	local sector_size
	sector_size=$(fdisk -l "$img" | grep "Sector size" | awk '{print $4}')
	local final_sector
	final_sector=$(fdisk -l "$img" | grep "${img}1[[:space:]]" | awk '{print $3}')
	local end_bytes=$(((final_sector + buffer) * sector_size))

	info "Truncating image to $(numfmt --to=iec-i --suffix=B ${end_bytes})"

	truncate -s "$end_bytes" "$img"
	gdisk "$img" << EOF
w
y
EOF
}

info "Deleting useless partitions"
"$SFDISK" --delete "$1" 1 4 5 6 7 8 9 10 11 12

info "Creating loop device"
loopdev=$(losetup -f)
losetup -P "$loopdev" "$1"

patch_root

sync
sleep 0.2

shrink_table

sync
sleep 0.2

patch_sh1mmer

losetup -d "$loopdev"
sync
sleep 0.2
truncate_image "$1"
sync
sleep 0.2

info "Done. Have fun!"
