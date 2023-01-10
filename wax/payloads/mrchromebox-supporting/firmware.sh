#!/bin/bash
#

###################
# flash RW_LEGACY #
###################
function flash_rwlegacy() {

    #set working dir
    cd /tmp

    echo_green "\nInstall/Update RW_LEGACY Firmware (Legacy BIOS)"

    # set dev mode legacy boot flag
    if [ "${isChromeOS}" = true ]; then
        crossystem dev_boot_legacy=1 >/dev/null 2>&1
        crossystem dev_boot_altfw=1 >/dev/null 2>&1
    fi

    #determine proper file
    if [ "$device" = "link" ]; then
        rwlegacy_file=$seabios_link
    elif [[ "$isHswBox" = true || "$isBdwBox" = true ]]; then
        rwlegacy_file=$seabios_hswbdw_box
    elif [[ "$isHswBook" = true || "$isBdwBook" = true ]]; then
        rwlegacy_file=$seabios_hswbdw_book
    elif [ "$isByt" = true ]; then
        rwlegacy_file=$seabios_baytrail
    elif [ "$isBsw" = true ]; then
        rwlegacy_file=$seabios_braswell
    elif [ "$isSkl" = true ]; then
        rwlegacy_file=$seabios_skylake
    elif [ "$isApl" = true ]; then
        rwlegacy_file=$seabios_apl
    elif [ "$kbl_use_rwl18" = true ]; then
        rwlegacy_file=$seabios_kbl_18
    elif [ "$isStr" = true ]; then
        rwlegacy_file=$rwl_altfw_stoney
    elif [ "$isKbl" = true ]; then
        rwlegacy_file=$seabios_kbl
    elif [ "$isWhl" = true ]; then
        rwlegacy_file=$rwl_altfw_whl
    elif [ "$device" = "drallion" ]; then
        rwlegacy_file=$rwl_altfw_drallion
    elif [ "$isCmlBox" = true ]; then
        rwlegacy_file=$rwl_altfw_cml
    elif [ "$isJsl" = true ]; then
        rwlegacy_file=$rwl_altfw_jsl
    elif [ "$isZen2" = true ]; then
        rwlegacy_file=$rwl_altfw_zen2
    elif [ "$isTgl" = true ]; then
        rwlegacy_file=$rwl_altfw_tgl
    elif [ "$isGlk" = true ]; then
        rwlegacy_file=$rwl_altfw_glk
    else
        echo_red "Unknown or unsupported device (${device}); cannot update RW_LEGACY firmware."
        read -ep "Press enter to return to the main menu"
        return 1
    fi

    #download SeaBIOS update
    echo_yellow "\nUsing RW_LEGACY firmware update\n(${rwlegacy_file})"
    #flash updated legacy BIOS
    echo_yellow "Installing RW_LEGACY firmware"
    ${flashromcmd} -w -i RW_LEGACY:${static_source}${rwlegacy_file} -o /tmp/flashrom.log >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        cat /tmp/flashrom.log
        echo_red "An error occurred flashing the RW_LEGACY firmware."
    else
        echo_green "RW_LEGACY firmware successfully installed/updated."
        # update firmware type
        firmwareType="Stock ChromeOS w/RW_LEGACY"
        #Prevent from trying to boot stock ChromeOS install
        rm -rf /tmp/boot/syslinux >/dev/null 2>&1
    fi

    if [ -z "$1" ]; then
        read -ep "Press [Enter] to return to the main menu."
    fi
}

function backup_fail() {
    umount /tmp/usb >/dev/null 2>&1
    rmdir /tmp/usb >/dev/null 2>&1
    exit_red "\n$@"
}

####################
# Set Boot Options #
####################
function set_boot_options() {
    # set boot options via firmware boot flags

    # ensure hardware write protect disabled
    [[ "$wpEnabled" = true ]] && {
        exit_red "\nHardware write-protect enabled, cannot set Boot Options / GBB Flags."
        return 1
    }

    [[ -z "$1" ]] && legacy_text="Legacy Boot" || legacy_text="$1"

    echo_green "\nSet Firmware Boot Options (GBB Flags)"
    echo_yellow "Select your preferred boot delay and default boot option.
You can always override the default using [CTRL+D] or
[CTRL+L] on the Developer Mode boot screen"

    echo -e "1) Short boot delay (1s) + ${legacy_text} default
2) Long boot delay (30s) + ${legacy_text} default
3) Short boot delay (1s) + ChromeOS default
4) Long boot delay (30s) + ChromeOS default
5) Reset to factory default
6) Cancel/exit
"
    local _flags=0x0
    while :; do
        read -ep "? " n
        case $n in
        1)
            _flags=0x4A9
            break
            ;;
        2)
            _flags=0x4A8
            break
            ;;
        3)
            _flags=0xA9
            break
            ;;
        4)
            _flags=0xA8
            break
            ;;
        5)
            _flags=0x0
            break
            ;;
        6)
            read -ep "Press [Enter] to return to the main menu."
            break
            ;;
        *) echo -e "invalid option" ;;
        esac
    done
    [[ $n -eq 6 ]] && return
    echo_yellow "\nSetting boot options..."
    #disable software write-protect
    ${flashromcmd} --wp-disable >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        exit_red "Error disabling software write-protect; unable to set GBB flags."
        return 1
    fi
    ${flashromcmd} -r -i GBB:/tmp/gbb.temp >/dev/null 2>&1
    [[ $? -ne 0 ]] && {
        exit_red "\nError reading firmware (non-stock?); unable to set boot options."
        return 1
    }
    ${gbbutilitycmd} --set --flags="${_flags}" /tmp/gbb.temp >/dev/null
    [[ $? -ne 0 ]] && {
        exit_red "\nError setting boot options."
        return 1
    }
    ${flashromcmd} -w -i GBB:/tmp/gbb.temp >/dev/null 2>&1
    [[ $? -ne 0 ]] && {
        exit_red "\nError writing back firmware; unable to set boot options."
        return 1
    }
    echo_green "\nFirmware Boot options successfully set."
    read -ep "Press [Enter] to return to the main menu."
}

