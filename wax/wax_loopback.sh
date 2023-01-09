#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi
echo "-------------------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool made by CoolElectronics and Sharp_Jack, improved by r58playz"
echo "Prerequisites: cgpt must be installed, program must be ran as root, chromebrew.tar.gz needs to exist"
echo "-------------------------------------------------------------------------------------------------------------"


bin=$1

echo "Expanding bin for 'arch' partition"
dd if=/dev/zero bs=1G count=6 >> $bin
echo -ne "\a"
# Expand Shim
dd if=/dev/zero bs=1G count=6  >> $1
fdisk $1 << EOF
w

EOF
fdisk $1 << EOF
n



w
EOF
echo "Creating loop device"
loop=$(losetup -f)
losetup -P $loop $bin

echo "Making arch partition"
mkfs.ext4 -L arch ${loop}p13
echo "Making ROOT mountable"
sh make_dev_ssd_no_resign.sh --remove_rootfs_verification -i ${loop}
echo "Creating Mountpoint"
mkdir mnt || :
mkdir mntarch || :
echo "Mounting ROOT-A"
mount "${loop}p3" mnt
echo "Mounting arch"
mount "${loop}p13" mntarch
echo "Extracting chromebrew"
cd mntarch
tar xvf ../chromebrew.tar.gz --strip-components=1
cd ..
echo "Injecting custom payloads"
cp payloads/* mntarch/payloads/
echo "Injecting GUI"
cp -rv sh1mmer-assets mnt/usr/share/sh1mmer-assets
cp -v sh1mmer-scripts/* mnt/usr/sbin/
cp -v factory_install.sh mnt/usr/sbin/
echo "Cleaning up..."
sync
umount "${loop}p3"
umount "${loop}p13"
rm -rf mnt
losetup -d ${loop}

echo "Done. Have fun"
