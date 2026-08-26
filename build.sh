#!/usr/bin/env bash
#
# Step 1 of 2 — build the Asahi "fairydust" kernel (USB-C DisplayPort support).
# Runs as your normal user. Touches nothing outside ~/fairydust-kernel except
# installing build dependencies. If this fails, your system is unchanged.
#
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$BASE/linux"
JOBS="${JOBS:-6}"   # 8 cores, but only 7.4 GB RAM — 6 keeps us out of swap

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
say "Preflight checks"
[ -r /proc/device-tree/compatible ] || die "This is not an Apple Silicon machine."
tr -d '\0' < /proc/device-tree/compatible | grep -q j313 \
  || die "Written for the M1 MacBook Air (apple,j313). Yours is different."
[ -r /proc/config.gz ] || die "/proc/config.gz missing; cannot seed the config."

avail=$(df --output=avail -BG "$BASE" | tail -1 | tr -dc '0-9')
[ "${avail:-0}" -ge 25 ] || die "Need ~25 GB free, only ${avail}G available."
echo "    machine ok, ${avail}G free, building with -j${JOBS}"

# ------------------------------------------------------------ dependencies
say "Installing build dependencies"
sudo pacman -S --needed --noconfirm \
    base-devel bc cpio dtc perl tar xz git \
    rust rust-src rust-bindgen clang llvm lld

# ------------------------------------------------------------------ source
say "Fetching the fairydust branch (~400 MB, shallow clone)"
if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch --depth 1 origin fairydust
    git -C "$SRC" reset --hard FETCH_HEAD
    git -C "$SRC" clean -xfdq
else
    git clone --depth 1 --single-branch --branch fairydust \
        https://github.com/AsahiLinux/linux.git "$SRC"
fi
cd "$SRC"

# Prove we actually got the DisplayPort commits, not plain asahi.
grep -q 'ENABLE_DCPEXT_TYPEC' arch/arm64/boot/dts/apple/t8103-jxxx.dtsi \
  || die "This tree is missing the fairydust DP patches. Wrong branch?"
echo "    fairydust DP patches confirmed present in the device tree"

# ------------------------------------------------------------------ config
say "Seeding the config from your running kernel"
zcat /proc/config.gz > .config

# A distinct name so this kernel installs beside the stock one instead of over it.
./scripts/config --set-str LOCALVERSION "-fairydust"
./scripts/config --disable LOCALVERSION_AUTO
# Debug info costs roughly an hour of build time and 20 GB of disk. We do not need it.
./scripts/config --disable DEBUG_INFO_DWARF5
./scripts/config --enable  DEBUG_INFO_NONE
make olddefconfig

say "Verifying the config kept what matters"
check() {
    grep -q "^$1=" .config && echo "    ok      $1" || die "$1 is missing from the config!"
}
check CONFIG_MUX_APPLE_DPXBAR   # the DisplayPort crossbar
check CONFIG_PHY_APPLE_DPTX     # the DisplayPort PHY
check CONFIG_DRM_APPLE          # the display driver
check CONFIG_DRM_ASAHI          # the GPU driver — without this your desktop is unusable
check CONFIG_ARM64_16K_PAGES    # must match your userspace
check CONFIG_RUST               # required by the GPU driver

# ------------------------------------------------------------------- build
say "Checking the Rust toolchain (the GPU driver is written in Rust)"
make rustavailable || die "Rust toolchain unusable — see the message above."

KVER="$(make -s kernelrelease)"
printf '%s\n' "$KVER" > "$BASE/kver"

say "Building $KVER — expect 60 to 100 minutes"
warn "You can keep using the laptop; it will just feel slow."
time make -j"$JOBS" Image modules dtbs

# Last check: did the built device tree really enable the external display?
say "Confirming the built device tree enables the external display"
python3 "$BASE/check-dtb.py" arch/arm64/boot/dts/apple/t8103-j313.dtb \
  || die "The built device tree did NOT enable dcpext. Stopping before install."

say "Build complete: $KVER"
echo
echo "    Next step:   sudo $BASE/install.sh"
