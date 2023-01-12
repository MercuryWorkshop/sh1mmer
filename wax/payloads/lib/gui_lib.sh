function movecursor() {
	printf "\033[$((3+$1));6H" # move cursor to correct place for sh1mmer menu
}

function showimage() {
	printf "\033]image:file=$1;scale=1\a" # display image
}

function cleargui() {
	showimage "/usr/share/sh1mmer-assets/terminalGeneric.png"
}

function allowtext() {
	stty echo
	setterm -cursor on
}

function disallowtext() {
	stty -echo
	setterm -cursor off
}
