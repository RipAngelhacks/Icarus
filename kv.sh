#!/bin/sh -u
# Copyright (c) 2010 The Chromium OS Authors.
# lobotomized version of chromeos-tpm-recovery, only resets kernel space

tpmc=tpmc
crossystem=crossystem
awk=awk
initctl=initctl
daemon_was_running=
err=0
secdata_kernel=0x1008

tpm2_target() {
  # crude detection
  if [ -f "/etc/init/trunksd.conf" ]; then
    return 0
  else
    return 1
  fi
}

use_v0_secdata_kernel() {
  # More robust FWID parsing; avoid arithmetic on empty/non-numeric
  local fwid
  fwid="$($crossystem ro_fwid 2>/dev/null || echo "")"

  # TPM1 always uses v0
  if ! tpm2_target; then
    return 0
  fi

  # Expect something like Google_Rammus.12953.145.0
  # Extract fields 2 and 3 (major/minor) only if they are numbers.
  local major minor
  major=$(printf "%s" "$fwid" | cut -d. -f2)
  minor=$(printf "%s" "$fwid" | cut -d. -f3)

  case "$major:$minor" in
    ''|*[^0-9]*:*|*:*[^0-9]*)
      log "Cannot parse FWID '$fwid'. Assuming v1 kernel space support."
      return 1
      ;;
  esac

  # Older than CL:2041695 => use v0
  if [ "$major" -lt 12953 ]; then
    return 0
  else
    return 1
  fi
}

log() { echo "$*"; }

quit() {
  log "ERROR: $*"
  restart_daemon_if_needed
  log "exiting"
  exit 1
}

log_tryfix() { log "$*: attempting to fix"; }
log_error() { err=$((err + 1)); log "ERROR: $*"; }
log_warn()  { log "WARNING: $*"; }

write_space() {
  # do not quote "$2" as we intend word expansion to send bytes
  if ! $tpmc write "$1" $2; then
    log_error "writing to $1 failed"
  else
    log "$1 written successfully"
  fi
}

reset_rw_space() {
  local index="$1"
  local bytes="$2"
  local size
  size=$(printf "%s" "$bytes" | wc -w)
  local permissions=0x1
  if tpm2_target; then
    permissions=0x40050001
  fi

  if ! $tpmc definespace "$index" "$size" "$permissions"; then
    log_error "could not redefine RW space $index"
    # try writing anyway
  fi
  write_space "$index" "$bytes"
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

log "Stopping ${DAEMON}..."
if $initctl stop "${DAEMON}" >/dev/null 2>/dev/null; then
  daemon_was_running=1
  log "done"
else
  daemon_was_running=0
  log "(was not running)"
fi

if ! tpm2_target; then
  # TPM 1.2: FIRST ensure physical presence ON
  if $tpmc getvf | grep -q "physicalPresence 0"; then
    log_tryfix "physical presence is OFF, expected ON"
    if $tpmc ppon; then
      log "physical presence is now on"
    else
      quit "could not turn physical presence on"
    fi
  fi

  # THEN fix PP enable flags
  pf="$($tpmc getpf)"
  if ! ( echo "$pf" | grep -q "physicalPresenceLifetimeLock 1" \
         && echo "$pf" | grep -q "physicalPresenceHWEnable 0" \
         && echo "$pf" | grep -q "physicalPresenceCMDEnable 1" ); then
    log_tryfix "bad state of physical presence enable flags"
    if $tpmc ppfin; then
      log "physical presence enable flags are now correctly set"
    else
      quit "could not set physical presence enable flags"
    fi
  fi
else
  # TPM 2.0: ensure Platform Hierarchy is enabled
  if ! $tpmc getvf | grep -q 'phEnable 1'; then
    quit "Platform Hierarchy is disabled, TPM can't be recovered"
  fi
fi

if use_v0_secdata_kernel; then
  reset_rw_space $secdata_kernel "02 4c 57 52 47 1 0 1 0 0 0 0 55"
else
  reset_rw_space $secdata_kernel "10 28 0c 0 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
fi

restart_daemon_if_needed

if [ "$err" -eq 0 ]; then
  log "Kernel rollback version has successfully been reset to factory defaults"
else
  log_error "An error occured..."
  exit 1
fi
