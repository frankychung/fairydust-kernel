# USB-C external display on the M1 MacBook Air (Omarchy / Asahi)

Builds the Asahi `fairydust` kernel so a USB-C monitor works on the M1 MacBook
Air (`apple,j313` / t8103) running Omarchy on Asahi.

## Credit

All of the actual work here is [Asahi Linux](https://asahilinux.org/)'s. The
`fairydust` branch of [AsahiLinux/linux](https://github.com/AsahiLinux/linux) is
where DisplayPort output on Apple Silicon is being developed. This repository is
nothing but four shell scripts that build that branch on Arch/Omarchy and work
around one packaging trap along the way.

## This is unsupported — please do not report its bugs to Asahi

`fairydust` is an in-development branch, not a release. If you run this kernel
and something breaks, that is between you and this repository. **Do not open
issues on the Asahi Linux tracker, and do not ask for help in Asahi support
channels while running it.** Reproduce on a stock `linux-asahi` kernel first;
if it only happens here, it is not their bug.

Expect: one display only, front-left port only, flaky hot-plug, and possibly
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
that before spending 90 minutes on a build. With a monitor attached to the
front-left port, every USB device should drop to 480 Mbps and the SuperSpeed bus
should sit empty — that means all four lanes have been handed to DisplayPort:

```sh
cat /sys/class/typec/port0/*/mode*/active   # DP alt mode should be "yes"
ls /sys/bus/usb/devices/                    # SuperSpeed bus empty while attached
```

If that already holds on your machine, the only missing piece is a display
controller to drive those lanes — which is what this fixes. If DP alt mode is
*not* negotiating, this repository will not help you.

## Usage

```sh
./build.sh              # ~90 min, no root except installing dependencies
sudo ./install.sh       # a few minutes
sudo reboot
./verify.sh             # after picking the fairydust entry in GRUB
```

Rollback at any time:

```sh
sudo ./rollback.sh
```

## Which port

**Front-left only** — the port nearer you, not the hinge. This is not a
preference; the device tree hardcodes `atcphy1`, and the other port physically
cannot carry DisplayPort. Plug in before booting; hot-plug is less reliable.

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
