#!/usr/bin/env bash
# z13-battery-guard — load-aware and presence-aware hibernate on battery.
# Called every 5 minutes by z13-battery-guard.timer.
#
# Policy (evaluated in order):
#
#   battery ≤ EMERGENCY_PCT (2%)
#       Hibernate unconditionally.  Hardware will cut power at 0%; this is
#       the last-resort floor before battery check is moved above cooldown.
#
#   battery ≤ CRITICAL_FLOOR_PCT (15%) [evaluated after cooldown]
#       Hibernate unconditionally — user present or not.  KDE PowerDevil's
#       critical battery action typically fires at 5-10%, which is too late:
#       this machine's LUKS-encrypted S4 write runs throttled (no CPU boost,
#       EC brownout risk), and the write can take 10+ minutes.  Battery died
#       at 1% mid-write after PowerDevil triggered at ~7% (confirmed 2026-07-21).
#       15% gives ~12 minutes of runway at the observed ~1.2%/min drain rate.
#
#   battery ≤ LOW_BAT_PCT (25%) AND screen is off
#       User is not present.  Hibernate to save state before the battery
#       dies.  Better to resume from hibernate at 22% than crash at 0%.
#
#   battery ≤ LOW_BAT_PCT (25%) AND screen is on AND battery > CRITICAL_FLOOR_PCT
#       User is actively present and battery is not yet critical.  Skip.
#       KDE notifications are visible.  CRITICAL_FLOOR_PCT overrides at 15%.
#
#   load1 > LOAD_IDLE_MAX  (default 1.0, absolute — NOT scaled by nproc)
#       CPU or disk-IO work in progress (compiler, local inference, DB query).
#       Load average counts D-state (IO-blocked) processes so disk-heavy jobs
#       are caught without a separate IO probe.
#       Load average is an ABSOLUTE count, not a percentage: one thread at
#       100% CPU contributes 1.0 regardless of how many CPUs the machine has.
#       Scaling the threshold by nproc would mean 3.2 on a 32-CPU machine —
#       a single important thread generating load 1.0 would be ignored.
#       Background system housekeeping (cron, systemd timers, dbus activity)
#       averages well below 0.5; a real single-threaded job sits at 0.5–1.0+.
#       NOTE: load average does NOT count network-waiting processes (S state).
#       A coding agent calling a cloud LLM generates near-zero load even when
#       active.  The network-bytes check below covers that case.
#
#   net_delta > NET_BUSY_BYTES (50 KB) since last run
#       Non-loopback network bytes transferred since the previous 5-minute
#       check exceed the threshold.  A single LLM API response is 2–50 KB;
#       active cloud-model usage easily exceeds 50 KB across five minutes.
#       Background noise (DNS, NTP, health-checks) is typically < 5 KB/5 min.
#       Snapshot is stored in NET_SNAP between runs.  Counter resets (reboot,
#       interface restart) are detected and the network check is skipped for
#       that cycle.
#       NOTE: this catches active API calls but misses long wait windows
#       between calls (e.g., waiting 10+ min for a single slow response).
#       For those, take an explicit inhibitor (see below).
#
#   sleep inhibitor held
#       Explicit block via systemd-inhibit --what=sleep.  Respect it.
#       Use for jobs that spend most of their time waiting with neither CPU
#       nor network activity visible in a 5-minute window:
#         systemd-inhibit --what=sleep --who="myjob" \
#                         --why="waiting on slow LLM" --mode=block ./job
#
#   otherwise
#       Genuinely idle on battery.  Hibernate.
#
# "Screen is off" detection (any of the following):
#   - All graphical sessions are idle (IdleHint=yes) or locked (LockedHint=yes)
#   - All /sys/class/backlight/*/actual_brightness values are 0

set -euo pipefail

BAT=/sys/class/power_supply/BAT0
EMERGENCY_PCT=2           # always hibernate: hardware safety floor
CRITICAL_FLOOR_PCT=15     # unconditional below this: hibernate even if user is present
LOW_BAT_PCT=25            # hibernate when screen off + idle; skip when user present
NET_SNAP=/run/z13-bat-net-snap   # persists non-loopback byte count between runs
NET_BUSY_BYTES=51200      # 50 KB: above this = active network work in progress

# CPU threshold: absolute, NOT scaled by nproc.
# Load average counts runnable + D-state threads as absolute units; one thread
# at 100% CPU contributes ~1.0 regardless of how many CPUs the machine has.
# A nproc-scaled threshold (e.g. 32×10% = 3.2 on this machine) would silently
# ignore a single important thread — a single-threaded job at full speed only
# generates load ~1.0.  Background system housekeeping (cron, systemd timers,
# dbus activity) with the screen locked averages well below 0.5; a real working
# thread sits at 0.5–1.0+.  1.0 is therefore the right minimum: "at least one
# full CPU thread is doing non-trivial work."
LOAD_IDLE_MAX=1.0

# ── Gate: only act when discharging ──────────────────────────────────────────
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

