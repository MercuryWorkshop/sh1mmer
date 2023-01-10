source /usr/sbin/sh1mmer_gui.sh
source /usr/sbin/sh1mmer_optionsSelector.sh

mount /dev/disk/by-label/arch /usr/local

setup
showbg Splash.png
echo -n "If you paid for this, demand your money back."
sleep 3

loadmenu() {
	case $selected in
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
	clear # FOR TESTING! REMOVE THIS ONCE ASSETS ARE FIXED -ce

	selected=0
	showbg "Main_$selected.png" # or something
	while true; do
		input=$(readinput)
		case $input in
		'kB') reboot ;;
		'kE') # again, bash return doesn't work if you have anything other than 0 or 1, so we'll just take the value of selected globally. real asm moment
			return ;;
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
	# thank you r58 :pray: | almost got it right this time -r58Playz
	selector 0 1 2 3
	loadmenu # idiot use $? for the return number! i told you! -r58Playz
	# well guess what that doesn't work anyway - ce
done

cleanup

bash # a failsafe in case i accidentally mess up very badly. this should never be reached
