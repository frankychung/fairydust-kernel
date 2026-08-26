#!/usr/bin/env bash
#
# Run this AFTER rebooting into the fairydust kernel, with the monitor plugged
# into the DisplayPort-capable USB-C port (see the table in detect.sh). Tells
# you what worked and what did not.
#
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32mok  \033[0m %s\n' "$*"; }
no()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }

. "$BASE/detect.sh"

say "Kernel"
case "$(uname -r)" in
    *fairydust*) ok "running $(uname -r)" ;;
    *) no "running $(uname -r) — this is the stock kernel, reboot and pick fairydust"; exit 1 ;;
esac

say "DisplayPort hotplug patch"
if nm -u "/lib/modules/$(uname -r)/kernel/drivers/usb/typec/tipd/tps6598x-core.ko" 2>/dev/null \
     | grep -q oob_hotplug; then
    ok "tps6598x-core has the DRM hotplug hook"
else
    no "tps6598x-core is missing the hotplug hook"
fi

say "External display controller"
# The fairydust device tree adds a "dcpext" alias; stock kernels have none. Use
# it when present so this works on any board, and fall back to the address that
# t8103 and t8112 both happen to use.
DCPEXT="$(cat /proc/device-tree/aliases/dcpext 2>/dev/null | tr -d '\0')"
if [ -n "$DCPEXT" ]; then
    ok "dcpext alias present -> $DCPEXT"
else
    DCPEXT=/soc/dcp@271c00000
    no "no dcpext alias — the fairydust device tree is not in effect"
fi
NODE="$(basename "$DCPEXT")"
if [ -e "/proc/device-tree$DCPEXT/status" ]; then
    st=$(tr -d '\0' < "/proc/device-tree$DCPEXT/status")
    [ "$st" = okay ] && ok "$NODE is enabled" || no "$NODE is '$st'"
else
    ok "$NODE present with no status property (enabled)"
fi
DRV="${NODE#*@}.${NODE%@*}"          # dcp@271c00000 -> 271c00000.dcp
if [ -e "/sys/bus/platform/drivers/apple-dcp/$DRV" ]; then
    ok "the external display driver bound to it"
else
    no "the external display driver did not bind — see: journalctl -k | grep ${NODE#*@}"
fi

say "Display connectors"
for c in /sys/class/drm/card*-*/status; do
    conn=$(basename "$(dirname "$c")")
    printf '  %-24s %s\n' "${conn#card*-}" "$(cat "$c")"
done
if ls -d /sys/class/drm/card*-DP-* >/dev/null 2>&1; then
    ok "a DisplayPort connector exists"
else
    no "no DisplayPort connector — the external controller is not running"
fi

say "USB-C port state"
# Do NOT read <port>-partner/identity/product here. On a partner with no
# identity VDO (MagSafe) that faults the typec module on 7.1.6 — a kernel oops
# from a plain sysfs read.
for p in /sys/class/typec/port[0-9]*; do
    case "$p" in *-partner) continue ;; esac
    [ -d "$p" ] || continue
    phy=$(ls -d "$p"/supplier:platform:*.phy 2>/dev/null | head -1)
    phy=$(basename "${phy:-}" 2>/dev/null); phy=${phy#supplier:platform:}
    printf '  %-7s phy: %-18s partner: %s\n' "$(basename "$p")" \
        "${phy:-none (power only)}" \
        "$([ -e "$p-partner" ] && echo connected || echo none)"
done
echo
echo "  DisplayPort port on $BOARD: $(port_hint)"

say "Recent display errors"
journalctl -k -b --no-pager | grep -iE 'dcp|dptx|crossbar|atcphy' \
  | grep -iE 'error|fail|warn|unsupported' | tail -10 || echo "  (none)"

say "If a connector appeared but the screen is dark"
echo "  Try:  hyprctl monitors        (see what Hyprland detected)"
echo "  Or:   journalctl -k -f        then unplug and replug"
