#!/usr/bin/env bash
# z13-battery-guard — load-aware hibernate on battery.
# Called every 5 minutes by z13-battery-guard.timer.
#
# Policy (evaluated in order):
#   battery ≤ LOW_BAT_PCT    → hibernate unconditionally (hardware safety)
#   load1 > LOAD_IDLE_MAX    → skip (CPU or I/O work in progress)
#   sleep inhibitor held     → skip (explicit block via systemd-inhibit)
#   otherwise                → hibernate (idle on battery)
#
# The load average already includes processes blocked in D-state (disk I/O
# wait), so it catches database queries, compilers, and most background jobs
# without needing a separate disk-IO check.
#
# For CPU-light but network-heavy jobs (LLM API calls, large uploads) that
# would not raise the load average, take an explicit inhibitor:
#   systemd-inhibit --what=sleep --who="my-job" --why="LLM API job" \
#                   --mode=block /path/to/job
# The guard respects all block and delay sleep inhibitors.

set -euo pipefail

BAT=/sys/class/power_supply/BAT0
LOW_BAT_PCT=15       # hibernate below this regardless of load
LOAD_IDLE_MAX=1.0    # 1-min load avg; above this = busy, skip hibernate

# Only act when discharging.
status=$(cat "$BAT/status" 2>/dev/null || echo Unknown)
if [ "$status" != "Discharging" ]; then
    echo "z13-battery-guard: not discharging (status=$status) — nothing to do"
    exit 0
fi

capacity=$(cat "$BAT/capacity" 2>/dev/null || echo 100)
load1=$(awk '{print $1}' /proc/loadavg)

# Low battery: hibernate regardless of load.
if [ "$capacity" -le "$LOW_BAT_PCT" ]; then
    echo "z13-battery-guard: battery ${capacity}% ≤ ${LOW_BAT_PCT}% — hibernating (low battery)"
    systemctl hibernate
    exit 0
fi

# System busy: skip.
busy=$(awk -v l="$load1" -v t="$LOAD_IDLE_MAX" 'BEGIN { print (l+0 > t+0) ? 1 : 0 }')
if [ "$busy" = "1" ]; then
    echo "z13-battery-guard: battery ${capacity}%, load=${load1} > ${LOAD_IDLE_MAX} — busy, skipping"
    exit 0
fi

# Sleep inhibitor held: skip.  Checks all active block/delay inhibitors.
if systemd-inhibit --list --no-legend 2>/dev/null | grep -qiE '\bsleep\b|\bhibernate\b'; then
    holder=$(systemd-inhibit --list --no-legend 2>/dev/null \
             | awk '/sleep|hibernate/ { print $1; exit }')
    echo "z13-battery-guard: battery ${capacity}%, load=${load1} — sleep inhibited by '${holder}', skipping"
    exit 0
fi

echo "z13-battery-guard: battery ${capacity}%, load=${load1} ≤ ${LOAD_IDLE_MAX} — idle on battery, hibernating"
systemctl hibernate
