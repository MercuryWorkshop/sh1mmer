source /usr/sbin/sh1mmer_gui.sh
source /usr/sbin/sh1mmer_optionsSelector.sh

deprovision() {
    vpd -i RW_VPD -s check_enrollment=0
    unblock_devmode
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
    vpd -i RW_VPD -s block_devmode=0
    crossystem block_devmode=0
    res=$(cryptohome --action=get_firmware_management_parameters 2>&1)
    if [ $? -eq 0 ] && [[ ! $(echo $res | grep "Unknown action") ]]; then
        tpm_manager_client take_ownership
        # sleeps no longer needed
        cryptohome --action=remove_firmware_management_parameters
    fi
}

shell() {
    cleanup
    echo "You can sudo su if you need a rootshell"
    su -c 'PATH="$PATH:/usr/local/bin" LD_LIBRARY_PATH="/lib64:/usr/lib64:/usr/local/lib64" /bin/bash' chronos # ok i didn't think of this very cool :+1: -ce
    setup
    clear
    sleep 0.1
}

runtask() {
    # are you happy now?!
    # no, i am not YOU USED IT WRONG!!! -r58Playz
    showbg terminalGeneric.png
    movecursor_generic 0 # you need to put in a number!
    echo "Starting task $1"
    sleep 2
    if $1; then
        movecursor_generic 1 # ya forgot it here
        echo "Task $1 succeeded."
        sleep 3
    else
        movecursor_generic 1 # ya forgot it here
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
