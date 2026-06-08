#!/usr/bin/env bash
# z13-hibernate common.sh
# Sourced by gate-hook.sh, hibernate-hook.sh, resume-hook.sh, post-resume-hook.sh
# Always sets white aura on source for visibility.

asusctl aura effect static -c ffffff 2>/dev/null || true

LOGFILE=/var/log/hibernate.log
PIDFILE=/var/run/hibernate-stopped-pids

# Tunables (can be overridden via /etc/z13-hibernate.conf if we add later)
BUSY_CPU_THRESHOLD=20
USE_SIGSTOP=1

mkdir -p "$(dirname "$LOGFILE")" /var/run

kmsg() {
  echo "hib: $*" >> "$LOGFILE" 2>/dev/null || true
  { echo '<6>hib: '"$*" > /dev/kmsg; } 2>/dev/null || true
}

console_msg() {
  kmsg "$*"
  { echo "HIB: $*" > /dev/tty1; } 2>/dev/null || true
  { echo "HIB: $*" > /dev/tty0; } 2>/dev/null || true
  { echo "HIB: $*" > /dev/console; } 2>/dev/null || true
}

is_on_battery() {
  if [ -f /sys/class/power_supply/BAT0/status ]; then
    grep -qi discharging /sys/class/power_supply/BAT0/status && return 0
  fi
  if command -v on_ac_power >/dev/null 2>&1; then
    on_ac_power && return 1 || return 0
  fi
  return 1
}

apply_power_profile() {
  if ! command -v asusctl >/dev/null 2>&1; then
    kmsg "common: asusctl not found, skipping profile"
    return
  fi
  if is_on_battery; then
    kmsg "common: on battery - Balanced + defaults (safer for resume)"
    asusctl profile set Balanced 2>/dev/null || true
    asusctl armoury set ppt_pl1_spl 60 2>/dev/null || true
    asusctl armoury set ppt_pl2_sppt 75 2>/dev/null || true
    asusctl armoury set ppt_pl3_fppt 86 2>/dev/null || true
  else
    kmsg "common: on AC - Performance + high PPT"
    asusctl profile set Performance 2>/dev/null || true
    asusctl armoury set ppt_pl1_spl 80 2>/dev/null || true
    asusctl armoury set ppt_pl2_sppt 92 2>/dev/null || true
    asusctl armoury set ppt_pl3_fppt 93 2>/dev/null || true
  fi
  kmsg "common: asusctl profile now: $(asusctl profile get 2>/dev/null || echo 'failed to query')"
}

# Force high performance for the write phase (called from hibernate-hook.sh)
force_high_performance() {
  if ! command -v asusctl >/dev/null 2>&1; then
    kmsg "common: asusctl not found, skipping high perf boost"
    return
  fi
  kmsg "common: forcing Performance + high PPT for snapshot write phase"
  asusctl profile set Performance 2>/dev/null || true
  asusctl armoury set ppt_pl1_spl 80 2>/dev/null || true
  asusctl armoury set ppt_pl2_sppt 92 2>/dev/null || true
  asusctl armoury set ppt_pl3_fppt 93 2>/dev/null || true
  # Explicitly set EPP to performance on all cores. asusctl profile does this via ACPI
  # but direct sysfs writes are more reliable and survive the cpufreq suspend/resume
  # inside hibernation_snapshot(). On battery, powerdevil may have set a lower EPP.
  for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [ -w "$epp" ] && echo performance > "$epp" 2>/dev/null || true
  done
  kmsg "common: EPP forced to performance on all cores (epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo unknown))"
}

