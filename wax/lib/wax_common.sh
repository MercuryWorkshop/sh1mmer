#!/usr/bin/env bash
# wax common file, this should probably be sourced

# internal variables
COLOR_RESET="\033[0m"
COLOR_BLACK_B="\033[1;30m"
COLOR_RED_B="\033[1;31m"
COLOR_GREEN="\033[0;32m"
COLOR_GREEN_B="\033[1;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_YELLOW_B="\033[1;33m"
COLOR_BLUE_B="\033[1;34m"
COLOR_MAGENTA_B="\033[1;35m"
COLOR_CYAN_B="\033[1;36m"

fail() {
	printf "${COLOR_RED_B}%b${COLOR_RESET}\n" "$*" >&2 || :
	exit 1
}

readlink /proc/$$/exe | grep -q bash || fail "Please run with bash"

check_deps() {
	for dep in "$@"; do
		command -v "$dep" &>/dev/null || echo "$dep"
	done
}

log_debug() {
	[ "${FLAGS_debug:-0}" = "${FLAGS_TRUE:-1}" ] && printf "${COLOR_YELLOW}Debug: %b${COLOR_RESET}\n" "$*" >&2 || :
}

log_info() {
	printf "${COLOR_GREEN}Info: %b${COLOR_RESET}\n" "$*" || :
}

log_warn() {
	printf "${COLOR_YELLOW}Warning: %b${COLOR_RESET}\n" "$*" || :
}

log_error() {
	printf "${COLOR_RED_B}Error: %b${COLOR_RESET}\n" "$*" || :
}

suppress() {
	if [ "${FLAGS_debug:-0}" = "${FLAGS_TRUE:-1}" ]; then
		"$@"
	else
		"$@" &>/dev/null
	fi
}

suppress_out() {
	if [ "${FLAGS_debug:-0}" = "${FLAGS_TRUE:-1}" ]; then
		"$@"
	else
		"$@" >/dev/null
	fi
}

SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}

load_shflags() {
	if [ -f "${SCRIPT_DIR}/lib/shflags" ]; then
		. "${SCRIPT_DIR}/lib/shflags"
	elif [ -f "${SCRIPT_DIR}/shflags" ]; then
		. "${SCRIPT_DIR}/shflags"
	else
		echo "ERROR: Cannot find the required shflags library."
		return 1
	fi
}

is_ext2() {
	local rootfs="$1"
	local offset="${2-0}"

	local sb_magic_offset=$((0x438))
	local sb_value=$(dd if="$rootfs" skip=$((offset + sb_magic_offset)) \
		count=2 bs=1 2>/dev/null)
	local expected_sb_value=$(printf '\123\357')
	if [ "$sb_value" = "$expected_sb_value" ]; then
		return 0
	fi
	return 1
}

enable_rw_mount() {
	local rootfs="$1"
	local offset="${2-0}"

	if ! is_ext2 "$rootfs" $offset; then
		echo "enable_rw_mount called on non-ext2 filesystem: $rootfs $offset" 1>&2
		return 1
	fi

	local ro_compat_offset=$((0x464 + 3))
	printf '\000' |
		dd of="$rootfs" seek=$((offset + ro_compat_offset)) \
			conv=notrunc count=1 bs=1 2>/dev/null
}

disable_rw_mount() {
	local rootfs="$1"
	local offset="${2-0}"

	if ! is_ext2 "$rootfs" $offset; then
		echo "disable_rw_mount called on non-ext2 filesystem: $rootfs $offset" 1>&2
		return 1
	fi

	local ro_compat_offset=$((0x464 + 3))
	printf '\377' |
		dd of="$rootfs" seek=$((offset + ro_compat_offset)) \
			conv=notrunc count=1 bs=1 2>/dev/null
}

rw_mount_disabled() {
	local rootfs="$1"
	local offset="${2-0}"

	if ! is_ext2 "$rootfs" $offset; then
		return 2
	fi

	local ro_compat_offset=$((0x464 + 3))
	local ro_value=$(dd if="$rootfs" skip=$((offset + ro_compat_offset)) \
		count=1 bs=1 2>/dev/null)
	local expected_ro_value=$(printf '\377')
	if [ "$ro_value" = "$expected_ro_value" ]; then
		return 0
	fi
	return 1
}

check_semver_ge() {
	local major="$(echo "$1" | cut -d. -f1)"
	local minor="$(echo "$1" | cut -d. -f2)"
	local patch="$(echo "$1" | cut -d. -f3)"
	[ "$major" -lt "$2" ] && return 1
	[ "$major" -gt "$2" ] && return 0
	[ "$minor" -lt "$3" ] && return 1
	[ "$minor" -gt "$3" ] && return 0
	[ "${patch:-0}" -lt "${4:-0}" ] && return 1
	return 0
}

ARCHITECTURE="$(uname -m)"
case "$ARCHITECTURE" in
	*x86_64* | *x86-64*) ARCHITECTURE=x86_64 ;;
	*aarch64* | *armv8*) ARCHITECTURE=aarch64 ;;
	*i[3-6]86*) ARCHITECTURE=i386 ;;
	*) fail "Unsupported architecture $ARCHITECTURE" ;;
