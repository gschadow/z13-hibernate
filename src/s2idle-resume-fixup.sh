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
#   3. RTC wake alarm — set MAX_S2IDLE_SEC from now.  NOTE: on GZ302EA the
#      RTC is NOT an ACPI S0 wakeup source (only S4).  The alarm fires a
#      ~200 μs kernel-internal interrupt only; it does NOT thaw userspace.
#      The code is harmless and future-proofs for a working wakeup source.
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
#   2. Framebuffer unblank — DPMS may have been off before sleep; on Z13 the
#      keyboard IS the lid so no key event fires on lid-open to wake DPMS.
#   3. Reload mt7925e (if we unloaded it) — with timeout 15 to prevent an
#      indefinite hang from a page_pool zombie left by the pre-hook unload
#      (confirmed 2026-06-13: blocked ~80 s until hard reset).
#   4. SimulateUserActivity via qdbus — tells KDE to re-enable DPMS outputs.
#   5. Re-trigger power_supply uevents — ASUS EC misreports AC as disconnected
#      after s2idle; without this UPower can fire CriticalPowerAction on AC.
#   6. Log pm_wakeup_irq for spurious-wake diagnosis.
#   7. Battery safety net — hibernate at ≤ 10% discharging.
#   8. Long-sleep gate — if an autonomous wake occurs while the lid is STILL
#      CLOSED after >= MAX_S2IDLE_SEC, hibernate.  Lid-open always resumes
#      normally; the gate must never fire on user lid-open (bad UX confirmed
#      2026-06-15).  The WakeSystem=yes timer (item 3 above) is the working
#      S0 wakeup source; RTC sysfs only wakes from S4 on this platform.
#
# Not needed for S4 hibernate (handled by 05-hibernate-hook.sh /
# 95-resume-hook.sh which have their own WiFi and recovery logic).

set -euo pipefail

