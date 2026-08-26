#!/usr/bin/env bash
#
# Run this AFTER rebooting into the fairydust kernel, with the monitor plugged
# into the front-left USB-C port. Tells you what worked and what did not.
#
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32mok  \033[0m %s\n' "$*"; }
no()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }

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
if [ -e /proc/device-tree/soc/dcp@271c00000/status ]; then
    st=$(tr -d '\0' < /proc/device-tree/soc/dcp@271c00000/status)
    [ "$st" = okay ] && ok "dcp@271c00000 is enabled" || no "dcp@271c00000 is '$st'"
else
    ok "dcp@271c00000 present with no status property (enabled)"
fi
if [ -e /sys/bus/platform/drivers/apple-dcp/271c00000.dcp ]; then
    ok "the external display driver bound to it"
else
    no "the external display driver did not bind — see: journalctl -k | grep 271c00000"
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
for p in /sys/class/typec/port0 /sys/class/typec/port1; do
    n=$(basename "$p"); lbl="hinge-side (back)"
    [ "$(readlink -f "$p/device")" != "${p%/*}" ] && \
      case "$(readlink -f "$p/device")" in *003f) lbl="FRONT — the one that works";; esac
    printf '  %-7s %-28s partner: %s\n' "$n" "$lbl" \
        "$([ -e "$p-partner" ] && echo connected || echo none)"
done

say "Recent display errors"
journalctl -k -b --no-pager | grep -iE 'dcp|dptx|crossbar|atcphy' \
  | grep -iE 'error|fail|warn|unsupported' | tail -10 || echo "  (none)"

say "If a connector appeared but the screen is dark"
echo "  Try:  hyprctl monitors        (see what Hyprland detected)"
echo "  Or:   journalctl -k -f        then unplug and replug"
