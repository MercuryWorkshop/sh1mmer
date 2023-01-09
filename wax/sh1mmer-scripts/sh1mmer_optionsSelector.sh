function readinput {
	read -rsn1 mode

	case $mode in
		'') read -rsn2 mode ;;
		'') echo kB ;;
		'') echo kE ;;
		*) echo $mode ;;
	esac

	case $mode in
		'[A') echo kU ;;
		'[B') echo kD ;;
		'[D') echo kL ;;
		'[C') echo kR ;;
	esac
}
