#!/bin/bash

[ "$EUID" -ne 0 ] && fail "Not running as root, this shouldn't happen! Failing."

fail() {
    printf "%b\n" "$*" >&2 || :
    sleep 1d
}

get_largest_cros_blockdev() {
    local largest size dev_name tmp_size remo
    size=0
    for blockdev in /sys/block/*; do
        dev_name="${blockdev##*/}"
        echo -e "$dev_name" | grep -q '^\(loop\|ram\)' && continue
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
    echo -e "$largest"
}

format_part_number() {
    echo -n "$1"
    echo "$1" | grep -q '[0-9]$' && echo -n p
    echo "$2"
}

mount /dev/disk/by-label/STATE /mnt/stateful_partition/
cros_dev="$(get_largest_cros_blockdev)"
if [ -z "$cros_dev" ]; then
    echo "No CrOS SSD found on device. Failing."
    sleep 1d
fi
stateful=$(format_part_number "$cros_dev" 1)
mkfs.ext4 -F "$stateful" || fail "Failed to wipe stateful." # This only wipes the stateful partition 
mount "$stateful" /tmp || fail "Failed to mount stateful."
mkdir -p /tmp/unencrypted/PKIMetadata
cp /payloads/PKIMetadata /tmp/unencrypted/ -rvf
chown 1000 /tmp/unencrypted/PKIMetadata -R
rm /tmp/.developer_mode
umount /tmp
crossystem disable_dev_request=1 || fail "Failed to set disable_dev_request."
read -p "Finished! Press enter to reboot."
reboot