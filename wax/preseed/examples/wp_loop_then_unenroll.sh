#!/usr/bin/bash

echo "don't use this script, it's unfinished"
echo "here's a root shell for whatever you're trying to do"
exec bash

credits
echo -e "@twinspikes - this script\n"


finish_unenrolling() {
    /usr/share/vboot/bin/set_gbb_flags.sh 0x8090
    deprovision
    enable_usb_boot
    
}


wp_disable_loop() {
    while :; do
        if flashrom --wp-disable; then
            echo -e "${COLOR_GREEN_B}Successfully disabled software WP${COLOR_RESET}"
            
        fi
        echo -e "${COLOR_RED_B}Press SHIFT+Q to cancel.${COLOR_RESET}"
        if [ "$(poll_key)" = "Q" ]; then
            printf "\nCanceled\n"
            return 1
        fi
        sleep 1
    done
}