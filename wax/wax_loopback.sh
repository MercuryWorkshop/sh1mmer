#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi
echo "-------------------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool made by CoolElectronics and Sharp_Jack, improved by r58playz"
echo "Prerequisites: cgpt must be installed, program must be ran as root"
echo "-------------------------------------------------------------------------------------------------------------"


bin=$1




# clean up if exited abnormally

echo "Creating loop device"
loop=$(losetup -f)
losetup -P $loop $bin

echo "Making ROOT mountable"
sh make_dev_ssd_no_resign.sh --remove_rootfs_verification -i ${loop}
sleep 2
echo "Creating Mountpoint"
mkdir mnt || :
echo "Mounting ROOT-A"
mount "${loop}p3" mnt
echo "Injecting payload"
sleep 5
cp ../sh1mmer.sh mnt/usr/sbin/factory_install.sh
echo "Cleaning up..."
sleep 5
umount "${loop}p3"
rm -rf mnt
losetup -d ${loop}

echo "Done. Have fun"
