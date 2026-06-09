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
if lsmod | grep -q '^vboxdrv'; then
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

kmsg "hook: drop_caches at $(date '+%H:%M:%S')"
echo 3 > /proc/sys/vm/drop_caches
kmsg "hook: sync starting at $(date '+%H:%M:%S') (may block several minutes on battery with dirty pages)"
sync
kmsg "hook: sync done at $(date '+%H:%M:%S')"

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

# Create a marker so the resume path knows this was a *real hibernate* (S4),
# not a regular suspend-to-RAM (S3). The resume hooks will only do heavy
# screen recovery / CONT if this marker exists. This prevents tearing a
# perfectly good lock screen or session on normal lid-close wakes.
touch /run/z13-was-hibernated || true
kmsg "hook: created hibernate marker /run/z13-was-hibernated (resume hooks will check this)"

# No watcher by default (per current decision: little benefit, adds noise).
# If you really want it back, add a debug flag check + bg loop here writing "Hibernating progress..."
# and save pid to /var/run/hibernate-watcher.pid so resume can kill it.

# Return; systemd-sleep will do the actual hibernate.
