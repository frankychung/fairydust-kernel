#!/usr/bin/env bash
#
# Step 1 of 2 — build the Asahi "fairydust" kernel (USB-C DisplayPort support).
# Runs as your normal user. Touches nothing outside this directory except
# installing build dependencies. If this fails, your system is unchanged.
#
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$BASE/linux"

# Parallelism is bounded by RAM, not cores — each job peaks around 1.2 GB, and
# swapping costs far more than the lost parallelism. 7.4 GB gives 6, 16 GB gives
# the full 8. Override by setting JOBS in the environment.
mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
cores=$(nproc)
by_mem=$(( mem_mb / 1200 )); [ "$by_mem" -lt 2 ] && by_mem=2
JOBS="${JOBS:-$(( cores < by_mem ? cores : by_mem ))}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
say "Preflight checks"
. "$BASE/detect.sh"
echo "    $MODEL"
echo "    board $BOARD on $SOC, device tree $DTB"
board_is_tested || warn "$BOARD is untested here — continuing; the device-tree check below is the real gate."
[ -r /proc/config.gz ] || die "/proc/config.gz missing; cannot seed the config."

avail=$(df --output=avail -BG "$BASE" | tail -1 | tr -dc '0-9')
[ "${avail:-0}" -ge 8 ] || die "Need ~8 GB free, only ${avail}G available."
echo "    ${avail}G free, building with -j${JOBS} (${cores} cores, $((mem_mb/1024))G RAM)"

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
# Two separate questions. First: is this the fairydust branch at all? That is a
# hard error — nothing downstream can succeed without it.
grep -rlq 'ENABLE_DCPEXT_TYPEC' arch/arm64/boot/dts/apple/ \
  || die "No DP patches anywhere in this tree. This is not the fairydust branch."
echo "    fairydust branch confirmed"

# Second: does the patch reach THIS board? Only a warning — the check on the
# built blob below is authoritative, and upstream file layout varies enough that
# a miss here is more likely our lookup than a genuinely unsupported board.
found=""
for f in $(dp_patch_sources); do
    [ -f "$f" ] && grep -q 'ENABLE_DCPEXT_TYPEC' "$f" && { found="$f"; break; }
done
if [ -n "$found" ]; then
    echo "    $BOARD enabled by $(basename "$found")"
else
    warn "Could not find the DP enable for $BOARD — building anyway; the device-tree check after the build will settle it."
fi

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
python3 "$BASE/check-dtb.py" "arch/arm64/boot/dts/apple/$DTB" \
  || die "The built device tree did NOT enable dcpext. Stopping before install."

say "Build complete: $KVER"
echo
echo "    Next step:   sudo $BASE/install.sh"
