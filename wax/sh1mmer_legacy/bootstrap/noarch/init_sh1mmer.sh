#!/bin/busybox sh

set -eE

TMPFS_SIZE=1024M
NEWROOT_MNT=/newroot
ROOTFS_MNT=/usb

STATEFUL_MNT="$1"
STATEFUL_DEV="$2"
BOOTSTRAP_DEV="$3"
ARCHITECTURE="${4:-x86_64}"

ROOTFS_DEV=

SCRIPT_DATE="[2024-01-28]"

COLOR_RESET="\033[0m"
COLOR_BLACK_B="\033[1;30m"
COLOR_RED_B="\033[1;31m"
COLOR_GREEN="\033[0;32m"
COLOR_GREEN_B="\033[1;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_YELLOW_B="\033[1;33m"
COLOR_BLUE_B="\033[1;34m"
COLOR_MAGENTA_B="\033[1;35m"
COLOR_CYAN_B="\033[1;36m"

fail() {
	printf "%b\nAborting.\n" "$*" >&2
	cleanup || :

	sleep 1
	self_shell || :

	tail -f /dev/null
	exit 1
}

cleanup() {
	umount "$STATEFUL_MNT" || :
	umount "$ROOTFS_MNT" || :
}

trap 'fail "An unhandled error occured."' ERR

enable_input() {
	stty echo || :
}

disable_input() {
	stty -echo || :
}

self_shell() {
	printf "\n\n"
	echo "This shell has PID 1. Exit = kernel panic."
	enable_input
	printf "\033[?25h"
	exec sh
}

unmount_and_self_shell() {
	umount "$STATEFUL_MNT" || :
	self_shell
}

notice_and_self_shell() {
	echo "Run 'exec sh1mmer_switch_root' to finish booting Sh1mmer."
	self_shell
}

poll_key() {
	local held_key
	# dont need enable_input here
	# read will return nonzero when no key pressed
	# discard stdin
	read -r -s -n 10000 -t 0.1 held_key || :
	read -r -s -n 1 -t 0.1 held_key || :
	echo "$held_key"
}

pv_dircopy() {
	[ -d "$1" ] || return 1
	local apparent_bytes
	apparent_bytes=$(du -sb "$1" | cut -f 1)
	mkdir -p "$2"
	tar -cf - -C "$1" . | pv -f -s "${apparent_bytes:-0}" | tar -xf - -C "$2"
}

determine_rootfs() {
	local bootstrap_num
	bootstrap_num="$(echo "$BOOTSTRAP_DEV" | grep -o '[0-9]*$')"
	ROOTFS_DEV="$(echo "$BOOTSTRAP_DEV" | sed 's/[0-9]*$//')$((bootstrap_num + 1))"
	[ -b "$ROOTFS_DEV" ] || return 1
}

patch_new_root_sh1mmer() {
	[ -f "$NEWROOT_MNT/usr/sbin/factory_install.sh" ] && cp "$NEWROOT_MNT/usr/sbin/factory_install.sh" "$NEWROOT_MNT/usr/sbin/factory_install_backup.sh"
	# ctrl+u boot unlock (to be improved)
	[ -f "$NEWROOT_MNT/etc/init/startup.conf" ] && sed -i "s/exec/pre-start script\nvpd -i RW_VPD -s block_devmode=0\ncrossystem block_devmode=0\nend script\n\nexec/" "$NEWROOT_MNT/etc/init/startup.conf"
}

# todo: dev console on tty4, better logging, wait key

disable_input
case "$(poll_key)" in
	x) set -x ;;
	s) unmount_and_self_shell ;;
esac

mkdir -p "$NEWROOT_MNT" "$ROOTFS_MNT"
mount -t tmpfs tmpfs "$NEWROOT_MNT" -o "size=$TMPFS_SIZE" || fail "Failed to mount tmpfs"

determine_rootfs || fail "Could not determine rootfs"
mount -o ro "$ROOTFS_DEV" "$ROOTFS_MNT" || fail "Failed to mount rootfs $ROOTFS_DEV"

printf "\033[2J\033[H"

printf "${COLOR_CYAN_B}"
echo "ICBfX18gXyAgXyBfIF9fICBfXyBfXyAgX18gX19fIF9fXyAKIC8gX198IHx8IC8gfCAgXC8gIHwgIFwvICB8IF9ffCBfIFwKIFxfXyBcIF9fIHwgfCB8XC98IHwgfFwvfCB8IF98fCAgIC8KIHxfX18vX3x8X3xffF98ICB8X3xffCAgfF98X19ffF98X1wKCg==" | base64 -d
printf "${COLOR_RESET}"
echo "Sh1mmer is loading..."
echo "Bootloader date: ${SCRIPT_DATE}"
echo "https://github.com/MercuryWorkshop/sh1mmer"
echo ""

echo "Pro tip: you can hold:"
echo "[x] at startup to enable xtrace"
echo "[s] at startup to open an early shell"
echo "[d] now to open a later shell"
echo "[n] now to skip sh1mmer patch (boot \"raw\" shim)"
echo ""

echo "Copying rootfs..."
pv_dircopy "$ROOTFS_MNT" "$NEWROOT_MNT"
umount "$ROOTFS_MNT"
echo ""

SKIP_SH1MMER_PATCH=0
if [ "$(poll_key)" = "n" ]; then
	SKIP_SH1MMER_PATCH=1
	echo "SKIPPING SH1MMER PATCH"
	echo ""
fi

echo "Patching new root..."
printf "${COLOR_BLACK_B}"
/bin/patch_new_root.sh "$NEWROOT_MNT" "$STATEFUL_DEV"
[ "$SKIP_SH1MMER_PATCH" -eq 0 ] && patch_new_root_sh1mmer
printf "${COLOR_RESET}"
echo ""

if [ "$SKIP_SH1MMER_PATCH" -eq 0 ]; then
	echo "Copying Sh1mmer files..."
	pv_dircopy "$STATEFUL_MNT/root/noarch" "$NEWROOT_MNT" || :
	pv_dircopy "$STATEFUL_MNT/root/$ARCHITECTURE" "$NEWROOT_MNT" || :
	echo ""
fi

umount "$STATEFUL_MNT"

# write this to a file so the user can easily run this from the debug shell
cat <<EOF >/bin/sh1mmer_switch_root
#!/bin/busybox sh

if [ \$\$ -ne 1 ]; then
	echo "No PID 1. Abort."
	exit 1
fi

BASE_MOUNTS="/sys /proc /dev"
move_mounts() {
	# copied from https://chromium.googlesource.com/chromiumos/platform/initramfs/+/54ea247a6283e7472a094215b4929f664e337f4f/factory_shim/bootstrap.sh#302
	echo "Moving \$BASE_MOUNTS to $NEWROOT_MNT"
	for mnt in \$BASE_MOUNTS; do
		# \$mnt is a full path (leading '/'), so no '/' joiner
		mkdir -p "$NEWROOT_MNT\$mnt"
		mount -n -o move "\$mnt" "$NEWROOT_MNT\$mnt"
	done
	echo "Done."
}

move_mounts
echo "exec switch_root"
echo "this shouldn't take more than a few seconds"
exec switch_root "$NEWROOT_MNT" /sbin/init -v --default-console output || :
EOF
chmod +x /bin/sh1mmer_switch_root

[ "$(poll_key)" = "d" ] && notice_and_self_shell

enable_input
exec sh1mmer_switch_root || :

# should never reach here
fail "Failed to exec switch_root."
