#!/usr/bin/env bash
# setup-hibernate-luks2.sh
# Most simple and straight-forward LUKS2 wrapping of the hibernate partition (nvme0n1p10).
# - Uses LUKS2 on p10 with aes-xts-plain64 (fastest bulk cipher on this Ryzen AI APU thanks to hardware AES/VAES/AVX512).
#   (destructive to current swap/hib image - this is expected).
# - crypttab entry "hibernate" with none (passphrase).
# - rd.luks.name=...=hibernate so sd-encrypt in initrd opens it early (before resume hook).
# - resume=/dev/mapper/hibernate in cmdline/GRUB.
# - fstab updated for the mapper as high-pri swap.
# - Adds hib-resume-prep (early initrd prep for resume + LUKS visibility) to mkinitcpio HOOKS (before sd-encrypt).
# - Does NOT use keyfile or the early-hibernate custom hook (that was more complex / used different UUID).
# - After this, re-apply the z13-hibernate hooks via the project's install.sh .
#
# Run from the z13-hibernate source tree: sudo ./luks/setup-hibernate-luks2.sh
#
# Then test hibernate on the LUKS hib swap.
# This is the baseline before any fancy keyfile or refined GPU suspend detection.
#
# Part of the z13-hibernate project (recommended for anyone wanting reliable encrypted hibernate).

set -euo pipefail

HIB_PART="/dev/nvme0n1p10"
MAPPER_NAME="hibernate"
OLD_RESUME_UUID="07dc4fc1-67dd-425f-b071-d77957c58823"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "dry" ]; then
  DRY_RUN=1
  echo "=== DRY RUN MODE (no luksFormat, no writes to /etc, no mkinit/grub, no swap changes) ==="
fi

echo "=== LUKS2 simple wrap for hibernate swap on ${HIB_PART} @ $(date) ==="
echo
echo "WARNING: DESTRUCTIVE."
echo "This will:"
echo "  - swapoff current ${HIB_PART} (losing any active swap there)"
echo "  - cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 ... ${HIB_PART}   <--- THIS WIPES THE PARTITION"
echo "  - The old plaintext swap signature and any prior hibernate image on it will be gone forever."
echo "  - New LUKS2 container with aes-xts-plain64 (optimal on your Ryzen AI MAX+ 395 which has strong VAES/AVX-512 AES accel in the CPU cores)."
echo "    On boot: if you use the *same* passphrase as root, systemd usually re-uses it silently (only one prompt)."
echo "    If different, you get an explicit second prompt (the hib-resume-prep hook helps make the prompt visible in the dark and prepares amdgpu for resume)."
echo "  - Then mkswap inside the mapper, update crypttab/fstab/GRUB/mkinitcpio."
echo
echo "Current state of ${HIB_PART}:"
lsblk -f -o NAME,UUID,FSTYPE,SIZE,TYPE,MOUNTPOINT "${HIB_PART}" || true
blkid "${HIB_PART}" || true
echo
echo "If you have active hibernated images or data you care about on the old plaintext p10 swap, STOP NOW."
echo
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY: skipping destructive confirm + swapoff + luksFormat"
  LUKS_UUID="SIMULATED-$(date +%s)-LUKS-UUID-EXAMPLE"
  echo "DRY: would have used LUKS container UUID: ${LUKS_UUID}"
else
  read -r -p "Type exactly YESLUKS2 to proceed with DESTRUCTIVE luksFormat on ${HIB_PART}: " confirm
  if [ "$confirm" != "YESLUKS2" ]; then
    echo "Aborted (did not type YESLUKS2)."
    exit 1
  fi

  echo
  echo "Proceeding with LUKS2 setup (simple config)..."

  # 1. Make sure we don't have it mounted/active as swap.
  echo "swapoff any use of ${HIB_PART} ..."
  swapoff "${HIB_PART}" 2>/dev/null || true
  swapoff -a 2>/dev/null || true  # safe: p7 volatile swap will be re-established on next boot or we can swapon its mapper if wanted; hib one we will recreate
  # Re-activate the volatile one if it was the only other (p7 mapper "swap")
  swapon /dev/mapper/swap 2>/dev/null || true

  # 2. luksFormat (optimized for this hardware + hibernate workload).
  # Your CPU (Ryzen AI MAX+ 395 / 8060S) has excellent AES hardware acceleration (VAES, AVX-512, etc.).
  # aes-xts-plain64 is dramatically the fastest bulk cipher here (kernel uses aesni_intel/vaes-avx512).
  # Blowfish etc. would be much slower. Larger sector size helps linear large writes (the memory image).
  # This is still "simple" LUKS2 but with explicit fast params instead of pure defaults.
  echo "Running cryptsetup luksFormat --type luks2 with fast AES-XTS params for Ryzen AI APU..."
  echo "  (you will be prompted for the new passphrase twice)"
  cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha256 \
    --sector-size 4096 \
    "${HIB_PART}"

  LUKS_UUID=$(cryptsetup luksUUID "${HIB_PART}")
  echo "LUKS container UUID: ${LUKS_UUID}"
  if [ -z "${LUKS_UUID}" ]; then
    echo "ERROR: could not read LUKS UUID after format"
    exit 1
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY: would rewrite /etc/crypttab cleanly (remove old keyfile comments, add simple ${MAPPER_NAME} entry), move aside stale luks-hibernate.key and early-hibernate hook"
  echo "DRY: would update /etc/fstab (comment old p10, add /dev/mapper/${MAPPER_NAME} none swap ... pri=100)"
  echo "DRY: would ensure hib-resume-prep before sd-encrypt in HOOKS"
  echo "DRY: would update /etc/default/grub GRUB_CMDLINE_LINUX (add resume + rd.luks for hib) + run grub-mkconfig"
  echo "DRY: would cryptsetup luksFormat with aes-xts-plain64 + sector 4k, open, mkswap /dev/mapper/${MAPPER_NAME}, swapon -p100"
  echo "DRY: would mkinitcpio -P"
  echo "DRY: would run the z13-hibernate project's install.sh (as root)"
