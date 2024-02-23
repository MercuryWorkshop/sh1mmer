#!/usr/bin/env bash

# TODO: properly error out/notify when run on a modern or raw shim

SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

PRESEED_FILENAME="usr/sbin/preseed.sh"

set -eE

[ "$EUID" -ne 0 ] && fail "Please run as root"
missing_deps=$(check_deps partx sgdisk mkfs.ext4 mkfs.ext2 e2fsck resize2fs file)
[ -n "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

cleanup () {
    log_debug "cleaning up..."
    [ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
    trap - EXIT INT
}

trap 'echo $BASH_COMMAND failed with exit code $?. THIS IS A BUG, PLEASE REPORT!' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

cat <<EOF
┌─────────────────────────────────────────────────────────────────────────────────────┐
│ welcome to the preseed injection tool (name not sexual innuendo)                    │
│ bypasses the sh1mmer menu and injects a shell script to run at boot                 │
│ (see examples @ github.com/MercuryWorkshop/sh1mmer/tree/beautifulworld/wax/preseed) │
│ credit: b0vik (darkn and r58playz provided moral support)                           │
│ prereq: prebuilt legacy shim (NOT bw/modern)                                        │
└─────────────────────────────────────────────────────────────────────────────────────┘
EOF

get_flags() {
	load_shflags

	FLAGS_HELP="Usage: $0 -s <path/to/legacy/shim.bin> -p <path/to/preseed.sh> [flags]"

	DEFINE_string shim "" "Path to prebuilt legacy shim" "s"

    DEFINE_string preseed "$SCRIPT_DIR/preseed/examples/dev_test.sh" "Path to preseed file" "p"

	DEFINE_boolean debug "$FLAGS_FALSE" "Print debug messages" "d"

	FLAGS "$@" || exit $?
	# eval set -- "$FLAGS_ARGV" # we don't need this

	if [ -z "$FLAGS_shim" ] || [ -z "$FLAGS_preseed" ]; then
		flags_help || :
		exit 1
	fi
}

inject_preseed_file() {
    log_info "injecting preseed file"

    MNT_SH1MMER=$(mktemp -d)
    
    mount "${LOOPDEV}p1" "$MNT_SH1MMER"

    SH1MMER_SCRIPT_ROOT="$MNT_SH1MMER/root/noarch"

    cp "$1" "$SH1MMER_SCRIPT_ROOT/$PRESEED_FILENAME"
    chmod +x "$SH1MMER_SCRIPT_ROOT/$PRESEED_FILENAME" # just in case

    if grep -q '# PRESEED_LOC' "$SH1MMER_SCRIPT_ROOT/usr/sbin/factory_install.sh"; then
        # if the PRESEED_LOC comment exists in factory_install.sh, insert before it
        log_debug "inserting before PRESEED_LOC"
        sed -i "/# PRESEED_LOC/i . /$PRESEED_FILENAME" "$SH1MMER_SCRIPT_ROOT/usr/sbin/factory_install.sh"
    else
        # for shims built before that was added, just insert before 'printf "\033[?25h"'
        log_debug "shim (likely) built before 2024-02-23, inserting before printf"
        sed -i "/printf \"\\\\033\[?25h\"/i . /$PRESEED_FILENAME" "$SH1MMER_SCRIPT_ROOT/usr/sbin/factory_install.sh" # aggressive character escaping there buddy
    fi

    umount "$MNT_SH1MMER"
    rmdir "$MNT_SH1MMER"

}

get_flags "$@"
IMAGE="$FLAGS_shim"
PRESEED="$FLAGS_preseed"

check_file_rw "$IMAGE" || fail "$IMAGE doesn't exist, isn't a file, or isn't RW"
check_gpt_image "$IMAGE" || fail "$IMAGE is not GPT, or is corrupted"
check_slow_fs "$IMAGE"

log_info "Creating loop device"
LOOPDEV=$(losetup -f)
losetup -P "$LOOPDEV" "$IMAGE"
safesync

inject_preseed_file "$FLAGS_preseed"
safesync

# losetup -d "$LOOPDEV"

log_info "Injection successful."

trap - EXIT