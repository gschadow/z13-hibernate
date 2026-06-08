#!/usr/bin/env bash
set -euo pipefail

source /usr/lib/z13-hibernate/common.sh

kmsg "post-resume: === BEGIN POST-RESUME HOOK ==="

# Guard: only do the (potentially destructive) recovery if we have the marker
# created by the actual hibernate pre-hook. This prevents the restore logic
# from running on a normal suspend-to-RAM resume (lid close), where the
# graphical session/lock screen is usually already perfectly restored and
# forcing chvt, kwin reconfigure, plasmashell actions etc. can tear it down.
if [ ! -f /run/z13-was-hibernated ]; then
  kmsg "post-resume: no /run/z13-was-hibernated marker — this was a regular sleep resume, skipping heavy recovery"
  exit 0
fi

# Since we don't do real kill -STOP yet (sidestep in get_busy_pids), there is
# little to CONT here. When we enable real detection, move the heavy CONT + any
# "system is really back" recovery here.

# For now, do a full screen restore (so resume still works well) and final done color.
restore_screen
restore_lights_and_profile

# Final "we are done" color
asusctl leds set high 2>/dev/null || true
asusctl aura effect static -c 00ff60 2>/dev/null || true
kmsg "post-resume: final color 00ff60, restore complete"

kmsg "post-resume: done (system should be fully back now)"

# Clean marker
rm -f /run/z13-was-hibernated || true
kmsg "post-resume: cleaned hibernate marker"
