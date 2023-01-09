source /usr/sbin/sh1mmer_gui.sh
source /usr/sbin/sh1mmer_optionsSelector.sh

mount /dev/disk/by-label/arch /usr/local

setup
showbg Splash.png
echo -n "If you paid for this, demand your money back."
sleep 3

loadmenu() {
	case $(readinput) in
	0) bash /usr/sbin/sh1mmer_payload.sh ;;
	1) bash /usr/sbin/sh1mmer_utilities.sh ;;
	2) credits ;;
	3) reboot ;;
	esac
}

credits() {
	showbg Credits.png

	while true; do
		case $(readinput) in
		'kB') break ;;
		esac
	done
}

selector() {
	selected=0
	showbg "Main_$selected.png" # or something
	while true; do
		input=$(readinput)
		case $input in
		'kB') reboot ;;
		'kE') return $selected ;;
		'kU')
			((selected--))
			if [ $selected -lt 0 ]; then selected=0; fi
			;;
		'kD')
			((selected++))
			if [ $selected -ge $# ]; then selected=$(($# - 1)); fi
			;;
		esac
	done
}

while true; do
	# thank you r58 :pray:
	selector 0 1 2 3
	loadmenu $*
done

cleanup
