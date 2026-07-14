#!/usr/bin/env bash
# z13-hibernate common.sh
# Sourced by gate-hook.sh, hibernate-hook.sh, resume-hook.sh, post-resume-hook.sh
# Sets white on source — deliberate: visible on every hook entry, reveals duplicate invocations.

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
#
# On battery this must NOT raise PPT: the 80/92/93W boost during the image
# write pulls more than the battery rail tolerates and the EC hard-resets
# the machine (observed 2026-06-10: first battery hibernate, 75% charge,
# reset ~30-90s into the write phase, EFI HibernateLocation set but no
# image signature on swap, pstore empty = power cut, not kernel panic).
# The image is only a few GB; Balanced writes it a few seconds slower.
force_high_performance() {
  if ! command -v asusctl >/dev/null 2>&1; then
    kmsg "common: asusctl not found, skipping high perf boost"
    return
  fi
  if is_on_battery; then
    kmsg "common: on battery — Balanced + battery PPT for write phase (no boost, EC brownout reset risk)"
    asusctl profile set Balanced 2>/dev/null || true
    asusctl armoury set ppt_pl1_spl 60 2>/dev/null || true
    asusctl armoury set ppt_pl2_sppt 75 2>/dev/null || true
    asusctl armoury set ppt_pl3_fppt 86 2>/dev/null || true
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
      [ -w "$epp" ] && echo balance_performance > "$epp" 2>/dev/null || true
    done
    return
  fi
  kmsg "common: on AC — forcing Performance + high PPT for snapshot write phase"
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
  : > "$PIDFILE"
  : > "$_GPU_STOPPED_FILE"

  local colors=(ff0000 ff5500 ffaa00 d4ff00 2bff00 00ff80 00aaff 0000ff 5500ff aa00ff)
  local ncolors=${#colors[@]}
  # CPU-busy processes do NOT block hibernation — the kernel freezes them fine.
  # The only real blocker is GPU compute holders (DRM render / ROCm KFD fds).
  kmsg "common: quiescing GPU compute holders (up to ${ncolors} attempts)..."

  # Grace period: number of initial attempts where we wait WITHOUT killing anything.
  # After KWin compositor suspend, the GPU needs a few seconds to drain display
  # pipeline fences.  Browsers and terminals that are merely idle (holding a DRM
  # render fd but not actively computing) will reach 0% GPU within this window and
  # will not be touched.  Only processes that keep the GPU genuinely busy past the
  # grace period are killed.  3 attempts × 3 s = 9 s of patience before any SIGTERM.
  local GRACE_ATTEMPTS=3

  local attempt handled_pids="" last_count=0 no_progress=0
  for attempt in $(seq 1 ${ncolors}); do
    asusctl leds set med 2>/dev/null || true
    local cidx=$(( attempt - 1 ))
    asusctl aura effect static -c "${colors[$cidx]}" 2>/dev/null || true

    local gpu_pids gpu_busy gpu_count
    gpu_pids=$(_gpu_get_compute_pids)
    gpu_busy=$(cat /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1 || echo 0)
    # Use awk (always exits 0) to count PIDs — grep -c exits 1 on no match which with
    # "|| echo 0" produces "0\n0" (internal newline), breaking the -eq 0 integer test.
    gpu_count=$(echo "$gpu_pids" | awk '/[0-9]/{n++} END{print n+0}')
    kmsg "common: attempt $attempt/${ncolors} color ${colors[$cidx]}: ${gpu_count} GPU holders, GPU ${gpu_busy:-0}% busy"

    # Only gpu_busy matters for the PM notifier — lingering fd-holders from dying
    # processes don't block GPU fence drain.  Exit as soon as the GPU is idle.
    if [ "${gpu_busy:-0}" -eq 0 ]; then
      [ "$gpu_count" -gt 0 ] \
        && kmsg "common: GPU idle after $attempt attempts (${gpu_count} lingering fd-holders, 0% busy — proceeding)" \
        || kmsg "common: GPU clean after $attempt attempts"
      return 0
    fi

    # Grace period: just wait — idle browsers/terminals will drain the GPU naturally.
    if [ "$attempt" -le "$GRACE_ATTEMPTS" ]; then
      kmsg "common: attempt $attempt: GPU ${gpu_busy:-0}% busy — grace period, waiting 3s (no action)"
      sleep 3
      continue
    fi

    # Past grace period: GPU is stubbornly busy.  Start stopping compute holders.
    # Act on any holder we have not yet signalled this session
    for pid in $gpu_pids; do
      echo " $handled_pids " | grep -q " $pid " && continue
      [ -d "/proc/$pid" ] || continue

      local comm cmdline classification
      comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 120 || echo "")
      classification=$(_gpu_classify_pid "$pid")
      kmsg "common: GPU holder pid=$pid comm=$comm cmd=$(echo "$cmdline" | cut -c1-80)"

      if [ -n "$classification" ]; then
        local svctype svc uid svcuser
        svctype=$(echo "$classification" | cut -d: -f1)
        case "$svctype" in
          system)
            svc=$(echo "$classification" | cut -d: -f2)
            if echo "$svc" | grep -qE "$_GPU_SERVICE_WHITELIST"; then
              kmsg "common: SKIP protected system service $svc (pid=$pid comm=$comm — display stack)"
            else
              kmsg "common: systemctl stop $svc (pid=$pid)"
              systemctl stop "$svc" 2>/dev/null \
                && echo "system:$svc" >> "$_GPU_STOPPED_FILE" \
                || { kmsg "common: $svc stop failed — SIGTERM fallback"; kill -TERM "$pid" 2>/dev/null || true; }
            fi
            ;;
          user)
            uid=$(echo "$classification" | cut -d: -f2)
            svc=$(echo "$classification" | cut -d: -f3)
            if echo "$svc" | grep -qE "$_GPU_SERVICE_WHITELIST"; then
              kmsg "common: SKIP protected user service $svc (pid=$pid comm=$comm — display stack)"
            else
              svcuser=$(id -nu "$uid" 2>/dev/null || echo "")
              if [ -n "$svcuser" ]; then
                kmsg "common: user systemctl stop $svc uid=$uid (pid=$pid)"
                sudo -u "$svcuser" \
                  env XDG_RUNTIME_DIR="/run/user/$uid" \
                      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
                  systemctl --user stop "$svc" 2>/dev/null \
                  && echo "user:$uid:$svc" >> "$_GPU_STOPPED_FILE" \
                  || { kmsg "common: user $svc stop failed — SIGTERM fallback"; kill -TERM "$pid" 2>/dev/null || true; }
              fi
            fi
            ;;
        esac
      else
        kmsg "common: bare process pid=$pid comm=$comm — SIGTERM (no auto-restart)"
        kill -TERM "$pid" 2>/dev/null || true
      fi
      handled_pids="$handled_pids $pid"
    done

    sleep 3

    # No-progress escalation: if holder count hasn't shrunk for 3 consecutive attempts, SIGKILL
    if [ "$gpu_count" -gt 0 ] && [ "$gpu_count" -ge "$last_count" ] && [ "$attempt" -gt 1 ]; then
      no_progress=$(( no_progress + 1 ))
      if [ "$no_progress" -ge 3 ]; then
        kmsg "common: no GPU holder reduction for $no_progress attempts — SIGKILL"
        for pid in $gpu_pids; do
          [ -d "/proc/$pid" ] || continue
          local comm; comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
          kmsg "common: SIGKILL pid=$pid comm=$comm"
          kill -KILL "$pid" 2>/dev/null || true
        done
        sleep 2
        no_progress=0
        handled_pids=""
      fi
    else
      no_progress=0
    fi
    last_count=$gpu_count
  done

  # Final escalation after exhausting all colour slots
  local final_pids final_busy final_count
  final_pids=$(_gpu_get_compute_pids)
  final_busy=$(cat /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1 || echo 0)
  final_count=$(echo "$final_pids" | awk '/[0-9]/{n++} END{print n+0}')
  if [ "$final_count" -gt 0 ] || [ "${final_busy:-0}" -gt 0 ]; then
    kmsg "common: GPU still ${final_busy:-0}% busy after ${ncolors} attempts — final SIGKILL, proceeding"
    for pid in $final_pids; do
      [ -d "/proc/$pid" ] || continue
      local comm; comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
      kmsg "common: final SIGKILL pid=$pid comm=$comm"
      kill -KILL "$pid" 2>/dev/null || true
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

