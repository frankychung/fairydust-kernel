#!/usr/bin/env bash
#
# Undo everything install.sh did. Safe to run at any point, including after a
# partial install. Boot the normal kernel first, then run this.
#
set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Run this with sudo:  sudo $0"
KVER="$(cat "$BASE/kver" 2>/dev/null || true)"

if [ -n "$KVER" ] && [ "$(uname -r)" = "$KVER" ]; then
    die "You are currently running $KVER. Reboot into the normal kernel first."
fi

# Order matters: restore the device-tree source BEFORE rewriting the bootloader,
# otherwise update-m1n1 would point at files we are about to delete.
say "Restoring the stock device trees"
if [ -f "$BASE/update-m1n1.bak" ]; then
    mv -f "$BASE/update-m1n1.bak" /etc/default/update-m1n1
    echo "    restored your previous /etc/default/update-m1n1"
else
    rm -f /etc/default/update-m1n1
    echo "    removed /etc/default/update-m1n1 (back to the *-ARCH default)"
fi

say "Rewriting the bootloader payload with the stock device trees"
update-m1n1 || die "update-m1n1 failed — do NOT reboot. Investigate first."

say "Removing the fairydust kernel"
rm -fv /boot/vmlinuz-linux-asahi-fairydust \
       /boot/initramfs-linux-asahi-fairydust.img \
       /etc/mkinitcpio.d/linux-asahi-fairydust.preset
[ -n "$KVER" ] && rm -rf "/usr/lib/modules/$KVER" && echo "    removed /usr/lib/modules/$KVER"

say "Restoring the boot menu"
[ -f "$BASE/grub.default.bak" ] && cp -a "$BASE/grub.default.bak" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
echo "    boot menu regenerated"

say "Rolled back"
cat <<DONE

  Your system is back to the stock kernel and stock device trees.
  The source tree is still at $BASE/linux — delete it to reclaim ~25 GB:
      rm -rf $BASE/linux

  Emergency fallback, if the machine will not boot at all: from macOS
  recovery (hold the power button), the previous bootloader payload is
  saved at /boot/m1n1/boot.bin.old plus a timestamped copy in $BASE.

DONE
