# Flashing

Commands, not scripts: flashing and acceptance are deliberately bare `adb` / `fastboot`
invocations, so that every step is readable and each one can be re-run on its own. The only
script in this project's build path is the build entry point; there is no flashing script to
maintain, and a flashing mistake you can see is worth more than a script that hides it.

Two routes:

| | Route A: rebuild from the stock firmware | Route B: re-flash this ROM |
| --- | --- | --- |
| When | starting from HyperOS, or after a bad partition layout | every normal iteration |
| Data | **wiped** (the firmware package re-partitions) | kept |
| Parts | firmware partitions, `boot`, `vendor_boot`, ROM, GApps | ROM (+ GApps), and `boot`/`vendor_boot` only if the kernel changed |

## 0. Three confirmations, every time

```sh
adb devices                                    # exactly one device
adb shell getprop ro.product.device            # elish - this guards against flashing to the wrong tablet
adb shell getprop ro.boot.slot_suffix          # the booting slot; this is the only slot truth
```

An empty `adb devices` here is not a cable problem to chase in this document: a stock system
ships USB debugging off, and a line reading `unauthorized` means that system's own confirmation prompt
has not been accepted. Both are settled in the stock OS's settings.

`fastboot getvar current-slot` is **not** a slot truth on this device: its ABL has been
observed to answer `a` consistently in both the stock firmware and after flashing, and once
`b`. Use it only to decide "is it in fastboot at all". To decide *which ROM is running*, read
three things and cross-check: `ro.system.build.fingerprint` (not `ro.build.fingerprint`, which
the vendor side overwrites), `ro.lineage.version`, and `uname -r`.

## 1. Fastboot and recovery: seven rules, each paid for

1. Without udev rules, `fastboot` fails with a permission error - re-run the same command with
   `sudo`.
2. The first few commands after connecting often go unanswered (`getvar` returning
   `FAILED (remote: 'unknown command')`, or a timeout). That is the device's fastboot
   connection, not the command. Resend as-is; the second attempt usually answers. Do not read
   `GetVar Variable Not found` as "device not found".
3. If the device wedges - `fastboot devices` lists it but nothing answers `getvar`, `flash` or
   `reboot`, and a USB reset does not help - the only recovery is a power-key hold to force a
   restart into fastboot (which restarts the ABL). Re-flashing a partition that already
   succeeded is harmless, so resume the same command afterwards.
4. Flash with the slot-suffixed partition name (`boot_a`); fall back to the bare name only if
   that fails. `erase boot_ab` was measured to return `Check device console.`, and `_ab`
   operations have a hang on record.
5. Progress is redrawn with `\r`, so piping to `tail` shows nothing - that is not a hang. And
   **do not give a long flash a short timeout**: a host-side timeout interrupting the transfer
   is what triggers rule 3. Scale the timeout with the image.
6. Enter fastboot with the hardware keys (hold power ~15 s until power cuts, then
   power + volume-down). `adb reboot bootloader` has been measured to hang for five minutes and
   panic back into the system on the stock-kernel path. Distinguish `fastbootd` from bootloader
   fastboot with `fastboot getvar is-userspace`: `yes` means fastbootd, and the firmware and
   `boot` images want `no`.
7. In recovery, check state with a single `adb devices`: it must say **`sideload`** before you
   push. While it says only `recovery`, `adb sideload` is a `connection failed: closed` no-op.
   `adb reboot sideload` switches it from the host, so you need not touch the screen. And
   `adb wait-for-device` **does not return** in sideload state - it waits for `device`, which
   sideload never reports - so use it never, and `adb devices` once.

## 2. Route A: from the stock firmware (wipes everything)

Scope, stated once: every rule inside these steps is measured, and the route as a whole has now been
walked end to end - 2026-11-10, from a stock device, one pass, 31 firmware commands with no failures,
through to a booted system that reported the expected build and kernel. The walk also showed where
the steps and the firmware package disagree; those places are marked below rather than left for the
next person to find.

What the walk took, on a machine with the images on local disk, so nobody has to guess from the
package's size. `fastboot` is far faster than `adb sideload` on the same cable, so the two should not
be estimated from each other:

