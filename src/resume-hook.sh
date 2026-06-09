#!/usr/bin/env bash
set -euo pipefail

source /usr/lib/z13-hibernate/common.sh

if [ "$1" != "post" ] || [ "$2" != "hibernate" ]; then
  # This is a normal suspend (S3) resume, not hibernate. Do nothing heavy.
  exit 0
fi

# Extra safety marker check: only proceed with recovery if the pre-hibernate hook
# actually created the marker. This protects against the hook being invoked
# in unexpected ways or on hybrid sleep modes.
if [ ! -f /run/z13-was-hibernated ]; then
  kmsg "resume: post-hibernate but no /run/z13-was-hibernated marker — skipping recovery to protect active session/lockscreen"
  exit 0
fi

kmsg "resume: === BEGIN RESUME HOOK ==="
echo "=== Post-hibernate resume hook START $(date) ===" | tee -a "$LOGFILE"

# Early framebuffer unblank. Do NOT write to /sys/class/drm/*/dpms here:
# on Wayland KWin owns the DRM device exclusively and writing to DPMS sysfs
# while KWin is holding the device causes atomic-commit EBUSY → black screen.
( for f in /sys/class/graphics/*/blank; do [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || true; done ) 2>/dev/null || true

# Color to 00ff60 to tell we are (starting to be) done
asusctl leds set high 2>/dev/null || true
asusctl aura effect static -c 00ff60 2>/dev/null || true
kmsg "resume: color 00ff60 (done signal)"

# Restore profile to something reasonable (apply will choose based on current AC/bat after resume)
apply_power_profile

# CONT anything we stopped in gate (currently almost none because sidestepped, but keep for when we enable real detection)
restore_processes

# Kill any stray watcher
kill_hibernate_watcher

# Early compositor resume: gate-hook suspended KWin compositor to drain GPU fences before
# the PM_HIBERNATION_PREPARE notifier. The suspended state is frozen into the S4 image.
# Resume it immediately so KWin starts rendering again. If D-Bus isn't quite ready this
# will silently fail; restore_screen() in post-resume-hook retries 15 seconds later.
_early_uid=$(id -u gunther 2>/dev/null || echo "")
if [ -n "$_early_uid" ]; then
  _early_xdg="/run/user/$_early_uid"
  _early_wl=""
  for _w in wayland-0 wayland-1 wayland-2; do
    [ -S "$_early_xdg/$_w" ] && _early_wl="$_w" && break
  done
  if [ -n "$_early_wl" ]; then
    sudo -u gunther env XDG_RUNTIME_DIR="$_early_xdg" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$_early_xdg/bus" \
      WAYLAND_DISPLAY="$_early_wl" \
      qdbus org.kde.KWin /Compositor resume 2>/dev/null \
      && kmsg "resume: KWin compositor resumed (early)" \
      || kmsg "resume: KWin compositor resume (early) failed — will retry in post-resume-hook"
  fi
fi

# Reload mt7925e WiFi after S4 resume.
# We unloaded it in the pre-hook to prevent the PM-suspend firmware-timeout hang.
# On resume udev reloads it, but ieee80211_reconfig() still times out (-110) leaving
# the driver in a broken state with the interface unusable. Force a clean full-stack
# reload here — before NetworkManager has dealt with the broken device — so WiFi comes
# back working without manual intervention.
_mt_loaded=$(lsmod | awk '/^mt79/{print $1}' | tr '\n' ' ')
kmsg "resume: mt79xx modules present: ${_mt_loaded:-none}"
if lsmod | grep -q '^mt79'; then
  kmsg "resume: removing mt79xx stack for clean firmware re-init"
  modprobe -r mt7925e mt7925_common mt792x_lib mt76_connac_lib mt76 2>/dev/null || true
  sleep 1
fi
modprobe mt7925e 2>/dev/null \
  && kmsg "resume: mt7925e reloaded — WiFi should come back via NetworkManager" \
  || kmsg "resume: mt7925e reload failed — WiFi may be unavailable"

# Schedule the post-resume-hook for when the system is really back (GUI settled, etc.)
# This is where we can safely do heavier CONT or other recovery later.
systemd-run --no-block --on-active=15s --unit=z13-post-resume-hook -- /usr/lib/z13-hibernate/post-resume-hook.sh 2>/dev/null || true
kmsg "resume: scheduled post-resume-hook in ~15s"

# Light early wake calls (the heavy restore_screen etc can move to post-resume-hook later)
console_msg "resume hook: early wake + CONT done (color 00ff60). Full recovery may continue in post-resume."

echo "=== Post-hibernate resume hook END ===" | tee -a "$LOGFILE"
# NOTE: marker /run/z13-was-hibernated is intentionally left here.
# post-resume-hook.sh (scheduled above) checks it and deletes it after screen recovery.
