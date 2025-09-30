#!/bin/sh -eu
# chromeos-safe-repair.sh
# Forces a system update and reboot on ChromeOS without touching recovery images.

log() { printf '%s\n' "$*"; }
quit() { log "ERROR: $*"; exit 1; }

tpm2_target() { [ -f "/etc/init/trunksd.conf" ]; }

DAEMON="tcsd"; tpm2_target && DAEMON="trunksd"

log "Stopping ${DAEMON}..."
if initctl stop "${DAEMON}" >/dev/null 2>&1; then
  log "TPM daemon stopped"
else
  log "TPM daemon not running"
fi

# Network sanity
log "Checking network connectivity..."
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
  quit "No network route (ping 8.8.8.8 failed). Connect to Wi‑Fi or Ethernet."
fi

log "Checking DNS resolution..."
if ! getent hosts dl.google.com >/dev/null 2>&1; then
  quit "DNS broken (dl.google.com not resolvable). Fix DNS and retry."
fi

# Update engine prep
log "Resetting update_engine state..."
update_engine_client --reset_status >/dev/null 2>&1 || true

# Optional: clear any throttling
rm -f /var/lib/update_engine/prefs/* >/dev/null 2>&1 || true

log "Starting update process (this can take time)..."
# Follow progress; returns non-zero if already up-to-date or failures occur
if update_engine_client --update --follow; then
  log "Update completed; rebooting..."
  reboot
  exit 0
fi

# If follow failed, try a status loop to capture reason
log "Update follow failed; capturing status for 60s..."
end=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  update_engine_client --status || true
  sleep 2
done

quit "System update did not complete. Use the Recovery Utility fallback below."
