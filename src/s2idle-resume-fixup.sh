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
#   4. mt7925e interface down — bringing the interface down before sleep makes
#      the firmware idle so wiphy_suspend() completes without timing out
#      (confirmed 2026-06-12: active firmware state after ~11 h caused a hang).
#      We do NOT unload the module: unloading with DMA pages in-flight creates
#      a page_pool zombie the kernel can never drain.  On S2idle the zombie
#      accumulated and caused a 7.5 h battery-drain / display-dead hang when a
#      spurious lid-open ACPI event woke the machine and the post hook read
#      "open" lid state before it reverted to "closed" (confirmed 2026-08-01).
#
# post/suspend:
#   1. Cancel RTC alarm.
#   2. Framebuffer unblank — DPMS may have been off before sleep; on Z13 the
#      keyboard IS the lid so no key event fires on lid-open to wake DPMS.
#   3. Reload mt7925e — no longer needed: we no longer unload it in the pre
#      hook.  wiphy_resume() re-activates the idle-but-loaded firmware cleanly.
#   4. SimulateUserActivity via qdbus6 — tells KDE to re-enable DPMS outputs.
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
RTC_WAKEALARM=/sys/class/rtc/rtc0/wakealarm
HIB_PENDING=/run/z13-hibernate-pending
WAKE_ALARM_UNIT=/run/z13-wake-alarm-unit   # stores the current timer's unit name
OLLAMA_STOPPED_FLAG=/run/z13-ollama-stopped-for-s2idle
MAX_S2IDLE_SEC=3600        # 1 hour: hibernate threshold on AC (lid-closed auto-wake)
MAX_S2IDLE_SEC_BAT=300     # 5 min: hibernate threshold on battery (any auto-wake)
_wifi_if=wlp194s0

