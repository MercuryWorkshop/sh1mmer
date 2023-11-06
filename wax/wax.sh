#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -e
if [ "$EUID" -ne 0 ]; then
	echo "Please run as root"
	exit 1
fi

echo "-------------------------------------------------------------------------------------------------------------"
echo "Welcome to wax, a shim modifying automation tool made by CoolElectronics and Sharp_Jack, greatly improved by r58playz and Rafflesia"
echo "Prerequisites: program must be ran as root, chromebrew.tar.gz needs to exist inside the wax folder"
echo "-------------------------------------------------------------------------------------------------------------"
echo "Launch flags you should know about: --dev will install a much larger chromebrew partition used for testing, --antiskid will relock the rootfs"
# ORDER MATTERS! bin name before flags

if grep -qEi "(Microsoft|WSL)" /proc/version &> /dev/null; then
	echo -e "\n\n\n\n"
	echo "==========[!]=========="
	echo "WAX HAS DETECTED THAT YOU ARE USING WSL"
	echo "DO NOT MAKE ISSUES ON THE GITHUB"
	echo "WSL IS NOT SUPPORTED"
	echo -e "\n\n\n\n"
fi

bin=$1

if [[ $* == *--dev* ]]; then
	CHROMEBREW=chromebrew-dev.tar.gz
	CHROMEBREW_SIZE=7
else
	CHROMEBREW_SIZE=4 # or whatever it is
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
loopdev=$(losetup -f)
losetup -P "$loopdev" "$bin"

echo "Making arch partition"
mkfs.ext2 -L arch "${loopdev}p13" # ext2 so we can use skid protection features (todo: why????)
echo "Making ROOT mountable"
enable_rw_mount "${loopdev}p3"
safesync

echo "Mounting ROOT"
MNT_ROOT=$(mktemp -d)
mount "${loopdev}p3" "$MNT_ROOT"

echo "Injecting payload"
cp -rv sh1mmer-assets "$MNT_ROOT/usr/share/sh1mmer-assets"
cp -v sh1mmer-scripts/* "$MNT_ROOT/usr/sbin"
echo "Inserting firmware"
curl "https://github.com/Netronome/linux-firmware/raw/master/iwlwifi-9000-pu-b0-jf-b0-41.ucode" >"$MNT_ROOT/lib/firmware/iwlwifi-9000-pu-b0-jf-b0-41.ucode"

echo "Brewing /etc/profile"
echo 'PATH="$PATH:/usr/local/bin"' >>"$MNT_ROOT/etc/profile"
echo 'LD_LIBRARY_PATH="/lib64:/usr/lib64:/usr/local/lib64"' >>"$MNT_ROOT/etc/profile"

umount "$MNT_ROOT"
rm -rf "$MNT_ROOT"

echo "Mounting arch"
MNT_ARCH=$(mktemp -d)
mount "${loopdev}p13" "$MNT_ARCH"

echo "Extracting chromebrew"
tar -xvf "$CHROMEBREW" --strip-components=1 -C "$MNT_ARCH"
cp -rv payloads "$MNT_ARCH"

umount "$MNT_ARCH"
rm -rf "$MNT_ARCH"

# if you're reading this, you may not be a skid. run sh lib/ssd_util.sh --no_resign_kernel --remove_rootfs_verification --unlock_root -i /dev/sdX on the flashed usb to undo this
if [[ $* == *--antiskid* ]]; then
	safesync
	echo "relocking rootfs..."
	disable_rw_mount "${loopdev}p3"
fi

safesync
losetup -d "$loopdev"

echo "Done. Have fun!"
