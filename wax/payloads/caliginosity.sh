 #!/bin/bash

reprovision() {
    echo "reprovisioning"
    vpd -i RW_VPD -s check_enrollment=1
}

fix_gbb() {
    /usr/share/vboot/bin/set_gbb_flags.sh 0x0
    echo "GBB fixed"

}


echo "CALIGINOSITY :: SH1mmer payload for re-enrolling"
echo ""
echo "THIS WILL RE-ENROLL YOUR CHROMEBOOK, ATTEMPT TO FIX GBB FLAGS, DISABLE USB BOOT, AND BLOCK DEVMODE."
echo "THIS SCRIPT ASSUMES YOU ARE USING STOCK FIRMWARE, AND HAVE WRITE-PROTECT OFF"
echo ""
read -p "ARE YOU SURE YOU WANT TO DO THIS? [y/n]" input

if [ "$input" = "y" ]; then
    crossystem dev_boot_usb=0
    reprovision
    crossystem block_devmode=1
    vpd -i RW_VPD -s block_devmode=1
    cryptohome --action=tpm_take_ownership
    cryptohome --action=set_firmware_management_parameters --flags=0x01
    fix_gbb
    echo "rebooting"
    reboot
    exit
else
    echo "ABORT"
    exit
fi




