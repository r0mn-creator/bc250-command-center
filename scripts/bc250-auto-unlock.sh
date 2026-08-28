#!/usr/bin/env bash
# Boot-time auto-unlock for the BC-250's 2 disabled cores.
# Software alternative to the BIOS/DXE mod: runs as root via systemd at every
# boot, and only touches anything if the cores AREN'T already unlocked.
#
# The underlying unlock script's write only takes effect after a reboot (AGESA
# re-enumerates cores at boot), so on a cold boot this does one automatic
# reboot to finish the job. STATE_FILE guards against ever doing that twice in
# a row — if cores are still not present after that one retry, something is
# genuinely wrong (possibly the "non-0x77 mask" defective-core case) and this
# stops and leaves it for a human, rather than reboot-looping.

set -euo pipefail

UNLOCK_SCRIPT="${UNLOCK_SCRIPT:-/usr/local/share/bc250-dashboard/bc250-unlock-cores.py}"
GOVERNOR="${GOVERNOR:-oberon-governor.service}"
STATE_DIR="/var/lib/bc250-core-unlock"
STATE_FILE="$STATE_DIR/attempted-this-cycle"
EXPECTED_CPUS=16

log() { echo "[bc250-auto-unlock] $*"; }

current_cpus="$(nproc)"

if [ "$current_cpus" -ge "$EXPECTED_CPUS" ]; then
    log "already unlocked ($current_cpus CPUs online) - nothing to do"
    rm -f "$STATE_FILE"
    exit 0
fi

mkdir -p "$STATE_DIR"

if [ -e "$STATE_FILE" ]; then
    log "ERROR: cores still not present ($current_cpus CPUs) after a prior unlock+reboot attempt this cycle."
    log "Not retrying automatically - this can mean the write didn't take, or the mask genuinely isn't 0x77 (possible defective cores)."
    log "Investigate by hand: sudo python3 $UNLOCK_SCRIPT"
    exit 1
fi

log "$current_cpus CPUs online, expected $EXPECTED_CPUS - attempting unlock"
touch "$STATE_FILE"

log "stopping $GOVERNOR"
systemctl stop "$GOVERNOR"

set +e
python3 "$UNLOCK_SCRIPT"
unlock_status=$?
set -e

log "starting $GOVERNOR"
systemctl start "$GOVERNOR"

if [ "$unlock_status" -ne 0 ]; then
    log "ERROR: unlock script exited $unlock_status - not rebooting. Investigate by hand."
    exit 1
fi

log "unlock write succeeded - rebooting to pick up all $EXPECTED_CPUS CPUs"
systemctl reboot
