#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi
echo "-------------------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool made by CoolElectronics and Sharp_Jack, greatly improved by r58playz and Rafflesia"
echo "Prerequisites: cgpt must be installed, program must be ran as root, chromebrew.tar.gz needs to exist"
echo "-------------------------------------------------------------------------------------------------------------"

bin=$1

echo "Expanding bin for 'arch' partition"
dd if=/dev/zero bs=1G count=6 >>$bin
echo -ne "\a"
# Fix corrupt gpt
fdisk $bin <<EOF
w

EOF

# create new partition filling rest of disk
fdisk $1 <<EOF
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

echo "Accquiring chromebrew"
# wget "https://files.alicesworld.tech/chromebrew.tar.gz"
# uncomment this line when file servers go public or add the creds yourself
echo "Extracting chromebrew"
cd mntarch
tar xvf ../chromebrew.tar.gz --strip-components=1
cd ..
echo "Injecting payload"
cp -rv sh1mmer-assets mnt/usr/share/sh1mmer-assets
cp -v sh1mmer-scripts/* mnt/usr/sbin/
cp -v factory_install.sh mnt/usr/sbin/
echo "Cleaning up..."
sync
if umount "${loop}p3" && umount "${loop}p13"; then
    rm -rf mnt # If we don't check whether the unmount succeeds, these lines wipe the rootfs.
    rm -rf mntarch
    losetup -d ${loop}
else
    echo "Couldn't safely unmount. Please unmount and detach the loopbacks yourself."
fi
echo "Done. Have fun!"
