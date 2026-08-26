# USB-C external display on Apple Silicon Macs (Omarchy / Asahi)

Builds the Asahi `fairydust` kernel so a USB-C monitor works on an Apple Silicon
Mac running Omarchy on Asahi. The scripts read `/proc/device-tree/compatible`
and derive everything machine-specific from it, so one checkout follows you
between Macs without edits.

Run on: MacBook Air M2 13" (`apple,j413` / t8112) and MacBook Air M1
(`apple,j313` / t8103).

## Credit

All of the actual work here is [Asahi Linux](https://asahilinux.org/)'s. The
`fairydust` branch of [AsahiLinux/linux](https://github.com/AsahiLinux/linux) is
where DisplayPort output on Apple Silicon is being developed. This repository is
nothing but a few shell scripts that build that branch on Arch/Omarchy and work
around one packaging trap along the way.

## This is unsupported — please do not report its bugs to Asahi

`fairydust` is an in-development branch, not a release. If you run this kernel
and something breaks, that is between you and this repository. **Do not open
issues on the Asahi Linux tracker, and do not ask for help in Asahi support
channels while running it.** Reproduce on a stock `linux-asahi` kernel first;
if it only happens here, it is not their bug.

Expect: one display only, one specific port only, flaky hot-plug, and possibly
wrong colours or missing resolutions. 4K60 should work — the PHY does HBR3
(32.4 Gbps across 4 lanes) and 4K60 8-bit needs 12.5. There is no DSC support
in the driver, so everything runs uncompressed.

Your stock kernel stays installed and stays the boot default. `rollback.sh`
undoes everything.

## Why this is needed

The stock kernel (`linux-asahi 7.1.6.asahi1` at the time of writing) already
contains almost all of the fairydust work — the DisplayPort crossbar driver, the
DPTX endpoint, and the DisplayPort support in the USB-C PHY are all compiled in
and loaded. Two things are missing:

1. The device tree leaves `dcp@271c00000` — the second display controller, the
   one that drives an external screen — set to `status = "disabled"`.
2. `drivers/usb/typec/tipd/` lacks a 23-line patch that tells the display stack
   when a monitor is plugged in.

The `fairydust` branch is only 11 commits ahead of `asahi`: 14 device-tree files
and those 2 C files. This builds that branch.

## Check this first

DisplayPort Alt Mode negotiation is not the problem, and it is worth confirming
that before spending 90 minutes on a build. With a monitor attached to the right
port, every USB device drops to 480 Mbps and the SuperSpeed bus sits empty —
that means all four lanes have been handed to DisplayPort:

```sh
# Which root hub is SuperSpeed (speed 5000 or 10000)?
for u in /sys/bus/usb/devices/usb*; do echo "$(basename "$u") $(cat "$u/speed")"; done

# Everything attached should read 480, and the SuperSpeed bus should be empty.
for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
    [ -e "$d/speed" ] && echo "$(basename "$d") $(cat "$d/speed") $(cat "$d/product" 2>/dev/null)"
done
```

Two sysfs traps, both learned the hard way:

**Do not trust `/sys/class/typec/port*/*/mode*/active`.** Under `tps6598x` it
reads `yes` on every port whether or not anything is plugged in, so it cannot
tell you whether DP alt mode was entered. The empty SuperSpeed bus is the real
signal.

**Do not read `/sys/class/typec/<port>-partner/identity/product`.** On a partner
with no identity VDO — MagSafe, on a laptop — it faults the `typec` module and
oopses the kernel on 7.1.6:

```
Unable to handle kernel paging request at virtual address ffff8000822a7d10
pc : product_show+0x34/0x60 [typec]
```

It only kills the reading process, but it taints the kernel until you reboot.
Nothing to do with fairydust — just do not poke it. `verify.sh` carries a
comment so nobody adds it back.

If DP alt mode is negotiating, the only missing piece is a display controller to
drive those lanes — which is what this fixes. If it is *not*, this repository
will not help you.

## Usage

```sh
./build.sh              # ~90 min, no root except installing dependencies
sudo ./install.sh       # a few minutes
sudo reboot
./verify.sh             # after picking the fairydust entry in GRUB
```

`build.sh` picks its own `-j` from RAM (~1.2 GB per job, capped at core count):
6 on a 8 GB machine, 8 on a 16 GB one. Override with `JOBS=n ./build.sh`.

Rollback at any time:

```sh
sudo ./rollback.sh
```

## Which port

Only one port works. This is not a preference — the device tree hardcodes a
single PHY (`atcphy1` on every board here) and the others physically cannot
carry DisplayPort. *Which* socket that is depends on the chassis and can only be
found by trying:

| Board | Machine | Port |
|---|---|---|
| `j313` | MacBook Air M1 | front-left — nearer you, not the hinge |
| `j413` | MacBook Air M2 13" | left side, the one on `atcphy1` (`/sys/class/typec/port1`) |
| `j474s` | Mac mini M2 Pro | back right middle — second closest to the power connector |

`verify.sh` prints the entry for your board and lists every port with the PHY
behind it, so you can match `atcphy1` (`503000000.phy`) to a physical socket.
Plug in before booting; hot-plug is less reliable.

## Moving between Macs

There is deliberately no per-generation split, because M1-vs-M2 is not where the
real seam is. Upstream groups the boards differently:

| Board | Where the DP enable lives |
|---|---|
| `j313` (M1 Air) | `t8103-jxxx.dtsi` — shared, so every M1 board inherits it |
| `j413` / `j415` / `j493` (M2 laptops) | their own `.dts`, one `#define` each |
| `j314c` / `j316c` (MBP 14/16) | `t600x-j314-j316.dtsi`, reached by `#include` |
| `j473` (Mac mini M2) | its own `.dts`, plus its own override block |

The M1 Air and the M2 Air are the *same* case: one-line enable, `atcphy1`,
`dcpext` at `0x271c00000`. The Mac mini M2 differs from the M2 Air far more than
the M2 Air differs from the M1 Air — swapped `dcp`/`dcpext` roles, a different
`mux-index`, a different audio node. Splitting by generation would separate the
two boards that are identical and group the two that are not.

So `detect.sh` derives it instead:

```
apple,j413  apple,t8112  apple,arm-platform   ->   BOARD=j413  SOC=t8112
                                              ->   t8112-j413.dtb
```

and the checks that would otherwise need a per-board table do not have one:

- `check-dtb.py` looks for `dcp@271c00000`, the same address on t8103 and t8112.
- `verify.sh` prefers the `dcpext` alias the fairydust device tree adds, which
  works regardless of address.
- `dp_patch_sources` looks in the board `.dts`, everything it `#include`s, and
  the SoC-wide `.dtsi` — covering all four layouts above.
- `-j` comes from RAM, not a constant.

The only genuinely per-board fact is the port table above.

To dry-run the detection for a machine you do not have in front of you:

```sh
printf 'apple,j313\0apple,t8103\0' > /tmp/c
COMPAT_FILE=/tmp/c bash -c '. ./detect.sh; echo "$BOARD $SOC $DTB"'
# -> j313 t8103 t8103-j313.dtb
```

## The trap this handles

This is the part that is specific to Arch and Omarchy, and the reason this
repository exists at all. `update-m1n1` picks device trees like this:

```sh
DTBS=$(ls -d /lib/modules/*-ARCH | sort -rV | head -1)/dtbs/*.dtb
```

A kernel named `7.1.9-fairydust` does not match `*-ARCH`, so the new device trees
would be silently ignored — the build succeeds, the install succeeds, and the
monitor stays dark, with no error anywhere to tell you why. `install.sh` pins
`DTBS` explicitly, and `check-dtb.py` verifies the installed blob really does
enable the external controller.

`install.sh` pins the *whole* directory (`.../dtbs/*.dtb`), so the derived board
name only decides which blob gets verified, not which get shipped.

## What changes on your system

| Changed | Detail |
|---|---|
| New kernel | `/boot/vmlinuz-linux-asahi-fairydust`, alongside the stock one |
| New modules | `/usr/lib/modules/7.1.9-fairydust/` |
| Bootloader payload | `/boot/m1n1/boot.bin` — rewritten with the new device trees |
| `/etc/default/update-m1n1` | created, pinning device trees to this kernel |
| `/etc/default/grub` | `GRUB_DEFAULT` pinned to the **stock** kernel |

Your stock kernel, packages, and configuration are untouched, and the stock
kernel stays the boot default.

One genuine caveat: m1n1 hands **one** device tree to whichever kernel you boot,
so the stock kernel also sees the external display enabled. Harmless — it has all
the drivers, just not the hotplug patch.

## Omarchy updates

`omarchy update` works exactly as before. It is `pacman -Syu` plus a git pull of
the Omarchy checkout plus migrations — none of which knows or cares about extra
kernels. Nothing here needs to be paused or undone first.

What survives an update on its own:

- **This kernel and its modules.** Different filenames from the stock ones, so
  pacman never touches them.
- **The boot menu entry.** Regenerated from `/boot/vmlinuz-*`, which still finds it.
- **The external display.** `95-m1n1-install.hook` re-runs `update-m1n1` whenever
  `linux-asahi` updates, and `update-m1n1` reads `/etc/default/update-m1n1` — so the
  fairydust device trees are re-applied automatically.

What does not update itself: this kernel stays where it was built. When
`linux-asahi` moves to a new version, the stock kernel moves and this one does
not. You do not have to follow along — but to do so:

```sh
cd fairydust-kernel
./build.sh && sudo ./install.sh
```

`install.sh` removes the previous `-fairydust` build automatically.

### Two things to know

**Device-tree drift.** Because `DTBS` is pinned here, the *stock* kernel also
boots with this kernel's device trees. Harmless while the versions are close.
If the stock kernel gets a release or two ahead and something display-related
acts strange, rebuild — or `sudo ./rollback.sh` to return to stock device trees.

**Snapshots.** Omarchy takes a Snapper snapshot before each update. `/boot` is a
separate partition and is *not* included, so restoring a pre-install snapshot
removes `/usr/lib/modules/<ver>-fairydust` while leaving the kernel image in
`/boot`. That entry then fails to boot. Not a problem: choose the stock entry,
then re-run `sudo ./install.sh` (or `sudo ./rollback.sh` to clean up).

### Disk

The kernel plus its initramfs is ~52 MB in `/boot`, so check you have room
there — an Asahi `/boot` is small and can be tight. On `/`, the built source
tree in `linux/` measured 3.3 GB (2.2 GB source, 0.8 GB build artifacts,
0.3 GB git history), plus ~94 MB of installed modules. `build.sh` asks for
8 GB free to leave headroom.

To reclaim space without giving up a fast rebuild — drops the object files,
keeps the source and git history:

```sh
cd linux && make clean    # ~1.2 GB back
```

To reclaim all of it, at the cost of a full re-clone next time:

```sh
rm -rf linux/    # build.sh re-clones it next time
```

Note that Omarchy's updater refuses to run with under 10 GB free on `/`, so
keep that in mind if the disk is tight.

## Licence

GPL-2.0, matching the kernel it builds. See [LICENSE](LICENSE).
