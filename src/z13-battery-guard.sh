#!/usr/bin/env bash
# z13-battery-guard — load-aware and presence-aware hibernate on battery.
# Called every 5 minutes by z13-battery-guard.timer.
#
# Policy (evaluated in order):
#
#   battery ≤ EMERGENCY_PCT (2%)
#       Hibernate unconditionally.  Hardware will cut power at 0%; KDE has
#       already shown low-battery notifications at 20/15/10/5%.
#
#   battery ≤ LOW_BAT_PCT (15%) AND screen is off
#       User is not present.  Hibernate to save state before the battery
#       dies.  Better to resume from hibernate at 13% than crash at 0%.
#
#   battery ≤ LOW_BAT_PCT (15%) AND screen is on
#       User is actively present and has chosen to continue despite the
#       KDE battery notifications.  Skip — they are managing the situation.
#       The EMERGENCY_PCT floor still applies.
#
#   load1 > LOAD_IDLE_MAX (1.0)
#       System is doing useful work (compiler, AI inference, DB query).
#       Skip.  The load average includes D-state IO-blocked processes, so
#       it catches disk-heavy workloads without a separate IO probe.
#
#   sleep inhibitor held
#       Explicit block via systemd-inhibit --what=sleep.  Respect it.
#       Use for CPU-light network-heavy jobs (LLM API calls, uploads) that
#       would not raise the load average:
#         systemd-inhibit --what=sleep --who="myjob" \
#                         --why="LLM API" --mode=block ./job
#
#   otherwise
#       Genuinely idle on battery.  Hibernate.
#
# "Screen is off" detection (any of the following):
#   - All graphical sessions are idle (IdleHint=yes) or locked (LockedHint=yes)
#   - All /sys/class/backlight/*/actual_brightness values are 0

set -euo pipefail

BAT=/sys/class/power_supply/BAT0
EMERGENCY_PCT=2      # always hibernate: hardware safety floor
LOW_BAT_PCT=15       # hibernate when screen off; skip when user present
# Scale "busy" threshold to actual CPU count.  10% of nproc, minimum 1.5.
# On a 32-CPU machine this gives 3.2; on a 2-CPU machine the floor of 1.5
# applies.  Load average already includes D-state (IO-blocked) processes.
_ncpu=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 4)
LOAD_IDLE_MAX=$(awk -v n="$_ncpu" 'BEGIN { t=n*0.10; printf "%.1f", (t<1.5)?1.5:t }')

# Only act when discharging.
status=$(cat "$BAT/status" 2>/dev/null || echo Unknown)
if [ "$status" != "Discharging" ]; then
    echo "z13-battery-guard: not discharging (status=$status) — nothing to do"
    exit 0
fi

capacity=$(cat "$BAT/capacity" 2>/dev/null || echo 100)
load1=$(awk '{print $1}' /proc/loadavg)

# ── Emergency floor ──────────────────────────────────────────────────────────
if [ "$capacity" -le "$EMERGENCY_PCT" ]; then
    echo "z13-battery-guard: battery ${capacity}% ≤ ${EMERGENCY_PCT}% — EMERGENCY hibernate"
    systemctl hibernate
    exit 0
fi

# ── Screen-presence check ────────────────────────────────────────────────────
# screen_on=yes  → user is present; respect their choice at low battery
# screen_on=no   → user is away; safe to hibernate at LOW_BAT_PCT threshold
screen_on=no
while read -r sid _rest; do
    locked=$(loginctl show-session "$sid" --value --property=LockedHint 2>/dev/null || echo yes)
    idle=$(loginctl show-session "$sid" --value --property=IdleHint   2>/dev/null || echo yes)
    if [ "$locked" = "no" ] && [ "$idle" = "no" ]; then
        screen_on=yes
        break
    fi
done < <(loginctl list-sessions --no-legend 2>/dev/null)

# Backlight override: if hardware reports all backlights at 0 the display is
# physically off regardless of what logind thinks.
if [ "$screen_on" = "yes" ]; then
    all_dark=yes
    for bl in /sys/class/backlight/*/actual_brightness; do
        [ -r "$bl" ] || continue
        b=$(cat "$bl" 2>/dev/null || echo 1)
        [ "${b:-0}" -gt 0 ] && { all_dark=no; break; }
    done
    [ "$all_dark" = "yes" ] && screen_on=no
fi

# ── Low-battery decisions ────────────────────────────────────────────────────
if [ "$capacity" -le "$LOW_BAT_PCT" ]; then
    if [ "$screen_on" = "no" ]; then
        echo "z13-battery-guard: battery ${capacity}%, screen off — hibernating (below ${LOW_BAT_PCT}%, user absent)"
        systemctl hibernate
    else
        echo "z13-battery-guard: battery ${capacity}%, user present — skipping (emergency floor: ${EMERGENCY_PCT}%)"
    fi
    exit 0
fi

# ── Above LOW_BAT_PCT: work and inhibitor checks ─────────────────────────────
busy=$(awk -v l="$load1" -v t="$LOAD_IDLE_MAX" 'BEGIN { print (l+0 > t+0) ? 1 : 0 }')
if [ "$busy" = "1" ]; then
    echo "z13-battery-guard: battery ${capacity}%, load=${load1} > ${LOAD_IDLE_MAX} (${_ncpu} CPUs × 10%) — busy, skipping"
    exit 0
fi

if systemd-inhibit --list --no-legend 2>/dev/null | grep -qiE '\bsleep\b|\bhibernate\b'; then
    holder=$(systemd-inhibit --list --no-legend 2>/dev/null \
             | awk '/sleep|hibernate/ { print $1; exit }')
    echo "z13-battery-guard: battery ${capacity}% — sleep inhibited by '${holder}', skipping"
    exit 0
fi

echo "z13-battery-guard: battery ${capacity}%, load=${load1} ≤ ${LOAD_IDLE_MAX} (${_ncpu} CPUs × 10%) — idle on battery, hibernating"
systemctl hibernate