SLEEP_SESSION_START=/run/z13-sleep-session-start
MT_UNLOADED_FLAG=/run/z13-s2idle-mt-unloaded
RTC_WAKEALARM=/sys/class/rtc/rtc0/wakealarm
HIB_PENDING=/run/z13-hibernate-pending
MAX_S2IDLE_SEC=3600   # 1 hour: hibernate threshold (only on auto-wake, not lid-open)
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

      # RTC sysfs wakealarm — kept for completeness but confirmed ineffective
      # on GZ302EA (RTC not an ACPI S0 wakeup source; fires a ~200 μs
      # kernel-internal interrupt only, never thaws userspace).
      if [ -w "$RTC_WAKEALARM" ]; then
        echo 0 > "$RTC_WAKEALARM" 2>/dev/null || true
        echo $(( $(date +%s) + MAX_S2IDLE_SEC )) > "$RTC_WAKEALARM" 2>/dev/null || true
      fi

      # CLOCK_REALTIME_ALARM wake via systemd WakeSystem=yes.
      # Uses the alarmtimer subsystem (separate kernel path from sysfs
      # wakealarm above — may work via rtc-efi or another backend).
      # If successful the machine wakes in MAX_S2IDLE_SEC, our post hook
      # fires, sees lid=closed + elapsed >= threshold, and hibernates.
      # Cancelled in the post hook so a user lid-open cleans it up.
      systemctl stop z13-s2idle-wake-alarm.timer 2>/dev/null || true
      systemctl reset-failed z13-s2idle-wake-alarm.timer z13-s2idle-wake-alarm.service 2>/dev/null || true
      systemd-run --no-block \
        --on-active="${MAX_S2IDLE_SEC}s" \
        --property=WakeSystem=yes \
        --unit=z13-s2idle-wake-alarm \
        -- /bin/true 2>/dev/null \
        && echo "s2idle-resume-fixup: z13-s2idle-wake-alarm set for ${MAX_S2IDLE_SEC}s (WakeSystem=yes)" \
        || echo "s2idle-resume-fixup: WARNING: z13-s2idle-wake-alarm scheduling failed"

      # Bring the WiFi interface down and drain before unloading.
      # 3 s: 1 s was not enough — a page still in-flight at the DMA level
      # survives as a page_pool zombie that causes modprobe in the post hook
      # to hang indefinitely (confirmed 2026-06-13; post hook blocked ~80 s).
      ip link set "$_wifi_if" down 2>/dev/null || true
      sleep 3

      # Unload mt7925e to bypass the buggy wiphy_suspend() callback.
      if [ -d /sys/module/mt7925e ]; then
        timeout 15 modprobe -r mt7925e 2>/dev/null \
          && { touch "$MT_UNLOADED_FLAG"; echo "s2idle-resume-fixup: mt7925e unloaded"; } \
          || echo "s2idle-resume-fixup: mt7925e unload failed — device-suspend may hang"
      fi
    fi
    ;;

  post/suspend|post/hybrid-sleep|post/suspend-then-hibernate)
    # Cancel both wake alarms set in pre/suspend.
    if [ -w "$RTC_WAKEALARM" ]; then
      echo 0 > "$RTC_WAKEALARM" 2>/dev/null || true
    fi
    systemctl stop z13-s2idle-wake-alarm.timer 2>/dev/null || true

    # Display recovery — must happen BEFORE the modprobe below, which can
    # block up to 15 s.  On Z13 the keyboard IS the lid; lid-open generates
    # an ACPI lid-switch event but NOT a key event, so KDE's DPMS stays off.
    # The user sees a black screen and hard-resets before modprobe finishes if
    # display recovery comes after it (confirmed 2026-06-15).
    #
    # Step 1: framebuffer unblank — safe kernel-level unblank, same pattern as
    # 95-resume-hook.sh.  Do NOT write /sys/class/drm/*/dpms: KWin owns the
    # DRM device on Wayland; writing DPMS sysfs while KWin holds it causes
    # atomic-commit EBUSY → black screen.
    ( for f in /sys/class/graphics/*/blank; do [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || true; done ) 2>/dev/null || true
    #
    # Step 2: SimulateUserActivity via D-Bus — tells KDE to re-enable DPMS
    # outputs.  This is the canonical Plasma way; framebuffer unblank alone
    # does not wake KWin's output pipeline on Wayland.
    _uid=$(id -u gunther 2>/dev/null || echo "")
    if [ -n "$_uid" ]; then
      _xdg="/run/user/$_uid"
      _wl=""
      for _w in wayland-0 wayland-1 wayland-2; do
        [ -S "$_xdg/$_w" ] && _wl="$_w" && break
      done
      if [ -n "$_wl" ]; then
        sudo -u gunther env \
          XDG_RUNTIME_DIR="$_xdg" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$_xdg/bus" \
          WAYLAND_DISPLAY="$_wl" \
          qdbus org.kde.ScreenSaver /ScreenSaver SimulateUserActivity 2>/dev/null \
          && echo "s2idle-resume-fixup: SimulateUserActivity sent (DPMS wake)" \
          || true
      fi
    fi

    # Reload mt7925e if we unloaded it in the pre hook.
    # timeout 15: a page_pool zombie left from the pre-hook unload (one page
    # still in-flight in hardware DMA at module removal time) can cause
    # modprobe to block indefinitely — confirmed 2026-06-13 where the hook
    # hung ~80 s until a hard reset, preventing the long-sleep hibernate gate
    # from ever firing.  Cap it; WiFi reconnects via NM on the next boot if
    # needed.
    if [ -f "$MT_UNLOADED_FLAG" ]; then
      rm -f "$MT_UNLOADED_FLAG"
      timeout 15 modprobe mt7925e 2>/dev/null \
        && echo "s2idle-resume-fixup: mt7925e reloaded" \
        || echo "s2idle-resume-fixup: mt7925e reload timed-out/failed — WiFi may be down"
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

    # Long-sleep gate: hibernate only on autonomous wake (lid still closed)
    # after >= MAX_S2IDLE_SEC.  NEVER hibernate on user lid-open.
    if [ -f "$SLEEP_SESSION_START" ]; then
      session_start=$(cat "$SLEEP_SESSION_START")
      now=$(date +%s)
      elapsed=$(( now - session_start ))
      lid_state=$(awk '{print $2}' /proc/acpi/button/lid/LID/state 2>/dev/null || echo open)

      if [ "$lid_state" = "closed" ] && [ "$elapsed" -ge "$MAX_S2IDLE_SEC" ]; then
        # Autonomous wake, lid still closed, slept long enough → hibernate.
        echo "s2idle-resume-fixup: autonomous wake after ${elapsed}s, lid closed — scheduling hibernate"
        rm -f "$SLEEP_SESSION_START"
        touch "$HIB_PENDING"
        systemd-run --on-active=5s --unit=z13-long-sleep-hibernate \
          bash -c "systemctl hibernate; rm -f $HIB_PENDING" \
          || rm -f "$HIB_PENDING"
      elif [ "$lid_state" = "open" ]; then
        # User opened the lid — always resume normally, never hibernate.
        echo "s2idle-resume-fixup: lid opened after ${elapsed}s — resuming normally"
        rm -f "$SLEEP_SESSION_START"
      fi
      # lid closed + under threshold: keep marker; lid-watch re-suspends.
    fi
    ;;
esac
