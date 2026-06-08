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

# Early unblank + backlight (quick visible sign)
( for f in /sys/class/graphics/*/blank; do [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || true; done ) 2>/dev/null || true
( for f in /sys/class/drm/*/dpms; do [ -w "$f" ] && echo on > "$f" 2>/dev/null || true; done ) 2>/dev/null || true

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

# Schedule the post-resume-hook for when the system is really back (GUI settled, etc.)
# This is where we can safely do heavier CONT or other recovery later.
systemd-run --no-block --on-active=15s --unit=z13-post-resume-hook -- /usr/lib/z13-hibernate/post-resume-hook.sh 2>/dev/null || true
kmsg "resume: scheduled post-resume-hook in ~15s"

# Light early wake calls (the heavy restore_screen etc can move to post-resume-hook later)
console_msg "resume hook: early wake + CONT done (color 00ff60). Full recovery may continue in post-resume."

echo "=== Post-hibernate resume hook END ===" | tee -a "$LOGFILE"

# Clean the marker so a subsequent normal sleep resume doesn't accidentally see it
rm -f /run/z13-was-hibernated || true
kmsg "resume: cleaned hibernate marker"
