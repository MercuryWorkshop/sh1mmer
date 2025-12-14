#!/bin/bash

TARGET=/usr/sbin/sh1mmer_main.sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LD_LIBRARY_PATH=/lib64:/lib:/usr/lib64:/usr/lib:/usr/local/lib64:/usr/local/lib

# from https://chromium.googlesource.com/chromiumos/platform/factory_installer/+/HEAD/factory_tty.sh
# slightly modified

# TTY_CONSOLE will be changed by build script (values from make.conf).
TTY_CONSOLE=""
export TTY=""
export LOG_TTY=""
export INFO_TTY=""
export DEBUG_TTY=""
FRECON_LITE_PATH=/sbin/frecon-lite
FRECON_PATH=/sbin/frecon
FRECON_TTY=/run/frecon/vt0

# Prints to kernel message (for debugging before TTY is setup).
kernel_msg() {
	if [ -e "/dev/kmsg" ]; then
		echo "$0: $*" >>/dev/kmsg || true
	fi
}

# Extracts tokens from kernel command line.
kernel_get_var() {
	local token="$1="
	local entry="$(cat /proc/cmdline)"
	local result=""
	while echo "${entry}" | grep -q "${token}" ; do
		entry="${entry#*${token}}"
		result="${entry%%[ ,]*} ${result}"
		entry="${entry#* }"
	done
	echo "${result}"
}

# Checks if given parameter is a valid TTY (or PTS) device file.
tty_is_valid() {
	[ -c "$1" ] && (echo "" >"$1") 2>/dev/null
}

# Starts the 'frecon' daemon.
tty_start_frecon() {
	pkill -9 frecon || :
	rm -rf /run/frecon
	kernel_msg "Starting frecon..."
	if [ "${FRECON_PATH}" != "${FRECON_LITE_PATH}" ]; then
		udevd --daemon
		udevadm trigger
		udevadm settle
	fi
	"${FRECON_PATH}" --enable-vt1 --daemon --no-login --enable-vts \
		--pre-create-vts --num-vts=8 --enable-gfx
	local loop_time=100
	while [ ! -e "${FRECON_TTY}" -a ${loop_time} -gt 0 ]; do
		kernel_msg " ${FRECON_TTY} does not exist. Retry for $((loop_time / 10)) seconds."
		sleep 0.1
		loop_time=$((loop_time - 1))
	done
	if [ ! -e "${FRECON_TTY}" ]; then
		kernel_msg "Frecon failed to start."
	else
		kernel_msg "Frecon is ready."
	fi
}

# Finds if the TTY can be enumerated with given index.
tty_find_relative() {
	local tty="$1"
	local offset="$2"
	# dash does not support [^0-9].
	local tty_num="${tty##*[a-zA-Z_/]}"
	local tty_base="${tty%${tty_num}}"
	if [ -z "${tty_num}" ]; then
		return
	fi
	local new_tty="${tty_base}$((tty_num + offset))"
	if tty_is_valid "${new_tty}"; then
		echo "${new_tty}"
	fi
}

#######################################
# Configure TTY console with options
# Arguments:
#	 Path to TTY (required as first argument).
#	 --enable_input (optional)
#	 --enable_cursor (optional)
# Returns:
#	 None
#######################################
config_console() {
	if [ $# -lt 1 ]; then
		kernel_msg "Not enough input, please provide TTY path."
		return
	fi
	local TTY="$1"
	shift
	if ! tty_is_valid "${TTY}"; then
		kernel_msg "Invalid TTY ${TTY}."
		return
	fi
	kernel_msg "Configuring ${TTY} ..."
	while [ $# -ne 0 ]; do
		case "$1" in
			--enable_input)
				printf "\033]input:on\a" > "${TTY}"
				kernel_msg "Input enabled."
				shift
				;;
			--enable_cursor)
				printf "\033[?25h" > "${TTY}"
				kernel_msg "Cursor enabled."
				shift
				;;
			--*)
				kernel_msg "Unknown option $1."
				return
				;;
			*)
				break
				;;
		esac
	done
}

# Determine and setup (if needed) TTYs (TTY, LOG_TTY, INFO_TTY, DEBUG_TTY).
# TTY is detected by following order:
#	- The last non-empty console= from cmdline.
#	- If fbdev and fbcon both exist, try /dev/tty1.
#	- ${FRECON_TTY} if available.
#	- If frecon-lite is available, start frecon-lite and try ${FRECON_TTY}.
#	- ${TTY_CONSOLE} if non-empty (which may be a list).
#	- /dev/null if nothing else.
tty_init() {
	local ttys="$(kernel_get_var console)"
	local tty_name="" tty_path=""
	TTY=""
	# Always use frecon-lite if possible.
	if [ -x "${FRECON_LITE_PATH}" ]; then
		FRECON_PATH="${FRECON_LITE_PATH}"
	fi
	# /dev/tty1 should be tried earlier if the device has fbdev and fbcon.
	if ! pgrep frecon >/dev/null 2>&1; then
		export HAS_FRECON=0
		ttys="${ttys} tty1"
	else
		export HAS_FRECON=1
		tty_start_frecon
		local frecon_tty="$(readlink -f ${FRECON_TTY})"
		ttys="${frecon_tty#/dev/} ${ttys}"
	fi
	ttys="${ttys} ${TTY_CONSOLE} null"
	kernel_msg "Finding best TTY from ${ttys}..."
	for tty_name in ${ttys}; do
		tty_path="/dev/${tty_name}"
		if tty_is_valid "${tty_path}"; then
			TTY="${tty_path}"
			break
		fi
	done
	# Devices using tty2 are actually using tty1 as default console.
	[ "${TTY}" = /dev/tty2 ] && TTY=/dev/tty1
	if [ $HAS_FRECON -eq 1 ]; then
		LOG_TTY="$(readlink -f "$(tty_find_relative "${FRECON_TTY}" 1)")"
		INFO_TTY="$(readlink -f "$(tty_find_relative "${FRECON_TTY}" 2)")"
		DEBUG_TTY="$(readlink -f "$(tty_find_relative "${FRECON_TTY}" 3)")"
	else
		LOG_TTY="$(tty_find_relative "${TTY}" 1)"
		INFO_TTY="$(tty_find_relative "${TTY}" 2)"
		DEBUG_TTY="$(tty_find_relative "${TTY}" 3)"
	fi
	# Sending escapes to enable input. Frecon is changing its behavior
	# to disable input and cursor by default. See b/271954812.
	if [ $HAS_FRECON -eq 1 ]; then
		config_console "${TTY}" --enable_input
		config_console "${LOG_TTY}" --enable_input
		config_console "${INFO_TTY}" --enable_input
		config_console "${DEBUG_TTY}" --enable_input
	fi
	kernel_msg "TTY=${TTY} LOG=${LOG_TTY} INFO=${INFO_TTY} DEBUG=${DEBUG_TTY}"
}

tty_init
setsid sh -c "exec script -afqc 'while :; do printf \"\033[?25h\033[2J\033[H[Debug Console]\n\"; /bin/bash || :; done' /dev/null <${DEBUG_TTY} >>${DEBUG_TTY} 2>&1" & disown
chmod +x "$TARGET"
exec setsid sh -c "exec script -afqc '$TARGET || sleep 1d' /dev/null <${TTY} >>${TTY} 2>&1"
