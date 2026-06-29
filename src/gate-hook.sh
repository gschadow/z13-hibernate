#!/usr/bin/env bash
set -euo pipefail

source /usr/lib/z13-hibernate/common.sh

# === TEST-ABORT SUPPORT ===
if [ -f /run/force-hibernate-abort-test ] || [ "${1:-}" = "test-abort" ]; then
  rm -f /run/force-hibernate-abort-test
  kmsg "=== z13 gate: IMMEDIATE ABORT TEST ==="
  rm -f "$PIDFILE" 2>/dev/null || true
  kill_hibernate_watcher
  restore_screen   # or restore_screen_gentle if we want less destructive
  asusctl leds set high > /dev/null 2>&1 || true
  asusctl aura effect static -c 00ff60 > /dev/null 2>&1 || true
  kmsg "gate: ABORT TEST done (color 00ff60). Screen should be back."
  exit 1
fi

kmsg "gate: === BEGIN HIBERNATE GATE PRE-CHECK ==="
kmsg "gate: kernel=$(uname -r)"

# NOTE: We deliberately do NOT call apply_power_profile or force_high_performance here.
# Performance settings are ONLY in hibernate-hook.sh (right before the image write).
# Gate is purely for the quiesce / PID check / STOP phase.

# Initial color for pre-check phase (blue-ish)
asusctl leds set med 2>/dev/null || true
asusctl aura effect static -c 0060ff 2>/dev/null || true

# Stop GPU-heavy services before touching the compositor.
# A cancelled or recently-completed ollama inference leaves the amdgpu driver with
# incomplete GPU fences.  If we try to hibernate while those fences are pending, the
# PM_HIBERNATION_PREPARE notifier hangs indefinitely at "hibernation entry".
# Stopping the service gives the driver a clean fence-drain window before the
# compositor suspend and the PM notifier.
if systemctl is-active --quiet ollama 2>/dev/null; then
  kmsg "gate: ollama service running — stopping to release GPU memory before hibernate"
  systemctl stop ollama 2>/dev/null || true
  sleep 3
  kmsg "gate: ollama stopped"
fi

# Suspend KWin compositor before the user.slice freeze.
# This drains all outstanding GPU fences so the kernel's PM_HIBERNATION_PREPARE notifier
# (amdgpu) can disable the display pipeline cleanly.  Dirty amdgpu GPU VM state causes the
# notifier to hang indefinitely at "PM: hibernation: hibernation entry".  Sources of dirty
# state: kscreenlocker crash on previous S4 resume, or a cancelled ollama inference job.
_hib_user=gunther
_hib_uid=$(id -u "$_hib_user" 2>/dev/null || echo "")
if [ -n "$_hib_uid" ]; then
  _hib_xdg="/run/user/$_hib_uid"
  _hib_wl=""
  for _w in wayland-0 wayland-1 wayland-2; do
    [ -S "$_hib_xdg/$_w" ] && _hib_wl="$_w" && break
  done
  if [ -n "$_hib_wl" ]; then
    _hib_env="XDG_RUNTIME_DIR=$_hib_xdg DBUS_SESSION_BUS_ADDRESS=unix:path=$_hib_xdg/bus WAYLAND_DISPLAY=$_hib_wl"
    if timeout 5 sudo -u "$_hib_user" env $_hib_env qdbus org.kde.KWin /Compositor suspend 2>/dev/null; then
      kmsg "gate: KWin compositor suspended (GPU fences will drain before PM notifier)"
      sleep 2
    else
      # Compositor suspend failed — GPU has dirty VM state (cascading "atomic commit failed"
      # errors visible in KWin log).  Run kwin_wayland --replace to forcefully clear the
      # dirty amdgpu state, wait for the new instance to settle, then retry.
      kmsg "gate: compositor suspend failed — running kwin_wayland --replace to clear dirty GPU VM"
      sudo -u "$_hib_user" env \
        XDG_RUNTIME_DIR="$_hib_xdg" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$_hib_xdg/bus" \
        WAYLAND_DISPLAY="$_hib_wl" \
        kwin_wayland --replace &>/dev/null &
      sleep 8
      if timeout 5 sudo -u "$_hib_user" env $_hib_env qdbus org.kde.KWin /Compositor suspend 2>/dev/null; then
        kmsg "gate: compositor suspended after kwin --replace (GPU state cleared)"
        sleep 2
      else
        kmsg "gate: compositor still failed after --replace — waiting 15s more for natural drain"
        sleep 15
      fi
    fi
  else
    kmsg "gate: no Wayland socket found for $_hib_user, skipping compositor suspend"
  fi
fi

stop_and_record_busy

# Decide final exit color
# 00ff60 (green) if we "aborted" the attempt (test path or decided not to proceed)
# 0060ff (blue) if we proceed normally
final_color=0060ff
exit_code=0

# In current design we almost always proceed (exit 0). Only test-abort uses exit 1 + 00ff60.
# If in future we add a real "still too busy, abort" decision, set final_color=00ff60; exit_code=1
kmsg "gate: system prepared for hibernate (proceeding). PIDFILE: $(cat $PIDFILE 2>/dev/null | tr '\n' ' ' || echo none)"

asusctl leds set high 2>/dev/null || true
asusctl aura effect static -c "$final_color" 2>/dev/null || true
kmsg "gate: exit color $final_color (proceed=$exit_code)"

exit $exit_code
