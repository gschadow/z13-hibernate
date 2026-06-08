# z13-hibernate

Reliable S4 hibernate for the ASUS ROG Flow Z13 (and similar AMD laptops) on
Arch-based Linux (CachyOS, stock Arch, etc.).

## The problem this solves

On a machine with 128 GB RAM, hibernate on battery was hanging indefinitely.
The root cause was a combination of:

- Default compressor (LZO or default) is 2–3× slower than LZ4 on Ryzen.
- Default 3 compression threads is badly underutilized on a 32-thread machine.
- On battery, the CPU EPP was set to a power-saving mode, throttling the write.

The fix lives entirely in the systemd-sleep hooks — no kernel patches needed.

## What this project contains

| Path | What it does |
|------|-------------|
| `src/05-hibernate-hook.sh` → `/usr/lib/systemd/system-sleep/` | Before the kernel writes the image: force LZ4, 12 threads, Performance EPP, drop_caches, LED feedback |
| `src/95-resume-hook.sh` → `/usr/lib/systemd/system-sleep/` | On resume: restore LED color, power profile, schedule post-resume work |
| `src/common.sh` → `/usr/lib/z13-hibernate/` | Shared functions (power profiles, LED, process management) |
| `src/gate-hook.sh` → `/usr/lib/z13-hibernate/` | Pre-hibernate quiesce check, runs as `z13-hibernate-gate.service` |
| `src/post-resume-hook.sh` → `/usr/lib/z13-hibernate/` | Heavier recovery scheduled 15 s after resume (screen, profile) |
| `systemd/z13-hibernate-gate.service` | Runs gate-hook before `systemd-hibernate.service` |
| `systemd/systemd-hibernate.service.d/10-gate.conf` | Drop-in: makes `systemd-hibernate.service` wait for the gate |
| `systemd/z13-hibernate-boot-cleanup.service` | Cleans stale hibernate markers on a normal (non-resume) boot |
| `etc/initcpio/hooks/hib-resume-prep` | Thin initramfs hook — see note below |
| `etc/default/grub.example` | Template showing required kernel parameters |
| `etc/mkinitcpio.conf.example` | Template showing required HOOKS order |
| `luks/setup-hibernate-luks2.sh` | One-time LUKS2 setup for the hibernate partition |
| `patches/` | Kernel debug patches (not needed for normal use) |

## Install

```bash
# As root — copies files only, does not touch /etc/default/grub or mkinitcpio.conf
make install

# OR: install AND enable services in one step
make deploy
```

After deploying for the first time, merge the config templates and rebuild:

```bash
# 1. Check what the grub template adds and merge those lines manually:
diff /etc/default/grub etc/default/grub.example

# 2. Add 'hib-resume-prep' before 'sd-encrypt' in your /etc/mkinitcpio.conf HOOKS
#    (see etc/mkinitcpio.conf.example for the full example line)

# 3. Rebuild initramfs and GRUB config
mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg
```

`make install` is safe to re-run after source changes. It never touches
`/etc/default/grub` or `/etc/mkinitcpio.conf`.

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
`rd.luks.name=...=hibernate` makes the initramfs unlock the hibernate LUKS device
early enough for `systemd-hibernate-resume` to find the image.

**The template uses placeholder names `ROOT_LUKS_UUID` and `HIB_LUKS_UUID`.**
These are intentionally not real values so they cannot be copied blindly into
a running system. Find your actual values:

```bash
blkid /dev/nvme0n1p2    # root LUKS partition
blkid /dev/nvme0n1p10   # hibernate LUKS partition (or whichever it is)
```

## Required initramfs HOOKS (`/etc/mkinitcpio.conf`)

```
HOOKS=(base udev systemd autodetect microcode modconf kms keyboard sd-vconsole
       block hib-resume-prep sd-encrypt resume filesystems fsck)
```

`hib-resume-prep` must come **before** `sd-encrypt`. See the note below on what
it actually does.

## LUKS setup

If your hibernate partition is not yet a LUKS2 container, run:

```bash
sudo luks/setup-hibernate-luks2.sh
```

