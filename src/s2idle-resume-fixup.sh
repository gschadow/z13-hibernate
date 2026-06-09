#!/usr/bin/env bash
# Runs on every sleep/wake via /usr/lib/systemd/system-sleep/.
# Fixes the ASUS EC AC-adapter status reporting bug on ROG laptops:
# after s2idle resume the EC can report AC as disconnected, causing
# asusd to apply battery profiles and UPower to potentially fire a
# CriticalPowerAction despite the machine being plugged in.
#
# Triggered by: systemd-sleep post/suspend and post/hybrid-sleep.
# Not needed for hibernate (S4) because the full resume path does a
# proper device re-probe.

set -euo pipefail

case "${1:-}/${2:-}" in
  post/suspend|post/hybrid-sleep)
    # Re-trigger uevents for all power_supply devices so that UPower and
    # asusd re-read the actual AC/battery state from the EC.
    for uevent in /sys/class/power_supply/*/uevent; do
      [ -f "$uevent" ] || continue
      echo change > "$uevent" 2>/dev/null || true
    done
    ;;
esac
