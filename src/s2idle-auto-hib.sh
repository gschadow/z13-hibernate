#!/usr/bin/env bash
# Called by the WakeSystem alarm (z13-s2idle-wake-EPOCH) after MAX_S2IDLE_SEC.
#
# The s2idle post-hook in s2idle-resume-fixup.sh is unreliable after an
# alarm-triggered wake: the kernel re-enters s2idle within ~400 μs (before
# systemd-sleep's write() returns and the post hook runs).  This script runs
# as a transient systemd unit service — PID 1 dispatches it reliably during
# the brief wakeup window, without depending on systemd-sleep thawing first.

SLEEP_SESSION_START=/run/z13-sleep-session-start
HIB_PENDING=/run/z13-hibernate-pending

# If session was already cleaned up (lid opened before the alarm fired), skip.
[ -f "$SLEEP_SESSION_START" ] || exit 0

lid_state=$(awk '{print $2}' /proc/acpi/button/lid/LID/state 2>/dev/null || echo open)
[ "$lid_state" = "closed" ] || exit 0

session_start=$(cat "$SLEEP_SESSION_START")
elapsed=$(( $(date +%s) - session_start ))
echo "s2idle-auto-hib: autonomous wake after ${elapsed}s, lid closed — scheduling hibernate"
rm -f "$SLEEP_SESSION_START"
touch "$HIB_PENDING"
systemd-run --on-active=5s --unit=z13-long-sleep-hibernate \
    bash -c "systemctl hibernate; rm -f $HIB_PENDING" \
    || { echo "s2idle-auto-hib: WARNING: failed to schedule hibernate"; rm -f "$HIB_PENDING"; }
