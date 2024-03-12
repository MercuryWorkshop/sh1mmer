#!/bin/bash

style_text() {
  printf "\033[31m\033[1m\033[5m$1\033[0m\n"
}

panic(){
clear
  case "$1" in
    "invalid-kernver")
      style_text "KVS PANIC"
      printf "\033[31mERR\033[0m"
      printf ": Invalid Kernel Version. Please make a GitHub issue at \033[3;34m$GITHUB_URL\033[0m with a picture of this information.\n"
      echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-="
      echo "tpm_kernver: $(crossystem tpm_kernver)"
      echo "fwid: $(dmidecode -s bios-version) (compiled: $(dmidecode -s bios-release-date))"
      echo "date: $(date +"%m-%d-%Y %I:%M:%S %p")"
      echo "model: $(cat /sys/class/dmi/id/product_name) $(cat /sys/class/dmi/id/product_version)"
      echo "Please shutdown your device now using REFRESH+PWR"
      sleep infinity
      ;;
    "mount-error")
      style_text "KVS PANIC"
      printf "\033[31mERR\033[0m"
      printf ": Unable to mount stateful. Please make a GitHub issue at \033[3;34m$GITHUB_URL\033[0m with a picture of this information.\n"
      echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-="
      echo "tpm_kernver: $(crossystem tpm_kernver)"
      echo "fwid: $(dmidecode -s bios-version) (compiled: $(dmidecode -s bios-release-date))"
      echo "state mounted: $([ -d /mnt/state/ ] && grep -qs '/mnt/state ' /proc/mounts && echo true || echo false)"
      echo "date: $(date +"%m-%d-%Y %I:%M:%S %p")"
      echo "model: $(cat /sys/class/dmi/id/product_name) $(cat /sys/class/dmi/id/product_version)"
      echo "Please shutdown your device now using REFRESH+PWR"
      sleep infinity
      ;;
    "non-reco")
      style_text "KVS PANIC"
      printf "\033[31mERR\033[0m"
      printf ": Wrong Boot Method. To fix: boot the shim using the recovery method. (ESC+REFRESH+PWR) and \033[31mNOT\033[0m USB Boot.\n"
      echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-="
      echo "tpm_kernver: $(crossystem tpm_kernver)"
      echo "fwid: $(dmidecode -s bios-version) (compiled: $(dmidecode -s bios-release-date))"
      echo "fw mode: $(crossystem mainfw_type)"
      echo "date: $(date +"%m-%d-%Y %I:%M:%S %p")"
      echo "model: $(cat /sys/class/dmi/id/product_name) $(cat /sys/class/dmi/id/product_version)"
      echo "Please shutdown your device now using REFRESH+PWR"
      sleep infinity
      ;;
    "tpmd-not-killed")
      style_text "KVS PANIC"
      printf "\033[31mERR\033[0m"
      printf ": $tpmdaemon unable to be killed. Please make a GitHub issue at \033[3;34m$GITHUB_URL\033[0m with a picture of this information.\n"
      echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-="
      echo "tpm_kernver: $(crossystem tpm_kernver)"
      echo "fwid: $(dmidecode -s bios-version) (compiled: $(dmidecode -s bios-release-date))"
      echo "tpmd ($tpmdaemon) running: $(status $tpmdaemon | grep stopped && echo true || echo false)"
      echo "date: $(date +"%m-%d-%Y %I:%M:%S %p")"
      echo "model: $(cat /sys/class/dmi/id/product_name) $(cat /sys/class/dmi/id/product_version)"
      echo "Please shutdown your device now using REFRESH+PWR"
      sleep infinity
      ;;
    "*")
      echo "Panic ID unable to be found: $1"
      echo "Exiting script to prevent crash, please make an issue at \033[3;34m$GITHUB_URL\033[0m."
  esac
}