function show_header() {
    printf "\ec"
    echo -e "${NORMAL}\n ChromeOS Device Firmware Utility Script ${script_date} ${NORMAL}"
    echo -e "${NORMAL} (c) Mr Chromebox <mrchromebox@gmail.com> (modded by r58Playz and CoolElectronics for sh1mmer) ${NORMAL}"
    echo -e "${MENU}*****************************************************************************${NORMAL}"
    echo -e "${MENU}**${NUMBER}   Device: ${NORMAL}${deviceDesc} (${boardName^^})"
    echo -e "${MENU}**${NUMBER} Platform: ${NORMAL}$deviceCpuType"
    echo -e "${MENU}**${NUMBER}  Fw Type: ${NORMAL}$firmwareType"
    echo -e "${MENU}**${NUMBER}   Fw Ver: ${NORMAL}$fwVer ($fwDate)"
    if [[ $isUEFI == true && $hasUEFIoption = true ]]; then
        # check if update available
        curr_yy=$(echo $fwDate | cut -f 3 -d '/')
        curr_mm=$(echo $fwDate | cut -f 1 -d '/')
        curr_dd=$(echo $fwDate | cut -f 2 -d '/')
        eval coreboot_file=$(echo "coreboot_uefi_${device}")
        date=$(echo $coreboot_file | grep -o "mrchromebox.*" | cut -f 2 -d '_' | cut -f 1 -d '.')
        uefi_yy=$(echo $date | cut -c1-4)
        uefi_mm=$(echo $date | cut -c5-6)
        uefi_dd=$(echo $date | cut -c7-8)
        if [[ ("$firmwareType" != *"pending"*) && (($uefi_yy > $curr_yy) ||
            ($uefi_yy == $curr_yy && $uefi_mm > $curr_mm) ||
            ($uefi_yy == $curr_yy && $uefi_mm == $curr_mm && $uefi_dd > $curr_dd)) ]]; then
            echo -e "${MENU}**${NORMAL}           ${GREEN_TEXT}Update Available ($uefi_mm/$uefi_dd/$uefi_yy)${NORMAL}"
        fi
    fi
    if [ "$wpEnabled" = true ]; then
        echo -e "${MENU}**${NUMBER}    Fw WP: ${RED_TEXT}Enabled${NORMAL}"
        WP_TEXT=${RED_TEXT}
    else
        echo -e "${MENU}**${NUMBER}    Fw WP: ${NORMAL}Disabled"
        WP_TEXT=${GREEN_TEXT}
    fi
    echo -e "${MENU}*****************************************************************************${NORMAL}"
}

