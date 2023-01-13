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
echo "Launch flags you should know about: --antiskid will relock the rootfs"
echo "THIS IS THE MINIMAL SHIM, PAYLOADS FEATURE **WILL NOT** WORK"
# ORDER MATTERS! bin name before flags

bin=$1

echo "Expanding bin for 'arch' partition. this will take a while"
echo -ne "\a"

# Fix corrupt gpt
fdisk $bin <<EOF
w

EOF

echo "Creating loop device"
loop=$(losetup -f)
losetup -P $loop $bin

echo "Making ROOT mountable"
sh make_dev_ssd_no_resign.sh --remove_rootfs_verification -i ${loop}

echo "Creating Mountpoint"
mkdir mnt || :

echo "Mounting ROOT-A"
mount "${loop}p3" mnt

echo "Injecting payload"
cp -rv sh1mmer-assets mnt/usr/share/sh1mmer-assets
cp -v sh1mmer-scripts/* mnt/usr/sbin/
cp -v factory_install.sh mnt/usr/sbin/

echo "Inserting wifi firmware"
curl "https://github.com/Netronome/linux-firmware/raw/master/iwlwifi-9000-pu-b0-jf-b0-41.ucode" >mnt/lib/firmware/iwlwifi-9000-pu-b0-jf-b0-41.ucode
sync # this sync should hopefully stop make_dev_ssd from messing up, as it does raw byte manip stuff
sleep 4
# if you're reading this, you aren't a skid. run sh make_dev_ssd_no_resign.sh --remove_rootfs_verification --unlock_arch -i /dev/sdX on the flashed usb to undo this
if [[ $* == *--antiskid* ]]; then
    echo "relocking rootfs..."
    sh make_dev_ssd_no_resign.sh --lock_root -i ${loop}
fi
sleep 2
echo "Cleaning up..."

sync
if umount "${loop}p3"; then
    losetup -d ${loop}
else
    echo "Couldn't safely unmount. Please unmount and detach the loopbacks yourself."
fi
echo "Done. Have fun!"
