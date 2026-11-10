# Building it yourself

[README](../README.md) says what changes; [flash.md](flash.md) says how to put a zip on the
device; this page is the part in between - the tree, the three files that are not in any
repository, and the four environment facts that cost the most time to discover by accident.

## 1. The tree

`elish` is not a LineageOS-supported device, so there is no `lineage_elish` entry in the
default manifest. Sync the platform and add the device, vendor and kernel projects explicitly:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="web1n" fetch="https://github.com/web1n/" />

  <project path="device/xiaomi/elish" name="android_device_xiaomi_elish"
           remote="web1n" revision="lineage-24.0" />
  <project path="device/xiaomi/sm8250-common" name="android_device_xiaomi_sm8250-common"
           remote="web1n" revision="lineage-24.0-test" />
  <project path="vendor/xiaomi/elish" name="proprietary_vendor_xiaomi_elish"
           remote="web1n" revision="main" />
  <project path="vendor/xiaomi/sm8250-common" name="proprietary_vendor_xiaomi_sm8250-common"
           remote="web1n" revision="lineage-24.0" />

  <project path="hardware/xiaomi" name="LineageOS/android_hardware_xiaomi"
           remote="github" revision="lineage-24.0" />
  <project path="kernel/xiaomi/sm8250" name="LineageOS/android_kernel_xiaomi_sm8250"
           remote="github" revision="lineage-24.0" />
</manifest>
```

Two things here are wrong in ways that do not look wrong:

- **`device/xiaomi/sm8250-common` has no `lineage-24.0` branch.** On that tree the Android 17
  branch is named `lineage-24.0-test`. Asking for `lineage-24.0` fails as a missing reference,
  and the vendor tree's own default branch is an older one, so "whatever the default is" pulls
  a mixture of two LineageOS versions.
- **A LineageOS project name needs its `LineageOS/` prefix** (as above) because the `github`
  remote in the platform manifest resolves to `https://github.com/`, not to LineageOS. Write
  `android_hardware_xiaomi` bare and you get `remote: Not Found`, which reads like a network
  failure and is not one.

The vendor trees carry the prebuilt blobs; nothing here extracts them from stock firmware.
Everything this document describes was built and tested on a device whose firmware is
`OS1.0.2.0.TKYCNXM`. The normal iteration (Route B) leaves the firmware partitions alone, so that
baseline carries through every update; no other firmware baseline has been measured.

## 2. The three files that are not in this repository

They are inputs the licences keep out of a public repository. Pin all three by sha256; the
build scripts do, and they stop on a mismatch rather than building something unverifiable.

