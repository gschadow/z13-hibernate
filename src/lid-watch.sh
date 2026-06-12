#!/usr/bin/env bash
# Debounced lid-switch suspend for the Z13.
#
# On this machine the "lid" is the detachable keyboard cover, so accidental
# close + immediate reopen is a NORMAL event. logind and PowerDevil act on
# the raw switch instantly: the reopen lands as a pending wakeup during the
# s2idle entry, the entry aborts, and the instant re-entry races amdgpu into
# a hard wedge (2026-06-12 00:18, wallpaper-frozen, power-cycle needed) —
# even with pm_async=0 and the 2s pre-suspend settle.
#
# Policy here: suspend only after the lid has been closed for DEBOUNCE_SEC
# without interruption. A reopen inside the window is a complete no-op — no
# suspend ever starts, so there is nothing to race.
#
# Requires that nobody else acts on the lid:
#   - logind drop-in: HandleLidSwitch=ignore (takes effect on reboot;
#     NEVER restart logind live — see project notes)
#   - PowerDevil: "When laptop lid is closed" = "Do nothing" (both profiles)
#
# After resume, if the lid is still closed the loop simply debounces again
# and re-suspends — which is the desired behavior for a spurious wake.

LID_STATE=/proc/acpi/button/lid/LID/state
DEBOUNCE_SEC=3
POLL_SEC=1

closed_since=""
while sleep "$POLL_SEC"; do
  state=$(awk '{print $2}' "$LID_STATE" 2>/dev/null) || continue
  if [ "$state" = "closed" ]; then
    now=$(date +%s)
    if [ -z "$closed_since" ]; then
      closed_since=$now
      echo "lid-watch: lid closed, debouncing ${DEBOUNCE_SEC}s"
      continue
    fi
    if [ $(( now - closed_since )) -ge "$DEBOUNCE_SEC" ]; then
      # Stand down while any sleep cycle is in flight: closing the lid over
      # a running hibernate (the normal "initiate and put it away" move)
      # must not inject a competing suspend. The marker also covers the
      # ~15s post-resume recovery; if the lid is still closed after the
      # marker clears, the timer below has already matured and we suspend
      # on the next poll — the right behavior for "resumed inside the bag".
      if [ -f /run/z13-was-hibernated ] \
         || systemctl list-jobs --no-legend 2>/dev/null | grep -qE 'sleep\.target|suspend\.target|hibernate\.target'; then
        continue
      fi
      closed_since=""
      echo "lid-watch: lid closed >= ${DEBOUNCE_SEC}s — suspending"
      systemctl suspend || echo "lid-watch: suspend request failed (already sleeping?)"
      # The loop is frozen during s2idle; this just skips the moments
      # between the request and the actual freeze.
      sleep 5
    fi
  else
    [ -n "$closed_since" ] && echo "lid-watch: lid reopened inside debounce window — ignored"
    closed_since=""
  fi
done