# ─── GPU COMPUTE PROCESS MANAGEMENT ──────────────────────────────────────────
# Finds processes holding DRM render nodes (/dev/dri/renderD*) or the ROCm
# compute node (/dev/kfd) and stops them before hibernate so amdgpu's
# PM_HIBERNATION_PREPARE notifier can drain GPU fences cleanly.
# Services are recorded in _GPU_STOPPED_FILE and restarted after resume.

_GPU_STOPPED_FILE=/run/z13-gpu-stopped

# Display-stack processes that own DRM fds legitimately and handle S4 themselves.
# Comm names are truncated to 15 chars by the kernel; entries >15 chars must use
# their truncated form (e.g. kscreenlocker_greet → kscreenlocker_g).
_GPU_WHITELIST='^(kwin_wayland|kwin|plasmashell|kded5|kded6|kded|sddm|sddm-greeter|sddm-helper|Xwayland|pipewire|wireplumber|xdg-desktop-por|polkit-kde-auth|polkitd|kscreenlocker_g|kglobalaccel5|kglobalaccel6|kglobalaccel|kactivitymanager|ksmserver|gnome-shell|mutter|maliit-keyboard|maliit-server)$'

# Service units that must never be stopped even if a GPU-holding child process
# lands in their cgroup.  The display compositor and SDDM own entire Wayland
# session trees — stopping them tears down the whole graphical session.
_GPU_SERVICE_WHITELIST='^(plasma-kwin_wayland|plasma-kwin_x11|plasma-plasmashell|plasma-xdg-desktop-portal-kde|plasma-polkit-kde-authentication-agent-1|sddm|display-manager|graphical-session)\.service$'

