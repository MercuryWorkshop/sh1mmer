#!/bin/bash

# REQUIREMENTS: cgpt, gparted, sfdisk, jq
# authored by CVFD

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit
fi

# check for cgpt
if ! [[ $(command -v cgpt) ]]; then
    echo "cgpt was not found, please install it!"
    exit
fi

# check for gparted
if ! [[ $(command -v gparted) ]]; then
    echo "gparted was not found, please install it!"
    exit
fi

# check for sfdisk
if ! [[ $(command -v sfdisk) ]]; then
    echo "sfdisk was not found, please install it!"
    exit
fi

# check for jq
if ! [[ $(command -v jq) ]]; then
    echo "jq was not found, please install it!"
    exit
fi

# check that the file passed actually exists
if ! [[ -f $1 ]]; then
    echo "File not found. Make sure you passed the right filename!"
    exit
fi

# check if utf-8 is supported
# if so, fancy title
# if not, unfancy title
if [[ $(locale charmap) == "UTF-8" ]]; then
    echo "┌──────────────────────────┐"
    echo "│  welcome to bds (nano)!  │"
    echo "└──────────────────────────┘"
else
    echo "----------------------------"
    echo "|  welcome to bds (nano)!  |"
    echo "----------------------------"
fi

# clean up in case anything went wrong
rm -rf needed mnt
mkdir needed

loop=$(losetup -f)

# create loop device
echo "Creating loop device on ${loop}..."
losetup -P "${loop}" "$1"

# remove rootfs verification from the shim making it mountable
echo "Making SHIM mountable..."
sh make_dev_ssd_no_resign.sh --remove_rootfs_verification -i "${loop}" 2>/dev/null

echo "Making mount directory..."
mkdir mnt

echo "Mounting partition 3..."
mount "${loop}p3" mnt

until test -f mnt/usr/sbin/factory_install.sh; do :; done

echo "Injecting script..."
cp sh1mpl.sh mnt/usr/sbin/factory_install.sh

sync

echo "Unmounting partition 3..."
umount "${loop}p3"

sleep 1

echo "Mounting partition 1..."
mount "${loop}p1" mnt

echo "Creating directories to grab necessary files..."
mkdir needed/dev_image || :

mkdir needed/dev_image/etc || :

if [ -d "mnt/dev_image/factory/sh/" ]; then
    mkdir needed/dev_image/factory || :

    mkdir needed/dev_image/factory/sh || :

    until test -f mnt/dev_image/etc/lsb-factory; do :; done

    echo "Grabbing necessary files..."
    cp mnt/dev_image/etc/lsb-factory needed/dev_image/etc/lsb-factory

    cp mnt/dev_image/factory/sh/* needed/dev_image/factory/sh/
else
    until test -f mnt/dev_image/etc/lsb-factory; do :; done

    echo "Grabbing necessary files..."
    cp mnt/dev_image/etc/lsb-factory needed/dev_image/etc/lsb-factory
fi

sync

echo "Unmounting partition 1..."
umount "${loop}p1"

echo "Deleting unnecessary partitions..."
sfdisk --delete "${loop}" 1 >/dev/null
sfdisk --delete "${loop}" 4 >/dev/null
sfdisk --delete "${loop}" 5 >/dev/null
sfdisk --delete "${loop}" 6 >/dev/null
sfdisk --delete "${loop}" 7 >/dev/null
sfdisk --delete "${loop}" 8 >/dev/null
sfdisk --delete "${loop}" 9 >/dev/null
sfdisk --delete "${loop}" 10 >/dev/null
sfdisk --delete "${loop}" 11 >/dev/null
sfdisk --delete "${loop}" 12 >/dev/null

echo "Opening gparted. Do the partitioning!"
gparted "${loop}"

echo "Mounting the new partition 1..."
mount "${loop}p1" mnt

echo "Copying necessary files into the new partition 1..."
cp -r needed/* mnt/

sync

echo "Unmounting partition 1..."
umount "${loop}p1"

sync

echo "Shrinking the image..."
resiz1=$(sfdisk "${loop}" --json | jq '[.partitiontable.partitions][0][2] | .start')
resiz2=$(sfdisk "${loop}" --json | jq '[.partitiontable.partitions][0][2] | .size')
resiz3=$((resiz1+resiz2))

losetup -d "${loop}"

truncate --size=$((resiz3*512)) $1

echo "Cleaning up..."
rm -rf needed mnt