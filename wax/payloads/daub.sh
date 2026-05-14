 #!/bin/bash
fail(){
	printf "$1\n"
	printf "exiting...\n"
	exit
}
main(){
  source /usr/sbin/write_gpt.sh
  load_base_vars
	intdis=$(get_fixed_dst_drive)
	if echo "$intdis" | grep -q '[0-9]$'; then
		intdis_prefix="$intdis"p
	else
		intdis_prefix="$intdis"
	fi
	clear
	menu
  echo
  read -p "Would you like to disable developer mode (skips beep) (Y/N)" -n 1 -r
  if [[ $REPLY =~ ^[Yy]$ ]]; then
	  crossystem disable_dev_request=1
  fi
  echo -e "\n\nDone! Run reboot -f to reboot."
}
menu() {
	echo "DAUB by crosbreaker, orginally found by Hannah. Script by Con, mariah scary, and kxtz"
	echo "https://crosbreaker.com"
	echo
	echo "(1) Setup DAUB"
	echo "(2) Exit Utility"
	# add undoing daub soon
	read -p "" -n 1 -r
	echo
	case "$REPLY" in
	1)
		echo "Setting up DAUB..."
		wipestate
		### credit to kxtz for fixing daub bootloop, this code is his
		OPPOSITE_KERN_ID="$(opposite_num $(get_booted_kernnum))"
		OPPOSITE_ROOT_ID="$(opposite_num $(get_booted_rootnum))"
		OPPOSITE_KERN_NAME=""
		OPPOSITE_ROOT_NAME=""
		case "${OPPOSITE_KERN_ID}" in
			2)
        OPPOSITE_KERN_NAME="KERN-A"
        ;;
			4)
        OPPOSITE_KERN_NAME="KERN-B"
        ;;
			*)
        OPPOSITE_KERN_NAME="SKID"
        ;;
		esac
		case "${OPPOSITE_ROOT_ID}" in
			2)
        OPPOSITE_ROOT_NAME="ROOT-A"
        ;;
			4)
        OPPOSITE_ROOT_NAME="ROOT-B"
        ;;
			*)
        OPPOSITE_ROOT_NAME="SKID"
        ;;
		esac
		cat <<EOF | fdisk "${intdis}"
d
${OPPOSITE_KERN_ID}
d
${OPPOSITE_ROOT_ID}
n
${OPPOSITE_KERN_ID}

+1K
n
${OPPOSITE_ROOT_ID}

+1K
t
${OPPOSITE_KERN_ID}
ChromeOS kernel
t
${OPPOSITE_ROOT_ID}
ChromeOS rootfs
x
n
${OPPOSITE_KERN_ID}
${OPPOSITE_KERN_NAME}
n
${OPPOSITE_ROOT_ID}
${OPPOSITE_ROOT_NAME}
r
w
EOF
		### end of kxtz code
		;;
	2)
		exit 0
		;;
	*)
		clear
		echo "invalid option"
		menu
		;;
	esac
}
get_fixed_dst_drive() {
	local dev
	if [ -z "${DEFAULT_ROOTDEV}" ]; then
		for dev in /sys/block/sd* /sys/block/mmcblk*; do
			if [ ! -d "${dev}" ] || [ "$(cat "${dev}/removable")" = 1 ] || [ "$(cat "${dev}/size")" -lt 2097152 ]; then
				continue
			fi
			if [ -f "${dev}/device/type" ]; then
				case "$(cat "${dev}/device/type")" in
				SD*)
					continue;
					;;
				esac
			fi
			DEFAULT_ROOTDEV="{$dev}"
		done
	fi
	if [ -z "${DEFAULT_ROOTDEV}" ]; then
		dev=""
	else
		dev="/dev/$(basename ${DEFAULT_ROOTDEV})"
		if [ ! -b "${dev}" ]; then
			dev=""
		fi
	fi
	echo "${dev}"
}
wipestate(){
  vgchange -ay #activate all volume groups
  volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
	if [ -b "/dev/$volgroup/unencrypted" ]; then
		echo "found volume group: $volgroup"
		mkfs.ext4 -F /dev/$volgroup/unencrypted
	else
		echo "lvm fail, falling back on p1"
    mkfs.ext4 -F "$intdis""$intdis_prefix"1
	fi
}
get_booted_kernnum() {
  if $(expr $(cgpt show -n "$intdis" -i 2 -P) > $(cgpt show -n "$intdis" -i 4 -P)); then
    echo -n 2
  else
    echo -n 4
  fi
}
get_booted_rootnum() {
	expr $(get_booted_kernnum) + 1
}
opposite_num() {
  case "$1" in
    "2") echo -n 4;;
    "4") echo -n 2;;
    "3") echo -n 5;;
    "5") echo -n 3;;
    *) return 1;;
  esac
}
main