_gpu_get_compute_pids() {
  # Only /dev/kfd holders are true ROCm compute workloads that cause the
  # amdgpu PM_HIBERNATION_PREPARE hang (dirty GPU VM state from cancelled
  # inference).  /dev/dri/renderD* holders are display clients (Chrome,
  # Firefox, VMs) that drain naturally when KWin compositor is suspended —
  # they do NOT cause the hang and must not be killed.
  for fd_dir in /proc/[0-9]*/fd; do
    local pid="${fd_dir%/fd}"; pid="${pid#/proc/}"
    [ -d "/proc/$pid" ] || continue
    local comm
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
    echo "$comm" | grep -qE "$_GPU_WHITELIST" && continue
    for fd in "$fd_dir"/[0-9]*; do
      [ -e "$fd" ] || continue
      local target
      target=$(readlink "$fd" 2>/dev/null) || continue
      case "$target" in
        /dev/kfd) echo "$pid"; break;;
      esac
    done
  done | sort -u
}

# Returns "system:<svc>", "user:<uid>:<svc>", or "" if not a managed service.
_gpu_classify_pid() {
  local pid="$1" cgroup svc
  cgroup=$(cat "/proc/$pid/cgroup" 2>/dev/null || echo "")
  # cgroup v2: "0::/system.slice/foo.service" or "0::/user.slice/.../foo.service"
  # For scope units (app-chrome-*.scope), grep -oE '[^/]+\.service' picks the
  # PARENT service in the path (e.g. user@1000.service), not the scope itself.
  # Stopping user@1000.service would kill the entire user session, so we treat
  # user@*.service as unclassified, letting the caller SIGTERM the bare pid instead.
  svc=$(echo "$cgroup" | grep -oE '[^/]+\.service' | tail -1 || true)
  [ -z "$svc" ] && return 0
  echo "$svc" | grep -qE '^user@[0-9]+\.service$' && return 0
  if echo "$cgroup" | grep -q 'system\.slice'; then
    echo "system:$svc"
  else
    local uid
    uid=$(stat -c '%u' "/proc/$pid" 2>/dev/null || echo "")
    [ -n "$uid" ] && echo "user:$uid:$svc"
  fi
}


