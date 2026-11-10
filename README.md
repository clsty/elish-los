# LineageOS 24.0 for the Xiaomi Pad 5 Pro (elish)

A self-built LineageOS 24.0 (Android 17, SDK 37) for the **Xiaomi Pad 5 Pro**
codenamed `elish` (SoC SM8250 / `kona`, non-GKI kernel 4.19.325), carrying four changes
over the stock LineageOS build for this device:

| What | In one line | Documented in |
| --- | --- | --- |
| **Natural landscape** | The panel is mounted physically portrait, but this is a tablet you hold landscape: display install orientation, touch and pen coordinates, and every sensor's device frame are unified so that "facing the screen, charger on the right" is direction zero - in the boot animation, the lock screen, auto-rotate, touch, and the camera. | [docs/orientation.md](docs/orientation.md) |
| **Root in the ROM itself** | KernelSU (ReSukiSU fork) plus SuSFS compiled into the device kernel, with the userspace half delivered by the image. No separate boot image to flash, no magisk zip to sideload. | [docs/root.md](docs/root.md) |
| **Root hiding that survives** | `verifiedbootstate=green` on both channels, SuSFS mount hiding, KernelSU's dynamic manager - verified without any root-management app installed. The kernel carries the mechanism; a KernelSU module carries the policy (docs/root.md says which is which). | [docs/root.md](docs/root.md) |
| **Camera app usable on a landscape tablet** | The stock camera app letterboxes itself and puts its controls across the preview on a natural-landscape screen. It gets a right-hand sidebar and a per-app landscape lock. | [docs/camera.md](docs/camera.md) |

Plus a small network fix (Chinese NTP and captive-portal addresses that no longer depend on
the system language: [docs/network.md](docs/network.md)).

Everything here is the difference from upstream, not a fork of LineageOS: five themes of
source changes expressed as scripts plus generated patches, and a set of on-device
acceptance commands.

## What this repository contains

```
patches/            the whole source delta: apply-*.sh (idempotent) + generated/*.patch
  files/            the files that have no upstream counterpart (rc, config.fs, idc, appcompat)
docs/               why each change is shaped the way it is, and how to verify it on device
tools/              the verification tools (framecheck, the doc/self checks)
```

What is **not** here, deliberately:

- **The base firmware.** This device is flashed from the `HyperOS 1.0.2.0.TKYCNXM` fastboot
  package (the CN firmware line). It provides the firmware and partition layout baseline.
  Get it from Xiaomi's official fastboot-package mirrors; the exact steps are in
  [docs/flash.md](docs/flash.md).
