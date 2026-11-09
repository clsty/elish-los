# Root built into the ROM

Root here means a KernelSU-based kernel implementation compiled into this device's own
kernel, with the userspace half delivered by the system image. Nothing is flashed
separately, and nothing has to be installed to make root work.

There is a second, smaller root story in this project: `adb root` does not work on these
images by default, because LineageOS ships `userdebug` builds with `ro.adb.secure=1` and no
`adb_root` feature. The kernel-side patch adds it (`kernel/feature/adb_root.c`), which is why
`adb root` works here without unlocking anything else. It is mentioned here for completeness;
it is not part of what KernelSU provides.

## Why the kernel needs patching at all

`elish` ships a 4.19 kernel that is **not** GKI. KernelSU's zero-delta paths all assume GKI:

- The loadable-module route (`kernelsu.ko`) needs a GKI kernel image.
- The tracepoint hook (`KSU_TRACEPOINT_HOOK`) is rejected by KernelSU's Kbuild on a non-GKI
  2.0 kernel image format - measured, not inferred.
- `KSU_MANUAL_HOOK` would compile out the hook calls in the integration patch, because those
  calls sit inside an `ifdef` for SuSFS.

That leaves `KSU_SUSFS` (SuSFS inline hooking), which is also what root hiding needs, so it
is the choice on every axis at once. The integration itself is six files of the kernel
(`kernel/sys.c`, `fs/exec.c`, `fs/open.c`, `fs/stat.c`, `kernel/reboot.c`,
`drivers/input/input.c`) plus SuSFS and a config fragment; the patch is
`generated/kernel-xiaomi-sm8250-ksu-susfs.patch` and the reasons for each pinned value are
in its header.

Two version numbers must agree, and this is the part a reader is most likely to trip over:
ReSukiSU's `Kbuild` computes the kernel's `version code` as `30000 + <git rev-list count> +
700`. For the pinned commit that is `30000 + 4361 + 700 = 35061`. A manager APK of that
release carries the same `versionCode`, and the userspace refuses a mismatch. This is why
`patches/apply-root-changes.sh` insists on a clone with **full history**: a `--depth` clone
computes a different version code, and the check in that script fails loudly rather than
producing a ROM whose root does not start. The same Kbuild also tests that
`drivers/kernelsu/../.git` exists, so copying kernel files into `drivers/kernelsu` is
refused by the build itself.

## What the ROM delivers, and why it is only `ksud`

The image ships two files and nothing else:

| File | Mode | Role |
| --- | --- | --- |
| `/product/bin/ksud` | 0755 | the userspace daemon, from the manager APK's `lib/arm64-v8a/libksud.so` |
| `/product/etc/init/ksu-install.rc` | 0644 | seeds `/data/adb/ksud` from it, once, at `boot-completed` |

Taking `ksud` out of the manager APK is deliberate: it makes it impossible for the delivered
userspace to be a different release from a manager of that release, so installing an official
manager of the matching version always agrees.

Modes are worth knowing about: a partition's file modes come from `fs_config`, not from the
staging directory, so a binary delivered through `PRODUCT_COPY_FILES` arrives 0644 unless
`config.fs` says otherwise (measured: 0755 in `out/`, 0644 on device). `libksud.so` is
exec'd rather than `dlopen`'d, and a file without the execute bit cannot be exec'd even by
root, so that `config.fs` entry is load-bearing.

### Why an rc file has to seed the binary

The kernel's own appended `init.rc` execs `/data/adb/ksud` - a path under `/data`, at a
stage where nothing has been copied there yet. The ROM cannot write `/data` before that
point, and its own `init.rc` cannot run earlier. So the delivery is a two-step:

1. The image offers `/product/bin/ksud`.
2. `ksu-install.rc` copies it to `/data/adb/ksud` on every `boot-completed`, re-checking the
   hash each time, so a deleted copy comes back and a replaced image re-seeds the file.

The consequence is a **shape**, not a defect, and it is the single most common false alarm on
this ROM:

| Boot | Three-stage root | `verifiedbootstate` | Modules |
| --- | --- | --- | --- |
| First boot after a data wipe, or right after `/data/adb/ksud` is deleted | 0 hits | `orange` | not mounted |
| Every boot after that | 3 hits | `green` | mounted |

The first boot has nothing to exec, so the SuSFS module (mounted in the `post-fs-data`
stage) never runs, and the unlocked-state indicator stays `orange` for that one cycle.
Deleting `/data/adb/ksud` by hand reproduces it exactly. Both rows are in
[acceptance.md](acceptance.md).

