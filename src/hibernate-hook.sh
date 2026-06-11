#!/usr/bin/env bash
set -euo pipefail

source /usr/lib/z13-hibernate/common.sh

if [ "$1" != "pre" ] || [ "$2" != "hibernate" ]; then
  exit 0
fi

# Flush early resume-prep log if present (from initrd hib-resume-prep hook)
if [ -f /run/hib-resume-prep.log ]; then
  kmsg "initrd hib-resume-prep log from this boot:"
  while IFS= read -r line || [ -n "$line" ]; do kmsg "  $line"; done < /run/hib-resume-prep.log
  rm -f /run/hib-resume-prep.log
fi
# Also support old hib-kbd.log name for transition
if [ -f /run/hib-kbd.log ]; then
  kmsg "initrd hib-kbd log from this boot (old name):"
  while IFS= read -r line || [ -n "$line" ]; do kmsg "  $line"; done < /run/hib-kbd.log
  rm -f /run/hib-kbd.log
fi

kmsg "hook: === BEGIN HIBERNATE HOOK (perf params + breathe) ==="
echo "=== Pre-hibernate hook START $(date) ===" | tee -a "$LOGFILE"
kmsg "hook: kernel=$(uname -r) (gate did pre-check; this hook does perf + breathe spinner)"

# pm_async: z13-s2idle-wakeup.service sets pm_async=0 globally because the
# lid-close abort/re-enter race hangs amdgpu under async s2idle callbacks.
# But every historically successful hibernate ran with pm_async=1, and the
# only two hibernates attempted under pm_async=0 (2026-06-10, both on
# battery) hung in the device-suspend/snapshot phase. Restore async for the
# hibernate window; the post-resume hook sets it back to 0 for s2idle.
echo 1 > /sys/power/pm_async 2>/dev/null || true
kmsg "hook: pm_async=1 for hibernate (s2idle keeps 0)"

# Diagnostic, scoped to the hibernate window (restored by resume hook): if
# the snapshot phase hangs again, convert the hang into a panic so efi_pstore
# captures the stack of the offending task, then auto-reboot after 30s.
# Scoped because a 2-min D-state during normal desktop use must NOT panic.
# The 2026-06-11 AC hang never tripped hung_task (no auto-reboot), so widen
# the net: 60s hung-task window, all-CPU backtraces in the dump, and the
# NMI hardlockup detector for busy-spins with interrupts off.
sysctl -q kernel.hung_task_panic=1 2>/dev/null || true
sysctl -q kernel.hung_task_timeout_secs=60 2>/dev/null || true
sysctl -q kernel.hung_task_all_cpu_backtrace=1 2>/dev/null || true
sysctl -q kernel.softlockup_panic=1 2>/dev/null || true
sysctl -q kernel.softlockup_all_cpu_backtrace=1 2>/dev/null || true
sysctl -q kernel.hardlockup_panic=1 2>/dev/null || true
sysctl -q kernel.panic=30 2>/dev/null || true
kmsg "hook: hung_task(60s)/softlockup/hardlockup panic armed for hibernate window (pstore capture)"

# Restore-side stop_machine deadlock (pstore dumps 2026-06-11): right after the
# S4 image restore re-enables the non-boot CPUs, a stop_machine call hangs —
# the NMI backtraces show several CPUs "idling at io_idle" that never run their
# migration threads. Reschedule IPIs to those CPUs are lost (platform/BIOS S4
# bug); a CPU in deep ACPI io_idle needs a real interrupt to wake, so it sleeps
# through the stop request and every other CPU spins forever. CPUs held at
# C1/mwait wake via the monitored need-resched flag WITHOUT an IPI, so pin the
# PM QoS latency to 0 for the whole hibernate window. The holder process (and
# its in-kernel QoS request) is frozen into the image, so the restore side is
# protected too; the resume hook stops the unit.
systemd-run --collect --unit=z13-cstate-hold /usr/lib/z13-hibernate/cstate-hold.sh 2>/dev/null \
  && kmsg "hook: deep C-states disabled for hibernate+restore window (z13-cstate-hold)" \
  || kmsg "hook: WARNING: could not start z13-cstate-hold (deep-idle IPI-loss hang possible)"

