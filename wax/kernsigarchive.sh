#!/usr/bin/env bash

set -eE

shellball_source="https://www.mrchromebox.tech/files/firmware/shellball/"

fail() {
	printf "%b\n" "$*" >&2
	exit 1
}

readlink /proc/$$/exe | grep -q bash || fail "Please run with bash"

check_deps() {
	for dep in "$@"; do
		command -v "$dep" &>/dev/null || echo "$dep"
	done
}

missing_deps=$(check_deps futility cbfstool jq curl unzip)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

cleanup() {
	[ -d "$MNT_ROOT" ] && umount "$MNT_ROOT" && rmdir "$MNT_ROOT"
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	[ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
	trap - EXIT INT
}

should_dump_keys() {
	grep -q "^$1;root;" "$OUTFILE" && grep -q "^$1;recovery;" "$OUTFILE" && return 1
	return 0
}

# 1: name
# 2: type (root or recovery)
# 3: version
# 4: algorithm
# 5: sha1
# 6: path to public key
dump_keys() {
	echo "Dumping $2 v$3 signature for $1" >&2
	echo -n "$1;$2;$3;$4;$5;"
	base64 -w0 "$6"
	echo ""
}

get_recovery_image_url() {
	local json model
	if jq -r ".builds.\"$1\" | keys" "$WORKDIR"/recovery_googlemeet.json >/dev/null 2>&1; then
		json="$WORKDIR"/recovery_googlemeet.json
	else
		json="$WORKDIR"/recovery_chromeos.json
	fi
	if model=$(jq -r "[.builds.\"$1\".models | to_entries[] | select(.value.pushRecoveries != {}) | .key] | first" "$json" 2>/dev/null); then
		jq -r ".builds.\"$1\".models.\"$model\".pushRecoveries | to_entries | last.value" "$json"
	else
		jq -r ".builds.\"$1\".pushRecoveries | to_entries | last.value" "$json"
	fi
}

trap 'echo $BASH_COMMAND failed with exit code $?.' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

[ -z "$1" ] && fail "Usage: $0 <output.txt> [search dir]"
[ "$EUID" -ne 0 ] && fail "Please run as root"
OUTFILE="$1"
SEARCHDIR="$2"
WORKDIR=$(mktemp -d)
[ -z "$SUDO_USER" ] || USER="$SUDO_USER"
touch "$OUTFILE"
chown "$USER:$USER" "$OUTFILE"

echo "Getting ChromeOS list"
curl 'https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS' -so "$WORKDIR"/recovery_chromeos.json
echo "Getting Google Meet list"
curl 'https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Google%20Meet%20Hardware' -so "$WORKDIR"/recovery_googlemeet.json

BOARDS=($(jq -r '.builds | keys[]' "$WORKDIR"/recovery_chromeos.json))
BOARDS+=($(jq -r '.builds | keys[]' "$WORKDIR"/recovery_googlemeet.json))
BOARDS=($(printf "%s\n" "${BOARDS[@]}" | sort))
echo "Found ${#BOARDS[@]} boards"

# TODO: maybe skip "nirva" and any board that ends with "-cfm", as these are duplicates
# TODO: also download OnHub firmware

if should_dump_keys developer; then
	dump_keys developer root 1 "11 RSA8192 SHA512" b11d74edd286c144e1135b49e7f0bc20cf041f10 /usr/share/vboot/devkeys/root_key.vbpubk >>"$OUTFILE"
	dump_keys developer recovery 1 "11 RSA8192 SHA512" c14bd720b70d97394257e3e826bd8f43de48d4ed /usr/share/vboot/devkeys/recovery_key.vbpubk >>"$OUTFILE"
fi

for board in "${BOARDS[@]}"; do
	if ! should_dump_keys "board:$board"; then
		echo "Skipping $board, already exists"
		continue
	fi
	rom="$WORKDIR"/rom.bin
	gbb="$WORKDIR"/gbb.bin
	rootkey="$WORKDIR"/root_key.vbpubk
	reckey="$WORKDIR"/recovery_key.vbpubk
	echo "Attempting to download shellball for $board..."
	if curl -f "$shellball_source"/shellball."$board".bin -o "$rom"; then
		echo "Success"
	else
		rec_zip=""
		echo "Failed, looking for recovery image..."
		if [ -d "$SEARCHDIR" ] && rec_zip=$(find "$SEARCHDIR" -maxdepth 2 -name "chromeos_*_${board}_recovery_*.bin.zip" -print -quit) && [ -n "$rec_zip" ]; then
			echo "Found"
		else
			echo "Failed, will download..."
			rec_zip="$WORKDIR"/image.zip
			rec_url=$(get_recovery_image_url "$board")
			echo "Downloading from $rec_url..."
			curl "$rec_url" -o "$rec_zip"
		fi
		rec_dir="$WORKDIR"/extract
		MNT_ROOT="$WORKDIR"/mnt
		sb_dir="$WORKDIR"/shellball
		mkdir -p "$rec_dir" "$MNT_ROOT" "$sb_dir"
		echo "Extracting zip..."
		unzip "$rec_zip" -d "$rec_dir"
		echo "Extracting shellball..."
		LOOPDEV=$(losetup -f)
		losetup -r -P "$LOOPDEV" "$rec_dir"/*.bin
		mount "${LOOPDEV}p3" "$MNT_ROOT" -o ro,exec
		"$MNT_ROOT"/usr/sbin/chromeos-firmwareupdate --sb_extract "$sb_dir"
		umount "$MNT_ROOT"
		losetup -d "$LOOPDEV"
		sb_rom=$(find "$sb_dir" -name "bios*.bin" -print -quit)
		cp "$sb_rom" "$rom"
		rm -rf "$rec_dir" "$MNT_ROOT" "$sb_dir"
	fi
	cbfstool "$rom" read -r GBB -f "$gbb" || dd if="$rom" of="$gbb" bs=262144 skip=14 count=1 # pinetrail only case
	gbb_full=$(futility show "$gbb")
	gbb_rootkey=$(echo "$gbb_full" | grep -A4 "Root Key:")
	gbb_reckey=$(echo "$gbb_full" | grep -A4 "Recovery Key:")
	gbb_rootkey_ver=$(echo "$gbb_rootkey" | grep "Key Version:" | sed "s/\s*Key Version:\s*//g")
	gbb_reckey_ver=$(echo "$gbb_reckey" | grep "Key Version:" | sed "s/\s*Key Version:\s*//g")
	gbb_rootkey_algo=$(echo "$gbb_rootkey" | grep "Algorithm:" | sed "s/\s*Algorithm:\s*//g")
	gbb_reckey_algo=$(echo "$gbb_reckey" | grep "Algorithm:" | sed "s/\s*Algorithm:\s*//g")
	gbb_rootkey_hash=$(echo "$gbb_rootkey" | grep "Key sha1sum:" | sed "s/\s*Key sha1sum:\s*//g")
	gbb_reckey_hash=$(echo "$gbb_reckey" | grep "Key sha1sum:" | sed "s/\s*Key sha1sum:\s*//g")
	futility gbb -g --rootkey="$rootkey" --recoverykey="$reckey" "$gbb"
	dump_keys "board:$board" root "$gbb_rootkey_ver" "$gbb_rootkey_algo" "$gbb_rootkey_hash" "$rootkey" >>"$OUTFILE"
	dump_keys "board:$board" recovery "$gbb_reckey_ver" "$gbb_reckey_algo" "$gbb_reckey_hash" "$reckey" >>"$OUTFILE"
	rm "$rom" "$gbb" "$rootkey" "$reckey"
done