else
  # 3. Update /etc/crypttab cleanly (remove old keyfile/early-hibernate comments from prior attempts,
  #    keep the volatile swap, add the simple hibernate entry).
  echo "Updating /etc/crypttab (cleaning old comments + adding simple entry) ..."
  cp -a /etc/crypttab "/etc/crypttab.bak.$(date +%s)" 2>/dev/null || true
  cat > /etc/crypttab << EOCRYPT
# /etc/crypttab
# See crypttab(5) for details.

# NOTE: Do not list your root (/) partition here, it must be set up
#       beforehand by the initramfs (/etc/mkinitcpio.conf).

# Volatile encrypted swap on p7 (plain dm-crypt + random key every boot).
# This one is re-keyed every boot; cannot be used for hibernation.
swap            /dev/nvme0n1p7                          /dev/urandom    plain,swap,cipher=aes-xts-plain64,size=256,discard

# Persistent LUKS2 for hibernation (simple config).
# Unlocked early in initrd via rd.luks.name=${LUKS_UUID}=${MAPPER_NAME} (see GRUB/cmdline).
# "none luks" => interactive passphrase. If you use the *same* passphrase as root LUKS,
# systemd often re-uses it and shows only one prompt (convenient). If different passphrases,
# you will get an explicit second prompt (hib-resume-prep hook helps visibility and does early amdgpu prep).
${MAPPER_NAME} UUID=${LUKS_UUID} none luks
EOCRYPT
  echo "  Clean crypttab written with ${MAPPER_NAME} entry."

  # Remove stale keyfile from earlier keyfile-based hibernate attempts (we are using simple passphrase + rd.luks.name).
  if [ -f /etc/luks-hibernate.key ]; then
    mv /etc/luks-hibernate.key "/etc/luks-hibernate.key.old.$(date +%s)" || true
    echo "  Stale /etc/luks-hibernate.key moved aside (not used in simple config)."
  fi

  # Move aside the early-hibernate hook (not used in current HOOKS; was for the complex keyfile path).
  if [ -f /etc/initcpio/hooks/early-hibernate ]; then
    mv /etc/initcpio/hooks/early-hibernate "/etc/initcpio/hooks/early-hibernate.old.$(date +%s)" 2>/dev/null || true
    mv /etc/initcpio/install/early-hibernate "/etc/initcpio/install/early-hibernate.old.$(date +%s)" 2>/dev/null || true
    echo "  early-hibernate hook files moved aside."
  fi

  # 4. Update /etc/fstab (fix the mangled p10 line and add proper mapper swap entry)
  echo "Updating /etc/fstab ..."
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)" 2>/dev/null || true
  # Remove or comment old p10 direct and any old mapper/hibernate baseline lines
  sed -i '\|/dev/nvme0n1p10| s|^|# OLD-UNENCRYPTED-HIB (now LUKS): |' /etc/fstab || true
  sed -i '\|mapper/hibernate| s|^|# OLD-BASELINE: |' /etc/fstab || true
  # Append (or ensure) the new high-pri swap on the LUKS mapper. Use "sw" not "defaults" for swap.
  if ! grep -q "^/dev/mapper/${MAPPER_NAME} " /etc/fstab; then
    cat >> /etc/fstab << EOFST
