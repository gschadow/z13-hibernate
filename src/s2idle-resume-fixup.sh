#!/usr/bin/env bash
# Runs on every sleep/wake via /usr/lib/systemd/system-sleep/.
#
# pre/suspend:
#   1. 2 s settle delay — the lid-close EC event is still pending when the
#      kernel samples wakeup_count, so the first suspend attempt aborts; the
#      instant re-entry races amdgpu into a hard hang. The settle lets the
#      event drain so the first attempt sticks.
#   2. Sleep-session tracking — /run/z13-sleep-session-start records when this
#      lid-close session began; brief re-suspends don't reset it so the post
#      hook can measure the true total sleep duration.
#   3. RTC wake alarm — set MAX_S2IDLE_SEC from now. When the machine is
#      properly in s2idle the alarm wakes it so the post hook can schedule a
#      hibernate (prevents indefinitely long s2idle that ends in a frozen
#      black screen on resume).
#   4. mt7925e unload — 2026-06-12: after ~11 h of runtime the device-suspend
#      phase hung at 17:27; "PM: suspend of devices complete" was never logged;
#      the machine sat in a broken PM state for 8 h until it crashed when the
#      lid was opened at 01:24. Root cause: wiphy_suspend() times out after the
#      firmware accumulates state across many hours of use — the same -ETIMEDOUT
#      that 05-hibernate-hook.sh already works around for S4. Fix: unload the
#      driver before sleep; post hook reloads it cleanly on wake.
#
# post/suspend:
#   1. Cancel RTC alarm.
#   2. Reload mt7925e (if we unloaded it).
#   3. Re-trigger power_supply uevents — ASUS EC misreports AC as disconnected
#      after s2idle; without this UPower can fire CriticalPowerAction on AC.
#   4. Log pm_wakeup_irq for spurious-wake diagnosis.
#   5. Battery safety net — hibernate at ≤ 10% discharging.
#   6. Long-sleep gate — if slept >= MAX_S2IDLE_SEC, set z13-hibernate-pending
#      flag so lid-watch doesn't re-suspend, then schedule a hibernate (the
#      RTC alarm fires to trigger this even when the lid stays closed).
#
# Not needed for S4 hibernate (handled by 05-hibernate-hook.sh /
# 95-resume-hook.sh which have their own WiFi and recovery logic).

set -euo pipefail

SLEEP_SESSION_START=/run/z13-sleep-session-start
MT_UNLOADED_FLAG=/run/z13-s2idle-mt-unloaded
RTC_WAKEALARM=/sys/class/rtc/rtc0/wakealarm
HIB_PENDING=/run/z13-hibernate-pending
MAX_S2IDLE_SEC=10800  # 3 hours: hibernate on wake if slept this long
_wifi_if=wlp194s0

case "${1:-}/${2:-}" in
  pre/suspend|pre/hybrid-sleep|pre/suspend-then-hibernate)
    sleep 2

    # The mt7925e unload, RTC alarm, and session tracking only apply to the
    # plain s2idle path. hybrid-sleep and suspend-then-hibernate are
    # explicitly disallowed in sleep.conf.d but handled gracefully here.
    if [ "${2:-}" = "suspend" ]; then
      # Record session start; don't overwrite if a re-suspend within the same
      # lid-close session (brief internal wakeup + immediate re-suspend).
      [ -f "$SLEEP_SESSION_START" ] || date +%s > "$SLEEP_SESSION_START"

      # RTC wakeup alarm: ensure the machine surfaces so the post hook can
      # trigger hibernate after a long sleep (even with lid still closed).
      if [ -w "$RTC_WAKEALARM" ]; then
        echo 0 > "$RTC_WAKEALARM" 2>/dev/null || true
        echo $(( $(date +%s) + MAX_S2IDLE_SEC )) > "$RTC_WAKEALARM" 2>/dev/null || true
      fi

      # Bring the WiFi interface down and drain before unloading (page_pool
      # zombie avoidance — same 1 s wait as the hibernate hook).
      ip link set "$_wifi_if" down 2>/dev/null || true
      sleep 1

      # Unload mt7925e to bypass the buggy wiphy_suspend() callback.
      if [ -d /sys/module/mt7925e ]; then
        timeout 15 modprobe -r mt7925e 2>/dev/null \
          && { touch "$MT_UNLOADED_FLAG"; echo "s2idle-resume-fixup: mt7925e unloaded"; } \
          || echo "s2idle-resume-fixup: mt7925e unload failed — device-suspend may hang"
      fi
    fi
    ;;

  post/suspend|post/hybrid-sleep|post/suspend-then-hibernate)
    # Cancel the RTC alarm (set in pre/suspend; cancel unconditionally to
    # avoid a stale alarm waking the machine a second time).
    if [ -w "$RTC_WAKEALARM" ]; then
      echo 0 > "$RTC_WAKEALARM" 2>/dev/null || true
    fi

    # Reload mt7925e if we unloaded it in the pre hook.
    if [ -f "$MT_UNLOADED_FLAG" ]; then
      rm -f "$MT_UNLOADED_FLAG"
      modprobe mt7925e 2>/dev/null \
        && echo "s2idle-resume-fixup: mt7925e reloaded" \
        || echo "s2idle-resume-fixup: mt7925e reload failed — WiFi may be down"
    fi

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

    # Battery safety net: hibernate at ≤ 10% discharging (replaces
    # SuspendThenHibernate, which skips the hibernate prep hooks).
    bat="/sys/class/power_supply/BAT0"
    if [ -r "$bat/capacity" ] && [ -r "$bat/status" ]; then
      cap=$(cat "$bat/capacity")
      status=$(cat "$bat/status")
      if [ "$status" = "Discharging" ] && [ "$cap" -le 10 ]; then
        echo "s2idle-resume-fixup: battery ${cap}% on resume, scheduling hibernate"
        rm -f "$SLEEP_SESSION_START"
        systemd-run --on-active=10s --unit=z13-low-battery-hibernate \
          systemctl hibernate || true
        exit 0
      fi
    fi

    # Long-sleep gate: after MAX_S2IDLE_SEC total sleep (RTC alarm or user
    # wake), hibernate instead of returning to the desktop. Resume from 3+ h
    # of s2idle risks driver-state rot; hibernate is the safe landing.
    if [ -f "$SLEEP_SESSION_START" ]; then
      session_start=$(cat "$SLEEP_SESSION_START")
      now=$(date +%s)
      elapsed=$(( now - session_start ))
      if [ "$elapsed" -ge "$MAX_S2IDLE_SEC" ]; then
        echo "s2idle-resume-fixup: slept ${elapsed}s (>=${MAX_S2IDLE_SEC}s threshold) — scheduling hibernate"
        rm -f "$SLEEP_SESSION_START"
        # Tell lid-watch to stand down while hibernate is starting (it checks
        # this flag before re-suspending).
        touch "$HIB_PENDING"
        systemd-run --on-active=5s --unit=z13-long-sleep-hibernate \
          bash -c "systemctl hibernate; rm -f $HIB_PENDING" \
          || rm -f "$HIB_PENDING"
      else
        lid_state=$(awk '{print $2}' /proc/acpi/button/lid/LID/state 2>/dev/null || echo open)
        if [ "$lid_state" = "open" ]; then
          # Lid is open, sleep was short — user woke normally; clear session.
          rm -f "$SLEEP_SESSION_START"
        fi
        # lid still closed + under threshold: keep marker; machine will
        # re-suspend via lid-watch, which preserves the session clock.
      fi
    fi
    ;;
esac
