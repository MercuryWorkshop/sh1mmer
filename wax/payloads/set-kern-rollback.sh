#!/bin/sh -u
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# lobotomized version of chromeos-tpm-recovery, only resets kernel space

tpmc=tpmc
crossystem=crossystem
awk=awk
tr=tr
initctl=initctl
daemon_was_running=
err=0
secdata_kernel=0x1008

tpm2_target() {
  vercheck=$($tpmc read $secdata_kernel 1 | $tr -d '\r\n[:space:]')
  if [ "$vercheck" = "10" ]; then
      return 0
  else
      return 1
  fi
}

use_v0_secdata_kernel() {
  local fwid=$(crossystem ro_fwid)
  local major=$(printf "$fwid" | cut -d. -f2)
  local minor=$(printf "$fwid" | cut -d. -f3)

  # TPM1 firmware never supports the v1 kernel space format.
  if ! tpm2_target; then
    return 0
  fi

  # First some validity checks: X -eq X checks that X is a number. cut may
  # return the whole string if no delimiter found, so major != minor checks that
  # the version was at least somewhat correctly formatted.
  if [ $major -eq $major ] && [ $minor -eq $minor ] && [ $major -ne $minor ]; then
    # Now what we really care about: is this firmware older than CL:2041695?
    if [ $major -lt 12953 ]; then
      return 0
    else
      return 1
    fi
  else
    log "Cannot parse FWID. Assuming local build that supports v1 kernel space."
    return 1
  fi
}

log() {
  echo "$*"
}

quit() {
  log "ERROR: $*"
  restart_daemon_if_needed
  log "exiting"

  exit 1
}

log_tryfix() {
  log "$*: attempting to fix"
}

log_error() {
  err=$((err + 1))
  log "ERROR: $*"
}


log_warn() {
  log "WARNING: $*"
}

write_space () {
  # do not quote "$2", as we mean to expand it here
  if ! $tpmc write $1 $2; then
    log_error "writing to $1 failed"
  else
    log "$1 written successfully"
  fi
}

reset_rw_space () {
  local index=$1
  local bytes="$2"
  local size=$(printf "$bytes" | wc -w)
  local permissions=0x1

  if tpm2_target; then
    permissions=0x40050001
  fi

  if ! $tpmc definespace $index $size $permissions; then
    log_error "could not redefine RW space $index"
    # try writing it anyway, just in case it works...
  fi

  write_space $index "$bytes"
}

restart_daemon_if_needed() {
  if [ "$daemon_was_running" = 1 ]; then
    log "Restarting ${DAEMON}..."
    $initctl start "${DAEMON}" >/dev/null
  fi
}

# ------------
# MAIN PROGRAM
# ------------

if tpm2_target; then
  DAEMON="trunksd"
else
  DAEMON="tcsd"
fi

# TPM daemon may or may not be running

log "Stopping ${DAEMON}..."
if $initctl stop "${DAEMON}" >/dev/null 2>/dev/null; then
  daemon_was_running=1
  log "done"
else
  daemon_was_running=0
  log "(was not running)"
fi

# Is the state of the PP enable flags correct?

if ! tpm2_target; then
  if ! ($tpmc getpf | grep -q "physicalPresenceLifetimeLock 1" &&
      $tpmc getpf | grep -q "physicalPresenceHWEnable 0" &&
      $tpmc getpf | grep -q "physicalPresenceCMDEnable 1"); then
    log_tryfix "bad state of physical presence enable flags"
    if $tpmc ppfin; then
      log "physical presence enable flags are now correctly set"
    else
      quit "could not set physical presence enable flags"
    fi
  fi

  # Is physical presence turned on?

  if $tpmc getvf | grep -q "physicalPresence 0"; then
    log_tryfix "physical presence is OFF, expected ON"
    # attempt to turn on physical presence
    if $tpmc ppon; then
      log "physical presence is now on"
    else
      quit "could not turn physical presence on"
    fi
  fi
else
  if ! $tpmc getvf | grep -q 'phEnable 1'; then
    quit "Platform Hierarchy is disabled, TPM can't be recovered"
  fi
fi

raw_kernel_bytes="02  4c 57 52 47  1 0 0 0  0 0 0  37" v1_raw_kernel_bytes="10  28  58  0  1 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
while true; do
  clear
  echo "0) Kernver 0 (All versions)"
  echo "1) Kernver 1 (All versions)"
  echo "2) Kernver 2 (112+)"
  echo "3) Kernver 3 (120+)"
  echo "4) Kernver 4 (125+)"
  echo "5) Kernver 5 (133+)"
  echo "6) Kernver 6 (138+)"
  read -p "Please select what kernel version you want to set: " kernver
  case $kernver in
    0) raw_kernel_bytes="02  4c 57 52 47  0 0 0 0  0 0 0  e8" v1_raw_kernel_bytes="10  28  0  0  0 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0" ;; #0x00000000
    1) raw_kernel_bytes="02  4c 57 52 47  1 0 0 0  0 0 0  37" v1_raw_kernel_bytes="10  28  58  0  1 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"  ;; #0x00000001
    2) raw_kernel_bytes="02  4c 57 52 47  2 0 0 0  0 0 0  51" v1_raw_kernel_bytes="10  28  b0  0  2 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"  ;; #0x00000002
    3) raw_kernel_bytes="02  4c 57 52 47  3 0 0 0  0 0 0  8e" v1_raw_kernel_bytes="10  28  e8  0  3 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"  ;; #0x00000003
    4) raw_kernel_bytes="02  4c 57 52 47  4 0 0 0  0 0 0  9d" v1_raw_kernel_bytes="10  28  67  0  4 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"  ;; #0x00000004
    5) raw_kernel_bytes="02  4c 57 52 47  5 0 0 0  0 0 0  42" v1_raw_kernel_bytes="10  28  3f  0  5 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"  ;; #0x00000005
    6) raw_kernel_bytes="02  4c 57 52 47  6 0 0 0  0 0 0  24" v1_raw_kernel_bytes="10  28  d7  0  6 0 0 0  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"  ;; #0x00000006
    *) continue ;;
  esac
  break
done
if use_v0_secdata_kernel; then
  reset_rw_space $secdata_kernel "$raw_kernel_bytes"
else
  reset_rw_space $secdata_kernel "$v1_raw_kernel_bytes"
fi

restart_daemon_if_needed

if [ "$err" -eq 0 ]; then
  log "Kernel rollback version has successfully been set"
else
  log_error "An error occured..."
  exit 1
fi
