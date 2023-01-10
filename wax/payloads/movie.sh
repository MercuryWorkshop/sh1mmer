source /usr/local/payloads/gui_lib.sh
showimage /usr/share/sh1mmer-assets/Logs.png
for file in /usr/local/payloads/movie-supporting/*.png; do
	showimageScale $file 2
	sleep 0.03
done

