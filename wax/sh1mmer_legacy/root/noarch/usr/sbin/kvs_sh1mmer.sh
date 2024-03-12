#!/bin/bash
# KVS: Kernel Version Switcher
# Written by kxtzownsu / kxtz#8161
# https://kxtz.dev
# Licensed under GNU Affero GPL v3

version=1
GITHUB_URL="https://github.com/MercuryWorkshop/sh1mmer"
tpmver=$(tpmc tpmver)

if [ "$tpmver" == "2.0" ]; then
  tpmdaemon="trunksd"
else
  tpmdaemon="tscd"
fi

# give me thy kernver NOW
case "$(crossystem tpm_kernver)" in
  "0x00000000")
    kernver="0"
    ;;
  "0x00010001")
    kernver="1"
    ;;
  "0x00010002")
    kernver="2"
    ;;
  "0x00010003")
    kernver="3"
    ;;
  *)
    panic "invalid-kernver"
    ;;
esac

if [ -f /tmp/current-kernver ]; then
  echo "kernver file exists.."
  kernver="$(cat /tmp/current-kernver)"
fi


# detect if booted from usb boot or from recovery boot
if [ "$(crossystem mainfw_type)" == "recovery" ]; then
  source /usr/share/kvs/tpmutil.sh
  source /usr/share/kvs/functions.sh
  mkdir -p /mnt/state &2>&1 /dev/zero
  mount --bind /opt/kvs/ /mnt/state
  # for the kernver backup, only mount this to the SH1mmer partiton!
  mkdir -p /mnt/realstate &2>&1 /dev/zero
  stop $tpmdaemon
  clear
elif [ "$(crossystem mainfw_type)" == "developer" ]; then
  source /usr/share/kvs/tpmutil.sh
  source /usr/share/kvs/functions.sh
  panic "non-reco"
  sleep infinity
fi

credits(){
  echo "KVS: Kernel Version Switcher v$version (SH1mmer Edition)"
  echo "Current kernver: $kernver"
  echo "TPM Version: $tpmver"
  echo "TPMD: $tpmdaemon"
  echo "-=-=-=-=-=-=-=-=-=-=-"
  echo "kxtzownsu - Writing KVS, Providing kernver 0 & kernver 1 files."
  echo "planetearth1363 - Providing kernver 2 files."
  echo "miimaker - Providing kernver 3 files."
  echo "OlyB - Helping me figure out the shim builder, seriously, thanks."
  echo "Google - Writing the 'tpmc' command :3"
}

endkvs(){
  clear
  echo "KVS: Kernel Version Switcher v$version (SH1mmer Edition)"
  echo "Current kernver: $kernver"
  echo "TPM Version: $tpmver"
  echo "TPMD: $tpmdaemon"
  echo "-=-=-=-=-=-=-=-=-=-=-"
  credits | tail -n 5
  echo "-=-=-=-=-=-=-=-=-=-=-"
  echo "Exiting KVS in 3 seconds..."
  sleep 3
  exit 0
}


main(){
  clear
  echo "KVS: Kernel Version Switcher v$version (SH1mmer Edition)"
  echo "Current kernver: $kernver"
  echo "TPM Version: $tpmver"
  echo "TPMD: $tpmdaemon"
  echo "-=-=-=-=-=-=-=-=-=-=-"
  echo "1) Set New kernver"
  echo "2) Backup kernver"
  echo "3) Credits"
  echo "4) Exit"
  printf '\x1b[?25h'
  read -rep "$(printf '\x1b[?25h')> " sel
  
  selection $sel
}


style_text "NOTICE: KVS is for UNENROLLED CHROMEBOOKS ONLY!"
echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-"
echo "Press ENTER to continue to KVS"
read -res
main