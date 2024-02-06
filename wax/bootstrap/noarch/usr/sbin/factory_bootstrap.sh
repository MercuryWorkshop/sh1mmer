#!/bin/sh

set -e

new_root="$1"
real_usb_dev="$2"

echo "$0: Preserving /run"
tar -cf - /run | tar -xf - -C "$new_root"

if [ -z "$2" ]; then
	exit
fi

echo "$0: Preserving REAL_USB_DEV"

dest_path="$new_root/mnt/stateful_partition/dev_image/etc/lsb-factory"
mkdir -p "$new_root/mnt/stateful_partition/dev_image/etc"

kern_guid=$(echo "$KERN_ARG_KERN_GUID" | tr '[:lower:]' '[:upper:]')
echo "REAL_USB_DEV=$real_usb_dev" >>"$dest_path"
echo "KERN_ARG_KERN_GUID=$kern_guid" >>"$dest_path"
