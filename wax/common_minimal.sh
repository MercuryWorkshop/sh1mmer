#!/bin/sh
#
# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Note: This file must be written in dash compatible way as scripts that use
# this may run in the Chrome OS client enviornment.

# shellcheck disable=SC2039,SC2059,SC2155

# Determine script directory
SCRIPT_DIR=$(dirname "$0")
if [$(uname -s) -ne "Darwin"]; then
  PROG=$(basename "$0")
  : "${GPT:=cgpt}"
  : "${FUTILITY:=futility}"
else
  PROG=$(basename "$0")
  : "${GPT:=cgpt}"
  : "${FUTILITY:=futility}"
fi
# The tag when the rootfs is changed.
TAG_NEEDS_TO_BE_SIGNED="/root/.need_to_be_signed"

# List of Temporary files and mount points.
TEMP_FILE_LIST=$(mktemp)
TEMP_DIR_LIST=$(mktemp)

# Finds and loads the 'shflags' library, or return as failed.
load_shflags() {
  # Load shflags
  if [ -f /usr/share/misc/shflags ]; then
    # shellcheck disable=SC1090,SC1091
    . /usr/share/misc/shflags
  elif [ -f "${SCRIPT_DIR}/lib/shflags/shflags" ]; then
    # shellcheck disable=SC1090
    . "${SCRIPT_DIR}/lib/shflags/shflags"
  else
    echo "ERROR: Cannot find the required shflags library."
    return 1
  fi

  # Add debug option for debug output below
  DEFINE_boolean debug $FLAGS_FALSE "Provide debug messages" "d"
}

# Functions for debug output
# ----------------------------------------------------------------------------

# These helpers are for runtime systems.  For scripts using common.sh,
# they'll get better definitions that will clobber these ones.
info() {
  echo "${PROG}: INFO: $*" >&2
}

warn() {
  echo "${PROG}: WARN: $*" >&2
}

error() {
  echo "${PROG}: ERROR: $*" >&2
}

# Reports error message and exit(1)
# Args: error message
die() {
  error "$@"
  exit 1
}

# Returns true if we're running in debug mode.
#
# Note that if you don't set up shflags by calling load_shflags(), you
# must set $FLAGS_debug and $FLAGS_TRUE yourself.  The default
# behavior is that debug will be off if you define neither $FLAGS_TRUE
# nor $FLAGS_debug.
is_debug_mode() {
  [ "${FLAGS_debug:-not$FLAGS_TRUE}" = "$FLAGS_TRUE" ]
}

# Prints messages (in parameters) in debug mode
# Args: debug message
debug_msg() {
  if is_debug_mode; then
    echo "DEBUG: $*" 1>&2
  fi
}

# Functions for temporary files and directories
# ----------------------------------------------------------------------------

# Create a new temporary file and return its name.
# File is automatically cleaned when cleanup_temps_and_mounts() is called.
make_temp_file() {
  local tempfile="$(mktemp)"
  echo "$tempfile" >>"$TEMP_FILE_LIST"
  echo "$tempfile"
}

# Create a new temporary directory and return its name.
# Directory is automatically deleted and any filesystem mounted on it unmounted
# when cleanup_temps_and_mounts() is called.
make_temp_dir() {
  local tempdir=$(mktemp -d)
  echo "$tempdir" >>"$TEMP_DIR_LIST"
  echo "$tempdir"
}

cleanup_temps_and_mounts() {
  while read -r line; do
    rm -f "$line"
  done <"$TEMP_FILE_LIST"

  set +e # umount may fail for unmounted directories
  while read -r line; do
    if [ -n "$line" ]; then
      if has_needs_to_be_resigned_tag "$line"; then
        echo "Warning: image may be modified. Please resign image."
      fi
      sudo umount "$line" 2>/dev/null
      rm -rf "$line"
    fi
  done <"$TEMP_DIR_LIST"
  set -e
  rm -rf "$TEMP_DIR_LIST" "$TEMP_FILE_LIST"
}

trap "cleanup_temps_and_mounts" EXIT

# Functions for partition management
# ----------------------------------------------------------------------------

# Construct a partition device name from a whole disk block device and a
# partition number.
# This works for [/dev/sda, 3] (-> /dev/sda3) as well as [/dev/mmcblk0, 2]
# (-> /dev/mmcblk0p2).
make_partition_dev() {
  local block="$1"
  local num="$2"
  # If the disk block device ends with a number, we add a 'p' before the
  # partition number.
  if [ "${block%[0-9]}" = "${block}" ]; then
    echo "${block}${num}"
  else
    echo "${block}p${num}"
  fi
}

