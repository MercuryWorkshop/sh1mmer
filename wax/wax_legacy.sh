#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/common_minimal.sh"

set -e
if [ "$EUID" -ne 0 ]; then
		echo "Please run as root"
		exit
fi

echo "-------------------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool made by CoolElectronics and Sharp_Jack, greatly improved by r58playz and Rafflesia and olyb"
echo "Prerequisites: cgpt must be installed, program must be ran as root"
echo "-------------------------------------------------------------------------------------------------------------"
echo "Warning: this is a legacy version of wax. There may be unresolved issues"

SFDISK="lib/sfdisk"

sync
sleep 0.2
lib/sfdisk --delete "$1" 1 4 5 6 7 8 9 10 11 12

echo "Creating loop device"
loopdev=$(losetup -f)
losetup -P "$loopdev" "$1"

shrink_table() {
	local numparts=3
	local numtries=1

	i=0
	while [ $i -le $numtries ]; do
		#j=1
		j=2
		while [ $j -le $numparts ]; do
			printf "\033[1;92m"
			echo "$SFDISK" -N $j --move-data "${loopdev}"
			printf "\033[0m"
			"$SFDISK" -N $j --move-data "${loopdev}" <<<"+,-" || :
			j=$((j+1))
		done
		i=$((i+1))
	done
}

truncate_image() {
	local buffer=35 # magic number to ward off evil gpt corruption spirits
	local img=$1
	local fdisk_stateful_entry
	#fdisk_stateful_entry=$(fdisk -l "$img" | grep "${img}1[[:space:]]")
	fdisk_stateful_entry=$(fdisk -l "$img" | grep "${img}3[[:space:]]")
	local sector_size
	sector_size=$(fdisk -l "$img" | grep "Sector size" | awk '{print $4}')
	local end_sector
	end_sector=$(awk '{print $3}' <<<"$fdisk_stateful_entry")
	local end_bytes=$(((end_sector + buffer) * sector_size))

	info "truncating image to $end_bytes bytes"

	truncate -s $end_bytes "$img"
	gdisk "$img" << EOF
w
y
EOF
}



echo "Making ROOT mountable"
sh lib/ssd_util.sh --no_resign_kernel --remove_rootfs_verification -i "${loopdev}"

echo "Creating Mountpoint"
mkdir mnt || :

echo "Mounting ROOT-A"
mount "${loopdev}p3" mnt

echo "Injecting payload"
mv mnt/usr/sbin/factory_install.sh mnt/usr/sbin/factory_install_backup.sh
cp factory_bootstrap.sh mnt/usr/sbin
cp sh1mmer_legacy.sh mnt/usr/sbin/factory_install.sh
cp vitetris mnt/usr/bin
chmod +x mnt/usr/sbin/factory_bootstrap.sh mnt/usr/sbin/factory_install.sh mnt/usr/bin/vitetris
# ctrl+u boot unlock
sed -i "s/exec/pre-start script\nvpd -i RW_VPD -s block_devmode=0\ncrossystem block_devmode=0\nend script\n\nexec/" mnt/etc/init/startup.conf

df "${loopdev}p3"



sync
sleep 0.2
umount "${loopdev}p3"
shrink_table
losetup -d "$loopdev"
sync
sleep 0.2
truncate_image "$1"
sync
sleep 0.2

rmdir mnt

echo "Done. Have fun!"
