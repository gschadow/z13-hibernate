#!/usr/bin/env bash
# Configure ACPI and USB wakeup sources for reliable s2idle on the ROG Z13 GZ302EA.
#
# Problem: the machine enters s2idle then immediately exits (PM: suspend exit +
# PM: suspend entry in the same second). This spurious-wake loop is caused by:
#   1. Empty XHC/NHI controllers (XHC1, XHC3, XHC4, NHI0, NHI1) left enabled as
#      S0 wakeup sources — they fire ACPI interrupts the moment s2idle starts.
#   2. Bluetooth (XHC0, 3-3) continuously sending USB keep-alive traffic that
#      wakes the host controller even with no user interaction.
#
# Fix:
#   - Disable ACPI wakeup for all XHC/NHI controllers except XHC0 (keyboard bus).
#   - Disable USB device-level wakeup for the BT device (3-3) within XHC0.
#   - Keep XHC0 ACPI wakeup enabled so the internal keyboard can still wake from s2idle.
#   - Keep keyboard (3-4) and N-KEY (3-5) device-level wakeup enabled.
#
# Consequence of disabling BT device wakeup: Bluetooth peripherals (headphones,
# mice) cannot wake the machine from s2idle. All other wake sources still work
# (keyboard, power button, lid open).

set -euo pipefail

_acpi_toggle() {
  # Toggle is the only write mechanism: current state flips each write.
  # Read first, only write if currently enabled.
  local dev="$1"
  local state
  state=$(awk -v d="$dev" '$1==d{print $3}' /proc/acpi/wakeup 2>/dev/null || true)
  if [ "$state" = "*enabled" ]; then
    echo "$dev" > /proc/acpi/wakeup
    echo "s2idle-wakeup: disabled ACPI wakeup for $dev"
  fi
}

# Disable unused/empty controller wakeup sources
for dev in XHC1 XHC3 XHC4 NHI0 NHI1; do
  _acpi_toggle "$dev"
done

# Disable BT device-level wakeup (vendor 13d3:3608 Wireless_Device on 3-3)
# The keyboard (3-4) and N-KEY (3-5) retain their device-level wakeup.
for bt_path in /sys/bus/usb/devices/3-3 /sys/bus/usb/devices/3-3.*; do
  wake_file="$bt_path/power/wakeup"
  [ -f "$wake_file" ] || continue
  echo disabled > "$wake_file" 2>/dev/null && \
    echo "s2idle-wakeup: disabled USB wakeup for $(basename $bt_path) (BT)" || true
done

echo "s2idle-wakeup: configuration applied"