# ── Post-resume cooldown ──────────────────────────────────────────────────────
# After hibernate resume, the OnUnitActiveSec=5min timer fires within ~1 min
# (time elapsed during hibernation catches up the monotonic interval).  The
# system hasn't settled yet — screen is still recovering, load is near zero,
# NET_SNAP was cleared (tmpfs) — and the idle-on-battery check would trigger
# a spurious re-hibernate (confirmed 2026-07-02).  Skip all non-emergency
# decisions for 10 minutes after resume.
if [ -f /run/z13-resume-cooldown ]; then
    age=$(( $(date +%s) - $(stat -c %Y /run/z13-resume-cooldown 2>/dev/null || echo 0) ))
    if [ "$age" -lt 600 ]; then
        echo "z13-battery-guard: post-resume cooldown (${age}s < 600s) — skipping"
        exit 0
    else
        rm -f /run/z13-resume-cooldown
    fi
fi

# ── Screen-presence check ────────────────────────────────────────────────────
# screen_on=yes  → user is present; respect their choice at low battery
# screen_on=no   → user is away; safe to hibernate at LOW_BAT_PCT threshold
screen_on=no
while read -r sid _rest; do
    locked=$(loginctl show-session "$sid" --value --property=LockedHint 2>/dev/null || echo yes)
    idle=$(loginctl show-session   "$sid" --value --property=IdleHint   2>/dev/null || echo yes)
    if [ "$locked" = "no" ] && [ "$idle" = "no" ]; then
        screen_on=yes
        break
    fi
done < <(loginctl list-sessions --no-legend 2>/dev/null)

# Backlight override: if all backlights report 0 the display is physically off
# regardless of what logind thinks.
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
    elif [ "$capacity" -le "$CRITICAL_FLOOR_PCT" ]; then
        # Below critical floor: hibernate regardless of user presence.
        # KDE PowerDevil cannot be trusted as the sole trigger — it fires too
        # late for this machine's throttled hibernate write (2026-07-21).
        echo "z13-battery-guard: battery ${capacity}% ≤ ${CRITICAL_FLOOR_PCT}% — critical floor, hibernating (user may be present)"
        systemctl hibernate
    else
        echo "z13-battery-guard: battery ${capacity}%, user present — skipping (critical floor at ${CRITICAL_FLOOR_PCT}%)"
    fi
    exit 0
fi

# ── CPU load check ───────────────────────────────────────────────────────────
busy=$(awk -v l="$load1" -v t="$LOAD_IDLE_MAX" 'BEGIN { print (l+0 > t+0) ? 1 : 0 }')
if [ "$busy" = "1" ]; then
    echo "z13-battery-guard: battery ${capacity}%, load=${load1} > ${LOAD_IDLE_MAX} — busy, skipping"
    exit 0
fi

# ── Network activity check ───────────────────────────────────────────────────
# Sum all non-loopback RX+TX bytes from /proc/net/dev.
net_now=$(awk '
    NR > 2 {
        gsub(/:/, " ", $1)
        if ($1 != "lo") sum += $2 + $10
    }
    END { print sum+0 }
' /proc/net/dev)

net_skip=no
if [ -f "$NET_SNAP" ]; then
    read -r snap_time snap_bytes < "$NET_SNAP" 2>/dev/null || snap_bytes=0
    now_time=$(date +%s)
    # If snapshot is stale (> 15 min) or counter went backwards (interface
    # reset / reboot), skip the network check this cycle.
    if [ $(( now_time - ${snap_time:-0} )) -gt 900 ] || [ "$net_now" -lt "$snap_bytes" ] 2>/dev/null; then
        net_skip=yes
    else
        net_delta=$(( net_now - snap_bytes ))
        if [ "$net_delta" -gt "$NET_BUSY_BYTES" ]; then
            echo "$(date +%s) $net_now" > "$NET_SNAP"
            echo "z13-battery-guard: battery ${capacity}%, net_delta=${net_delta}B > ${NET_BUSY_BYTES}B — active network work, skipping"
            exit 0
        fi
    fi
else
    net_skip=yes
fi
echo "$(date +%s) $net_now" > "$NET_SNAP"
[ "$net_skip" = "yes" ] && echo "z13-battery-guard: network snapshot initialised — skipping network check this cycle"

# ── Sleep inhibitor check ────────────────────────────────────────────────────
if systemd-inhibit --list --no-legend 2>/dev/null | grep -qiE '\bsleep\b|\bhibernate\b'; then
    holder=$(systemd-inhibit --list --no-legend 2>/dev/null \
             | awk '/sleep|hibernate/ { print $1; exit }')
    echo "z13-battery-guard: battery ${capacity}% — sleep inhibited by '${holder}', skipping"
    exit 0
fi

# ── Idle: hibernate ──────────────────────────────────────────────────────────
echo "z13-battery-guard: battery ${capacity}%, load=${load1}, net_delta=${net_delta:-0}B — idle on battery, hibernating"
systemctl hibernate