function stock_menu() {

    show_header

    if [[ "$unlockMenu" = true || ("$isFullRom" = false && "$isBootStub" = false && "$isUnsupported" = false && "$isEOL" = false) ]]; then
        echo -e "${MENU}**${WP_TEXT}     ${NUMBER} 1)${MENU} Install/Update RW_LEGACY Firmware ${NORMAL}"
    else
        echo -e "${GRAY_TEXT}**     ${GRAY_TEXT} 1)${GRAY_TEXT} Install/Update RW_LEGACY Firmware ${NORMAL}"
    fi

    if [[ "$unlockMenu" = true || "$hasUEFIoption" = true || "$hasLegacyOption" = true ]]; then
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} 2)${MENU} Install/Update UEFI (Full ROM) Firmware. WILL NOT WORK!!!! ${NORMAL}"
    else
        echo -e "${GRAY_TEXT}**     ${GRAY_TEXT} 2)${GRAY_TEXT} Install/Update UEFI (Full ROM) Firmware. WILL NOT WORK!!!!${NORMAL}"
    fi
    if [[ "${device^^}" = "EVE" ]]; then
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} D)${MENU} Downgrade Touchpad Firmware ${NORMAL}"
    fi
    if [[ "$unlockMenu" = true || ("$isFullRom" = false && "$isBootStub" = false) ]]; then
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} 3)${MENU} Set Boot Options (GBB flags) ${NORMAL}"
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} 4)${MENU} Set Hardware ID (HWID) ${NORMAL}"
    else
        echo -e "${GRAY_TEXT}**     ${GRAY_TEXT} 3)${GRAY_TEXT} Set Boot Options (GBB flags)${NORMAL}"
        echo -e "${GRAY_TEXT}**     ${GRAY_TEXT} 4)${GRAY_TEXT} Set Hardware ID (HWID) ${NORMAL}"
    fi
    if [[ "$unlockMenu" = true || ("$isFullRom" = false && "$isBootStub" = false &&
        ("$isHsw" = true || "$isBdw" = true || "$isByt" = true || "$isBsw" = true)) ]]; then
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} 5)${MENU} Remove ChromeOS Bitmaps ${NORMAL}"
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} 6)${MENU} Restore ChromeOS Bitmaps ${NORMAL}"
    fi
    if [[ "$unlockMenu" = true || ("$isChromeOS" = false && "$isFullRom" = true) ]]; then
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} 7)${MENU} Restore Stock Firmware (full) ${NORMAL}"
    fi
    if [[ "$unlockMenu" = true || ("$isByt" = true && "$isBootStub" = true && "$isChromeOS" = false) ]]; then
        echo -e "${MENU}**${WP_TEXT} [WP]${NUMBER} 8)${MENU} Restore Stock BOOT_STUB ${NORMAL}"
    fi
    if [[ "$unlockMenu" = true || "$isUEFI" = true ]]; then
        echo -e "${MENU}**${WP_TEXT}     ${NUMBER} C)${MENU} Clear UEFI NVRAM ${NORMAL}"
    fi
    echo -e "${MENU}*****************************************************************************${NORMAL}"
    echo -e "${ENTER_LINE}Select a menu option or${NORMAL}"
    echo -e "${nvram}${RED_TEXT}R${NORMAL} to reboot ${NORMAL} ${RED_TEXT}P${NORMAL} to poweroff ${NORMAL} ${RED_TEXT}Q${NORMAL} to quit ${NORMAL}"

    read -e opt
    case $opt in

    1)
        if [[ "$unlockMenu" = true || "$isChromeOS" = true || "$isFullRom" = false &&
            "$isBootStub" = false && "$isUnsupported" = false && "$isEOL" = false ]]; then
            flash_rwlegacy
        fi
        stock_menu
        ;;

    2)
        if [[ "$unlockMenu" = true || "$hasUEFIoption" = true || "$hasLegacyOption" = true ]]; then
            flash_coreboot
        fi
        stock_menu
        ;;

    [dD])
        if [[ "${device^^}" = "EVE" ]]; then
            downgrade_touchpad_fw
        fi
        stock_menu
        ;;

    3)
        if [[ "$unlockMenu" = true || "$isChromeOS" = true || "$isUnsupported" = false &&
            "$isFullRom" = false && "$isBootStub" = false ]]; then
            set_boot_options
        fi
        stock_menu
        ;;

    4)
        if [[ "$unlockMenu" = true || "$isChromeOS" = true || "$isUnsupported" = false &&
            "$isFullRom" = false && "$isBootStub" = false ]]; then
            set_hwid
        fi
        stock_menu
        ;;

    5)
        if [[ "$unlockMenu" = true || ("$isFullRom" = false && "$isBootStub" = false &&
            ("$isHsw" = true || "$isBdw" = true || "$isByt" = true || "$isBsw" = true)) ]]; then
            remove_bitmaps
        fi
        stock_menu
        ;;

    6)
        if [[ "$unlockMenu" = true || ("$isFullRom" = false && "$isBootStub" = false &&
            ("$isHsw" = true || "$isBdw" = true || "$isByt" = true || "$isBsw" = true)) ]]; then
            restore_bitmaps
        fi
        stock_menu
        ;;

    7)
        if [[ "$unlockMenu" = true || "$isChromeOS" = false && "$isUnsupported" = false &&
            "$isFullRom" = true ]]; then
            restore_stock_firmware
        fi
        stock_menu
        ;;

    8)
        if [[ "$unlockMenu" = true || "$isBootStub" = true ]]; then
            restore_boot_stub
        fi
        stock_menu
        ;;

    [rR])
        echo -e "\nRebooting...\n"
        cleanup
        reboot
        exit
        ;;

    [pP])
        echo -e "\nPowering off...\n"
        cleanup
        poweroff
        exit
        ;;

    [qQ])
        cleanup
        exit
        ;;

    [U])
        if [ "$unlockMenu" = false ]; then
            echo_yellow "\nAre you sure you wish to unlock all menu functions?"
            read -ep "Only do this if you really know what you are doing... [y/N]? "
            [[ "$REPLY" = "y" || "$REPLY" = "Y" ]] && unlockMenu=true
        fi
        stock_menu
        ;;

    [cC])
        if [[ "$unlockMenu" = true || "$isUEFI" = true ]]; then
            clear_nvram
        fi
        stock_menu
        ;;

    *)
        clear
        stock_menu
        ;;
    esac
}