| Step | Time |
| --- | --- |
| Unpacking the 5.4 GB `.tgz` | 21 s |
| The 31 firmware commands, `super` included (7.5 GB, sparse, 11 chunks) | 4 min 40 s, of which `super` was 199 s |
| `boot` + `vendor_boot` into both slots | 15 s |
| ROM sideload (1.47 GB) | 2 min 30 s |
| GApps sideload (544 MB) | 31 s |
| First boot after a data wipe, to `sys.boot_completed` | about 3.5 min |

1. Flash the `HyperOS 1.0.2.0.TKYCNXM` fastboot package (CN firmware line). This re-partitions
   and clears all data and cannot be undone by flashing a ROM. Unpack the `.tgz` first; the
   directory it contains is what the next step needs, and `flash_all.sh` inside it must be run
   from that directory because its image paths are relative to it.

   The file this document was written against is
   `elish_images_OS1.0.2.0.TKYCNXM_20240507.0000.00_13.0_cn_f8476ce7cc.tgz`, 5.4 GB, MD5
   `f8476ce7cc2f9a87276bb62398903b2f`. Xiaomi's own links expire, so verify whatever copy you end
   up using against those two values - and the name carries a shortcut: **its last ten hex
   characters are the first ten of the file's MD5**, so a filename alone already says whether a
   download is the right one. [miuidownloader](https://miuidownloader.com/hyperos/elish/stable/os1-0-2-0-tkycnxm)
   is named here because it publishes both values for this version; other firmware indexes list
   the same version with neither, so they cannot be checked by name alone.

   Run the package's own list rather than `flash_all.sh` itself, for two measured reasons: it
   checks the product with `getvar` exactly once, and this ABL often does not answer the first
   command (rule 2), so the script exits by itself with `Missmatching image and device`; and it
   has no retry at all, while an occasional unanswered command is normal here. Transforming the
   list changes three things only - the script's own directory, the `getvar` self-check, and
   `_ab` → the current slot - and drops four partitions that exist for Xiaomi's own bookkeeping
   (`crclist`, `sparsecrclist`, `rescue`, `imagefv`):

   ```sh
   # this block works from either state: the getprop line answers when the system is booted, and
   # when it does not, the device is in fastboot and the getvar fallbacks answer instead
   d=/path/to/elish_images_OS1.0.2.0.TKYCNXM_13.0/   # the unpacked package, note the trailing slash
   slot=$(adb shell getprop ro.boot.slot_suffix | tr -d '\r' | sed -n 's/^_//p')
   # the getvar line appears twice on purpose, not a typo: this ABL often leaves the first
   # command unanswered (rule 2), and a wrong slot silently retargets every partition below
   [ -n "$slot" ] || slot=$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: //p')
   [ -n "$slot" ] || slot=$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: //p')
   sed -e 's|^fastboot \$\* |fastboot |' -e 's|`dirname \$0`|'"$d"'|g' \
       -e 's|^fastboot set_active |fastboot --set-active=|' \
       -e '/^fastboot /!d' -e '/getvar/d' -e '/^fastboot reboot$/d' \
       -e 's/_ab\b/_'"$slot"'/g' "$d/flash_all.sh" \
     | grep -vE "flash (crclist|sparsecrclist|rescue|imagefv_$slot) |erase imagefv_$slot" \
     > sta.list
   ```

   The slot is read from the running system rather than from `fastboot getvar`, for the reason given
   in section 1: this ABL's `current-slot` answer has not been trustworthy, and a wrong slot silently
   retargets every slotted partition in the list. If the device no longer boots, use the `getvar`
   fallback and read the derived list twice.

   **Reboot into the firmware's fastboot with the hardware keys (rule 6) first: every line below is
   a fastboot command.** Then read the list before running it, and run it one line at a time. It is a
   list of commands, not a script to hand to `sh`: a wrapper swallows the per-partition output, and
   that output is the only diagnosis a failed flash gives. Paste one line, read what it printed, then paste the next. When a
   line fails, re-send just that line - resending a partition that already succeeded is harmless
   (rule 3), which is what makes the retry safe however often it turns out to be needed.

   Two lines in the derived list deserve a look against the slot you actually wrote. The package's own
   script ends with `set_active a`, hard-coded (`flash_all.sh` line 84 of the version above): the
   transformation changes that command's **form**, not its argument, so a device whose slotted images
   went to `_b` would be told to boot a slot whose firmware was never written. Set it to the slot you
   wrote - the walk of 2026-11-10 ran `--set-active=b` for exactly that reason.
   The other line to check is a `gpt` one, if your package carries it. This version carries **no
   `gpt` line at all**, so none of the following applied to the walk. Where a `gpt` line is present,
   a `not found` for `gpt_backup$slot` on a device that has never re-partitioned is not a failure:
   that partition does not exist yet, and this very run creates it.

2. Once LineageOS is installed, do **not** re-flash the firmware package's `dtbo` or
   `vendor_dlkm`. They belong to the stock kernel, while the ROM's `boot` carries a different
   one, and a mismatch is a device that does not boot. If you must, flash both slots and reboot
   immediately.

3. Do **not** boot into the stock system to "verify" it. The firmware package provides the
   firmware and partition baseline and takes effect as soon as it is written. Keep it as a
   fallback argument: if LineageOS fails to boot, booting the freshly-flashed firmware
   successfully is what proves the problem is on the ROM side.

4. **Flash `boot` and `vendor_boot` into both slots - this is what gives you a recovery to install
   with.** This build has no `recovery.img`: the LineageOS recovery lives inside `vendor_boot`
   (`BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true` in
   `device/xiaomi/sm8250-common/BoardConfigCommon.mk`). Until those two are written the tablet
   still has the firmware package's own recovery, and step 5 then has nothing to enter. Both files
   are published next to the ROM zip; here, flashing both slots is the point rather than a
   precaution.

   ```sh
   for s in a b; do fastboot flash boot_$s boot.img; fastboot flash vendor_boot_$s vendor_boot.img; done
   ```

5. `fastboot reboot recovery` - after step 4 the tablet is in fastboot; use `adb reboot recovery`
   instead if it is booted. Then everything is on the screen: `Wipe → Format data/factory reset`
   (type yes), `Advanced → Enable ADB`,
   `Apply update → Apply from ADB`, sideload the ROM, then **in the same session** sideload
   GApps - the only hard condition is not to boot the system before GApps are in - then
   `Reboot system now`.

## 3. Route B: re-flash this ROM (keeps data)

**Take the zip by today's date, not by mtime.** `mka bacon` writes the same inode under
`lineage-24.0-<old date>`, `<new date>` and `lineage_elish-ota.zip`; picking by timestamp can
select the stale name (same content, misleading record). Record three hashes - ROM zip,
`boot.img`, `vendor_boot.img` - as "the artifact was not truncated or replaced" evidence for
the next round. `boot.img`'s hash changes every build from build noise alone, so it is not a
criterion; if the kernel did not change, `boot` and `vendor_boot` are not re-flashed at all.

**Decide about wiping `/data` from the `framework-res.apk` signing fingerprint**, read on both
sides at runtime (device and the new build's `out/`). Same fingerprint → same key → no format.
Different → every LOS system app changes signature → format is required. Both sides here use
the AOSP test key, so routine iterations do not wipe.

**Remove data-side test installs** of anything you are about to test (`pm path` prefers
`/data/app`, so a leftover install means you are not testing the image's copy):

```sh
MANAGER_PKG=com.example.manager            # the package name of the manager you installed
for pkg in "$MANAGER_PKG" org.lineageos.aperture; do
  adb shell pm path "$pkg" | grep -q /data/app/ && adb uninstall "$pkg"
done
```

`$ZIP` is the dated ROM zip - from your own build or from this project's release page. `$OUT`
is a build's output directory (`out/target/product/elish` under the tree) and appears in the one
**optional** command below, so a reader who downloaded the build needs neither the tree nor this
variable. Both must be absolute when used: `adb` stats its argument on the host, so a relative
path is an `rc=1` no-op.

```sh
ZIP=/path/to/lineage-24.0-20260101-UNOFFICIAL-elish.zip  # the dated name, not lineage_elish-ota.zip
OUT=/path/to/los24/out/target/product/elish              # optional step only
GAPPS_DIR=/path/to/packages                              # the directory holding the GApps zip
```

**Optional, and only when the kernel changed: give *both* slots the same `boot` and
`vendor_boot`.** The package carries both by itself - this build's payload writes `boot`,
`vendor_boot`, `dtbo`, `vbmeta`, `vbmeta_system`, `odm`, `product`, `system`, `system_ext` and
`vendor`, which is `AB_OTA_PARTITIONS` in `device/xiaomi/sm8250-common/BoardConfigCommon.mk` - but
into the slot it installs to, not the other one. So after a sideload the slot you boot has the
matching kernel, while the slot you did not boot keeps the kernel it had. That asymmetry is
measured rather than theoretical: `boot` was once flashed into `_a` and the device then booted
`_b`. Aligning the two slots removes the guesswork; the two images are in `$OUT` if you built, and
are published next to the zip if you did not.

```sh
adb reboot bootloader; sleep 8
for s in a b; do fastboot flash boot_$s "$OUT/boot.img"; fastboot flash vendor_boot_$s "$OUT/vendor_boot.img"; done
fastboot reboot recovery
```

**Sideload the ROM**, then **re-push GApps**:

```sh
adb reboot recovery
adb devices                  # must say sideload (rule 7); adb reboot sideload if not
adb sideload "$ZIP"
adb devices                  # if it still says sideload, push the next package right away
adb sideload "$GAPPS_DIR"/MindTheGapps-17.0.0-arm64-*.zip   # $GAPPS_DIR is where that zip is; keep it absolute
```

`failed to read command: Success` at the end of a sideload is normal. Between the two transfers the
recovery has a step of its own, and on 2026-11-10 it cost the first person through a detour: when the
ROM finishes, recovery asks whether it should restart itself. Answering `Yes` re-enters recovery, and
entering recovery turns the adb function off - so `Advanced → Enable ADB` is needed again before the
next package. If `adb devices` still says `sideload`, nothing has restarted and there is nothing to
re-enable: push the next package.

Which brings one rule with it. **Do not restart the adb server to fix a connection that already says
`sideload`.** Measured the other way round: `adb kill-server && adb start-server` on a healthy
`sideload` turned it into `unauthorized`, and only the screen could put it back.

**`unauthorized` inside recovery has one fix, and no prompt will arrive for it.** The reading met
on entering recovery (measured 2026-11-10) means the adb function is not enabled yet, and **this
recovery shows no "allow USB debugging" prompt, in no state and under no circumstances** - unlike
a booted system, where that popup is the normal next step. Nothing will reach the screen here
however long you wait. The only way in is
`Advanced → Enable ADB`, after which `adb devices` reads `sideload` directly. Re-entering recovery
after a finished transfer is the same case, for the same reason. Nothing a host does reaches either
one: a server restart is not a substitute for that menu item, and it cannot undo one.

GApps are **not optional after a ROM-only flash**: the ROM payload is a full `super` image, and
MindTheGapps installs into `system/`, which the payload rewrites wholesale. One moment needs a
human at the device, and its reason is signatures rather than paperwork: MindTheGapps signs with
its own key, which is not one of the keys recovery verifies against, so when that transfer finishes
recovery reports the mismatch and waits for confirmation - press **`Yes`** to continue the install
(wake the screen with a short power-key press if it went dark). It is a yes/no prompt, not a licence
page; there is no licence page anywhere in this flow. That is the only point in the whole flow where
someone has to be next to the tablet - within this route, and provided the two transfers go in
one recovery session: answer `Yes` to the restart question above and `Advanced → Enable ADB` needs
the screen again. Route A is a different matter; its wipe and menu steps are all on the screen.
Then `Reboot system now`. The GApps package this ROM was tested with - file name, hash and release page -
is the row marked GApps in [build.md](build.md).

**After first boot: install a manager.** The image delivers `ksud` and no manager APK, so root has
no interface until you do. Which APK matches this kernel, its pinned hash and the install command
are in [root.md](root.md); section 6 of [acceptance.md](acceptance.md) is the reading that tells
"ROM only" apart from "root set up".

## 4. Two regularities this device obeys

1. **A ROM-only sideload lands on the other slot.** Four consecutive observations of `_b`→`_a`→
   `_b`→`_a`→`_b`. The practical consequence is that a slot you assumed is not the booted one;
   read `ro.boot.slot_suffix` after booting (it is the truth) rather than inferring.
2. **After a ROM-only re-flash, GApps must be pushed again** (see above). Forgetting this is
   the most common cause of a "GApps disappeared" report that is not a regression.

A third, smaller one: `adb root` does not survive a reboot. Re-issue it after every boot
before anything that needs a root shell. On a fresh `/data` it also needs one setting first -
Settings → System → Developer options → **Rooted debugging** - because a new `/data` ships it off and
adbd refuses the command until it is on, naming the setting in its own error text.