# Find the block size of a device in bytes
# Args: DEVICE (e.g. /dev/sda)
# Return: block size in bytes
blocksize() {
  local output=''
  local path="$1"
  if [ -b "${path}" ]; then
    local dev="${path##*/}"
    local sys="/sys/block/${dev}/queue/logical_block_size"
    output="$(cat "${sys}" 2>/dev/null)"
  fi
  echo "${output:-512}"
}

# Read GPT table to find the starting location of a specific partition.
# Args: DEVICE PARTNUM
# Returns: offset (in sectors) of partition PARTNUM
partoffset() {
  sudo "$GPT" show -b -i "$2" "$1"
}

# Read GPT table to find the size of a specific partition.
# Args: DEVICE PARTNUM
# Returns: size (in sectors) of partition PARTNUM
partsize() {
  sudo "$GPT" show -s -i "$2" "$1"
}

# Tags a file system as "needs to be resigned".
# Args: MOUNTDIRECTORY
tag_as_needs_to_be_resigned() {
  local mount_dir="$1"
  sudo touch "$mount_dir/$TAG_NEEDS_TO_BE_SIGNED"
}

# Determines if the target file system has the tag for resign
# Args: MOUNTDIRECTORY
# Returns: true if the tag is there otherwise false
has_needs_to_be_resigned_tag() {
  local mount_dir="$1"
  [ -f "$mount_dir/$TAG_NEEDS_TO_BE_SIGNED" ]
}

# Determines if the target file system is a Chrome OS root fs
# Args: MOUNTDIRECTORY
# Returns: true if MOUNTDIRECTORY looks like root fs, otherwise false
is_rootfs_partition() {
  local mount_dir="$1"
  [ -f "$mount_dir/$(dirname "$TAG_NEEDS_TO_BE_SIGNED")" ]
}

# If the kernel is buggy and is unable to loop+mount quickly,
# retry the operation a few times.
# Args: IMAGE PARTNUM MOUNTDIRECTORY [ro]
#
# This function does not check whether the partition is allowed to be mounted as
# RW.  Callers must ensure the partition can be mounted as RW before calling
# this function without |ro| argument.
_mount_image_partition_retry() {
  local image=$1
  local partnum=$2
  local mount_dir=$3
  local ro=$4
  local bs="$(blocksize "${image}")"
  local offset=$(($(partoffset "${image}" "${partnum}") * bs))
  local out try

  # shellcheck disable=SC2086
  set -- sudo LC_ALL=C mount -o loop,offset=${offset},${ro} \
    "${image}" "${mount_dir}"
  try=1
  while [ ${try} -le 5 ]; do
    if ! out=$("$@" 2>&1); then
      if [ "${out}" = "mount: you must specify the filesystem type" ]; then
        printf 'WARNING: mounting %s at %s failed (try %i); retrying\n' \
          "${image}" "${mount_dir}" "${try}"
        # Try to "quiet" the disks and sleep a little to reduce contention.
        sync
        sleep $((try * 5))
      else
        # Failed for a different reason; abort!
        break
      fi
    else
      # It worked!
      return 0
    fi
    : $((try += 1))
  done
  echo "ERROR: mounting ${image} at ${mount_dir} failed:"
  echo "${out}"
  # We don't preserve the exact exit code of `mount`, but since
  # no one in this code base seems to check it, it's a moot point.
  return 1
}

# If called without 'ro', make sure the partition is allowed to be mounted as
# 'rw' before actually mounting it.
# Args: IMAGE PARTNUM MOUNTDIRECTORY [ro]
_mount_image_partition() {
  local image=$1
  local partnum=$2
  local mount_dir=$3
  local ro=$4
  local bs="$(blocksize "${image}")"
  local offset=$(($(partoffset "${image}" "${partnum}") * bs))

  if [ "$ro" != "ro" ]; then
    # Forcibly call enable_rw_mount.  It should fail on unsupported
    # filesystems and be idempotent on ext*.
    enable_rw_mount "${image}" ${offset} 2>/dev/null
  fi

  _mount_image_partition_retry "$@"
}

