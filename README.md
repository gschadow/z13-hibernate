# z13-hibernate

Reliable S4 hibernate and s2idle sleep for the ASUS ROG Flow Z13 (and similar
AMD laptops) on Arch-based Linux (CachyOS, stock Arch, etc.).

## Problems this solves

### S4 hibernate (write-image-to-disk)

- **Slow hibernate on battery** — default LZO compressor + 3 threads on a
  32-thread Ryzen is 2–3× slower than LZ4.  Battery EPP throttles the write
  further.  Fixed in `05-hibernate-hook.sh`.

- **Infinite hang at hibernation entry** — the amdgpu `PM_HIBERNATION_PREPARE`
  notifier waits for all GPU fences to drain.  Outstanding display pipeline
  fences from KWin prevent it from completing.  Fixed by suspending the KWin
  compositor in the gate hook before the `user.slice` freeze.

- **Black screen on resume** — KWin's compositor-suspended state is frozen into
  the S4 image.  After resume KWin renders nothing.  Fixed by resuming the
  compositor immediately in `95-resume-hook.sh` with a retry in
  `post-resume-hook.sh`.

- **GPU compute processes blocking hibernate** — ollama, ComfyUI, TTS, Chrome,
  etc. hold `/dev/dri/renderD*` or `/dev/kfd` file descriptors with outstanding
  GPU command-ring fences.  The gate hook's color-wheel loop identifies these
  processes, stops or kills them (skipping the display stack via whitelists),
  waits for `gpu_busy_percent` to reach 0, and records stopped services for
  restart after resume.

- **WiFi driver hang at hibernation entry** — `mt7925e` firmware times out
  (`-ETIMEDOUT`) in the PM suspend callback after a prior s2idle cycle, leaving
  the driver in a broken state.  The hibernate hook unloads the driver before
  the image is written; the resume hook reloads it cleanly.

- **VirtualBox deadlock at hibernation entry** — `vboxdrv` PM callbacks
  deadlock the kernel when a VM is running.  The hibernate hook saves all
  running VMs then unloads the VirtualBox kernel modules.

- **Stale hibernation marker** — the boot-cleanup service previously used a
  condition path that disappeared after initrd-switch-root, causing it to fire
  on S4 resumes and delete the marker that the resume hooks depend on.  Fixed.

### s2idle (suspend-to-idle, the only sleep mode available on this platform)

- **Hard reset during s2idle on AC** — after a long s2idle the ASUS EC
  (Embedded Controller) can misreport the AC adapter as disconnected.  UPower
  reads this, thinks the battery is critically low, and fires
  `CriticalPowerAction` — causing a hard reset even when the machine is plugged
  in.  Fixed by re-triggering `power_supply` uevents immediately on s2idle
  resume so UPower and asusd re-read the real AC state.

- **Battery drain / permanent data loss during unattended sleep** — there is no
  true S3 on this platform; s2idle keeps the SoC partially active, draining the
  battery faster than expected.  `SuspendThenHibernate` is NOT the answer: its
  S4 transition skips the system-sleep hibernate prep hooks (no WiFi unload, no
  VBox handling) and hangs — it is explicitly disallowed in `sleep.conf.d`.
  Instead, every s2idle resume checks the battery and schedules a full,
  properly-prepped S4 hibernate when discharging at ≤ 10%.  After 3 h of total
  sleep a hibernate is also scheduled unconditionally (see WiFi hang below).

- **WiFi driver hang during device-suspend (s2idle)** — after many hours of
  runtime `mt7925e`'s firmware accumulates state that causes `wiphy_suspend()`
  to time out, hanging the device-suspend phase indefinitely.  Confirmed
  2026-06-12: PM: suspend of devices complete was never logged for an 8-hour
  sleep; the machine crashed when the lid was opened next morning.  Same root
  cause as the hibernate-path hang (already fixed in `05-hibernate-hook.sh`).
  Fixed in `50-s2idle-resume-fixup.sh`: unload `mt7925e` before sleep, reload
  on wake with `timeout 15` (adds ~3 s to suspend entry; WiFi reconnects via
  NetworkManager).  A long-sleep gate triggers a full S4 hibernate when the
  machine wakes after ≥ 3 h total s2idle.  (An RTC alarm is also armed but
  confirmed ineffective on this platform: the RTC has no ACPI wakeup entry so
  the alarm fires a 376 μs kernel-internal interrupt only — no userspace thaw.)