Three details about the counts in that table, because they cause false failures:

- **What the three stages are.** The kernel's appended rc contains four `exec` lines
  (`KERNEL_SU_RC`, in `kernel/runtime/ksud_integration.c`): `post-fs-data`, `services` under
  `on nonencrypted`, `services` under `vold.decrypt=trigger_restart_framework`, and
  `boot-completed`. The grep counts the kernel's own log line, `for init executing ksud`
  (`kernel/feature/sucompat.c`), and on this device three of those four fire: an encrypted
  device takes one of the two `services` branches. **Three is the steady-state expectation,
  not four.**
- **The count is time-sensitive.** `dmesg` and `logcat -b all` are ring buffers, so hours into
  a boot those lines are gone and the count reads 0 while root itself is fine (measured here:
  both channels empty about 3.4 hours after boot, with the hash, the modules and `su` all
  normal). On an aged boot, judge by the seeding result instead: `/data/adb/ksud` present and
  equal to `/product/bin/ksud`, plus the module list.
- **A hit count is cheap evidence.** It shows `init` ran the line; it does not say what the
  child returned, and that child is what does the work.

## The default form: no manager preinstalled

`patches/apply-root-changes.sh` delivers `ksud` and installs **no** manager. That is a
privacy decision, not a shortcut: the usual way to hide root is to build the manager with a
package name and signing key of your own, and that name is the thing root-hiding relies on.
Baking it into a public image publishes it for everyone who downloads the ROM, and a manager
with the upstream package name is trivially recognizable.

So: install a manager of the matching release yourself - in practice `versionCode 35061`, the
release asset [ReSukiSU_v4.2.0-rc1_35061-arm64-v8a-release.apk](https://github.com/Baka-SU/BakaSU/releases/tag/v4.2.0-rc1) (SHA-256
`544cf6cb105acacf219b3db71e43b9818e3f335153763e56aa0356bd09d1b450`), which is the APK
`patches/apply-root-changes.sh` pins and takes `ksud` from, so the delivered userspace and that
manager are the same release by construction. A manager built with a signing key of your own works
too, and that is the form root hiding wants - read the recognition rule below before concluding
that root is broken because its screen does not appear.

```sh
adb install -r ReSukiSU_v4.2.0-rc1_35061-arm64-v8a-release.apk
adb shell 'dmesg | grep -i crowning'        # one Crowning manager line = the kernel found it
```

Which manager to install is a real choice, and the two answers are not equivalent:

- **The upstream APK** (the asset above) keeps the upstream package name. The module still hides
  the mount and cmdline side, but a detecting app can also just look for that name - and the name
  is the one thing the image cannot change for you. Root itself works the same. Such an APK is
  signed with a key the kernel carries built in, so it is *expected* to be recognised without
  registration - but that has not been measured on this device, so treat the crowning line below
  as the question, not as a formality.
- **A manager built with your own signing key and package name** is the form root hiding is about
  (see the reason nothing is preinstalled above). It is not in the kernel's key list, so it
  needs the one-time `set-apk` registration described under "Root hiding" - measured on this
  device, where it was crowned in the reserved slot.

The kernel finds the manager in `/data/app` by scanning APK paths - the path is parsed for the package name (the second-to-last path
segment) and the file must be named `base.apk`, which is why the *optional* preinstall form
below has constraints that look arbitrary.

The kernel change that teaches it the `/product/app` layout
(`generated/kernelsu-preinstalled-manager.patch`) is applied in **both** forms: the default
image's kernel already recognizes a manager preinstalled in `/product/app` and simply never
finds one. What the default form leaves out is the APK itself and the `config.fs` entries that
name it, so no package name reaches the image at all.

A manager can be preinstalled instead with `KSU_PREINSTALL_MANAGER=1`. That form needs three
things a partition APK demands, all measured:

- The Soong module is **named after the package** and the APK is imported as `base.apk`,
  because the kernel crowns the manager by parsing its APK path.
- `presigned: true` **and** `preprocessed: true` **and** `skip_preprocessed_apk_checks: true`:
  re-signing or re-zipping would break the APK's v2 signature, but `preprocessed` on makes
  the build insist its JNI libraries be uncompressed, and a release APK ships them compressed.
- The JNI libraries are additionally delivered as plain files next to the APK, because
  **nothing unpacks a partition APK**. Without them the measured failure is
  `libksud.so was not found in the application native library path`.

