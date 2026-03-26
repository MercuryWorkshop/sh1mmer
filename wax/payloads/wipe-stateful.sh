#!/bin/bash

set -e

get_largest_blockdev() {
    local largest size dev_name tmp_size remo
    size=0
    for blockdev in /sys/block/*; do
        dev_name="${blockdev##*/}"
        echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
        tmp_size=$(cat "$blockdev"/size)
        remo=$(cat "$blockdev"/removable)
        if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
            largest="/dev/$dev_name"
            size="$tmp_size"
        fi
    done
    echo "$largest"
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

# --- Main Script Logic ---

cros_dev="$(get_largest_cros_blockdev)"
if [ -z "$cros_dev" ]; then
    echo "No CrOS SSD found on device!"
    exit 1
fi

stateful="$(format_part_number "$cros_dev" 1)"

echo "This will erase all user data on ${stateful}"
echo "Continue? (y/N)"
read -r action

case "$action" in
    [yY]) 
        :
        ;;
    *) 
        echo "Exiting..."
        exit 1 
        ;;
esac

mkfs.ext4 -F -b 4096 -L H-STATE "$stateful"