- **Lid bounce hard-wedge** — the lid is the detachable keyboard cover, so
  accidental close + instant reopen is a normal event.  The reopen lands as a
  pending wakeup during the s2idle entry, aborts it, and the immediate re-entry
  races amdgpu into a hard freeze (even with `pm_async=0`).  Fixed by
  `z13-lid-watch.service`: nobody acts on the raw lid switch (logind and
  PowerDevil are set to ignore it); suspend happens only after the lid has been
  closed for 3 s straight, so a brief flip never starts a suspend at all.

- **stop_machine deadlock after S4 restore** — right after the image restore
  re-onlines the CPUs, reschedule IPIs to some CPUs are lost (platform/BIOS
  bug, GZ302EA.311); CPUs sitting in deep ACPI `io_idle` sleep through the
  stop request and the machine wedges (pstore dumps in `diagnostics/`).  Fixed
  by `cstate-hold.sh`: PM QoS pinned to 0 (no deep C-states) across the whole
  hibernate window — the holder is frozen into the image, so the restore side
  is protected; C1/mwait CPUs wake via the monitored flag without an IPI.

## Files

| Source path | Installed to | What it does |
|---|---|---|
| `src/common.sh` | `/usr/lib/z13-hibernate/common.sh` | Shared library: GPU quiesce loop, LED, power profiles, KWin compositor helpers |
| `src/gate-hook.sh` | `/usr/lib/z13-hibernate/gate-hook.sh` | Pre-hibernate: suspends KWin compositor, drains GPU compute, LED feedback |
| `src/post-resume-hook.sh` | `/usr/lib/z13-hibernate/post-resume-hook.sh` | T+15 s after resume: retries compositor resume, restarts GPU services, final LED |
| `src/hibernate-hook.sh` | `/usr/lib/systemd/system-sleep/05-hibernate-hook.sh` | Before image write: LZ4, 12 threads, Performance EPP, WiFi unload, VBox save+unload, shutdown mode |
| `src/resume-hook.sh` | `/usr/lib/systemd/system-sleep/95-resume-hook.sh` | On resume: early compositor resume, WiFi clean reload, schedule post-resume |
| `src/s2idle-resume-fixup.sh` | `/usr/lib/systemd/system-sleep/50-s2idle-resume-fixup.sh` | Pre-suspend 2 s settle; on every s2idle wake: re-trigger power_supply uevents (ASUS EC AC-status bug) + hibernate at ≤ 10% battery discharging |
| `src/s2idle-wakeup-config.sh` | `/usr/lib/z13-hibernate/s2idle-wakeup-config.sh` | At boot: disable spurious ACPI/USB wakeup sources, set `pm_async=0` |
| `src/cstate-hold.sh` | `/usr/lib/z13-hibernate/cstate-hold.sh` | Transient QoS holder: no deep C-states during hibernate+restore (lost-IPI deadlock workaround) |
| `src/lid-watch.sh` | `/usr/lib/z13-hibernate/lid-watch.sh` | Debounced lid handling: suspend only after 3 s sustained close |
| `systemd/z13-hibernate-gate.service` | `/usr/lib/systemd/system/` | Runs gate-hook before `systemd-hibernate.service` |
| `systemd/systemd-hibernate.service.d/10-gate.conf` | `/usr/lib/systemd/system/systemd-hibernate.service.d/` | Drop-in: gate is `RequiredBy` hibernate |
| `systemd/z13-hibernate-boot-cleanup.service` | `/usr/lib/systemd/system/` | On fresh boot: cleans stale PID files (skipped on S4 resume) |
| `systemd/z13-s2idle-wakeup.service` | `/usr/lib/systemd/system/` | Runs s2idle-wakeup-config at boot |
| `systemd/z13-lid-watch.service` | `/usr/lib/systemd/system/` | Runs lid-watch.sh (the only lid actor) |
| `etc/systemd/sleep.conf.d/z13-suspend-then-hibernate.conf` | `/etc/systemd/sleep.conf.d/` | **Disallows** SuspendThenHibernate (its S4 transition skips the hibernate prep hooks) |
| `etc/systemd/logind.conf.d/z13-lid.conf` | `/etc/systemd/logind.conf.d/` | logind ignores the lid (z13-lid-watch owns it) |
| `etc/initcpio/hooks/hib-resume-prep` | `/etc/initcpio/hooks/` | Thin initramfs hook: modprobes amdgpu/asus_wmi before LUKS prompt |
| `etc/default/grub.example` | (manual merge) | Required kernel parameters |
| `etc/mkinitcpio.conf.example` | (manual merge) | Required HOOKS order |
| `luks/setup-hibernate-luks2.sh` | (run once) | One-time LUKS2 setup for the hibernate partition |

