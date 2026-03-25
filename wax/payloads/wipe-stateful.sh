#!/bin/bash

set -e

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

echo "Locating ChromeOS disk..."
cros_dev="$(get_largest_cros_blockdev)"

if [ -z "$cros_dev" ]; then
    echo "No ChromeOS device found!"
    read -p "Press enter..."
    exit 1
fi

stateful="$(format_part_number "$cros_dev" 1)"

echo "WARNING:"
echo "This will wipe stateful on:"
echo "$stateful"
echo "(Make sure this is correct)"

read -p "Type Y to continue: " confirm

if [ "$confirm" != "Y" ] && [ "$confirm" != "y" ]; then
    echo "Cancelled."
    sleep 1
    exit 0
fi

echo "Wiping stateful partition..."
mkfs.ext4 -F -b 4096 -L H-STATE "$stateful"
echo "Stateful has been wiped."
