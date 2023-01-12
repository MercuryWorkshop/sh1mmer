source /usr/local/payloads/lib/gui_lib.sh

movecursor 0
echo "Wings - SH1MMER Wifi Payload"
movecursor 1
echo "Will only work with Open and password-only networks, not EAP networks. Leave password blank for Open networks."
movecursor 2
echo "Made by r58Playz"
movecursor 3
allowtext
read -p "network > " network
movecursor 4
read -p "password> " password
disallowtext
movecursor 5
/usr/local/bin/python3 /usr/local/autotest/client/cros/scripts/wifi connect $network $password