- **GApps.** This build carries no Google packages; the setup documented here adds
  MindTheGapps for Android 17 (`17.0.0`, matching the ROM's Android version). Because a
  partition APK cannot be unpacked by the platform, the GApps choice also matters for one
  root detail (see docs/root.md).
- **The manager APK.** The root management app is *not* preinstalled in this ROM (why:
  docs/root.md). The `ksud` binary this ROM ships is extracted from the APK of one manager
  release, `ReSukiSU v4.2.0-rc1` (that fork publishes as BakaSU now; see the table below),
  and that binary's sha256 is what the scripts pin (the APK
  filename and its hash are a record of this build's input and are overridable). Install any
  manager of that release; `ksud` and the manager must agree on the release.

## Download

| file | bytes | SHA-256 |
| --- | --- | --- |
| [`lineage-24.0-20261109-UNOFFICIAL-elish.zip`][dl-zip] | 1,468,406,575 | `1ae728cac801b3c4cc12c420ef10bfabe74f209d6b454769b655464d274f1eeb` |
| [`boot.img`][dl-boot] | 201,326,592 | `d8ba7b098e23d2ca48b68dc9a21d4111e7ae0c0c20c5583972007721478f3de0` |
| [`vendor_boot.img`][dl-vb] | 100,663,296 | `447381c8efbb844aeca373334426285a7cddd387dbe22fb1c3bdf411b61df42d` |

```sh
sha256sum -c - <<EOF
1ae728cac801b3c4cc12c420ef10bfabe74f209d6b454769b655464d274f1eeb  lineage-24.0-20261109-UNOFFICIAL-elish.zip
d8ba7b098e23d2ca48b68dc9a21d4111e7ae0c0c20c5583972007721478f3de0  boot.img
447381c8efbb844aeca373334426285a7cddd387dbe22fb1c3bdf411b61df42d  vendor_boot.img
EOF
```

**Coming from the stock firmware, take all three.** This build has no `recovery.img` - the LineageOS
recovery lives inside `vendor_boot`, so on a stock tablet those two images are what make the recovery
you install from exist ([`docs/flash.md`][flash], Route A). If the tablet already runs a build from
this project, **the zip alone is enough**: the package carries `boot` and `vendor_boot` too, into the
slot it installs to. You will also need a MindTheGapps package matching this Android version; the one
this ROM is tested with, with its hash and release page, is the GApps row in [`docs/build.md`][build].

Read these three lines before installing:

- It is **userdebug** and signed with the **AOSP test key**. That is fine for development and root
  testing; it is not a daily-driver posture, and a build signed with a different key will require
  wiping userdata ([`docs/build.md`][build]).
- Install by **sideloading from recovery**, with GApps in the same session
  ([`docs/flash.md`][flash]). Route A has been walked end to end from stock on 2026-11-10 - one pass,
  31 firmware commands, no failures - and that document carries the measured timings along with the
  two lines of the firmware package's own list that need checking before you run them.
- Root is in the kernel, but **no manager APK is preinstalled**, and the manager is a real choice:
  the upstream APK is recognised by a key the kernel carries (measured: crowned at
  `signature_index=0`, nothing to register), while a manager built with your own key and package name
  - the form root hiding is about - needs one registration command (`signature_index=255`), and
  turning on `adb root` on a fresh install needs one setting first ([`docs/root.md`][root]).

What has been verified on the device, and how, is the checklist in [`docs/acceptance.md`][acc].

[dl-zip]: https://github.com/clsty/elish-los24/releases/download/24.0-20261109/lineage-24.0-20261109-UNOFFICIAL-elish.zip
[dl-boot]: https://github.com/clsty/elish-los24/releases/download/24.0-20261109/boot.img
[dl-vb]: https://github.com/clsty/elish-los24/releases/download/24.0-20261109/vendor_boot.img
[flash]: docs/flash.md
[build]: docs/build.md
[root]: docs/root.md
[acc]: docs/acceptance.md

## Getting started

Two ways to use this: take a published build, or make your own. Published builds are GitHub
release assets with their hashes, listed under [Download](#download); building takes a synced
LineageOS 24.0 tree plus three files that no licence lets us ship here, and
[docs/build.md](docs/build.md) is that path end to end - the manifest to write, the three inputs
with their hashes, the environment facts that cost real time to learn by accident, and what the
signing key implies.

`elish` is **not** a LineageOS-supported device, so its device and vendor trees are not in the
default manifest: you add `device/xiaomi/elish`, `device/xiaomi/sm8250-common`,
`vendor/xiaomi/elish` and `vendor/xiaomi/sm8250-common` yourself (they carry the prebuilt blobs;
the build fails before linking if they are missing), plus `hardware/xiaomi` and
`kernel/xiaomi/sm8250`. Nothing here modifies those beyond what `patches/` does.

```sh
sh patches/apply-all.sh /path/to/los24          # replay every change; idempotent
# then build for lineage_elish-cp2a-userdebug with your usual soong invocation, or follow
# docs/build.md for the measured version of that command
sh tools/check-repo.sh                          # optional: this repository's own self-checks
```

Three inputs live outside the source tree, and the scripts take their location from the
environment rather than assuming one:

| Variable | Default | What it is for |
| --- | --- | --- |
| `LOS24_TREE` | the script's `../srcs/los24` | where the synced tree is (or pass it as the first argument) |
| `KSU_MATERIAL_DIR` | the script's `../material` | a directory holding a manager APK of the pinned KernelSU release, which is where `ksud` is extracted from |
| `KSU_PKG` | `com.resukisu.resukisu` | only for the optional preinstall form (`KSU_PREINSTALL_MANAGER=1`): the package name to install as. It defaults to the upstream name, which is trivially recognizable; for that form a name of your own is the point, so pass it explicitly |

The defaults are where this project keeps its own files, which is why they are relative to
`patches/`: anyone using these scripts from elsewhere sets the variables or passes the path.

The known-good upstream revisions this document describes. `elish` is **not** a
LineageOS-supported device: its device and vendor trees live under `web1n`, while the platform
and the four AOSP-derived trees are LineageOS's own. Each revision was checked to exist in the
repository named beside it (2026-11-09).

| Project | Repository | Revision |
| --- | --- | --- |
| LineageOS 24.0 platform | `LineageOS/android`, branch `lineage-24.0` | Android 17 / SDK 37 |
| `device/xiaomi/elish` | `web1n/android_device_xiaomi_elish` | `23e652d` |
| `kernel/xiaomi/sm8250` | `LineageOS/android_kernel_xiaomi_sm8250` | `6b34d2476532`, with `KernelSU/` replaced by the fork below |
| `frameworks/native` | `LineageOS/android_frameworks_native` | `46018f54b4` |
| `frameworks/av` | `LineageOS/android_frameworks_av` | `937eb90` |
| `packages/apps/Aperture` | `LineageOS/android_packages_apps_Aperture` | `0a140ed` |
| KernelSU fork (manager, and the source of `ksud`) | `Baka-SU/BakaSU` | `v4.2.0-rc1` = `a9216b04` |
| SuSFS | carried by the device kernel patch; NOTICE gives the chain | `v2.2.0` (`SUSFS_VERSION` in `include/linux/susfs_def.h`) |
| susfs4ksu module | `sidex15/susfs4ksu-module` | `v1.5.2+` (`R28`), for the hiding policy |

That KernelSU fork publishes as **BakaSU** now and published as **ReSukiSU** at `v4.2.0-rc1`,
the release everything here is pinned to. This document keeps the name it had at that commit
where it refers to the release, to `ReSukiSU's Kbuild`, and to file and variable names.

The scripts pin a commit, a tag, a rev-list count and a few sha256 values - all to the release
used in the build documented here. A pin that does not match your input stops the build with the
hash it computed, which is the intended interaction: `ksud` must be the same release as the
manager you will install, so check what you got rather than editing the pin away.

`apply-all.sh` ends by freezing the resulting tree into `generated/*.patch`. The two forms
are equivalent in the narrow sense: replaying the scripts and applying the patches produce the
same file contents for the files they cover. Content a patch cannot carry - a git clone, a
submodule checkout, binaries taken out of an APK - is placed and hash-checked by the scripts,
so those still need a replay. `patches/README.md` gives the command that checks the
equivalence, and `gen-patches.sh` is what keeps the patch files honest: it refuses to write a
patch that leaves a file out (a file it did not list, an untracked file nobody explained, or a
patch that suddenly covers fewer files than before), because all three failure modes were paid
for once.

Flashing, and the flashing rules this device actually obeys, are in
[docs/flash.md](docs/flash.md). On-device acceptance - every claim above, as bare `adb`
commands with expected values - is in [docs/acceptance.md](docs/acceptance.md).

## Before reporting a problem

Each document states both *the model* (which knob is read by whom, and where the
information comes from) and *the criteria* (the exact command and the exact expected
value), because several plausible-looking readings on this device mean the opposite of
what they appear to. [docs/acceptance.md](docs/acceptance.md) also lists the readings that
must **not** be judged at all under certain conditions - a flat-lying tablet, an untethered
clock, a screen that is off. If it is not one of those, open an issue with the build
identifiers and the actual command output: the issue template asks for the few facts that
make a device report diagnosable.

## Licence

Original material in this repository (scripts, tools, documentation) is MIT-licensed; see
[LICENSE](LICENSE). Patch files contain code derived from upstream projects under their own
licences, and the prebuilt-binary inputs are not redistributable here: see
[NOTICE](NOTICE).
