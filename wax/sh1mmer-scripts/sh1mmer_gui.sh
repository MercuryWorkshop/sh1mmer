function setup() {
	stty -echo # turn off showing of input
	setterm -cursor off # turn off cursor so that it doesn't make holes in the image
	printf "\033[2J" # clear screen
	sleep 0.1
}

function movecursor_generic() {
	printf "\033[$((3+$1));6H" # move cursor to correct place for sh1mmer menu
}

function movecursor_Credits() {
	printf "\033[$((10+$1));6H" # move cursor to correct place for sh1mmer menu
}

function showbg() {
	printf "\033]image:file=/usr/share/sh1mmer-assets/$1;scale=1\a" # display image
}

function cleargui() {
	printf "\033]box:color=0x00FFFFFF;size=530,200;offset=-250,-125\a"
}

function cleanup() {
	printf "\033]box:color=0x00000000;size=1366,768;position=0,0\a" # clear screen using frecon to prevent any part of the image remaining
	printf "\033[2J" # clear screen using bash to prevent any of the menu remaining
	setterm -cursor on # turn on cursor
	printf "\033[0;0H" # set to 0,0
	stty echo
}

function test() {
	setup
	showbg "Credits.png"
	movecursor_Credits 0
	echo -n "Test"
	sleep 1
	cleanup
}

