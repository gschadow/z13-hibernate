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

kmsg "gate: === BEGIN HIBERNATE GATE PRE-CHECK (white from common) ==="
kmsg "gate: kernel=$(uname -r)"

# NOTE: We deliberately do NOT call apply_power_profile or force_high_performance here.
# Performance settings are ONLY in hibernate-hook.sh (right before the image write).
# Gate is purely for the quiesce / PID check / STOP phase.

# Initial color for pre-check phase (blue-ish)
asusctl leds set med 2>/dev/null || true
asusctl aura effect static -c 0060ff 2>/dev/null || true

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
