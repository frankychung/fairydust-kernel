#!/usr/bin/env bash
#
# Step 2 of 2 — install the kernel built by build.sh. Run with sudo.
# Your existing kernel is left completely alone and stays the boot default.
#
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$BASE/linux"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Run this with sudo:  sudo $0"
[ -f "$BASE/kver" ] || die "No build found. Run build.sh first."
KVER="$(cat "$BASE/kver")"
IMAGE="$SRC/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "Kernel image missing. Did build.sh finish?"

say "Installing kernel $KVER"

# ------------------------------------------------- clean up older attempts
# /boot is a 499 MB partition, so a stale kernel from a previous build is worth
# clearing out. Only ever removes *-fairydust builds that are not this one.
for old in /usr/lib/modules/*-fairydust; do
    [ -d "$old" ] || continue
    [ "$(basename "$old")" = "$KVER" ] && continue
    say "Removing the older build $(basename "$old")"
    rm -rf "$old"
done

# ------------------------------------------------------------------ modules
say "Installing modules to /usr/lib/modules/$KVER"
make -C "$SRC" INSTALL_MOD_STRIP=1 modules_install >/dev/null

# ------------------------------------------------------------------- image
say "Installing the kernel image"
install -Dm644 "$IMAGE" /boot/vmlinuz-linux-asahi-fairydust
echo "    /boot/vmlinuz-linux-asahi-fairydust"

# -------------------------------------------------------------------- dtbs
# Arch keeps device trees flat in /usr/lib/modules/<ver>/dtbs/, so match that.
say "Installing device trees"
install -d "/usr/lib/modules/$KVER/dtbs"
cp "$SRC"/arch/arm64/boot/dts/apple/*.dtb "/usr/lib/modules/$KVER/dtbs/"
echo "    $(ls /usr/lib/modules/$KVER/dtbs/*.dtb | wc -l) device trees installed"

say "Verifying the installed device tree"
python3 "$BASE/check-dtb.py" "/usr/lib/modules/$KVER/dtbs/t8103-j313.dtb" \
  || die "Installed device tree does not enable the external display. Stopping."

# --------------------------------------------------------------- initramfs
say "Generating the initramfs"
cat > /etc/mkinitcpio.d/linux-asahi-fairydust.preset <<PRESET
# mkinitcpio preset for the locally built fairydust kernel
ALL_kver="$KVER"
PRESETS=('default')
default_image="/boot/initramfs-linux-asahi-fairydust.img"
PRESET
mkinitcpio -p linux-asahi-fairydust

# ------------------------------------------------------- m1n1 device trees
# THE IMPORTANT BIT. update-m1n1 defaults to:
#     DTBS=$(ls -d /lib/modules/*-ARCH | sort -rV | head -1)/dtbs/*.dtb
# Our kernel directory ends in "-fairydust", so it does NOT match "*-ARCH" and
# our device trees would be silently ignored — everything would install fine and
# the monitor would still be dark. Pin DTBS explicitly to avoid that.
say "Pointing m1n1 at the new device trees"
[ -f /etc/default/update-m1n1 ] && cp -a /etc/default/update-m1n1 "$BASE/update-m1n1.bak"
cat > /etc/default/update-m1n1 <<CONF
# Written by fairydust-kernel/install.sh
# Pin the device trees to the locally built fairydust kernel. Without this,
# update-m1n1 globs /lib/modules/*-ARCH and would use the stock device trees,
# leaving the external display disabled.
DTBS="/usr/lib/modules/$KVER/dtbs/*.dtb"
CONF
echo "    /etc/default/update-m1n1 -> $KVER"

say "Updating the bootloader payload"
warn "update-m1n1 saves the previous payload as /boot/m1n1/boot.bin.old"
cp -a /boot/m1n1/boot.bin "$BASE/boot.bin.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
update-m1n1

# -------------------------------------------------------------------- grub
say "Regenerating the boot menu"
cp -a /etc/default/grub "$BASE/grub.default.bak"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | grep -Ei 'found|error' || true

# Keep the STOCK kernel as the default so an unattended reboot is always safe.
STOCK_ID="$(grep -o "gnulinux-linux-asahi-advanced-[0-9a-f-]*" /boot/grub/grub.cfg | head -1)"
SUB_ID="$(grep -o "gnulinux-advanced-[0-9a-f-]*" /boot/grub/grub.cfg | head -1)"
if [ -n "$STOCK_ID" ] && [ -n "$SUB_ID" ]; then
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${SUB_ID}>${STOCK_ID}\"|" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
    echo "    default entry pinned to the STOCK kernel"
else
    warn "Could not pin the default entry — check the menu manually at boot."
fi

say "Done"
cat <<DONE

  Installed : $KVER
  Stock     : still installed, still the boot default

  Reboot, then in the GRUB menu choose:
      Advanced options for Omarchy Linux
        -> Omarchy Linux, with Linux linux-asahi-fairydust

  Plug the monitor into the FRONT-left USB-C port (nearer you, not the hinge).
  Plugging in before you boot is more reliable than hot-plugging.

  If anything goes wrong: reboot and pick the normal entry, then run
      sudo $BASE/rollback.sh

DONE
