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
restart_gpu_processes

# Restart KWin after S4 resume to clear dirty amdgpu GPU VM state from the
# kscreenlocker crash that occurs on every S4 resume (observed every resume,
# documented in gate-hook.sh).  Without this, the session accumulates cascading
# "atomic commit failed: Device or resource busy" errors; the next hibernate's
# compositor suspend call fails; GPU processes are killed with "non-zero when fini"
# VM memory; and the amdgpu PM_HIBERNATION_PREPARE notifier hangs indefinitely at
# "PM: hibernation: hibernation entry" (confirmed failure log 2026-06-26 05:06).
# --replace takes over the live compositor slot so display is not lost, only
# briefly flickered.  This runs AFTER restore_screen so the display is already on.
_pr_uid=$(id -u gunther 2>/dev/null || echo "")
if [ -n "$_pr_uid" ]; then
  _pr_xdg="/run/user/$_pr_uid"
  _pr_wl=""
  for _w in wayland-0 wayland-1 wayland-2; do
    [ -S "$_pr_xdg/$_w" ] && _pr_wl="$_w" && break
  done
  if [ -n "$_pr_wl" ]; then
    sleep 3
    sudo -u gunther env \
      XDG_RUNTIME_DIR="$_pr_xdg" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$_pr_xdg/bus" \
      WAYLAND_DISPLAY="$_pr_wl" \
      kwin_wayland --replace &>/dev/null &
    kmsg "post-resume: KWin --replace launched (clearing dirty amdgpu VM from kscreenlocker crash)"
  else
    kmsg "post-resume: no Wayland socket found — skipping KWin --replace (manual kwin_wayland --replace may be needed)"
  fi
fi

# Final "we are done" color
asusctl leds set high 2>/dev/null || true
asusctl aura effect static -c 00ff60 2>/dev/null || true
kmsg "post-resume: final color 00ff60, restore complete"

kmsg "post-resume: done (system should be fully back now)"

# Clean marker
rm -f /run/z13-was-hibernated || true
kmsg "post-resume: cleaned hibernate marker"
