#!/usr/bin/env bash
# Called by the WakeSystem alarm (z13-s2idle-wake-EPOCH) every 5 minutes.
#
# The alarm is always armed for 5 minutes (regardless of AC/battery state at
# sleep entry) so that AC removal mid-sleep is detected within 5 minutes.
# This script reads CURRENT battery state when the alarm fires and decides.
#
# The s2idle post-hook in s2idle-resume-fixup.sh is unreliable after an
# alarm-triggered wake: the kernel re-enters s2idle within ~400 μs (before
# systemd-sleep's write() returns and the post hook runs).  This script runs
# as a transient systemd unit service — PID 1 dispatches it reliably during
# the brief wakeup window, without depending on systemd-sleep thawing first.
#
# Battery policy: hibernate regardless of lid state.  On battery, any
# unattended sleep must resolve to hibernate — the lid may be open
# (PowerDevil idle-initiated sleep) or closed.  lid-watch already handles
# lid-close-on-battery with immediate hibernate, so this path only fires for
# PowerDevil idle-suspend while lid is open, or for AC removal mid-sleep.
# (Confirmed failure 2026-06-25: lid-open battery sleep, AC removal during
# s2idle, machine re-entered s2idle silently, stuck until hard reset.)
# (Confirmed failure 2026-07-02: lid close on AC then unplug; 1-hour alarm
# committed before cable pulled; machine cooked in bag before auto-hib fired.)
#
# AC policy: hibernate only after MAX_AC_S2IDLE_SEC (1 hour) with lid closed.
# Fires every 5 minutes but skips until threshold is reached, then hibernates.
# Avoids hibernating immediately on AC (bad for overnight charging), and avoids
# hibernating on user lid-open (confirmed bad UX 2026-06-15).

SLEEP_SESSION_START=/run/z13-sleep-session-start
HIB_PENDING=/run/z13-hibernate-pending
WAKE_ALARM_UNIT=/run/z13-wake-alarm-unit
MAX_AC_S2IDLE_SEC=3600   # hibernate on AC only after 1 hour of lid-closed sleep

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
    if [ "$elapsed" -lt "$MAX_AC_S2IDLE_SEC" ]; then
        echo "s2idle-auto-hib: AC, lid closed, ${elapsed}s elapsed < ${MAX_AC_S2IDLE_SEC}s — not hibernating yet"
        # Re-arm the next 5-minute WakeSystem alarm.  One-winner guard: stale
        # units from a past proliferation cycle all fire in the same wake window;
        # flock(-n) ensures only the first instance proceeds; the WAKE_ALARM_UNIT
        # check handles sequential arrivals after the winner finishes quickly and
        # releases the lock.  Both guards are needed: flock for simultaneous
        # races, WAKE_ALARM_UNIT for sequential ones seconds apart.
        # (Second proliferation path confirmed 2026-07-19: 158 units × 1 unit/s
        # over a 3-minute firing window = 158 new units per cycle.)
        # Do NOT stop the previous unit — it's the unit we're running inside.
        # The fired timer is already deactivating; stopping it kills this script
        # before systemd-run can execute (confirmed self-kill, 2026-07-10).
        _lockfile="/var/lock/z13-s2idle-rearm.lock"
        exec 9>"$_lockfile"
        if ! flock -n 9; then
            echo "s2idle-auto-hib: re-arm lock busy — another instance re-arming (pid=$$, yielding)"
            exit 0
        fi
        _existing=$(cat "$WAKE_ALARM_UNIT" 2>/dev/null || true)
        if [ -n "$_existing" ] && systemctl is-active --quiet "${_existing}.timer" 2>/dev/null; then
            echo "s2idle-auto-hib: alarm $_existing already active — yielding (pid=$$)"
            exit 0
        fi
        _next="z13-s2idle-wake-$(date +%s)"
        systemd-run --no-block \
            --on-active=300s \
            --timer-property=WakeSystem=yes \
            --unit="$_next" \
            -- /usr/lib/z13-hibernate/s2idle-auto-hib.sh 2>/dev/null \
            && echo "$_next" > "$WAKE_ALARM_UNIT" \
            || echo "s2idle-auto-hib: WARNING: failed to re-arm WakeSystem alarm — machine may sleep until lid-open"
        exit 0
    fi
    echo "s2idle-auto-hib: AC, lid closed, ${elapsed}s elapsed ≥ ${MAX_AC_S2IDLE_SEC}s — scheduling hibernate"
else
    echo "s2idle-auto-hib: AC, lid open after ${elapsed}s — skipping (user wake)"
    exit 0
fi

rm -f "$SLEEP_SESSION_START"
touch "$HIB_PENDING"
systemd-run --on-active=15s --unit=z13-long-sleep-hibernate \
    bash -c "systemctl hibernate; rm -f $HIB_PENDING" \
    || { echo "s2idle-auto-hib: WARNING: failed to schedule hibernate"; rm -f "$HIB_PENDING"; }