# If called without 'ro', make sure the partition is allowed to be mounted as
# 'rw' before actually mounting it.
# Args: LOOPDEV PARTNUM MOUNTDIRECTORY [ro]
_mount_loop_image_partition() {
  local loopdev=$1
  local partnum=$2
  local mount_dir=$3
  local ro=$4
  local loop_rootfs="${loopdev}p${partnum}"

  if [ "$ro" != "ro" ]; then
    # Forcibly call enable_rw_mount.  It should fail on unsupported
    # filesystems and be idempotent on ext*.
    enable_rw_mount "${loop_rootfs}" 2>/dev/null
  fi

  sudo mount -o "${ro}" "${loop_rootfs}" "${mount_dir}"
}

# Mount a partition read-only from an image into a local directory
# Args: IMAGE PARTNUM MOUNTDIRECTORY
mount_image_partition_ro() {
  _mount_image_partition "$@" "ro"
}

# Mount a partition read-only from an image into a local directory
# Args: LOOPDEV PARTNUM MOUNTDIRECTORY
mount_loop_image_partition_ro() {
  _mount_loop_image_partition "$@" "ro"
}

# Mount a partition from an image into a local directory
# Args: IMAGE PARTNUM MOUNTDIRECTORY
mount_image_partition() {
  local mount_dir=$3
  _mount_image_partition "$@"
  if is_rootfs_partition "${mount_dir}"; then
    tag_as_needs_to_be_resigned "${mount_dir}"
  fi
}

# Mount a partition from an image into a local directory
# Args: LOOPDEV PARTNUM MOUNTDIRECTORY
mount_loop_image_partition() {
  local mount_dir=$3
  _mount_loop_image_partition "$@"
  if is_rootfs_partition "${mount_dir}"; then
    tag_as_needs_to_be_resigned "${mount_dir}"
  fi
}

# Mount the image's ESP (EFI System Partition) on a newly created temporary
# directory.
# Prints out the newly created temporary directory path if succeeded.
# If the image doens't have an ESP partition, returns 0 without print anything.
# Args: LOOPDEV
# Returns: 0 if succeeded, 1 otherwise.
mount_image_esp() {
  local loopdev="$1"
  local ESP_PARTNUM=12
  local loop_esp="${loopdev}p${ESP_PARTNUM}"

  local esp_offset=$(($(partoffset "${loopdev}" "${ESP_PARTNUM}")))
  # Check if the image has an ESP partition.
  if [[ "${esp_offset}" == "0" ]]; then
    return 0
  fi

  local esp_dir="$(make_temp_dir)"
  if ! sudo mount -o "${ro}" "${loop_esp}" "${esp_dir}"; then
    return 1
  fi

  echo "${esp_dir}"
  return 0
}

# Extract a partition to a file
# Args: IMAGE PARTNUM OUTPUTFILE
extract_image_partition() {
  local image=$1
  local partnum=$2
  local output_file=$3
  local offset=$(partoffset "$image" "$partnum")
  local size=$(partsize "$image" "$partnum")

  # shellcheck disable=SC2086
  dd if="$image" of="$output_file" bs=512 skip=$offset count=$size \
    conv=notrunc 2>/dev/null
}

# Replace a partition in an image from file
# Args: IMAGE PARTNUM INPUTFILE
replace_image_partition() {
  local image=$1
  local partnum=$2
  local input_file=$3
  local offset=$(partoffset "$image" "$partnum")
  local size=$(partsize "$image" "$partnum")

  # shellcheck disable=SC2086
  dd if="$input_file" of="$image" bs=512 seek=$offset count=$size \
    conv=notrunc 2>/dev/null
}

# For details, see crosutils.git/common.sh
enable_rw_mount() {
  local rootfs="$1"
  local offset="${2-0}"

  # Make sure we're checking an ext2 image
  # shellcheck disable=SC2086
  if ! is_ext2 "$rootfs" $offset; then
    echo "enable_rw_mount called on non-ext2 filesystem: $rootfs $offset" 1>&2
    return 1
  fi

  local ro_compat_offset=$((0x464 + 3)) # Set 'highest' byte
  # Dash can't do echo -ne, but it can do printf "\NNN"
  # We could use /dev/zero here, but this matches what would be
  # needed for disable_rw_mount (printf '\377').
  printf '\000' |
    sudo dd of="$rootfs" seek=$((offset + ro_compat_offset)) \
      conv=notrunc count=1 bs=1 2>/dev/null
}