/dev/mapper/${MAPPER_NAME} none swap defaults,pri=100 0 0
EOFST
  fi
  echo "  fstab now has /dev/mapper/${MAPPER_NAME} as high-pri swap (old p10 direct line commented)."

  # 5. Ensure hib-resume-prep hook is in mkinitcpio HOOKS before sd-encrypt
  # (for LUKS passphrase visibility + early amdgpu/display prep for resume).
  echo "Ensuring hib-resume-prep in /etc/mkinitcpio.conf HOOKS (before sd-encrypt) ..."
  cp -a /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak.$(date +%s)" 2>/dev/null || true
  if ! grep -q 'hib-resume-prep' /etc/mkinitcpio.conf; then
    sed -i 's|block sd-encrypt|block hib-resume-prep sd-encrypt|' /etc/mkinitcpio.conf || true
    sed -i 's|block sd-encrypt early-hibernate|block hib-resume-prep sd-encrypt|' /etc/mkinitcpio.conf || true
  fi
  grep '^HOOKS=' /etc/mkinitcpio.conf | cat

  # 6. Safer GRUB update: only modify GRUB_CMDLINE_LINUX to add the required resume and rd.luks.name parameters.
  # We do NOT overwrite custom menuentry scripts. Let the distro's normal GRUB generation handle menus.
  echo "Updating /etc/default/grub GRUB_CMDLINE_LINUX for hibernate LUKS (safer, cmdline-only) ..."
  cp -a /etc/default/grub "/etc/default/grub.bak.$(date +%s)" 2>/dev/null || true

  # Remove any old resume=... 
  sed -i 's| resume=[^ ]*||g' /etc/default/grub || true

  # Add resume= to the cmdline
  sed -i "s|\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 resume=/dev/mapper/${MAPPER_NAME}\"|" /etc/default/grub || true

  # Add the hib rd.luks.name if not already present (next to the root one).
  # The example template uses ROOT_LUKS_UUID=root as placeholder; this sed will
  # match any ...=root and append the hibernate one.
  if ! grep -q "rd.luks.name=.*=${MAPPER_NAME}" /etc/default/grub; then
    sed -i "s|\(rd.luks.name=[^ ]*root\)|\1 rd.luks.name=${LUKS_UUID}=${MAPPER_NAME}|" /etc/default/grub || true
  fi

  echo "Current GRUB_CMDLINE_LINUX:"
  grep '^GRUB_CMDLINE_LINUX=' /etc/default/grub || true

  echo "Running grub-mkconfig (this will use your normal CachyOS menu generation with the updated cmdline) ..."
  grub-mkconfig -o /boot/grub/grub.cfg

  # 7. Open the new LUKS, mkswap on mapper, activate as swap now (high pri). Leave mapper open for this session.
  echo "Opening ${HIB_PART} as ${MAPPER_NAME} (you will type the passphrase) and mkswap ..."
  cryptsetup open "${HIB_PART}" "${MAPPER_NAME}"
  mkswap "/dev/mapper/${MAPPER_NAME}"
  swapon -p 100 "/dev/mapper/${MAPPER_NAME}"
  echo "  Active swaps now:"
  swapon --show | cat

  # 8. Rebuild initrd (so hib-resume-prep hook is included)
  echo "Running mkinitcpio -P (to pick up hib-resume-prep in HOOKS) ..."
  mkinitcpio -P

  # 9. Re-deploy the z13-hibernate hooks
  echo "Re-deploying z13-hibernate (cd to the source tree and 'make install', or manually copy from usr/ and etc/). Then:"
  echo "  systemctl daemon-reload"
  echo "  mkinitcpio -P"
  echo "  grub-mkconfig -o /boot/grub/grub.cfg"
fi

echo
echo "=== LUKS2 simple hibernate setup complete ==="
echo "Verify (run these):"
echo "  lsblk -f | grep -E 'nvme0n1p10|${MAPPER_NAME}'"
echo "  blkid ${HIB_PART}"
echo "  cat /etc/crypttab | tail -5"
echo "  cat /etc/fstab | grep -E 'mapper|swap' "
echo "  cat /proc/cmdline | tr ' ' '\n' | grep -E 'resume|rd.luks'"
echo "  # Note: the example configs in the project use placeholders ROOT_LUKS_UUID and HIB_LUKS_UUID - see README.md"
echo "  grep '^HOOKS=' /etc/mkinitcpio.conf"
echo "  grep -o 'resume=[^ ]*' /boot/grub/grub.cfg | head -3"
echo
echo "The hib swap is now LUKS2 using aes-xts-plain64 (best speed on your Ryzen AI with VAES/AVX512 accel)."
echo "On next boot (or hibernate resume) the rd.luks.name will cause it to be unlocked."
echo "If same passphrase as root: often silent reuse (no extra prompt). If different: explicit 2nd prompt (hib-resume-prep hook helps)."
echo "Current gate+pre (with sidestep: no suspend loop activity) is active; post still inert."
echo "See the main README.md for how the example configs abstract ROOT_LUKS_UUID / HIB_LUKS_UUID for sharing on GitHub."
echo "Test with: systemctl hibernate   (or your DE button). Expect clean short black -> graphics on resume, using image from /dev/mapper/${MAPPER_NAME} ."
echo
echo "If you later want keyfile (no 2nd prompt), we can extend the early-hibernate hook + key on root (more complex)."
echo "Detection of busy/GPU pids still sidestepped (empty) - will refine later."
echo "Done."