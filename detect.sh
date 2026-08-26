# Machine detection, sourced by build.sh / install.sh / verify.sh.
#
# Everything machine-specific is derived from /proc/device-tree/compatible:
#
#     apple,j413apple,t8112apple,arm-platform   ->   BOARD=j413  SOC=t8112
#
# so moving between Macs needs no edits. The device-tree filename falls straight
# out of the pair, and the display-controller nodes are at the same addresses on
# every board this has been tried on.
#
# The one thing that cannot be derived is which physical port carries
# DisplayPort. That is per-chassis and only discoverable by trying it, so it
# lives in the table at the bottom.

# Callers define their own die(); provide one if sourced somewhere that has not.
declare -F die >/dev/null || die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Set COMPAT_FILE to dry-run the detection for a different Mac without one.
COMPAT_FILE="${COMPAT_FILE:-/proc/device-tree/compatible}"
[ -r "$COMPAT_FILE" ] || die "This is not an Apple Silicon machine."
# NUL-separated, one entry per line. Do not strip the NULs: the entries would
# run together and "apple,j413" would glob into "apple,j413apple".
#     apple,j413 / apple,t8112 / apple,arm-platform
COMPAT="$(tr '\0' '\n' < "$COMPAT_FILE")"
BOARD="$(sed -n 's/^apple,\(j[0-9a-z]*\)$/\1/p' <<<"$COMPAT" | head -1)"
SOC="$(  sed -n 's/^apple,\(t[0-9]*\)$/\1/p'    <<<"$COMPAT" | head -1)"
[ -n "$BOARD" ] && [ -n "$SOC" ] \
  || die "Could not parse a board and SoC out of: $(tr '\n' ' ' <<<"$COMPAT")"

DTB="${SOC}-${BOARD}.dtb"
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "$BOARD")"

# Where the DP enable can live for this board, in the fairydust source tree.
# There is no single convention upstream:
#   j413  -> t8112-j413.dts          (per-board .dts)
#   j313  -> t8103-jxxx.dtsi         (shared dtsi, so all M1 boards inherit it)
#   j314c -> t600x-j314-j316.dtsi    (a dtsi the .dts pulls in by #include)
# so list the board .dts, everything it #includes from this directory, and the
# SoC-wide dtsi. Run from the top of the kernel tree.
dp_patch_sources() {
    local d=arch/arm64/boot/dts/apple
    local dts="$d/${SOC}-${BOARD}.dts"   # separate: `local a=x b=$a` expands $a too early
    echo "$dts"
    [ -f "$dts" ] && sed -n 's/^#include "\([^"]*\)".*/\1/p' "$dts" | sed "s|^|$d/|"
    echo "$d/${SOC}-jxxx.dtsi"
}

# Boards this has actually been run on, and the port that carries DisplayPort.
# An unlisted board is a warning, never an error: check-dtb.py on the freshly
# built blob is the real gate, and it works regardless of what this table says.
board_is_tested() {
    case "$BOARD" in j313|j413) return 0 ;; *) return 1 ;; esac
}

port_hint() {
    case "$BOARD" in
        j313)       echo "front-left — the port nearer you, not the hinge" ;;
        j413|j415)  echo "left side — the port wired to atcphy1 (/sys/class/typec/port1 here)" ;;
        j493)       echo "the port wired to atcphy1" ;;
        j473|j474s) echo "back right middle — second closest to the power connector" ;;
        *)          echo "not known for this board — try each USB-C port in turn" ;;
    esac
}