# Performance settings (the critical boost + tunings right before write)
# No profile apply here that looks at battery; we always want max for the snapshot.

swapoff /dev/mapper/swap 2>/dev/null || kmsg "hook: volatile swapoff (ok if absent)"
echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true

# mt7925e WiFi: on S4 resume the firmware times out (error -110 in ieee80211_reconfig).
# The driver is left in a broken state. If hibernate starts while the driver is in that
# state, the PM suspend callback hangs waiting for firmware that never answers → fans
# spin, system never powers off. Unloading the driver before hibernation forces a clean
# firmware re-init on the next resume instead of trying to suspend a broken state.
#
# Always bring the interface down first regardless of lsmod state: the physical device
# is still present and will get PM callbacks even if the module name doesn't match or
# the driver was briefly absent due to a rapid S3 cycle reloading it.
_wifi_if=wlp194s0
if ip link show "$_wifi_if" &>/dev/null; then
  ip link set "$_wifi_if" down 2>/dev/null || true
  kmsg "hook: ${_wifi_if} brought down"
  # Give the RX path a moment to drain before unload: yanking the module with
  # packets in flight can leave a page_pool that never shuts down
  # ("page_pool_release_retry stalled pool shutdown", 2026-06-11) and the
  # subsequent kernel hibernate entry wedges on it.
  sleep 1
fi
_mt_mods=$(lsmod | awk 'NR>1 && /^mt79/ {print $1}' | tr '\n' ' ')
kmsg "hook: mt79xx lsmod: ${_mt_mods:-none}"
if echo "$_mt_mods" | grep -qw 'mt7925e'; then
  # timeout 20s: if firmware is broken the remove callback can hang; cap it so
  # the machine doesn't breathe forever on AC if WiFi refuses to unload.
  timeout 20 modprobe -r mt7925e 2>/dev/null \
    && kmsg "hook: mt7925e unloaded" \
    || kmsg "hook: mt7925e unload timed-out or failed (PM suspend may still hang)"
else
  kmsg "hook: mt7925e not in lsmod (absent or already removed)"
fi

# VirtualBox: vboxdrv PM callbacks deadlock the kernel at hibernation entry when any VM is
# running. Save running VMs first (they resume from saved state after you start VBox post-resume),
# then unload the modules. Without this, the machine hangs indefinitely at hibernation entry.
# NOTE: do NOT use `lsmod | grep -q` here: under `set -o pipefail`, grep -q
# exiting at first match can SIGPIPE lsmod and fail the whole pipeline — the
# branch silently skips even when the module IS loaded (bit us 2026-06-11:
# vboxdrv stayed loaded into the snapshot and the restore deadlocked in
# stop_machine). /sys/module is race-free.
if [ -d /sys/module/vboxdrv ]; then
  _vbox_user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '($4 == "active" || $3 == "seat0") { print $3; exit }')
  [ -z "$_vbox_user" ] && _vbox_user=gunther
  _running=$(sudo -u "$_vbox_user" VBoxManage list runningvms 2>/dev/null | awk -F'"' '{print $2}')
  if [ -n "$_running" ]; then
    kmsg "hook: saving running VMs before hibernate: $(echo "$_running" | tr '\n' ',')"
    while IFS= read -r _vm; do
      [ -z "$_vm" ] && continue
      timeout 120 sudo -u "$_vbox_user" VBoxManage controlvm "$_vm" savestate 2>/dev/null \
        && kmsg "hook: VM saved: $_vm" \
        || kmsg "hook: WARNING: failed to save VM: $_vm (unloading anyway)"
    done <<< "$_running"
    sleep 1
  else
    kmsg "hook: vboxdrv loaded, no VMs running"
  fi
  modprobe -r vboxnetflt vboxnetadp vboxdrv 2>/dev/null \
    && kmsg "hook: vbox modules unloaded" \
    || kmsg "hook: vbox modules already gone"
