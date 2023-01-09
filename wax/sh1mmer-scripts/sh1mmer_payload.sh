source /usr/sbin/sh1mmer_gui.sh
source /usr/sbin/sh1mmer_optionsSelector.sh
shopt -s nullglob

showbg terminalGeneric.png

selectorLoop() {
	selected=0
	while true; do
		idx=0
		for opt; do
			movecursor_generic $idx
			if [ $idx -eq $selected ]; then
				echo -n "--> $opt"
			else
				echo -n "    $opt"
			fi
			((idx++))
		done
		input=`readinput`
		case $input in
			'kB') exit ;;
			'kE') return $selected ;;
			'kU') ((selected--)); if [ $selected -lt 0 ]; then selected=0; fi ;;
			'kD') ((selected++)); if [ $selected -ge $# ]; then selected=$(($#-1)); fi ;;
		esac
	done
}
while true; do
	options=(/usr/local/payloads/*.sh)
	selectorLoop "${options[@]}"
	sel="$?"
	showbg terminalGeneric.png
	movecursor_generic 0
	bash "${options[$sel]}"
	sleep 2
	showbg terminalGeneric.png
done
