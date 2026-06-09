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

# Suspend KWin compositor before the user.slice freeze.
# This drains all outstanding GPU fences so the kernel's PM_HIBERNATION_PREPARE notifier
# (amdgpu) can disable the display pipeline cleanly. Without this, after S4 resume the
# amdgpu PM notifier can block indefinitely on a stuck atomic commit or fence from the
# kscreenlocker GPU crash (VM memory stats non-zero when fini) that happens on every
# S4 resume — causing an infinite hang at "PM: hibernation: hibernation entry".
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
    sudo -u "$_hib_user" env $_hib_env qdbus org.kde.KWin /Compositor suspend 2>/dev/null \
      && kmsg "gate: KWin compositor suspended (GPU will drain before PM notifier)" \
      || kmsg "gate: KWin compositor suspend skipped/failed (non-fatal)"
    sleep 2
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