fi

# 'shutdown' mode writes the image then does a plain poweroff rather than ACPI S4,
# which is more reliable on AMD. 'platform' (the default) can hang on S4 transitions.
echo shutdown > /sys/power/disk 2>/dev/null || true
kmsg "hook: hibernate disk mode: $(cat /sys/power/disk 2>/dev/null | tr -d '\n')"

# Marker EARLY (was at the end of this hook): systemd-sleep kills a sleep
# hook after ~90s and proceeds to hibernate anyway (2026-06-11: a slow sync
# got this hook killed mid-run — no marker meant the resume hooks skipped all
# recovery). The marker must exist for any hibernate that this hook started.
touch /run/z13-was-hibernated || true
kmsg "hook: created hibernate marker /run/z13-was-hibernated (early; resume hooks check this)"

kmsg "hook: drop_caches at $(date '+%H:%M:%S')"
echo 3 > /proc/sys/vm/drop_caches
kmsg "hook: sync starting at $(date '+%H:%M:%S') (bounded: hook is killed at ~90s total)"
# Bounded: an unbounded sync blocked 88s+ on battery once and the hook got
# killed before setting compression/PPT/breathe. Dirty pages that don't make
# it are frozen into the image and written on the next boot's flush anyway.
timeout 45 sync \
  && kmsg "hook: sync done at $(date '+%H:%M:%S')" \
  || kmsg "hook: WARNING: sync exceeded 45s, continuing without full flush"

echo 1024 > /sys/block/nvme0n1/queue/nr_requests 2>/dev/null || true
echo 4096 > /sys/block/nvme0n1/queue/max_sectors_kb 2>/dev/null || true
echo 8192 > /sys/block/nvme0n1/queue/read_ahead_kb 2>/dev/null || true
kmsg "hook: nvme tunings (scheduler untouched to avoid unrestorable images)"

kmsg "hook: meminfo: $(grep -E 'MemTotal|MemAvailable|Active:' /proc/meminfo | tr '\n' ' ')"
swapon -s | sed 's/^/hook: swapon: /'

# Tune hibernate compression before the write: LZ4 is 2-3x faster than LZO on this
# hardware (AES-NI handles LUKS, Ryzen's integer throughput handles LZ4 well).
# The threads default is 3 which is badly underutilized on a 32-thread machine with
# 128GB RAM. Use num_online_cpus-1 capped at 12 (beyond that io becomes the limit).
modprobe -q lz4 2>/dev/null || kmsg "hook: WARNING: lz4 module not available, will fall back to lzo"
echo lz4 > /sys/module/hibernate/parameters/compressor 2>/dev/null || kmsg "hook: WARNING: could not set lz4 compressor"
_nth=$(( $(nproc) - 1 ))
_nth=$(( _nth > 12 ? 12 : _nth ))
_nth=$(( _nth < 1 ? 1 : _nth ))
echo "$_nth" > /sys/power/hibernate_compression_threads 2>/dev/null || true
kmsg "hook: compression: $(cat /sys/module/hibernate/parameters/compressor 2>/dev/null || echo unknown), threads=$_nth"

# The performance boost
force_high_performance

kmsg "hook: starting image write. Watch kernel messages for PM: hibernation progress."

# Breathe spinner (the "user spinner during write")
asusctl leds set low 2>/dev/null || true
asusctl aura effect breathe --colour 00ff60 --colour2 ff4080 --speed high 2>/dev/null || true
kmsg "hook: breathe effect set for write phase"

kmsg "hook: prep complete (perf params only) — proceeding to hibernation"

# (hibernate marker is created early in this hook — see above — so it exists
# even if systemd-sleep kills a slow hook run at the ~90s timeout.)

# No watcher by default (per current decision: little benefit, adds noise).
# If you really want it back, add a debug flag check + bg loop here writing "Hibernating progress..."
# and save pid to /var/run/hibernate-watcher.pid so resume can kill it.

# Return; systemd-sleep will do the actual hibernate.
