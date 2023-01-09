source /usr/sbin/sh1mmer_gui.sh
source /usr/sbin/sh1mmer_optionsSelector.sh

mount /dev/disk/by-label/arch /usr/local

setup
showbg Splash.png
echo -n WE HATE IRWIN!
sleep 3

while true; do
	showbg optionSelect.png
	case `readinput` in
		'1') bash /usr/sbin/sh1mmer_payload.sh ;;
		'2') bash /usr/sbin/sh1mmer_utilities.sh ;;
	esac
done
cleanup