get_busy_pids() {
  # SIDESTEP (per user request): return nothing. Full detection preserved below for later.
  echo ""
  return 0

  # --- preserved original detection code below (CPU thresh + GPU fd + maps + blacklist) ---
  {
    ps -eo pid,%cpu,comm --no-headers --sort=-%cpu 2>/dev/null | awk -v t="$BUSY_CPU_THRESHOLD" '$2 > t {print $1}'

    if command -v rocm-smi >/dev/null 2>&1; then
      rocm-smi --showpidgpus 2>/dev/null | grep -oE '^[0-9]{4,}' || true
    fi

    for pid in /proc/[0-9]*; do
      pid=${pid#/proc/}
      [ -d "/proc/$pid/fd" ] || continue
      for fdlink in "/proc/$pid/fd"/*; do
        target=$(readlink "$fdlink" 2>/dev/null || echo "")
        case "$target" in
          /dev/dri/*|/dev/kfd*)
            echo "$pid"
            break
            ;;
        esac
      done
    done

    for pid in /proc/[0-9]*; do
      pid=${pid#/proc/}
      if [ -r /proc/$pid/maps ]; then
        if grep -qE 'hip|rocm|amdgpu|drm|kfd|opencl|vulkan' /proc/$pid/maps 2>/dev/null; then
          echo "$pid"
        fi
      fi
    done
  } | sort -u | while read -r pid; do
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || continue
    local comm
    comm=$(ps -o comm= -p "$pid" 2>/dev/null || echo "")
    case "$comm" in
      kwin*|plasmashell|kded*|kscreen*|powerdevil*|baloo*|akonadi*|Xwayland|kglobalaccel*|kactivitymanagerd*|xdg-desktop-portal*|sddm|polkit*|upower*|systemd|dbus*|login*|ksmserver*|klauncher*|kdeinit*|plasma*|kwin_wayland*|Xorg*|compositor*|pipewire*|pulseaudio*|wireplumber*|btop|htop|top) continue ;;
    esac
    if grep -qE 'kwin_wayland|plasmashell|kwin|plasma|kde|wayland|compositor' /proc/$pid/cmdline 2>/dev/null; then continue; fi
    echo "$pid"
  done
}

stop_and_record_busy() {
  : > "$PIDFILE" || true
  local colors=(ff0000 ff5500 ffaa00 d4ff00 2bff00 00ff80 00aaff 0000ff 5500ff aa00ff)
  local ncolors=${#colors[@]}
  kmsg "common: preparing system for hibernate (up to 10 attempts...)..."

  local attempt busy_pids busy_count load no_progress=0 last_busy_count=0
  for attempt in $(seq 1 10); do
    asusctl leds set med 2>/dev/null || true
    local cidx=$(( (attempt-1) % ncolors ))
    asusctl aura effect static -c "${colors[$cidx]}" 2>/dev/null || true
    kmsg "common: attempt $attempt color index $cidx (${colors[$cidx]})"

    busy_pids=$(get_busy_pids)
    if [ -n "$busy_pids" ]; then
      kmsg "common: busy details before stop (attempt $attempt):"
      for p in $busy_pids; do
        ps -o pid,%cpu,%mem,stat,comm --no-headers -p $p 2>/dev/null | while read -r line; do kmsg "common:   $line"; done
      done
    fi
    for pid in $busy_pids; do
      grep -q "^${pid}$" "$PIDFILE" 2>/dev/null && continue
      cmd=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | head -c 300 || echo "?")
      if [ "$USE_SIGSTOP" = "1" ]; then
        if kill -STOP "$pid" 2>/dev/null; then
          echo "$pid" >> "$PIDFILE"
          kmsg "common: SIGSTOP pid $pid (attempt $attempt) cmdline: $cmd"
        fi
      else
        echo "$pid" >> "$PIDFILE"
        kmsg "common: noted busy pid $pid (no SIGSTOP) cmdline: $cmd"
      fi
    done

    sleep 3

    busy_pids=$(get_busy_pids)
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 99)
    busy_count=$(echo "$busy_pids" | wc -w)
    kmsg "common: after attempt $attempt, ~${busy_count} high-cpu procs, loadavg=$load, stopped=$(wc -l <"$PIDFILE" 2>/dev/null || echo 0)"

    if [ -z "$busy_pids" ]; then
      kmsg "common: system quiet after $attempt attempts (no busy pids from query)"
      return 0
    fi

    if [ "$busy_count" -gt 0 ] && [ "$busy_count" -eq "${last_busy_count:-0}" ]; then
      no_progress=$(( ${no_progress:-0} + 1 ))
      if [ "$no_progress" -ge 3 ]; then
        kmsg "common: no progress for $no_progress attempts; escalating kill early"
        busy_pids=$(get_busy_pids)
        for pid in $busy_pids; do
          if [ -d "/proc/$pid" ]; then
            cmd=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | head -c 300 || echo "?")
            kmsg "common: kill -9 $pid (no progress) cmdline: $cmd"
            kill -9 "$pid" 2>/dev/null || true
          fi
        done
        sleep 2
        return 0
      fi
    else
      no_progress=0
    fi
    last_busy_count=$busy_count
  done

  # Final escalation
  busy_pids=$(get_busy_pids)
  if [ -n "$busy_pids" ]; then
    kmsg "common: still busy after 10 attempts; kill -9 remaining non-critical"
    for pid in $busy_pids; do
      if [ -d "/proc/$pid" ]; then
        cmd=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | head -c 300 || echo "?")
        kmsg "common: kill -9 $pid cmdline: $cmd"
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
    sleep 2
  fi

  kmsg "common: system prepared for hibernate"
  return 0
}

restore_processes() {
  if [ -f "$PIDFILE" ]; then
    local restored=0
    while read -r pid; do
      if [ -d "/proc/$pid" ]; then
        if ps -o state= -p "$pid" 2>/dev/null | grep -q '^[Tt]'; then
          kill -CONT "$pid" 2>/dev/null || true
          restored=$((restored+1))
        fi
      fi
    done < "$PIDFILE"
    rm -f "$PIDFILE"
    kmsg "common: CONTed $restored actually-stopped pids"
  fi
}

kill_hibernate_watcher() {
  if [ -f /var/run/hibernate-watcher.pid ]; then
    local wpid
    wpid=$(cat /var/run/hibernate-watcher.pid 2>/dev/null)
    if [ -n "$wpid" ]; then
      kill "$wpid" 2>/dev/null || true
      kmsg "common: killed watcher pid $wpid"
    fi
    rm -f /var/run/hibernate-watcher.pid
  fi
}

# Light early wake for resume-hook (color + profile)
restore_lights_and_profile() {
  asusctl leds set high > /dev/null 2>&1 || true
  asusctl aura effect static -c 00ff60 > /dev/null 2>&1 || true
  apply_power_profile
  kmsg "common: lights + 00ff60 + profile restored (resume)"
}

# Full restore kept for post-resume-hook or if needed in resume.
# (For now post-resume-hook is mostly stub since no real STOPs yet.)
restore_screen() {
  kill_hibernate_watcher
  console_msg "RESTORE SCREEN..."
  chvt 1 2>/dev/null || true
  sleep 1
  loginctl unlock-sessions 2>/dev/null || true
  for f in /sys/class/graphics/*/blank; do [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || true; done
  for f in /sys/class/drm/*/dpms; do [ -w "$f" ] && echo on > "$f" 2>/dev/null || true; done
  for bl in /sys/class/backlight/*/brightness; do
    maxf="${bl%brightness}max_brightness"
    [ -r "$maxf" ] && [ -w "$bl" ] && cat "$maxf" > "$bl" 2>/dev/null || true
  done
  # User-level wake (may need sudo -u in future)
  local user
  user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '($4 == "active" || $3 == "seat0") { print $3; exit }')
  [ -z "$user" ] && user=${SUDO_USER:-gunther}
  if id "$user" >/dev/null 2>&1; then
    sudo -u "$user" env DISPLAY=:0 xset dpms force on 2>/dev/null || true
    timeout 5 sudo -u "$user" kscreen-doctor output.eDP-1.enable 2>/dev/null || true
    timeout 5 sudo -u "$user" qdbus org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.wakeScreen 2>/dev/null || true
  fi
  console_msg "screen restore complete"
}
