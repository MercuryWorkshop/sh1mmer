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
unblock_devmode() {
    vpd -i RW_VPD -s check_enrollment=0
    vpd -i RW_VPD -s block_devmode=0
    crossystem block_devmode=0

    # the sleeps here are so cryptohome won't get pissy

    tpm_manager_client take_ownership
    sleep 2
    cryptohome --action=tpm_take_ownership
    sleep 2
    cryptohome --action=remove_firmware_management_parameters
}
shell() {
    cleanup
    bash
    setup
    clear
    sleep 0.1
}
runtask() {

    # are you happy now?!
    showbg terminalGeneric.png
    movecursor_generic
    echo "Starting task $1"
    sleep 2
    if $1; then
        echo "Task $1 succeeded."
        sleep 3
    else
        read "THERE WAS AN ERROR! The utility likely did not work. Press any key to continue."
    fi
}

while true; do
    showbg Utilities.png
    case $(readinput) in
    'kB') break ;;
    '1') runtask fix_gbb ;;
    '2') runtask deprovision ;;
    '3') runtask reprovision ;;
    '4') runtask usb ;;
    '5') runtask disable_verity ;;
    '6') runtask unblock_devmode ;;
    '7') shell ;;
    esac
done