# For details, see crosutils.git/common.sh
is_ext2() {
  local rootfs="$1"
  local offset="${2-0}"

  # Make sure we're checking an ext2 image
  local sb_magic_offset=$((0x438))
  local sb_value=$(sudo dd if="$rootfs" skip=$((offset + sb_magic_offset)) \
    count=2 bs=1 2>/dev/null)
  local expected_sb_value=$(printf '\123\357')
  if [ "$sb_value" = "$expected_sb_value" ]; then
    return 0
  fi
  return 1
}

disable_rw_mount() {
  local rootfs="$1"
  local offset="${2-0}"

  # Make sure we're checking an ext2 image
  # shellcheck disable=SC2086
  if ! is_ext2 "$rootfs" $offset; then
    echo "disable_rw_mount called on non-ext2 filesystem: $rootfs $offset" 1>&2
    return 1
  fi

  local ro_compat_offset=$((0x464 + 3)) # Set 'highest' byte
  # Dash can't do echo -ne, but it can do printf "\NNN"
  # We could use /dev/zero here, but this matches what would be
  # needed for disable_rw_mount (printf '\377').
  printf '\377' |
    sudo dd of="$rootfs" seek=$((offset + ro_compat_offset)) \
      conv=notrunc count=1 bs=1 2>/dev/null
}

rw_mount_disabled() {
  local rootfs="$1"
  local offset="${2-0}"

  # Make sure we're checking an ext2 image
  # shellcheck disable=SC2086
  if ! is_ext2 "$rootfs" $offset; then
    return 2
  fi

  local ro_compat_offset=$((0x464 + 3)) # Set 'highest' byte
  local ro_value=$(sudo dd if="$rootfs" skip=$((offset + ro_compat_offset)) \
    count=1 bs=1 2>/dev/null)
  local expected_ro_value=$(printf '\377')
  if [ "$ro_value" = "$expected_ro_value" ]; then
    return 0
  fi
  return 1
}

# Functions for CBFS management
# ----------------------------------------------------------------------------

# Get the compression algorithm used for the given CBFS file.
# Args: INPUT_CBFS_IMAGE CBFS_FILE_NAME
get_cbfs_compression() {
  cbfstool "$1" print -r "FW_MAIN_A" | awk -vname="$2" '$1 == name {print $5}'
}

# Store a file in CBFS.
# Args: INPUT_CBFS_IMAGE INPUT_FILE CBFS_FILE_NAME
store_file_in_cbfs() {
  local image="$1"
  local file="$2"
  local name="$3"
  local compression=$(get_cbfs_compression "$1" "${name}")

  # Don't re-add a file to a section if it's unchanged.  Otherwise this seems
  # to break signature of existing contents.  https://crbug.com/889716
  if cbfstool "${image}" extract -r "FW_MAIN_A,FW_MAIN_B" \
    -f "${file}.orig" -n "${name}"; then
    if cmp -s "${file}" "${file}.orig"; then
      rm -f "${file}.orig"
      return
    fi
    rm -f "${file}.orig"
  fi

  cbfstool "${image}" remove -r "FW_MAIN_A,FW_MAIN_B" -n "${name}" || return
  # This add can fail if
  # 1. Size of a signature after compression is larger
  # 2. CBFS is full
  # These conditions extremely unlikely become true at the same time.
  cbfstool "${image}" add -r "FW_MAIN_A,FW_MAIN_B" -t "raw" \
    -c "${compression}" -f "${file}" -n "${name}" || return
}

# Misc functions
# ----------------------------------------------------------------------------

# Parses the version file containing key=value lines
# Args: key file
# Returns: value
get_version() {
  local key="$1"
  local file="$2"
  awk -F= -vkey="${key}" '$1 == key { print $NF }' "${file}"
}

# Returns true if all files in parameters exist.
# Args: List of files
ensure_files_exist() {
  local filename return_value=0
  for filename in "$@"; do
    if [ ! -f "$filename" ] && [ ! -b "$filename" ]; then
      echo "ERROR: Cannot find required file: $filename"
      return_value=1
    fi
  done

  return $return_value
}

# Check if the 'chronos' user already has a password
# Args: rootfs
no_chronos_password() {
  local rootfs=$1
  # Make sure the chronos user actually exists.
  if grep -qs '^chronos:' "${rootfs}/etc/passwd"; then
    sudo grep -q '^chronos:\*:' "${rootfs}/etc/shadow"
  fi
}

# Returns true if given ec.bin is signed or false if not.
is_ec_rw_signed() {
  ${FUTILITY} dump_fmap "$1" | grep -q KEY_RO
}
