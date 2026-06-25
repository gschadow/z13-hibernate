#!/usr/bin/env bash
# Called by the WakeSystem alarm (z13-s2idle-wake-EPOCH) after the
# battery-aware timeout (5 min on battery, 1 hour on AC).
#
# The s2idle post-hook in s2idle-resume-fixup.sh is unreliable after an
# alarm-triggered wake: the kernel re-enters s2idle within ~400 μs (before
# systemd-sleep's write() returns and the post hook runs).  This script runs
# as a transient systemd unit service — PID 1 dispatches it reliably during
# the brief wakeup window, without depending on systemd-sleep thawing first.
#
# Battery policy: hibernate regardless of lid state.  On battery, any
# unattended sleep for the alarm duration must resolve to hibernate — the
# lid may be open (PowerDevil idle-initiated sleep) or closed.  lid-watch
# already handles lid-close-on-battery with immediate hibernate, so this
# path only fires for PowerDevil idle-suspend while lid is open on battery.
# (Confirmed failure 2026-06-25: lid-open battery sleep, AC removal during
# s2idle, machine re-entered s2idle silently, stuck until hard reset.)
#
# AC policy: hibernate only if lid is still closed (avoids hibernating on
# user lid-open, confirmed bad UX 2026-06-15).

SLEEP_SESSION_START=/run/z13-sleep-session-start
HIB_PENDING=/run/z13-hibernate-pending

# If session was already cleaned up (lid opened before the alarm fired and
# post-hook ran), skip — user woke the machine intentionally.
[ -f "$SLEEP_SESSION_START" ] || exit 0

lid_state=$(awk '{print $2}' /proc/acpi/button/lid/LID/state 2>/dev/null || echo open)
bat_status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")

session_start=$(cat "$SLEEP_SESSION_START")
elapsed=$(( $(date +%s) - session_start ))

if [ "$bat_status" = "Discharging" ]; then
    echo "s2idle-auto-hib: battery, ${elapsed}s elapsed, lid=${lid_state} — scheduling hibernate"
elif [ "$lid_state" = "closed" ]; then
    echo "s2idle-auto-hib: AC, lid closed, ${elapsed}s elapsed — scheduling hibernate"
else
    echo "s2idle-auto-hib: AC, lid open after ${elapsed}s — skipping (user wake)"
    exit 0
fi

rm -f "$SLEEP_SESSION_START"
touch "$HIB_PENDING"
systemd-run --on-active=15s --unit=z13-long-sleep-hibernate \
    bash -c "systemctl hibernate; rm -f $HIB_PENDING" \
    || { echo "s2idle-auto-hib: WARNING: failed to schedule hibernate"; rm -f "$HIB_PENDING"; }
