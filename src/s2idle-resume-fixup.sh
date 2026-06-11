#!/usr/bin/env bash
# Runs on every sleep/wake via /usr/lib/systemd/system-sleep/.
#
# pre:  Settle delay before s2idle. On lid-close the EC's lid wakeup event
#       is still pending when the kernel samples wakeup_count, so the first
#       suspend attempt aborts within microseconds and systemd-sleep
#       immediately re-enters — a rapid re-entry that has raced the amdgpu
#       suspend path into a hard hang. Waiting ~2s lets the lid event drain
#       so the first attempt sticks.
#
# post: Fixes the ASUS EC AC-adapter status reporting bug on ROG laptops:
#       after s2idle resume the EC can report AC as disconnected, causing
#       asusd to apply battery profiles and UPower to potentially fire a
#       CriticalPowerAction despite the machine being plugged in.
#       Also logs the wakeup IRQ for spurious-wake diagnosis.
#
# Not needed for hibernate (S4) because the full resume path does a
# proper device re-probe.

set -euo pipefail

case "${1:-}/${2:-}" in
  pre/suspend|pre/hybrid-sleep|pre/suspend-then-hibernate)
    sleep 2
    ;;
  post/suspend|post/hybrid-sleep|post/suspend-then-hibernate)
    # Re-trigger uevents for all power_supply devices so that UPower and
    # asusd re-read the actual AC/battery state from the EC.
    for uevent in /sys/class/power_supply/*/uevent; do
      [ -f "$uevent" ] || continue
      echo change > "$uevent" 2>/dev/null || true
    done
    # Record what woke us, for spurious-wake diagnosis.
    if [ -r /sys/power/pm_wakeup_irq ]; then
      echo "s2idle-resume-fixup: pm_wakeup_irq=$(cat /sys/power/pm_wakeup_irq 2>/dev/null || echo none)"
    fi
    # Battery safety net: s2idle drains the battery and nothing can act
    # while userspace is frozen. SuspendThenHibernate is not usable here
    # (it skips the hibernate prep hooks entirely), so instead check on
    # every resume: if we are on battery and below the threshold, go
    # straight to hibernate (which runs the full S4 prep via its hooks).
    # Detached via systemd-run because sleep.target is still active while
    # this hook runs.
    bat="/sys/class/power_supply/BAT0"
    if [ -r "$bat/capacity" ] && [ -r "$bat/status" ]; then
      cap=$(cat "$bat/capacity")
      status=$(cat "$bat/status")
      if [ "$status" = "Discharging" ] && [ "$cap" -le 10 ]; then
        echo "s2idle-resume-fixup: battery ${cap}% on resume, scheduling hibernate"
        systemd-run --on-active=10s --unit=z13-low-battery-hibernate \
          systemctl hibernate || true
      fi
    fi
    ;;
esac