stopwatch() {
    display_timer() {
        printf "[%02d:%02d:%02d]\n" $hh $mm $ss
    }
    hh=0 #hours
    mm=0 #minutes
    ss=0 #seconds
    
    while true; do
        clear
        echo "Initiated reboot, if this doesn't reboot please manually reboot with REFRESH+PWR"
        echo "Time since reboot initiated:"
        display_timer
        ss=$((ss + 1))
        # if seconds reach 60, increment the minutes
        if [ $ss -eq 60 ]; then
            ss=0
            mm=$((mm + 1))
        fi
        # if minutes reach 60, increment the hours
        if [ $mm -eq 60 ]; then
            mm=0
            hh=$((hh + 1))
        fi
        sleep 1
    done
}

selection(){
  case $1 in
    "1")
      echo "Please Enter Target kernver (0-3)"
      read -rep "> " kernver
      case $kernver in
        "0")
          echo "Setting kernver 0"
          write_kernver $(cat /mnt/state/kernver0)
          echo $kernver > /tmp/current-kernver
          sleep 2
          echo "Finished writing kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        "1")
          echo "Setting kernver 1"
          write_kernver $(cat /mnt/state/kernver1)
          echo $kernver > /tmp/current-kernver
          sleep 2
          echo "Finished writing kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        "2")
          echo "Setting kernver 2"
          write_kernver $(cat /mnt/state/kernver2)
          echo $kernver > /tmp/current-kernver
          sleep 2
          echo "Finished writing kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        "3")
          echo "Setting kernver 3"
          write_kernver $(cat /mnt/state/kernver3)
          echo $kernver > /tmp/current-kernver
          sleep 2
          echo "Finished writing kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        *)
          echo "Invalid kernver. Please check your input."
          main
          ;;
      esac
      main
      ;;
    "2")
      mount /dev/disk/by-label/SH1MMER /mnt/realstate
      case $kernver in
        "0")
          echo "Current kernver: 0"
          echo "Outputting to stateful/kernver-out"
          cp /mnt/state/raw/kernver0.raw /mnt/realstate/kernver-out
          sleep 2
          echo "Finished saving kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        "1")
          echo "Current kernver: 1"
          echo "Outputting to stateful/kernver-out"
          cp /mnt/state/raw/kernver1.raw /mnt/realstate/kernver-out
          sleep 2
          echo "Finished saving kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        "2")
          echo "Current kernver: 2"
          echo "Outputting to stateful/kernver-out"
          cp /mnt/state/raw/kernver2.raw /mnt/realstate/kernver-out
          sleep 2
          echo "Finished saving kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        "3")
          echo "Current kernver: 3"
          echo "Outputting to stateful/kernver-out"
          cp /mnt/state/raw/kernver3.raw /mnt/realstate/kernver-out
          sleep 2
          echo "Finished saving kernver $kernver!"
          echo "Press ENTER to return to main menu.."
          read -r
          ;;
        *)
          panic "invalid-kernver"
          ;;
      esac
      umount /mnt/realstate
      main
      ;;
    "3")
      clear
      credits
      echo "-=-=-=-=-=-=-=-=-=-=-"
      echo "Press ENTER to return to the main menu"
      read -r
      main
      ;;
    "4")
      endkvs
      ;;
    "5")
      clear
      style_text "silly debug menu!!"
      echo "panic menu"
      echo "1) invalid-kernver"
      echo "2) mount-error"
      echo "3) non-reco"
      echo "4) tpmd-not-killed"
      echo "5) return to menu"
      read -rep "> " panicsel
      
      case $panicsel in
        "1")
          panic "invalid-kernver"
          ;;
        "2")
          panic "mount-error"
          ;;
        "3")
          panic "non-reco"
          ;;
        "4")
          panic "tpmc-not-killed"
          ;;
        "5")
          echo ""
          ;;
        "*")
          echo "invalid option, wat the flip!!!"
          ;;
      esac ;;
  esac
}