The two forms converge: re-running the script with the flag flipped retires the manager
material as a set (the old package name is read out of `Android.bp`, never hard-coded) and
rewrites the blocks it owns in `device.mk` and `BoardConfig.mk`. Those blocks are delimited
by markers and rewritten whole, which is what makes switching forms safe; the script refuses
to guess at the end of an unmarked block left by an older version, because guessing once
deleted everything to end of file.

## Root hiding, and how it is verified

### Where the hiding comes from

The ROM ships two files for root: `ksud` and `ksu-install.rc`. It ships no manager and **no
hiding**. Three of the readings people check for hiding come from things outside the image:

- **`verifiedbootstate=green` on both channels** comes from the KernelSU module `susfs4ksu`
  ([sidex15/susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module)), which rewrites the
  cmdline parameters (`spoof_cmdline=1`) and the matching properties. The kernel build carries SuSFS itself, but
  the policy - which path to hide, which parameter to spoof - lives in that module.
- **The manager being recognized** is a signature check, not a package-name check: the kernel
  compares each candidate against a built-in list of signing keys, and this build carries six of
  them (`CONFIG_KSU_MULTI_MANAGER_SUPPORT=y` in
  `arch/arm64/configs/vendor/xiaomi/ksu-susfs.config`). A manager signed with a key outside that
  list needs one extra command, once per install: `ksud kernel dynamic-manager set-apk`
  `<base.apk>`, which registers it in a reserved slot. It needs a root shell (it writes
  `/data/adb/ksu/.dynamic_manager`), and it takes the **installed** path, which `pm path <pkg>`
  prints - the kernel only accepts a file named `base.apk`. Whether a manager signed with one of
  the six needs it as well is not measured on this device, so judge recognition by the reading
  (`dmesg | grep -i crowning`), not by whether the command was run.
- Both live under `/data` (`/data/adb/modules`, `/data/adb/ksu/dynamic_manager.txt`), so a
  **factory reset or Format data removes them** and the readings go back to what a ROM-only
  device shows. Nothing in the image is wrong at that point; the setup simply has to be
  repeated.

So: after flashing the ROM alone, expect `orange` and no crowning line. The two things under
`/data` account for the rest separately: the module brings the two `green` readings, and
registration brings the dynamic-manager line - which a manager whose key is already in the
kernel's list does not need.

### Reading each mechanism

| Mechanism | Where it comes from | Reading that proves it ran |
| --- | --- | --- |
| Locked-state indication | the `susfs4ksu` module | `verifiedbootstate=green` **both** in `/proc/cmdline` **and** in `getprop ro.boot.verifiedbootstate`; `ro.boot.flash.locked=1`, `ro.boot.veritymode=enforcing` |
| SuSFS mount hiding | kernel SuSFS + that module | the module listed enabled by `/data/adb/ksud module list`; `ksu_susfs` present in `/data/adb/ksu/bin` |
| Manager recognition | the manager APK; `set-apk` if its signing key is not one of the kernel's six | `dmesg | grep -i crowning` shows exactly one `Crowning manager: <pkg>` line, and `SYS_SECCOMP, syscall 142` count is 0 (a manager that was not crowned dies on `reboot(2)`) |

The index in that line says which of the two paths registered it: 255 is the reserved slot for a
manager added through `set-apk`, while a key in the built-in list takes one of the 254 general
slots (`kernel/manager/apk_sign.c`).

With no manager installed at all, the first two rows still hold and there is nothing to crown
- the crowning line is absent, and that is the expected reading rather than a failure.

## `su` after reinstalling a manager

Authorization is keyed by uid. Reinstalling a manager (or letting a ROM-only flash remove a
preinstalled one and installing it again) changes its uid, so the old grants do not follow:
`su` from a shell then behaves exactly like an ungranted app - `/system/bin/sh: su:
inaccessible or not found` - until the manager grants it once. There is no `grant` subcommand
in `ksud`; the grant is a UI action. Do not read this as a regression.

## Criteria

Bare commands, with the expected readings, in [acceptance.md](acceptance.md) sections 6 and
10. The line that summarizes this document: on a steady-state boot, `dmesg | grep -c "for init
executing ksud"` equals 3, and `sha256sum /data/adb/ksud /product/bin/ksud` gives the same
hash twice. Both readings are time-sensitive in the way described in section 4.3, so on a
device that has been up for hours the second one is the proof and the first is a bonus.
