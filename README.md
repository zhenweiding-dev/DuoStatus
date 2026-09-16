# DuoStatus

The iPhone Duo rolls Wi-Fi, cell signal and battery into a single circle instead of a row of icons. I thought that was a neat idea, so I brought it to the
Mac with Claude.

It's a menu bar app: mixes battery, network and volume in one badge, with the basics in the dropdown. 

I like it, and hopefully someone else will too. 🎉

![The icon and menu](docs/menu.png)

## It asks for nothing

No Location, no Accessibility, no Full Disk Access, no prompts of any kind. There isn't
a single usage-description key in the bundle and the binary carries no entitlements.

That wasn't free — Wi-Fi signal and network latency are the two things that normally
drag a permission prompt in with them. Both turned out to be avoidable; see below.

## Some things I ran into

A few of these cost real time, so in case they save someone else's:

- **macOS 27 hides menu item images by default.** Setting `item.image` is no longer
  enough; you also need `preferredImageVisibility = .visible`. The SDK header says it
  outright — AppKit "will typically hide images".
- **Timers don't fire while a menu is open.** The run loop switches to event tracking,
  so a normally scheduled `Timer` goes silent. `RunLoop.main.add(timer, forMode: .common)`
  is what makes the numbers tick live while you're looking at them.
- **`NSStatusBar.thickness` reports 22pt, but that isn't a ceiling.** The button grows
  with whatever image you hand it — 32pt still wasn't clipped. I had the badge pinned
  at 20pt for a while because I assumed otherwise.
- **Location permission only gates the Wi-Fi *name*.** SSID and BSSID come back `nil`
  without it, but RSSI, noise, channel, PHY mode and transmit rate all read fine, so the
  signal bars cost nothing.
- **Battery health isn't in IORegistry.** Nothing in the registry equals the percentage
  System Settings shows, and deriving it from `NominalChargeCapacity / DesignCapacity`
  lands a point off. `system_profiler SPPowerDataType` takes 0.09s and is authoritative.
- **ICMP doesn't need root on macOS.** `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` just
  works, so latency is measured in-process instead of shelling out to `ping`.
- **Round caps eat your gaps.** When spacing arcs around a circle, each round line cap
  extends `stroke/2` past its endpoint — ask for a 10° gap and you can end up with a
  negative one. Every gap here is computed as `(gap + stroke) / radius`.

The badge geometry is easy to break in ways you don't notice, so each change to the
drawing was checked by rendering all 1442 state combinations into one grid image and
diffing the hash against a baseline.

## Install

Download the [latest release](https://github.com/zhenweiding-dev/duostatus/releases/latest),
open the `.dmg`, and drag **DuoStatus** onto the **Applications** folder.

macOS blocks the first launch: the app is signed locally but not notarized, which needs a
paid Apple developer account I don't have. Let it through once via **System Settings →
Privacy & Security** — scroll to the bottom and click **Open Anyway**.

Or build it yourself:

```bash
./build.sh --install     # build and install to /Applications
./build.sh --dmg         # build the disk image
```

macOS 14+, universal (Apple silicon and Intel). Building needs Xcode 27.
English and 简体中文, following the system language unless you pick one.