## Install

```bash
# As root — copies files only, does not touch /etc/default/grub or mkinitcpio.conf
make install

# OR: install AND enable systemd services in one step
make deploy
```

After deploying for the first time, merge the config templates and rebuild:

```bash
# 1. Check what the grub template adds and merge those lines manually:
diff /etc/default/grub etc/default/grub.example

# 2. Add 'hib-resume-prep' before 'sd-encrypt' in your /etc/mkinitcpio.conf HOOKS
#    (see etc/mkinitcpio.conf.example for the full example line)

# 3. Rebuild initramfs and GRUB config
make bootimage
```

`make deploy` also sets PowerDevil's lid action to "Do nothing" for `PDUSER`
(default `gunther`) — required because `z13-lid-watch.service` is the only
thing allowed to act on the lid switch.  Verify in System Settings → Power
Management if in doubt.  The logind drop-in takes effect on the next reboot.

`make install` is safe to re-run after source changes. It never touches
`/etc/default/grub` or `/etc/mkinitcpio.conf`.

**Do not restart `systemd-logind` while a desktop session is active.** The
logind.conf drop-in takes effect on the next full reboot. Restarting logind
mid-session kills all user sessions immediately.

## Uninstall

```bash
make uninstall
# Then remove 'hib-resume-prep' from /etc/mkinitcpio.conf HOOKS and run mkinitcpio -P
```

## Required kernel parameters (`/etc/default/grub`)

See `etc/default/grub.example`. The critical additions to `GRUB_CMDLINE_LINUX`:

```
rd.luks.name=<ROOT_LUKS_UUID>=root
rd.luks.name=<HIB_LUKS_UUID>=hibernate
root=/dev/mapper/root
resume=/dev/mapper/hibernate
zswap.enabled=0
```

`resume=` tells the kernel where the hibernate image lives.
`rd.luks.name=...=hibernate` makes the initramfs unlock the hibernate LUKS
device early enough for `systemd-hibernate-resume` to find the image.

**The template uses placeholder names `ROOT_LUKS_UUID` and `HIB_LUKS_UUID`.**
Find your actual values:

```bash
blkid /dev/nvme0n1p2    # root LUKS partition
blkid /dev/nvme0n1p10   # hibernate LUKS partition (or whichever it is)
```

## Required initramfs HOOKS (`/etc/mkinitcpio.conf`)

```
HOOKS=(base udev systemd autodetect microcode modconf kms keyboard sd-vconsole
       block hib-resume-prep sd-encrypt resume filesystems fsck)
```

`hib-resume-prep` must come **before** `sd-encrypt`.

## LUKS setup

If your hibernate partition is not yet a LUKS2 container, run:

```bash
sudo luks/setup-hibernate-luks2.sh
```

## How it all fits together

```
systemctl hibernate   (manual, or scheduled by the ≤10%-battery check on s2idle resume)
  → hibernate.target
    → z13-hibernate-gate.service     (gate-hook.sh)
        • Suspend KWin compositor    (drains GPU display fences)
        • GPU compute color-wheel loop:
            - identify processes holding /dev/dri/renderD* or /dev/kfd
            - skip display-stack processes (kwin, plasmashell, sddm, …)
            - stop/kill GPU compute processes (ollama, ComfyUI, etc.)
            - wait for gpu_busy_percent == 0
            - record stopped services for post-resume restart
    → systemd-hibernate.service
        → 05-hibernate-hook.sh  pre hibernate
            • Unload mt7925e WiFi driver
            • Save + unload VirtualBox modules (if running)
            • Force LZ4 + 12 threads + Performance EPP
            • drop_caches, sync, LED breathe
            • Set disk mode = shutdown (more reliable than platform on AMD)
        → kernel writes image and powers off
  ── system powered off ──
  reboot
    → initramfs
        → hib-resume-prep (modprobes, optional debug)
        → sd-encrypt (LUKS passphrase)
        → systemd-hibernate-resume (kernel loads image, restores memory)
  ── memory state restored ──
    → 95-resume-hook.sh  post hibernate
        • Resume KWin compositor (early attempt)
        • Reload mt7925e WiFi (clean firmware init)
        • LED green
        • Schedule post-resume-hook.sh at T+15 s
    → post-resume-hook.sh at T+15 s
        • Retry KWin compositor resume (if early attempt failed)
        • Restart GPU compute services that were stopped in gate
        • Restore power profile + LED final color
        • Clean hibernate marker
```

