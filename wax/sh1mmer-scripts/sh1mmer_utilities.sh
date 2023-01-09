source /usr/sbin/sh1mmer_gui.sh
source /usr/sbin/sh1mmer_optionsSelector.sh

deprovision() {
    vpd -i RW_VPD -s check_enrollment=0
    vpd -i RW_VPD -s block_devmode=0
}

reprovision() {
    vpd -i RW_VPD -s check_enrollment=1
}

usb() {
    crossystem dev_boot_usb=1
}

fix_gbb() {
    /usr/share/vboot/bin/set_gbb_flags.sh 0x0
}

disable_verity() {
    /usr/share/vboot/bin/make_dev_ssd.sh -i /dev/mmcblk0 --remove_rootfs_verification
}

shell() {
    cleanup
    bash
    setup
    clear
    sleep 0.1
}

credits() {
    showbg Credits.png
    movecursor_Credits 0
    echo -n "CoolElectronics: Creating the original script"
    movecursor_Credits 1
    echo -n "r58Playz: Creating the GUI script"
    movecursor_Credits 2
    echo -n "rabbithawk256: Providing GUI assets"
    movecursor_Credits 3
    echo -n "ULTRA BLUE: Testing & discovering how to disable rootfs verification"
    movecursor_Credits 4
    echo -n "Sharp_Jack: Creating the wax automation tool"
    movecursor_Credits 5
    echo -n "Unciaur: Finding the first shim"
    movecursor_Credits 6
    echo -n "TheMemeSniper: Testing"
    movecursor_Credits 7
    echo -n "OlyB: Scraping more shims"
    movecursor_Credits 8
    echo -n "Rafflesia: Hosting"
    printf "\033[0;0H"
    while true; do
        case `readinput` in
            'kB') break ;;
        esac
    done
}

while true; do
    showbg Utilities.png
    case `readinput` in
	'kB') break ;;
	'1') fix_gbb 2>/dev/null ;;
	'2') deprovision 2>/dev/null ;;
	'3') reprovision 2>/dev/null ;;
	'4') usb 2>/dev/null;;
	'5') disable_verity 2>/dev/null;;
	'6') shell ;;
	'7') credits;;
    esac
done

