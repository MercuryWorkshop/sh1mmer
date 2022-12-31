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
read -p "please enter the path do your .bin file (example: /home/username/Downloads/sentry.bin) : " bin
lsblk
read -p "Out of the devices above, enter the path to the usb you want to flash (example: /dev/sdb) : " usb

flash() {
    echo flashing $1 to $2
    dd if=$1 of=$2 status=progress
}

# clean up if exited abnormally
umount "${usb}3" || :
rm -rf mnt || :

echo "Flashing raw shim"
flash $bin $usb
echo "Making ROOT mountable"
sh make_dev_ssd_no_resign.sh --remove_rootfs_verification -i $usb
sleep 2
echo "Creating Mountpoint"
mkdir mnt || :
echo "Mounting ROOT-A"
mount "${usb}3" mnt
echo "Injecting payload"
sleep 5
cp ../sh1mmer.sh mnt/usr/sbin/factory_install.sh
echo "Cleaning up..."
sleep 5
umount "${usb}3"
rm -rf mnt
echo "Done. Have fun"