esac

if command -v sfdisk &>/dev/null && check_semver_ge "$(sfdisk --version | awk '{print $NF}')" 2 38 0; then
	log_debug "using machine's sfdisk"
	SFDISK=sfdisk
else
	log_debug "using bundled sfdisk"
	SFDISK="${SCRIPT_DIR}/lib/bin/$ARCHITECTURE/sfdisk"
	chmod +x "$SFDISK"
fi

# no way to check cgpt version, so we always use the bundled build
CGPT="${SCRIPT_DIR}/lib/bin/$ARCHITECTURE/cgpt"
chmod +x "$CGPT"

format_bytes() {
	numfmt --to=iec-i --suffix=B "$@"
}

parse_bytes() {
	numfmt --from=iec "$@" 2>/dev/null
}

check_file_rw() {
	[ -f "$1" -a -r "$1" -a -w "$1" ]
}

check_gpt_image() {
	"$SFDISK" -l "$1" 2>/dev/null | grep -q "Disklabel type: gpt"
}

check_slow_fs() {
	if uname -r | grep -qi microsoft && realpath "$1" | grep -q "^/mnt"; then
		echo "You are attempting to run wax on a file in your windows filesystem."
		echo "Performance would suffer, so please move your file into your linux filesystem (e.g. ~/file.bin)"
		exit 1
	fi
}

safesync() {
	sync
	sleep 0.2
}

get_sectors() {
	"$SFDISK" -l "$1" 2>/dev/null | grep -m 1 " sectors$" | awk '{print $(NF-1)}'
}

get_sector_size() {
	"$SFDISK" -l "$1" 2>/dev/null | grep -m 1 "^Sector size" | awk '{print $4}'
}

get_final_sector() {
	"$SFDISK" -l -o end "$1" 2>/dev/null | grep "^\s*[0-9]" | awk '{print $1}' | sort -nr | head -n 1
}

get_gpt_backup_table_sector() {
	"$CGPT" show "$1" | grep "Sec GPT table$" | awk '{print $1}'
}

get_parts() {
	"$CGPT" show -q "$1" | awk '{print $3}'
}

get_parts_physical_order() {
	local part_table=$("$CGPT" show -q "$1")
	local physical_parts=$(awk '{print $1}' <<<"$part_table" | sort -n)
	for part in $physical_parts; do
		grep "^\s*${part}\s" <<<"$part_table" | awk '{print $3}'
	done
}

delete_partitions_except() {
	local img="$1"
	local to_delete=()
	shift

	for part in $(get_parts "$img"); do
		grep -qw "$part" <<<"$@" || to_delete+=("$part")
	done

	log_info "Deleting partitions: ${to_delete[@]}"
	suppress "$SFDISK" --delete "$img" "${to_delete[@]}"
}

squash_partitions() {
	log_info "Squashing partitions"

	for part in $(get_parts_physical_order "$1"); do
		log_info "Squashing ${1}p${part}"
		suppress "$SFDISK" -N "$part" --move-data "$1" <<<"+,-" || :
	done
}

truncate_image() {
	local buffer=35 # magic number to ward off evil gpt corruption spirits
	local sector_size=$(get_sector_size "$1")
	local final_sector=$(get_final_sector "$1")
	local end_bytes=$(((final_sector + buffer) * sector_size))
	log_info "Truncating image to $(format_bytes "$end_bytes")"

	if [ -b "$1" ]; then
		local loopdev=$(losetup -f)
		losetup -P "$loopdev" "$1" --sizelimit "$end_bytes"
		suppress sgdisk -e "$loopdev" 2>&1 | sed 's/\a//g'
		losetup -d "$loopdev"
	else
		truncate -s "$end_bytes" "$1"
		suppress sgdisk -e "$1" 2>&1 | sed 's/\a//g'
	fi

	[ -z "$2" ] || echo "$end_bytes" >"$2"
}

resize_image() {
	# 1: size, 2: image, 3: loop (optional)
	if [ -b "$2" ]; then
		echo "$2 is a block device, cannot resize" >&2
		return 1
	fi
	log_info "Resizing image to $(format_bytes "$1")"
	truncate -s "$1" "$2"
	suppress sgdisk -e "$2" 2>&1 | sed 's/\a//g'
	[ -z "$3" ] || losetup -c "$3"
}

cgpt_add_auto() {
	local final_sector gpt_sector difference img_sectors sector_size new_size
	local image="$1"
	local device="$2"
	local part="$3"
	local sectors="$4"
	shift 4
	final_sector=$(get_final_sector "$device")
	gpt_sector=$(get_gpt_backup_table_sector "$device")
	difference=$((gpt_sector - final_sector - sectors - 1))
	if [ "$difference" -lt 0 ]; then
		img_sectors=$(get_sectors "$device")
		sector_size=$(get_sector_size "$device")
		# remember difference is negative
		new_size=$((sector_size * (img_sectors - difference)))
		resize_image "$new_size" "$image" "$device"
	fi
	"$CGPT" add "$device" -i "$part" -b $((final_sector + 1)) -s "$sectors" "$@"
	partx -u -n "$part" "$device"
}