This creates the LUKS container, adds the `/etc/crypttab` entry, and adds the
swap to `/etc/fstab`. It does **not** regenerate GRUB or the initramfs.

## The gate service (`z13-hibernate-gate.service`)

Runs before `systemd-hibernate.service`. Checks that the system is quiet enough
to hibernate (no high-CPU processes), sets the LED to a blue "proceeding" color,
and exits 0 to allow hibernate to continue (or 1 to abort). The drop-in
`systemd-hibernate.service.d/10-gate.conf` wires the ordering.

Enable once (done by `make deploy`):

```bash
systemctl enable z13-hibernate-gate.service
```

The service name is `z13-hibernate-gate` to distinguish it from the system's own
`systemd-hibernate.service`. They are different things: `systemd-hibernate.service`
is the kernel's hibernate sequence; `z13-hibernate-gate.service` is our pre-check
that runs before it.

## The boot cleanup service (`z13-hibernate-boot-cleanup.service`)

On every normal boot (no resume), removes stale `/run/z13-was-hibernated` and
PID files that could have been left by an interrupted hibernate or resume.
Prevents the resume hooks from running on the wrong wakeup.

## The `hib-resume-prep` initramfs hook

This hook runs in the initramfs before the LUKS passphrase prompt. It:

- `modprobe asus_nb_wmi asus_wmi amdgpu` — ensures modules are present before the
  LUKS prompt (belt-and-suspenders; autodetect already includes them).
- Checks for `/hib-resume-prep-debug` on the EFI partition and enables `set -x`
  tracing if found (useful for debugging initramfs behavior).

**What it does not do (and why):**

- *Keyboard backlight* — the WMI/ACPI stack is not available this early in the
  initramfs. The sysfs nodes are not populated. This was removed because it never
  worked.
- *amdgpu performance/recovery settings* — on a hibernate **resume** the full
  driver state is restored from the memory image, overwriting anything set here.
  The performance fix (LZ4, 12 threads, EPP=performance) lives in
  `05-hibernate-hook.sh`, which runs before the image is **written**.
- *Display unblank* — amdgpu is not initialized at this stage; the sysfs paths
  do not exist yet.

The hook is intentionally thin. The heavy lifting is in the systemd-sleep hooks.

## How it all fits together

```
systemctl hibernate
  → hibernate.target
    → z13-hibernate-gate.service     (our pre-check, gate-hook.sh)
    → systemd-hibernate.service
        → /usr/lib/systemd/system-sleep/05-hibernate-hook.sh pre hibernate
             (force LZ4, 12 threads, EPP performance, drop_caches, LED breathe)
        → kernel writes image and powers off
  ── system powered off ──
  reboot
    → initramfs
        → hib-resume-prep (modprobes, optional debug)
        → sd-encrypt (LUKS passphrase)
        → systemd-hibernate-resume (kernel loads image, restores memory)
  ── memory state restored ──
    → /usr/lib/systemd/system-sleep/95-resume-hook.sh post hibernate
         (LED green, restore power profile, schedule post-resume in 15 s)
    → post-resume-hook.sh at T+15s
         (restore screen, final LED, cleanup marker)
```

## LED color legend

| Color | Meaning |
|-------|---------|
| White (static) | Hook starting |
| Cycling colors | Gate quiesce attempts |
| Blue `0060ff` | Gate passed, proceeding |
| Breathe green/pink | Image write in progress |
| Green `00ff60` | Resume complete / abort test done |

## Monitoring

```bash
# Kernel messages during hibernate/resume
journalctl -k -f | grep -E 'PM:|hib:'

# Full hook log
tail -f /var/log/hibernate.log

# Test the gate abort path (no real hibernate)
sudo /usr/lib/z13-hibernate/gate-hook.sh test-abort
```

## Notes on the `systemd-hibernate.service.d/` drop-in directory

The directory is named `systemd-hibernate.service.d` because that is the name of
the systemd unit being extended — `systemd-hibernate.service` (part of systemd
itself). Drop-ins must live in a directory named `<unit-name>.d/`. This is
standard systemd convention, not a naming choice of this project.
