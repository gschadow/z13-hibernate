#!/usr/bin/env bash
# cleanup-luks-hibernate-cruft.sh
# Removes outdated comments and stale keyfile artifacts from previous
# (more complex keyfile-based) hibernate LUKS attempts.
# Leaves the current simple "hibernate UUID=... none luks" entry and
# the volatile swap entry.
#
# Run from the z13-hibernate source tree: sudo ./luks/cleanup-luks-hibernate-cruft.sh

set -euo pipefail

echo "=== Cleaning old hibernate LUKS comments and keyfile cruft ==="

# Backup
ts=$(date +%s)
cp -a /etc/crypttab "/etc/crypttab.bak.${ts}" || true

# Rewrite crypttab cleanly: keep volatile swap + the simple hibernate entry.
# Strip the big outdated "early-hibernate keyfile" comment block.
cat > /etc/crypttab << 'EOC'
# /etc/crypttab
# See crypttab(5) for details.

# NOTE: Do not list your root (/) partition here, it must be set up
#       beforehand by the initramfs (/etc/mkinitcpio.conf).

# Volatile encrypted swap on p7 (plain dm-crypt + random key every boot).
# This one is re-keyed every boot; cannot be used for hibernation.
swap            /dev/nvme0n1p7                          /dev/urandom    plain,swap,cipher=aes-xts-plain64,size=256,discard

# Persistent LUKS2 for hibernation (simple config).
# Unlocked early in initrd via rd.luks.name=...=hibernate on the kernel cmdline
# (processed by sd-encrypt). "none" means interactive passphrase (or reuse of
# root passphrase if identical; systemd often avoids a visible 2nd prompt in that case).
# The hib-resume-prep initrd hook helps make any prompt visible in a dark room and preps amdgpu for resume.
hibernate UUID=84a05a98-9168-485c-b3fb-42bb0647d82b none luks
EOC

echo "crypttab cleaned (old keyfile comment block removed). New content:"
cat /etc/crypttab

# Remove (or back up) the stale keyfile from previous keyfile-based attempts.
# The current simple setup uses "none" + rd.luks.name (passphrase-based).
# The old keyfile is from before the luksFormat and is not needed for the simple path.
if [ -f /etc/luks-hibernate.key ]; then
  mv /etc/luks-hibernate.key "/etc/luks-hibernate.key.old.${ts}" || true
  echo "Stale /etc/luks-hibernate.key moved to /etc/luks-hibernate.key.old.${ts}"
fi

# Optionally remove the early-hibernate hook file (it is not in current HOOKS,
# but the file on disk can be confusing).
if [ -f /etc/initcpio/hooks/early-hibernate ]; then
  mv /etc/initcpio/hooks/early-hibernate "/etc/initcpio/hooks/early-hibernate.old.${ts}" || true
  echo "early-hibernate hook file moved aside (was not active in HOOKS anyway)."
  # Also the install side if present
  mv /etc/initcpio/install/early-hibernate "/etc/initcpio/install/early-hibernate.old.${ts}" 2>/dev/null || true
fi

echo
echo "Cleanup done. The simple LUKS2 hibernate config is now the only thing documented in crypttab."
echo "Reboot if you want a completely fresh boot with the cleaned crypttab (optional)."
echo "You can now test hibernate."