restart_gpu_processes() {
  [ -f "$_GPU_STOPPED_FILE" ] || { kmsg "resume: no GPU stopped services to restart"; return 0; }

  local count=0
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local svctype; svctype=$(echo "$entry" | cut -d: -f1)
    case "$svctype" in
      system)
        local svc; svc=$(echo "$entry" | cut -d: -f2)
        kmsg "resume: starting system service $svc"
        systemctl start "$svc" 2>/dev/null \
          && kmsg "resume: $svc started OK" \
          || kmsg "resume: $svc start failed (start manually if needed)"
        count=$((count+1))
        ;;
      user)
        local uid svc svcuser
        uid=$(echo "$entry" | cut -d: -f2)
        svc=$(echo "$entry" | cut -d: -f3)
        svcuser=$(id -nu "$uid" 2>/dev/null || echo "")
        [ -n "$svcuser" ] || continue
        kmsg "resume: starting user service $svc (uid=$uid user=$svcuser)"
        sudo -u "$svcuser" \
          env XDG_RUNTIME_DIR="/run/user/$uid" \
              DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
          systemctl --user start "$svc" 2>/dev/null \
          && kmsg "resume: $svc started OK" \
          || kmsg "resume: $svc start failed (start manually if needed)"
        count=$((count+1))
        ;;
    esac
  done < "$_GPU_STOPPED_FILE"
  rm -f "$_GPU_STOPPED_FILE"
  kmsg "resume: GPU service restart done (${count} restarted)"
}

# ─── END GPU COMPUTE PROCESS MANAGEMENT ──────────────────────────────────────

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
  loginctl unlock-sessions 2>/dev/null || true
  for f in /sys/class/graphics/*/blank; do [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || true; done
  # Do NOT write to /sys/class/drm/*/dpms on Wayland: KWin owns the DRM device
  # exclusively and the sysfs write causes atomic-commit EBUSY → black screen.
  for bl in /sys/class/backlight/*/brightness; do
    maxf="${bl%brightness}max_brightness"
    [ -r "$maxf" ] && [ -w "$bl" ] && cat "$maxf" > "$bl" 2>/dev/null || true
  done
  # User-level wake: must pass Wayland/DBUS env or these calls fail silently.
  local user uid xdg_rt dbus_addr wl_display uenv
  user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '($4 == "active" || $3 == "seat0") { print $3; exit }')
  [ -z "$user" ] && user=${SUDO_USER:-gunther}
  uid=$(id -u "$user" 2>/dev/null || echo "")
  if [ -n "$uid" ] && id "$user" >/dev/null 2>&1; then
    xdg_rt="/run/user/$uid"
    dbus_addr="unix:path=$xdg_rt/bus"
    wl_display=""
    for _wl in wayland-0 wayland-1 wayland-2; do
      [ -S "$xdg_rt/$_wl" ] && wl_display="$_wl" && break
    done
    uenv="XDG_RUNTIME_DIR=$xdg_rt DBUS_SESSION_BUS_ADDRESS=$dbus_addr"
    [ -n "$wl_display" ] && uenv="$uenv WAYLAND_DISPLAY=$wl_display"
    kmsg "common: restore_screen user=$user uid=$uid wl=${wl_display:-none}"
    sudo -u "$user" env $uenv DISPLAY=:0 xset dpms force on 2>/dev/null || true
    # Resume KWin compositor that was suspended in the gate hook for GPU fence drain.
    # The suspended state is preserved in the S4 hibernation image; without this call
    # KWin wakes up with compositing off → Wayland renders nothing → black screen.
    # KWin compositor resume skipped: gate-hook suspend fails in KWin 6.x so
    # compositor is never actually suspended — nothing to resume here.
    # Do NOT call kscreen-doctor output.eDP-1.enable: it fights with KWin's atomic
    # modesetting and causes cascading "atomic commit failed: Device or resource busy"
    # for the entire session, which blocks amdgpu PM_HIBERNATION_PREPARE on next hibernate.
    timeout 5 sudo -u "$user" env $uenv qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.wakeScreen 2>/dev/null || true
    # kscreenlocker sometimes crashes on S4 resume leaving KWin in locked state with black screen.
    # loginctl unlock-sessions (above) marks the session unlocked; this simulates activity so KWin repaints.
    timeout 3 sudo -u "$user" env $uenv qdbus6 org.kde.screensaver /ScreenSaver SimulateUserActivity 2>/dev/null || true
  fi
  console_msg "screen restore complete"
}
