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

# Prevent battery-guard from immediately re-hibernating.  Its OnUnitActiveSec=5min
# timer fires within ~1 minute of resume because monotonic elapsed time during
# hibernation catches up the interval; confirmed spurious re-hibernate 2026-07-02.
touch /run/z13-resume-cooldown

# Since we don't do real kill -STOP yet (sidestep in get_busy_pids), there is
# little to CONT here. When we enable real detection, move the heavy CONT + any
# "system is really back" recovery here.

# For now, do a full screen restore (so resume still works well) and final done color.
restore_screen
restore_lights_and_profile
restart_gpu_processes

# Restart ollama — gate-hook.sh stops it before hibernate to drain GPU fences,
# but that stop bypasses _GPU_STOPPED_FILE so restart_gpu_processes won't catch it.
if systemctl is-enabled --quiet ollama 2>/dev/null; then
  systemctl start ollama 2>/dev/null \
    && kmsg "post-resume: ollama restarted" \
    || kmsg "post-resume: ollama start failed (start manually if needed)"
fi

# KWin --replace: removed.  The gate-hook no longer runs kwin_wayland --replace
# on compositor suspend failure (KWin 6.x API change — fixed 2026-07-08).
# Without gate-hook --replace, kscreenlocker survives every hibernate cycle
# cleanly, so there is no accumulated dirty amdgpu GPU VM state to clear here.
# Running --replace unnecessarily crashes kscreenlocker and causes the exact
# session corruption it was meant to prevent.

# Reload VirtualBox kernel modules.
# The gate hook kills GPU-holding processes (including any running VMs) before
# hibernate; their reference counts drop to zero and the vbox modules auto-unload
# before the hibernate image is captured, so they are gone on resume.
# modprobe is a no-op when modules are already loaded, so this is always safe.
if modinfo vboxdrv &>/dev/null 2>&1; then
  for _vmod in vboxdrv vboxnetflt vboxnetadp; do
    modprobe "$_vmod" 2>/dev/null && kmsg "post-resume: modprobe $_vmod OK" || kmsg "post-resume: modprobe $_vmod failed (skipping)"
  done
  # Recreate host-only interfaces.  The OS-level vboxnet* interfaces are
  # destroyed when vboxnetadp unloads; VirtualBox's own config still references
  # them, so 'hostonlyif create' makes a new one (vboxnet1 if vboxnet0 is stale
  # in the config).  Remove stale records first so the new interface reclaims
  # vboxnet0 (and any additional ones the user had).
  _vbox_needed=$(VBoxManage list hostonlyifs 2>/dev/null | awk '/^Name:/{print $2}')
  for _viface in $_vbox_needed; do
    if ! ip link show "$_viface" &>/dev/null 2>&1; then
      VBoxManage hostonlyif remove "$_viface" 2>/dev/null || true
      VBoxManage hostonlyif create 2>/dev/null \
        && kmsg "post-resume: recreated VBox host-only interface (was $_viface)" \
        || kmsg "post-resume: VBox hostonlyif create failed — start VirtualBox manually"
    fi
  done
fi

# Final "we are done" color
asusctl leds set high 2>/dev/null || true
asusctl aura effect static -c 00ff60 2>/dev/null || true
kmsg "post-resume: final color 00ff60, restore complete"

kmsg "post-resume: done (system should be fully back now)"

# Clean marker
rm -f /run/z13-was-hibernated || true
kmsg "post-resume: cleaned hibernate marker"
