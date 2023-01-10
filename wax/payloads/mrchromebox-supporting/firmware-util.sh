#!/bin/bash
#
# This script offers provides the ability to update the
# Legacy Boot payload, set boot options, and install
# a custom coreboot firmware for supported
# ChromeOS devices
#
# Created by Mr.Chromebox <mrchromebox@gmail.com>
#
# May be freely distributed and modified as needed,
# as long as proper attribution is given.
#

#where the stuff is
script_url="https://raw.githubusercontent.com/MrChromebox/scripts/master/"

#ensure output of system tools in en-us for parsing
export LC_ALL=C

#check for cmd line param, expired CrOS certs
if ! curl -sLo /dev/null https://mrchromebox.tech/index.html || [[ "$1" = "-k" ]]; then
	export CURL="curl -k"
else
	export CURL="curl"
fi

source /usr/local/payloads/mrchromebox-supporting/sources.sh
source /usr/local/payloads/mrchromebox-supporting/firmware.sh
source /usr/local/payloads/mrchromebox-supporting/functions.sh

#set working dir
cd /tmp

#do setup stuff
prelim_setup || exit 1

#show menu
stock_menu
