#!/bin/bash

shopt -s nullglob

CHR_ESC=$(printf "\x1b")
CHR_BS=$(printf "\x08")
CHR_DEL=$(printf "\x7f")

readinput() {
	local mode
	# discard stdin
	read -rsn 10000 -t 0.1 mode || :
	read -rsn1 mode

	case "$mode" in
		"$CHR_ESC") read -rsn2 mode ;;
		"$CHR_BS" | "$CHR_DEL") echo kB ;;
		"") echo kE ;;
		*) echo "$mode" ;;
	esac

	case "$mode" in
		"[A") echo kU ;;
		"[B") echo kD ;;
		"[D") echo kL ;;
		"[C") echo kR ;;
	esac
}

function setup() {
	stty -echo # turn off showing of input
	printf "\033[?25l" # turn off cursor so that it doesn't make holes in the image
	printf "\033[2J\033[H" # clear screen
	sleep 0.1
}

function cleanup() {
	printf "\033[2J\033[H" # clear screen
	printf "\033[?25h" # turn on cursor
	stty echo
}

function movecursor_generic() {
	printf "\033[$((2+$1));1H"
}

run_task() {
	cleanup
	chmod +x "$1"
	if (cd "$(dirname "$1")" && "$@"); then
		echo "Done."
	else
		echo "TASK FAILED."
	fi
	echo "Press enter."
	read -res
	setup
}

mapname() {
	case "$(basename "$1")" in
		'autoupdate.sh') echo -n "Fetch updated payloads. REQUIRES WIFI (not working)" ;;
		'caliginosity.sh') echo -n "Revert all changes made by sh1mmer (reenroll + more)" ;;
		'crap.sh') echo -n "CRAP - ChromeOS Automated Partitioning" ;;
		'cryptosmite.sh') echo -n "Cryptosmite (unenrollment up to r119, by writable)" ;;
		'defog.sh') echo -n "Set GBB flags to allow devmode and unenrollment on r112-113. WRITE PROTECTION MUST BE DISABLED" ;;
		'icarus.sh') echo -n "Icarus (unenrollment up to r129, by writable)";;
		'movie.sh') echo -n "HAHA WINDOWS SUX BUT THE MOVIE" ;;
		'mrchromebox.sh') echo -n "MrChromebox firmware-util.sh" ;;
		'reset-kern-rollback.sh') echo -n "Reset kernel rollback version" ;;
		'troll.sh') echo -n "hahah wouldn't it be realllly funny if you ran this payload trust me nothing bad will happen" ;;
		'weston.sh') echo -n "Launch the weston Desktop Environment. REQUIRES A DEVSHIM" ;;
		'wifi.sh') echo -n "Connect to wifi" ;;
		'wp-disable.sh') echo -n "WP disable loop (for pencil method)" ;;
		*) echo -n "$1" ;;
	esac
}

selectorLoop() {
	local selected idx input
	selected=0
	while :; do
		idx=0
		for opt in "$@"; do
			movecursor_generic $idx >&2
			if [ $idx -eq $selected ]; then
				printf "\033[0;36m" >&2
				echo -n "--> $(mapname "$opt")" >&2
			else
				printf "\033[0m" >&2
				echo -n "    $(mapname "$opt")" >&2
			fi
			printf "\033[0m" >&2
			((idx++))
		done
		input=$(readinput)
		case "$input" in
		'kB') return 1 ;;
		'kE') echo $selected; return ;;
		'kU')
			((selected--))
			if [ $selected -lt 0 ]; then selected=$(($# - 1)); fi
			;;
		'kD')
			((selected++))
			if [ $selected -ge $# ]; then selected=0; fi
			;;
		esac
	done
}

setup
while :; do
	clear
	echo "Press backspace to go back"
	options=(/payloads/*.sh)
	if ! sel=$(selectorLoop "${options[@]}"); then
		cleanup
		exit 0
	fi
	clear
	run_task "${options[$sel]}"
done
