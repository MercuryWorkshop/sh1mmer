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
echo "Launch flags you should know about: --dev will install a much larger chromebrew partition used for testing, --antiskid will relock the rootfs"
# ORDER MATTERS! bin name before flags

bin=$1

if [[ $* == *--dev* ]]; then
    CHROMEBREW=chromebrew-dev.tar.gz
    CHROMEBREW_SIZE=7
else
    CHROMEBREW_SIZE=3 # or whatever it is
    CHROMEBREW=chromebrew.tar.gz
fi

echo "Expanding bin for 'arch' partition. this will take a while"

dd if=/dev/zero bs=1G status=progress count=${CHROMEBREW_SIZE} >>$bin
echo -ne "\a"
# Fix corrupt gpt
fdisk $bin <<EOF
w

EOF
echo "Partitioning"
# create new partition filling rest of disk
fdisk $1 <<EOF
n



w
EOF
echo "Creating loop device"
loop=$(losetup -f)
losetup -P $loop $bin

echo "Making arch partition"
mkfs.ext2 -L arch ${loop}p13 # ext2 so we can use skid protection features
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
# wget "https://files.alicesworld.tech/${CHROMEBREW}"
# uncomment this line when file servers go public or add the creds yourself
echo "Extracting chromebrew"
cd mntarch
tar xvf ../${CHROMEBREW} --strip-components=1
cp -rv ../payloads/* payloads/
cd ..
echo "Injecting payload"
cp -rv sh1mmer-assets mnt/usr/share/sh1mmer-assets
cp -v sh1mmer-scripts/* mnt/usr/sbin/
cp -v factory_install.sh mnt/usr/sbin/

# if you're reading this, you aren't a skid. run sh make_dev_ssd_no_resign.sh --remove_rootfs_verification --unlock_arch -i /dev/sdX on the flashed usb to undo this
if [[ $* == *--antiskid* ]]; then
    echo "relocking rootfs..."
    sh make_dev_ssd_no_resign.sh --lock_root --lock_arch -i ${loop}
fi

echo "Cleaning up..."
sync
if umount "${loop}p3" && umount "${loop}p13"; then
    losetup -d ${loop}
else
    echo "Couldn't safely unmount. Please unmount and detach the loopbacks yourself."
fi
echo "Done. Have fun!"