| Input | Where it comes from | sha256 |
| --- | --- | --- |
| Manager APK (source of the delivered `ksud`) | [Baka-SU/BakaSU `v4.2.0-rc1`](https://github.com/Baka-SU/BakaSU/releases/tag/v4.2.0-rc1), asset `ReSukiSU_v4.2.0-rc1_35061-arm64-v8a-release.apk` | `544cf6cb105acacf219b3db71e43b9818e3f335153763e56aa0356bd09d1b450` |
| susfs4ksu module (the hiding policy, installed on-device) | [sidex15/susfs4ksu-module `v1.5.2+_R28`](https://github.com/sidex15/susfs4ksu-module/releases/tag/v1.5.2%2B_R28), asset `ksu_module_susfs_1.5.2+.zip` | `abcd6bf456ea8189298d9e496faa440201d90e4f0bd93b83c0527589001c9376` |
| GApps (flashed with the ROM, see flash.md) | [MindTheGapps `17.0.0-arm64`, release `MindTheGapps-17.0.0-arm64-20261022_132445`](https://github.com/MindTheGapps/17.0.0-arm64/releases/tag/MindTheGapps-17.0.0-arm64-20261022_132445), 544284463 bytes | `a6844eeb2613541558237e467b20feb01f8b45b2ebab0109834140ea59b6ca4d` |

Each link is the release page rather than the file link on purpose: a GitHub asset URL answers
302 into a signed CDN URL whose query string expires, so it is not something to pin in a document.
Check the download by the asset name and the sha256 above (the GApps release also ships its own
`.zip.sha256sum` beside the file). Verified reachable on 2026-11-09; a stale link is reported by
`tools/check-repo.sh`, which fails on a redirect as well as on a 404.

The manager APK is only a container: what the image ships is its `lib/arm64-v8a/libksud.so`
(`fb049cdcd2ffac43c43d6e1a52bfae5f0c5328f94c1398e977159020c026d85d`), so **any** manager APK of
that release reproduces the same `ksud` - the official asset above and the private-fork APK this
project's own build used give byte-identical binaries. `KSU_MATERIAL_DIR` is where the scripts
look; pass it explicitly if you keep the file elsewhere.

The kernel-side KernelSU source is not in the manifest either: `apply-root-changes.sh` clones it from
`Baka-SU/BakaSU` (published as ReSukiSU at the pinned tag) and detaches at `a9216b04e29c`, then checks
the commit *and* the `rev-list` count - the version code is derived from that count, so a shallow clone
fails the check rather than building a misversioned kernel. Pass `KSU_LOCAL_CLONE=/path/to/clone` to
place a clone you already have instead of going to the network.

## 3. Four environment facts

A full build measured 142 G for the tree and 136 G for `out/`. Both are `du` figures - logical sizes. A
filesystem that compresses writes will use less of the pool (measured here: about 63 G of a 931 G pool
for that `out/`, on a mount using `compress=zstd:3`, where `du` itself still reports the uncompressed
size), but plan against the logical numbers unless you have measured your own. The four facts below are
what made the difference between a rebuild and a wasted afternoon.

1. **Keep `out/` off anything that is snapshotted or backed up.** The tree's `out` was a symlink
   to a filesystem no snapshot policy covered. A build writes hundreds of thousands of files, and
   an hourly snapshot pins every superseded block those writes produce: the pool climbs to full
   without anything you can point at. Two consequences of a symlink are worth remembering:
   **`rm -rf out` deletes the link, `rm -rf out/` follows it and deletes the real directory**, and
   if you build inside a container you must bind-mount the real path at **the same absolute path**
   - otherwise the build silently creates a real `out/` inside the tree and recompiles everything.
2. **Give the build a `TMPDIR` with roughly 20 G free.** The super-image and zip packaging stages
   accumulate about 17 G of temporary files; on a container whose root is an overlay that space
   comes out of whatever filesystem holds the overlay, and it is released only when the container
   exits.
3. **There is no ccache here.** Checking `out/soong/build.*.ninja` found the string `ccache` only
   as part of a file name (`bccache.py`), never on a command line, and `envsetup.sh` sets no
   `USE_CCACHE`. Incrementality is `out/` plus ninja. A leftover `CCACHE_DIR` explains nothing and
   makes a full rebuild look like a cache failure.
4. **Ask for the target you want.** `mka bacon` produces the flashable zip; a bare `mka` (or
   `droid`) rebuilds the images **without repacking the OTA zip**, so the build reports success
   while the zip keeps its previous hash. That symptom - "it built, but the artifact did not
   change" - is this, not a caching bug.

## 4. Build, then verify

```sh
sh patches/apply-all.sh /path/to/los24        # replay every change; idempotent
cd /path/to/los24
source build/envsetup.sh
lunch lineage_elish-cp2a-userdebug            # the target this project's builds used
mka bacon
sh tools/check-repo.sh                        # optional: this repository's own self-checks
```

Take the zip by its dated name (`lineage-24.0-<date>-UNOFFICIAL-elish.zip`), not by modification
time, and record three hashes - the zip, `boot.img`, `vendor_boot.img` ([flash.md](flash.md)
explains why, including the fact that `mka bacon` writes those dated names as hardlinks to one
inode, so an old-looking name can point at today's content). Then run
[acceptance.md](acceptance.md) before believing the build.

## 5. Signing

The builds documented here are signed with the AOSP test keys
(`build/make/target/product/security/platform.x509.pem`). Two things follow, and both were
measured on device:

- Flashing over a build signed with a **different** key requires wiping user data. That is not a
  bug in this ROM and no flag avoids it; it is how the platform verifies partitions.
- Once you publish a build, keep the key. Switching keys later turns an upgrade into a wipe for
  everyone who installed the first one, so a public build series should say plainly which key it
  uses - ours says test keys, so anyone building the same tree can produce a compatible update.
