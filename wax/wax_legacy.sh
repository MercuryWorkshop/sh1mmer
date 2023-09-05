#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

echo "-------------------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool made by CoolElectronics and Sharp_Jack, greatly improved by r58playz and Rafflesia anD olyb"
echo "Prerequisites: cgpt must be installed, program must be ran as root"
echo "-------------------------------------------------------------------------------------------------------------"
echo "Warning: this is a legacy version of wax. There may be unresolved issues"

echo "Creating loop device"
loop=$(losetup -f)
losetup -P "$loop" "$1"

echo "Making ROOT mountable"
sh lib/ssd_util.sh --no_resign_kernel --remove_rootfs_verification -i "${loop}"

echo "Creating Mountpoint"
mkdir mnt || :

echo "Mounting ROOT-A"
mount "${loop}p3" mnt

echo "Injecting payload"
mv mnt/usr/sbin/factory_install.sh mnt/usr/sbin/factory_install_backup.sh
cp factory_bootstrap.sh mnt/usr/sbin
cp sh1mmer_legacy.sh mnt/usr/sbin/factory_install.sh
chmod +x mnt/usr/sbin/factory_bootstrap.sh mnt/usr/sbin/factory_install.sh
# ctrl+u boot unlock
sed -i "s/exec/pre-start script\nvpd -i RW_VPD -s block_devmode=0\ncrossystem block_devmode=0\nend script\n\nexec/" mnt/etc/init/startup.conf

echo "Cleaning up..."
sync
if umount "${loop}p3"; then
	losetup -d "${loop}"
else
	echo "Couldn't safely unmount. Please unmount and detach the loopbacks yourself."
fi
echo "Done. Have fun!"