For s2idle (normal sleep/wake, lid close):

```
lid close  →  z13-lid-watch: 3 s debounce
                • reopened inside the window → no-op (no suspend starts)
                • still closed after 3 s     → systemctl suspend (s2idle)
              50-s2idle-resume-fixup.sh  pre suspend:
                • 2 s settle (lid EC event drain)
                • record sleep-session start (first entry only)
                • set RTC alarm for 3 h (harmless on this hw; see WiFi note)
                • bring wlp194s0 down + 3 s drain (reduces page_pool zombies)
                • modprobe -r mt7925e  (bypasses wiphy_suspend() hang)
              (machine sleeps in s2idle)
any wake   →  50-s2idle-resume-fixup.sh  post suspend:
                • cancel RTC alarm
                • framebuffer unblank (display recovery: keyboard IS the lid,
                  no key event fires on lid-open, DPMS stays off otherwise)
                • timeout 15 modprobe mt7925e  (timeout prevents ~80 s hang
                  from page_pool zombie left by pre-hook unload; 2026-06-13)
                • qdbus SimulateUserActivity → KDE re-enables DPMS outputs
                • Re-trigger power_supply uevents
                  (fixes ASUS EC AC-status misreport → prevents spurious UPower action)
                • Battery discharging at ≤ 10% → schedule full S4 hibernate
                  (with all prep hooks — this replaces SuspendThenHibernate)
                • Slept ≥ 3 h total → set z13-hibernate-pending flag,
                  schedule hibernate in 5 s (lid-watch stands down on flag)
              z13-lid-watch (if lid still closed): re-suspends after 3 s
                unless z13-hibernate-pending is set → skips to let hibernate win
```

## LED color legend

| Color | Meaning |
|-------|---------|
| Blue `0060ff` (static) | Gate entered, beginning quiesce |
| Cycling: red/orange/yellow/green/cyan/blue/violet/pink/white/magenta | GPU compute color-wheel (one color per attempt) |
| Blue `0060ff` (final) | Gate passed, proceeding to hibernate |
| Breathe green/pink | Image write in progress |
| Green `00ff60` | Resume complete / abort test done |

## Monitoring

```bash
# Kernel messages during hibernate/resume
journalctl -k | grep -E 'PM:|z13|gate:|resume-hook'

# Full hook log
tail -f /var/log/hibernate.log

# Test the gate abort path (no real hibernate)
sudo /usr/lib/z13-hibernate/gate-hook.sh test-abort
```

## The gate service (`z13-hibernate-gate.service`)

Runs before `systemd-hibernate.service` via `RequiredBy=hibernate.target` in the
drop-in.  Unlike `WantedBy`, `RequiredBy` means a gate failure aborts the
hibernate rather than being silently ignored.

## The boot cleanup service (`z13-hibernate-boot-cleanup.service`)

On every fresh boot (no resume), removes stale PID files that could have been
left by an interrupted hibernate or resume.  Gated on
`ConditionPathExists=!/run/z13-was-hibernated` — on S4 resume the hibernated
RAM is restored with the marker present, so the service is skipped.  On a fresh
boot `/run` is empty, the marker is absent, and cleanup runs.

## The `hib-resume-prep` initramfs hook

Thin.  Modprobes `asus_nb_wmi asus_wmi amdgpu` before the LUKS prompt and
optionally enables `set -x` tracing if `/hib-resume-prep-debug` is present on
the EFI partition.  The heavy lifting (LZ4 settings, EPP) is in
`05-hibernate-hook.sh`, which runs before the **write** — not before the read.

## Notes on the `systemd-hibernate.service.d/` drop-in directory

Drop-ins must live in `<unit-name>.d/`.  The unit being extended is
`systemd-hibernate.service` (part of systemd itself), hence that exact name.
