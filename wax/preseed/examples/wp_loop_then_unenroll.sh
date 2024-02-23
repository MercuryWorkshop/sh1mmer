#!/usr/bin/bash


# THIS IS COMPLETELY UNTESTED


echo -e "${COLOR_GREEN_B}Loaded preseed file.${COLOR_RESET}"
credits
echo -e "@twinspikes - this script\n" # lol

countdown() {
    for i in {10..1}; do
        read -t  1 -n  1 input
        if [ "$input" = "Q" ]; then
            echo -e "${COLOR_CYAN_B}\ncountdown canceled      ${COLOR_RESET}"
            exec bash
            return
        fi
        echo -ne "${COLOR_RED_B}$i seconds remaining   ${COLOR_RESET}\r"
        sleep 1
    done
    echo -e "\n${COLOR_RED_B}rebooting${COLOR_RESET}"
    reboot
}

finish_unenrolling() {
    echo -e "${COLOR_GREEN_B}Setting GBB flags...${COLOR_RESET}"
    /usr/share/vboot/bin/set_gbb_flags.sh 0x8090
    echo -e "${COLOR_GREEN_B}Deprovisioning...${COLOR_RESET}"
    deprovision
    echo -e "${COLOR_GREEN_B}Enabling USB boot...${COLOR_RESET}"
    enable_usb_boot
    echo -e "${COLOR_RED_B}Rebooting in 10 seconds; press SHIFT+Q to cancel${COLOR_RESET}"
    countdown
}


wp_disable_loop() {
    while :; do
        if flashrom --wp-disable; then
            echo -e "${COLOR_GREEN_B}Successfully disabled software WP${COLOR_RESET}"
            finish_unenrolling
        fi
        echo -e "${COLOR_RED_B}Press SHIFT+Q to cancel.${COLOR_RESET}"
        if [ "$(poll_key)" = "Q" ]; then
            printf "\nCanceled\n"
            return 1
        fi
        sleep 1
    done
}

wp_disable_loop