case "${1:-}/${2:-}" in
  pre/suspend|pre/hybrid-sleep|pre/suspend-then-hibernate)
    sleep 2

    # The RTC alarm, session tracking, and WiFi actions only apply to the
    # plain s2idle path. hybrid-sleep and suspend-then-hibernate are
    # explicitly disallowed in sleep.conf.d but handled gracefully here.
    if [ "${2:-}" = "suspend" ]; then
      if [ ! -f "$SLEEP_SESSION_START" ]; then
        # First lid close: create session marker and initial WakeSystem alarm.
        # On re-suspends (SLEEP_SESSION_START already exists), s2idle-auto-hib.sh
        # has already re-armed the next 5-minute alarm when it ran; creating another
        # here races with it and causes exponential alarm proliferation — 2 instances
        # at cycle 2, 3 at cycle 3, etc. (confirmed 2026-07-10/11).
        date +%s > "$SLEEP_SESSION_START"

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
        # When the alarm fires, s2idle-auto-hib.sh is dispatched by PID 1
        # (reliable even if systemd-sleep re-enters s2idle in ~200 μs).
        # Cancelled in the post hook so a user lid-open cleans it up.
        #
        # Always use the short (5-minute) alarm regardless of AC/battery state.
        # The hibernate-vs-sleep decision is made in s2idle-auto-hib.sh when the
        # alarm fires, using the CURRENT battery state at that moment.  Baking the
        # timeout in at sleep-entry caused the "lid close on AC, then unplug" failure
        # (2026-07-02): the 1-hour alarm was committed before the cable was pulled;
        # the machine then sat on battery in S2idle for up to an hour in a bag,
        # overheated, and hard-crashed before auto-hib ever fired.
        # With a universal 5-minute alarm, s2idle-auto-hib.sh sees "Discharging"
        # within 5 minutes of AC removal and hibernates immediately.
        #
        # Unit name includes the epoch so each sleep cycle gets a unique name.
        # Reusing the same unit name across sleep cycles fails: after the timer
        # fires and completes, the transient unit remains in inactive/dead state
        # in systemd's memory; systemd-run refuses to create another unit with
        # the same name until GC runs, causing a WARNING and leaving the machine
        # with no autonomous wakeup (confirmed 2026-06-18 failure: slept 11 h).
        _alarm_sec="$MAX_S2IDLE_SEC_BAT"
        _prev_alarm=$(cat "$WAKE_ALARM_UNIT" 2>/dev/null || true)
        [ -n "$_prev_alarm" ] && systemctl stop "$_prev_alarm" 2>/dev/null || true
        rm -f "$WAKE_ALARM_UNIT"
        _alarm_unit="z13-s2idle-wake-$(date +%s)"
        systemd-run --no-block \
          --on-active="${_alarm_sec}s" \
          --timer-property=WakeSystem=yes \
          --unit="$_alarm_unit" \
          -- /usr/lib/z13-hibernate/s2idle-auto-hib.sh "$_alarm_unit" 2>/dev/null \
          && { echo "$_alarm_unit" > "$WAKE_ALARM_UNIT"; echo "s2idle-resume-fixup: $_alarm_unit set for ${_alarm_sec}s (WakeSystem=yes, initial)"; } \
          || echo "s2idle-resume-fixup: WARNING: WakeSystem alarm scheduling failed — machine may sleep indefinitely"
      else
        echo "s2idle-resume-fixup: re-suspend (session $(cat "$SLEEP_SESSION_START")), alarm managed by s2idle-auto-hib.sh"
      fi

      # Stop ollama to drain ROCm GPU fences before S2idle.
      # With active compute running, amdgpu can hang on the suspend/resume path
      # after repeated S2idle cycles (confirmed 2026-07-24: 5.5 h S2idle with
      # llama-server active → GPU hang on wake, wallpaper frozen, no keyboard).
      # The gate hook already does this for S4 hibernate; mirror it here.
      # Only on first lid-close — ollama stays stopped for all re-suspends; it
      # is restarted in the post hook when the user actually opens the lid.
      if systemctl is-active --quiet ollama 2>/dev/null; then
        systemctl stop ollama 2>/dev/null || true
        touch "$OLLAMA_STOPPED_FLAG"
        echo "s2idle-resume-fixup: stopped ollama (ROCm GPU drain for S2idle)"
      fi

      # Bring WiFi down before sleep so firmware is idle for wiphy_suspend().
      # Do NOT unload mt7925e: unloading with DMA pages in-flight leaves a
      # page_pool zombie that the kernel can never drain — confirmed to block
      # S2idle cycling for 7+ hours (2026-08-01).  An idle interface is enough
      # for wiphy_suspend() to complete without timing out.
      ip link set "$_wifi_if" down 2>/dev/null || true
      echo "s2idle-resume-fixup: ${_wifi_if} brought down for S2idle (mt7925e kept loaded)"
    fi
    ;;

  post/suspend|post/hybrid-sleep|post/suspend-then-hibernate)
    # Cancel RTC wakealarm (ineffective on this platform but cleanup is harmless).
    if [ -w "$RTC_WAKEALARM" ]; then
      echo 0 > "$RTC_WAKEALARM" 2>/dev/null || true
    fi
    # Let the ACPI lid state settle before reading it.  A spurious lid-open
    # ACPI event can wake the machine from S2idle and leave the state file
    # reporting "open" for 1-2 s before reverting to "closed" (confirmed
    # 2026-08-01: a 19:08:41 spurious event woke the machine from a 19:08:10
    # alarm check; the post hook read "open" instantly, cancelled the alarm
    # chain, restarted ollama, and the machine stayed awake for 7.5 h on
    # battery with the lid physically closed the entire time).
    sleep 2

    # Cancel WakeSystem alarm only on lid-open (user wake).  For autonomous
    # wakes (lid still closed), s2idle-auto-hib.sh already re-armed a fresh
    # 5-minute alarm before exiting; cancelling it here would leave the machine
    # with no subsequent check alarm.  The pre/suspend hook (triggered when
    # lid-watch calls systemctl suspend next) stops the old alarm itself.
    _lid_cancel=$(awk '{print $2}' /proc/acpi/button/lid/LID/state 2>/dev/null || echo open)
    if [ "$_lid_cancel" = "open" ]; then
      _prev_alarm=$(cat "$WAKE_ALARM_UNIT" 2>/dev/null || true)
      if [ -n "$_prev_alarm" ]; then
        systemctl stop "$_prev_alarm" 2>/dev/null || true
        rm -f "$WAKE_ALARM_UNIT"
      fi
      # Cancel any pending hibernate timer set by s2idle-auto-hib.sh or the
      # long-sleep gate below.  The 15-second monotonic timer survives lid-open
      # if the user wakes the machine before it fires; without this cancel it
      # fires ~15 s after waking and hibernates the machine while the user is
      # actively working (confirmed 2026-07-25).
      systemctl stop z13-long-sleep-hibernate 2>/dev/null || true
      rm -f "$HIB_PENDING"
    fi

    # Display recovery — only on lid-open wakes.  Skip for autonomous wakes
    # (lid still closed → going to hibernate): qdbus6 SimulateUserActivity can
    # block for 25 s when KDE is unresponsive after a long sleep, and the
    # hibernate timer (15 s) would fire before the post hook finishes, causing
    # systemd to refuse hibernate with "Action suspend already in progress"
    # (confirmed 2026-06-25).  On Z13 the keyboard IS the lid; lid-open
    # generates an ACPI lid-switch event but NOT a key event, so KDE's DPMS
    # stays off.  The user sees a black screen and hard-resets if display
    # recovery is skipped when they actually open the lid (confirmed 2026-06-15).
    _lid_now=$(awk '{print $2}' /proc/acpi/button/lid/LID/state 2>/dev/null || echo open)
    if [ "$_lid_now" = "open" ]; then
      # Restart ollama if we stopped it on S2idle entry.
      if [ -f "$OLLAMA_STOPPED_FLAG" ]; then
        rm -f "$OLLAMA_STOPPED_FLAG"
        systemctl start ollama 2>/dev/null || true
        echo "s2idle-resume-fixup: restarted ollama (user lid-open)"
      fi

      # Step 1: framebuffer unblank — safe kernel-level unblank.  Do NOT write
      # /sys/class/drm/*/dpms: KWin owns the DRM device on Wayland; writing DPMS
      # sysfs while KWin holds it causes atomic-commit EBUSY → black screen.
      ( for f in /sys/class/graphics/*/blank; do [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || true; done ) 2>/dev/null || true
      # Step 2: SimulateUserActivity via D-Bus — tells KDE to re-enable DPMS
      # outputs.  Framebuffer unblank alone does not wake KWin's output pipeline
      # on Wayland.  Timeout 10 s: cap a hung qdbus6 to prevent blocking the gate.
      _uid=$(id -u gunther 2>/dev/null || echo "")
      if [ -n "$_uid" ]; then
        _xdg="/run/user/$_uid"
        _wl=""
        for _w in wayland-0 wayland-1 wayland-2; do
          [ -S "$_xdg/$_w" ] && _wl="$_w" && break
        done
        if [ -n "$_wl" ]; then
          _qdbus_env="sudo -u gunther env \
            XDG_RUNTIME_DIR=$_xdg \
            DBUS_SESSION_BUS_ADDRESS=unix:path=$_xdg/bus \
            WAYLAND_DISPLAY=$_wl"
          timeout 10 $_qdbus_env \
            qdbus6 org.kde.ScreenSaver /ScreenSaver SimulateUserActivity 2>/dev/null \
            && echo "s2idle-resume-fixup: SimulateUserActivity sent (DPMS wake)" \
            || true
          # KWin Wayland occasionally stops processing pointer button events after
          # resume even though libinput delivers them correctly (Plasma 6.x bug).
          # reconfigure() re-initialises KWin's input pipeline without the visual
          # disruption of --replace.  No-op if KWin is healthy; harmless if not.
          timeout 5 $_qdbus_env \
            qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null \
            && echo "s2idle-resume-fixup: KWin reconfigure sent (input pipeline refresh)" \
            || true
        fi
      fi
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
        wall "
*** BATTERY LOW — HIBERNATING IN 10 SECONDS ***

Battery is at ${cap}% after waking from sleep.  Saving state to disk
in 10 seconds.  Plug in to cancel if possible.
DO NOT switch virtual terminals — GPU suspend is about to begin.
"
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
        # s2idle-auto-hib.sh (run by the WakeSystem timer unit) may have already
        # set HIB_PENDING and scheduled z13-long-sleep-hibernate; skip if so.
        if [ -f "$HIB_PENDING" ]; then
          echo "s2idle-resume-fixup: hibernate already pending (from WakeSystem timer) — skipping duplicate"
          rm -f "$SLEEP_SESSION_START"
        else
          echo "s2idle-resume-fixup: autonomous wake after ${elapsed}s, lid closed — scheduling hibernate"
          wall "
*** LONG SLEEP HIBERNATE IN 15 SECONDS ***

Machine has been idle (lid closed) for $(( elapsed / 3600 ))h $(( (elapsed % 3600) / 60 ))m.
Saving state to disk in 15 seconds to protect battery.
DO NOT switch virtual terminals — GPU suspend is about to begin.
Machine will resume on next power-on.  This is NOT a crash or hang.
"
          rm -f "$SLEEP_SESSION_START"
          touch "$HIB_PENDING"
          systemd-run --on-active=15s --unit=z13-long-sleep-hibernate \
            bash -c "systemctl hibernate; rm -f $HIB_PENDING" \
            || rm -f "$HIB_PENDING"
        fi
      elif [ "$lid_state" = "open" ]; then
        # User opened the lid — always resume normally, never hibernate.
        echo "s2idle-resume-fixup: lid opened after ${elapsed}s — resuming normally"
        rm -f "$SLEEP_SESSION_START"
      fi
      # lid closed + under threshold: keep marker; lid-watch re-suspends.
    fi
    ;;
esac
