# On-device acceptance

Every claim in `docs/` reduced to a command and the value that makes it pass. All commands
are bare `adb`; nothing here needs a root shell unless the line says so (`adb root` is needed
after each boot - it does not survive a reboot - and on a fresh `/data` it first needs the Rooted
debugging switch, which [root.md](root.md) explains at its top).

One convention worth knowing before you run anything: a command that greps for an expected
string exits **1** when the string is absent, which is a pass criterion here, not a script
failure. `grep -c` prints `0` and also exits 1. The few blocks that are not bare `adb` need a
host with `python3`, `pillow`, `ffmpeg`, `numpy` and `scipy` (the sensor check in section 3 and
the mask detector in section 5). Section 3 asks for one more thing: `tools/framecheck` is built
from the prebuilts inside a LineageOS tree, so if you downloaded this ROM without building it, use
the `dumpsys sensorservice` reading section 4 gives for the same poses instead.

Read the last section too: several readings on this device are **not judgements** under
certain conditions, and mistaking one for a failure has cost more time than any real bug.

## 1. Identity

```sh
adb shell 'getprop ro.product.device; getprop ro.lineage.version; getprop ro.boot.slot_suffix; uname -r'
```

`elish`, the version you built, the slot you now believe is booted, and a kernel version string
whose localversion marks your build. `ro.build.fingerprint` is not usable here - the vendor
side overwrites it - use `ro.system.build.fingerprint` if you need a fingerprint.

## 2. Landscape: display, touch, sensors, camera

```sh
adb shell getprop ro.surface_flinger.primary_display_orientation       # ORIENTATION_90
adb shell grep -h primary_display_orientation /vendor/build.prop       # present in the image
adb shell 'dumpsys display | grep -m1 -o "installOrientation [0-9]"'    # installOrientation 1
```

The second line needs a root shell, and so does `ls -l /vendor/usr/idc/` further down: as uid 2000
both answer `Permission denied` (measured; the `ls` also logs `avc: denied { getattr }` on
`/vendor/usr/idc`, while the `grep` on `/vendor/build.prop` logged nothing). The rest of this section
is bare `adb`.

Touch and pen - **wake the screen first**, then read all five fields (the field-by-field
meaning is in [orientation.md](orientation.md)):

```sh
adb shell input keyevent KEYCODE_WAKEUP; sleep 2
for d in NVTCapacitiveTouchScreen NVTCapacitivePen; do
  echo "--- $d"
  adb shell dumpsys input | sed -n "/Device [0-9]*: $d/,/Device [0-9]*: /p" \
    | grep -E "Touch Input Mapper|Orientation: Rotation|RawToDisplay|InputDeviceOrientation"
done
adb shell ls -l /vendor/usr/idc/ | grep NVT
```

Pass: `mode - DIRECT`, `Orientation: Rotation90`, `InputDeviceOrientation: Rotation90`, a
`RawToDisplay` transform containing `ROTATE` (the pen additionally has `SCALE`, which is
normal), and both `.idc` files present in the partition.

The sensor device frame, one line at boot:

```sh
adb shell 'nohup logcat -v time > /data/local/tmp/boot-log.txt 2>&1 &'   # start as soon as adbd answers
adb exec-out cat /data/local/tmp/boot-log.txt | grep -F "Panel installed at" | grep -vF adbd
# Panel installed at 90 degrees: publishing one public device frame, v_public = Rz(+90) * v_hal, TYPE_DEVICE_ORIENTATION step +3
```

Exactly one line, and read it this way rather than with `adb shell grep`: the capture records every
command `adbd` is asked to run, so a device-side `grep` for this phrase writes its own echo into the
file and every later read counts that echo too (measured: 5 matches after three greps, one of them
real). `cat` matches nothing, and the last `grep` drops the echoes an earlier run left behind.
`orientation.md` explains why the capture has to start at the first `adbd` answer rather than after
boot completes.

Camera, judged by facing (expect `BACK 0` and `FRONT 0`; the HAL block numbers are not camera ids):

```sh
adb shell dumpsys media.camera | grep -A1 -E "android.lens.facing \(80005|android.sensor.orientation \(e000e" \
  | grep -E "^\s{4,}\S" | paste - - | column -t
```

## 3. Sensor self-consistency (needs a pose, nothing else)

```sh
sh tools/framecheck/build.sh && adb install -r tools/framecheck/build/framecheck.apk
python3 tools/framecheck/check.py 12 "leaning at 45 degrees"
echo $?          # 0 = PASS, 3 = pose too flat (pipeline only), 2 = FAIL, 1 = nothing collected
adb uninstall com.framecheck
```

Pass: exit 0 with the worst angle well under the 2-degree threshold under the `R^T` convention,
and the `TYPE_ORIENTATION` pair check agreeing on pitch and roll. Reference readings from this
tablet: 0.00-0.01 degrees settled, and the two branches agreeing within 0.08 degrees. Measured
again 2026-11-10 on the cold-installed build at a 48.9 degree tilt: worst angle 0.01.

The heading says a pose, not "no hands": the tablet has to be leaning. That is not decoration -
with the tablet nearly flat, an error in a rotation about z does not move the world-frame gravity
vector, so it cannot be seen, and the script says so (exit 3) rather than passing quietly.

Exit 1 means the app logged no sensor snapshots, which is almost always the screen rather than the
sensors: with the keyguard up, the activity starts behind it and is paused before it registers a
listener, so the log holds `BEGIN`, a few `PROBE` lines and `END`. The script now wakes the device
and sends `wm dismiss-keyguard` itself (measured from a dozing, locked device: exit 1 before, exit 0
after). A screen timeout in the middle of the run pauses the activity the same way.

## 4. Absolute direction (poses - these need hands)

Internal consistency cannot prove that direction zero is the direction you intend.

| Pose | What to read | Expected |
| --- | --- | --- |
| Each of the four edges down, once each | the gravity vector (the framecheck `SNAP` line is the live one; see the two reading notes below) and `mCurrentRotation` | the axis that reads `+1 g` is the edge physically **up**, and the rotation index is the one that pose deserves |
| Landscape, charger right | `adb shell 'dumpsys window' \| grep -m1 -o "mCurrentRotation=[A-Z_0-9]*"` | `ROTATION_0` |
| Rotate to the other landscape | the same command | `ROTATION_180`, and the UI follows |
| Landscape, **burst** of several photos | EXIF of each saved frame (`/sdcard/DCIM/Camera`) | every photo's EXIF `Orientation` is `1`. One photo proves nothing: the symptom was two-state |

Measured 2026-11-10 on the cold-installed build, four edges, one pass through all of them. Gravity is
the mean of the settled frames of each pose (24-28 frames per pose, sampled at 400 ms), and
`device_orient` is the enumeration the framework itself settled on:

| Edge up | gravity | `device_orient` | `mCurrentRotation` |
| --- | --- | --- | --- |
| natural landscape (charger right) | `-0.03, +9.80, +0.38` | `0` | `ROTATION_0` |
| the P-key short edge | `-9.73, +0.71, +0.43` | `3` | `ROTATION_270` |
| the connector long edge | `-0.18, -9.77, +0.59` | `2` | `ROTATION_180` |
| the charger short edge | `+9.72, -0.58, +0.09` | `1` | `ROTATION_90` |

Every pose measures about 9.8 with `z` near zero (the screen plane was vertical, so the axis
assignment is not ambiguous), and each `device_orient` transition lands within a second of the
matching rotation change. Four photos taken in landscape at the same sitting carry EXIF
`Orientation: 1` with the pixels already 4160x2368 - stored upright, not rotated on read.

Two reading notes, both found by being wrong first:

- **`mRotation=[0-9]*` matches the wrong thing.** The dump contains
  `overrideConfig={… mRotation=ROTATION_0}` *before* the numeric `mRotation=0` line, so a `-m1` grep
  for digits stops there and prints a bare `mRotation=` - an empty reading that looks like a failure.
  `mCurrentRotation` appears exactly once in `dumpsys window` and is the current value; the
  `sensor=ROTATION_…` lines under `OrientationSensorJudge` are a history of fallback slots, not a
  verdict.
- **`gravity` in `dumpsys sensorservice` can be hours old.** Those "last events" belong to whoever
  subscribed last; with nothing subscribed, the block still prints - measured reading an hour-old
  leaning pose while the tablet lay flat. Check the `wall=` timestamp, or get a live value from the
  `framecheck` `SNAP` lines, which are produced while the app is subscribed.

One spelling note for greps that run **on the device** (inside `adb shell '…'`): its grep is toybox,
which has no `\|` alternation in either syntax - BRE rejects it and ERE reads it as a literal bar -
so both `"a\|b"` forms match nothing and look like an empty result rather than an error. Write
`-E "a|b"`. Greps after an unquoted `adb shell cat …` run on the host, where GNU grep accepts `\|`,
which is why the blocks in section 5 are spelled that way and are correct.

## 5. Camera app

```sh
adb shell dumpsys platform_compat | grep -o "ChangeId(236283604[^)]*packageOverrides={[^}]*}" | head -1
# expect org.lineageos.aperture=true
```

Geometry - lock the rotation, cold-start, read bounds, then restore:

```sh
adb shell 'settings put system accelerometer_rotation 0; settings put system user_rotation 3'
adb shell am force-stop org.lineageos.aperture
adb shell input keyevent KEYCODE_WAKEUP; adb shell wm dismiss-keyguard
adb logcat -c
adb shell am start -n org.lineageos.aperture/.CameraActivity >/dev/null; sleep 9
adb shell 'dumpsys window | grep -m1 -o "mDisplayRotation=ROTATION_[0-9]*"'
adb shell uiautomator dump /sdcard/w.xml && adb shell cat /sdcard/w.xml | tr '>' '\n' \
  | grep -E 'viewFinder|cameraModeSelectorLayout|shutterButton' \
  | grep -o 'resource-id="[^"]*"\|bounds="\[[0-9,]*\]\[[0-9,]*\]"' | paste - -
adb logcat -d | grep -c 'Ignoring manifest-declared fixed orientation'
adb shell 'settings put system accelerometer_rotation 1; settings put system user_rotation 0'
```

Pass: `mDisplayRotation=ROTATION_0`; `viewFinder` bounds `[0,0][2133,1600]`; the sidebar
starting at `x=2133`; the shutter inside that sidebar; and zero "Ignoring …" lines.

The mask, four states (16:9 and VIDEO draw it, 4:3 and SCAN do not) - detected, not eyeballed:

```sh
adb shell am force-stop org.lineageos.aperture
adb shell input keyevent KEYCODE_WAKEUP; adb shell wm dismiss-keyguard
adb shell am start -n org.lineageos.aperture/.CameraActivity >/dev/null; sleep 9
adb exec-out screencap -p > v_43.png       # state 1: the ratio in effect (4:3 after a first boot)
# The ratio and mode controls are reached through the secondary bar; read its bounds rather than
# hard-coding a coordinate, since the point that matters is "what did the app actually lay out":
adb shell uiautomator dump /sdcard/q.xml >/dev/null
adb shell cat /sdcard/q.xml | tr '>' '\n' | grep -E 'aspectRatioButton|cameraModeSelector' \
  | grep -o 'resource-id="[^"]*"\|bounds="\[[0-9,]*\]\[[0-9,]*\]"' | paste - -
adb shell input tap "$X" "$Y"              # centre of the aspect-ratio button, then pick 16:9
adb exec-out screencap -p > v_169.png
```

Assign `$X` and `$Y` from the bounds you just printed, using the button's centre:

```sh
X=$(adb shell cat /sdcard/q.xml | tr '>' '\n' | grep aspectRatioButton \
  | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1 \
  | sed 's/.*\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \2 \3 \4/' \
  | awk '{print int(($1+$3)/2)}')
Y=$(adb shell cat /sdcard/q.xml | tr '>' '\n' | grep aspectRatioButton \
  | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1 \
  | sed 's/.*\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \2 \3 \4/' \
  | awk '{print int(($2+$4)/2)}')
```

The two remaining states are camera **modes**, reached by swiping the mode strip (its bounds are
`cameraModeSelectorLayout`, printed above) leftwards along its own axis, then capturing:

```sh
adb shell input swipe "$((X-20))" "$Y" "$((X-900))" "$Y" 300    # swipe the strip; X,Y are any point on it
adb exec-out screencap -p > v_video.png
# capture twice if you are not sure the mode took: check the strip's selected entry in a fresh dump
# swipe back to PHOTO, then to SCAN the same way:
adb exec-out screencap -p > v_scan.png
```

If a mode is not reached, leave that row out rather than reading it as `none`: an
unreached state and a state without a mask produce the same output.

```sh
python3 - <<'PY'
import subprocess
def lines(png):
    subprocess.run(['ffmpeg','-loglevel','error','-y','-i',png,'-vf',
                    'crop=2133:1600:0:0,scale=533:400','-pix_fmt','gray','-update','1','/tmp/t.pgm'],check=True)
    d=open('/tmp/t.pgm','rb').read(); w,h=map(int,d.split(b'\n',2)[1].split())
    px=d[-w*h:]; rows=[sum(px[y*w:(y+1)*w])//w for y in range(h)]
    return [y*4 for y in range(2,398) if rows[y]>170 and rows[y]-rows[y-1]>60]
for nm in ('v_43','v_169','v_video','v_scan'):
    print(nm, lines('%s.png'%nm) or 'none')
PY
```

Pass: `[200, 1396]` for 16:9 and VIDEO, `none` for 4:3 and SCAN. Restore afterwards: SCAN →
PHOTO, ratio back to 4:3, collapse the bar.

## 6. Root, without a manager installed

```sh
adb shell 'ls -l /product/bin/ksud; ls -l /product/etc/init/ksu-install.rc'
MANAGER_PKG=com.example.manager   # the package name of the manager you installed
adb shell "ls /product/app | grep -i su; pm path $MANAGER_PKG"   # both empty in the default form
adb shell 'dmesg | grep -c "for init executing ksud"'                      # 3 on a steady-state boot
adb shell 'sha256sum /data/adb/ksud /product/bin/ksud | cut -c1-16 | uniq -c'   # 2  <same hash>
adb shell '/data/adb/ksud -V; ls /data/adb/ksu/bin'                        # version; ksu_susfs present
adb shell '/data/adb/ksud module list'                                     # your modules, enabled
```

Root hiding. **These next five lines assume two things the ROM does not provide**: the
susfs4ksu KernelSU module is installed, and a manager the kernel recognizes is installed - which
for a manager signed with a key outside the kernel's built-in list means registering it once with
`/data/adb/ksud kernel dynamic-manager set-apk <base.apk>`, run as root ([root.md](root.md) has the
rule, the command and why `su` is a prerequisite rather than a formality). On a device that has the ROM only, or after a factory reset, expect `orange` and
no dynamic-manager line, and treat that as the precondition missing rather than as a failure.

The root channel itself, worth one line before debugging anything below it - probe with the **read**
subcommand, since `set-apk` would change the registration you are trying to verify. If `adb root`
answers `ADB Root access is disabled by system setting - enable in Settings -> System -> Developer
options` and `id -u` stays `2000`, that is the switch named above rather than a broken build.

```sh
adb root; adb shell 'id -u; id -Z'                       # 0  u:r:su:s0 (adbd's own --root_seclabel)
adb shell '/data/adb/ksud kernel dynamic-manager get'    # reads the registration; changes nothing
```

An unregistered device does not answer with rc 0. Measured on a cold-installed device that had a
manager installed and nothing registered, the ioctl itself fails:

```
$ adb shell '/data/adb/ksud kernel dynamic-manager get'
Error: No data available (os error 61)        # rc=1, i.e. ENODATA
```

So the three readings each name their own cause, and telling them apart saves the wrong diagnosis:

| Reading | What it means |
| --- | --- |
| rc **127**, `inaccessible or not found` | You are not root. `/data/adb` is `0700 root`, so uid 2000 cannot resolve the path - do not go looking for an avc denial in this case |
| rc **1**, `Error: No data available (os error 61)` | The channel is open and you are root; nothing is registered. This is the *correct* answer for a manager whose signing key the kernel carries built in |
| rc **0**, `size: …, hash: …` | A dynamic manager is registered |

```sh
adb shell 'cat /proc/cmdline' | grep -o 'verifiedbootstate=[a-z]*'   # green, needs spoof_cmdline=1
adb shell getprop ro.boot.verifiedbootstate                          # green, the module's default
adb shell 'getprop ro.boot.flash.locked; getprop ro.boot.veritymode'  # 1, enforcing
adb shell 'dmesg | grep -i crowning'                                  # one line with your package
adb shell 'dmesg | grep -i "dynamic manager" | tail -1'               # injection happened
```

What those first three lines are reading has been measured here, and it is worth knowing before a
reading is called a regression. With the module absent (a cold install, or after `Format data`):
`orange` on both channels, and `ro.boot.flash.locked`, `ro.boot.veritymode` and
`ro.boot.vbmeta.device_state` all empty. With it installed and enabled, an unprivileged shell
(`u:r:shell:s0`) reads `green`, `1`, `enforcing`, `locked`. `fastboot getvar unlocked` answers `yes`
on this device, so `orange` is its ordinary boot state and nothing in either flash route changes it.

One switch decides whether the first line of that block passes. The module's
`/data/adb/susfs4ksu/config.sh` ships `spoof_cmdline=0`, while the property channel is spoofed with
no configuration at all - so a device that answers `green` from `getprop` and `orange` from
`/proc/cmdline` is not half broken, it is running the default configuration. Set
`spoof_cmdline=1` and reboot to close the second channel. `uname -r` behaves the same way one level
down: it keeps the build's own kernel string until `spoof_uname` is set.

With no manager installed there is nothing to crown, so the crowning line is *absent*, which is
the expected reading for that state; the rows above it are still judgements, and they
should still pass. The index in a crowning line says which path recognised the manager, and both
have been read here: `signature_index=255` is the reserved slot for a dynamic manager, so seeing it
means `set-apk` did its job, and `signature_index=0` means one of the kernel's own signing keys
matched and nothing had to be registered.

Both `dmesg` greps here and in the block above are time-sensitive: the kernel ring buffer
forgets, so hours into a boot they read empty while everything is working. On an aged boot,
read `uptime` first and judge root by the seeding result and the module list.

**The seeding cycle** (worth running once, because it is the shape of this delivery):

```sh
adb shell 'rm -f /data/adb/ksud'; adb reboot
```

Expected on that boot: three-stage count `0`, `verifiedbootstate=orange`, no modules mounted,
`/data/adb/ksud` present again with the image's hash (re-seeded at `boot-completed`, with
`mark no sucompat checks … exec: '/product/bin/ksud'` in the kernel log as the direct
evidence). On the **next** boot all three return to normal. One `orange` round is the designed
behaviour of a fresh `/data`, not a regression.

`su` from a shell - optional, because it needs a manager, and the default form installs none:

```sh
adb unroot; sleep 4; adb wait-for-device; adb shell su -c id
```

`su: inaccessible or not found` is the correct reading for an app that has not been granted -
and after reinstalling a manager the uid changed, so old grants do not apply. Grant once in the
manager UI, then expect `uid=0(root)` in the `ksu` domain: `id -Z` reads `u:r:ksu:s0`, **not** the
`u:r:su:s0` that `adb root` reports, because the two routes are different - one is KernelSU granting
a uid, the other is adbd's own `--root_seclabel`. Measured 2026-11-10 on both branches.

## 7. Network

```sh
adb shell 'cmd overlay list' | grep -E "android.framework_res.overlay.elish|com.android.networkstack.overlay.miui"   # both [x]
adb shell settings get global captive_portal_http_url        # null (a value here would shadow the config)
adb shell dumpsys network_stack | grep -oE "https?://[A-Za-z0-9._/-]*generate_204" | sort -u
adb shell dumpsys time_detector | grep -iE "ntp|Network suggestion|systemClockConfidence"
```

The 204 address is read from **`network_stack`, not `connectivity`**: on this Android version the
NetworkStack service owns the probes, and `dumpsys connectivity` contains no `generate_204` and no
`captive`/`portal` line at all (measured 2026-11-10 - reading the wrong service looks like a missing
endpoint). `dumpsys network_stack` also carries the probe itself, which is the stronger evidence:
`PROBE_HTTP http://connect.rom.miui.com/generate_204 ... ret=204`.

The last two need a working default route. Without one, `Network suggestion history: {Empty}` and
`systemClockConfidence()=0` are **precondition unmet, not judgements** (section 12). With a
connection, `ntp.aliyun.com` and `connect.rom.miui.com/generate_204` are the expected names. Run
once with the system language set to English.

Measured 2026-11-10 on a cold-installed device, which is a useful case because its UI is English by
default (`ro.product.locale=en-US`, `persist.sys.locale` empty): the portal probe answered
`http://connect.rom.miui.com/generate_204 ... ret=204` and the clock came from
`ntp.aliyun.com/203.107.6.88:123` with `systemClockConfidence()=100`. Two CN endpoints under an
English UI - that is the independence claim seen from this side.

## 8. GApps

```sh
for p in com.google.android.gms com.google.android.gsf com.android.vending; do printf '%-26s ' $p; adb shell pm path $p; done
```

All three must resolve to a path. The GApps major version must match the ROM's Android version.

## 9. SELinux baseline

```sh
adb shell 'dmesg | grep "avc.*denied"' | sed 's/.*avc:/avc:/' | sort | uniq -c
```

On this build there are ~13 distinct denials at boot, all from vendor components and GApps
(`getopt` on `usap_pool_primary`, and similar), and the count grows with what you ask the device to
do, so read the set, not the number. The judgement is a *set comparison*: none of them
should mention `ksu`, `/product/bin`, or any file this project adds. New denials for files this
project introduces are a real finding; the existing noise is not.

Your own probes appear in this set, and it helps to know which ones do. Reading `/data/adb` or
`/vendor/usr/idc` as the shell user adds a `getattr` denial each time (measured: `ls` on either path
produced one). Running `/data/adb/ksud` without root adds **none** - measured 24 denials before the
probe and 24 after, because `/data/adb` is `0700 root` and the permission check refuses the path
before SELinux is consulted. That absence is the point: the `127` in section 6 has no avc line to
find, so a search for one there is a dead end.

## 10. KeyStore attestation - the channel the spoofing does not reach

Root hiding rewrites what processes can *read*. An attestation is different: the fields travel inside
a signed structure, so rewriting properties does not touch them. That makes it worth its own
judgement, and it is also why an app that checks root through attestation can still see what the
properties no longer say.

No tool on the device can produce one. `keystore_cli_v2` has no attestation command, its 22 brillo
tests contain none, `generate` leaves the attestation fields out of `get-chars`, and `export` returns
a self-signed 803-byte certificate - because asking for an attestation means
`setAttestationChallenge()`, which is app-facing. So `tools/attestcheck/` is a 12 KB app that asks,
plus a script that reads the answer back:

```sh
sh tools/attestcheck/build.sh && adb install -r tools/attestcheck/build/attestcheck.apk
python3 tools/attestcheck/check.py 8
echo $?          # 0 = chain with our challenge; 2 = not (reason printed); 1 = nothing ran
adb uninstall com.attestcheck
```

Three things are being judged, and they are separate:

1. **Mechanics.** A chain of two or more certificates whose leaf carries extension
   `1.3.6.1.4.1.11129.2.1.17` with the challenge from this run inside it. One certificate is not an
   attestation - that is the self-signed public-key certificate you get when no challenge was asked.
2. **What it says about the device.** `ROOT_OF_TRUST` carries `deviceLocked`, `verifiedBootState`,
   `verifiedBootKey` and `verifiedBootHash`. On this unlocked device the answer is
   `deviceLocked=False`, `verifiedBootState=UNVERIFIED` with `verifiedBootKey` all zero bytes -
   *including while the susfs4ksu module is installed and enabled*, because spoofing reaches the
   properties and the cmdline, not this. Read the zero key as part of the answer rather than as a
   contradiction: a key of all zeros means no root-of-trust value reached the signer at all, which is
   what `UNVERIFIED` says in another field. What the judgement needs is that this channel does not
   report `VERIFIED` and `deviceLocked=True`, whatever the properties say.
3. **What it is worth.** `attestationSecurityLevel` and the root of the chain. Both carry findings
   that belong in the report beside the mechanics, and neither is a failure of this build: the root
   is self-signed, so there is no external trust anchor for a verifier to check against, and the
   reported security level is `SOFTWARE` while the certificates' own names say `TEE`.

Which component answers is worth knowing before interpreting either label. The reading came from
`/vendor/bin/hw/android.hardware.keymaster@4.0-service-qti` (a HIDL HAL, and `keymasterVersion 41` =
4.1 agrees with that), which holds `/dev/qseecom` open - so the key material sits with the vendor
side, not in this image. That is also why the extension is Keymaster-shaped: the tag numbers below
are KeyMint's, taken from the tree's `Tag.aidl`, and they decode this structure correctly.

Measured 2026-11-10 on the cold-installed build, with the module installed and `spoof_cmdline=1`:
chain of 4 (`CN=Android Keystore Key` <- `title=TEE` <- `title=TEE` <- a root whose DN is a bare
`serialNumber`, self-signed); `attestationVersion 3`, `keymasterVersion 41`, both security levels
`SOFTWARE`, `ORIGIN 0`; `deviceLocked=False`, `verifiedBootState=UNVERIFIED`, `verifiedBootKey` all
zero bytes, `verifiedBootHash` non-zero; `OS_VERSION 170000`, `OS_PATCHLEVEL` and `BOOT_PATCHLEVEL
202610`, `VENDOR_PATCHLEVEL 20250401`; `ATTESTATION_APPLICATION_ID` naming the test package. In the
same minute, an unprivileged shell read `ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`,
`ro.boot.veritymode=enforcing` and `verifiedbootstate=green` on the cmdline. **The two channels
disagreed, in the direction the hiding intends** - the attestation still shows an unlocked device, so
an app that consults it sees what the properties no longer say.

Two traps met while reading the structure, both already handled by `check.py` but worth knowing if
you go at it by hand:

- `openssl x509 -ext 1.3.6.1.4.1.11129.2.1.17` answers **"No extensions in certificate"** on this
  leaf even though the extension is there; `openssl asn1parse` does see it. Locate it there.
- Tag numbers are the low 28 bits of the enum values in the tree's
  `android/hardware/security/keymint/aidl/.../Tag.aidl` (`PURPOSE = 536870913` -> 1). Reading them
  from memory was wrong twice over: `ROOT_OF_TRUST` is **704**, not 708, and `ATTESTATION_CHALLENGE`
  is 708.

## 11. Power-state and radio behaviour

This is the kernel's side of the ledger, and nothing else here touches it. The kernel in `boot.img` is
built from these sources, and the branch this device used before (`Astide`) carried a reboot defect that
reproduced every single time, along with changes to shutdown and Bluetooth. So these four rows exist to
catch a regression that no property or dumpsys reading would show.

| Item | Judgement | Status |
| --- | --- | --- |
| Reboot to boot | one measurement, **≤120 s** and no power-key hold needed. One run is the judgement, *not* best-of-three: what this guards reproduces every time, so "three runs, one pass" would read looser than the defect | measured 2026-11-10 on the cold-installed build: **36 s** (two further runs under the older ×3 wording: 37 s and 35 s) |
| Software power-off really cuts power | after ~60 s the screen is dark and the device no longer enumerates on USB at all | judged by the owner's own test on an earlier build (2026-11-04); not re-run on this build. Power-off entered from recovery's menu was dropped as a separate check (2026-11-10): it asks for exactly these two readings, only reached from a different entry point, so it was redundant rather than unmeasured |
| Drain: 60 min off, 60 min with the screen off | ≤1% and ≤2% respectively, and no growth in `suspend_stats`' `failed_resume*` | waived by the owner's judgement (2026-11-04): the power-off row above already proves the power-off path, and the two hour-long windows were judged to add nothing |
| Bluetooth controller | pairs, and reconnects after a reconnect of the link; when it fails, the evidence route is the HCI log (developer options -> Bluetooth HCI snoop) | measured by the owner's own test on an earlier build (2026-11-04), once on a fresh `/data` (a true first pairing) and once as a reconnect |

The reboot measurement is two commands and takes under a minute, so it is worth re-running on any build
that changes `boot`:

```sh
t0=$(date +%s); adb reboot; adb wait-for-device
while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do sleep 2; done
echo "$(( $(date +%s) - t0 ))s"           # expected <= 120, and no power key touched
```

## 12. Readings that are not judgements

| Reading | Why it is not a failure |
| --- | --- |
| Touch mapper `mode - DISABLED`, `InputDeviceOrientation: Rotation0` | the screen was off; those are defaults |
| `Orientation: Rotation0` under the *Keyboard* Input Mapper | a different mapper, unrelated to touch |
| `verifiedbootstate=orange` with the `susfs4ksu` module absent (a wipe, or the module disabled) | `orange` is this device's real boot state; `green` is what the module writes, so removing it removes the `green`, permanently, not just for one boot |
| `su -c id` fails for a uid that worked yesterday | that uid has no grant. Grants live in `/data/adb/ksu/.allowlist`, keyed by **package name** (the file holds `com.android.shell`) and loaded once at boot, so a manager reinstalled under the same name keeps them and a differently-named one starts with none; editing the file mid-boot changes nothing. Judge by `su -c id`, not by `command -v su` - the latter still resolves to `/system/bin/su` with no grant at all |
| No crowning line while no manager is installed | there is nothing to crown |
| `Network suggestion history: {Empty}`, `systemClockConfidence()=0` with no default route | precondition unmet, do not judge |
| framecheck exit 3 with a small tilt | correct verdict for a flat pose: pipeline OK, side/sign untested |
| framecheck or attestcheck exit 1, no lines from the app | the app never ran to completion: not installed, or the screen was asleep and the activity was paused before it registered anything. The scripts wake and unlock the device, so check the install first |
| `user_rotation` not matching the app's direction | the system synchronizes it while an app forces a direction |
| `dmesg | grep -c …` for the three stages returns 0 hours after boot | the kernel ring buffer has wrapped; judge by the seeding result |
| `orange` and no dynamic-manager line on a ROM-only device | the susfs4ksu module is not installed; and a manager that matched one of the kernel's own keys adds no dynamic-manager line at all - judge it by the crowning line |

## 13. Not covered here

Any acceptance run should say what it skipped and why. Not covered on the build this document
describes, each with its reason:

| Item | Why it is not judged here |
| --- | --- |
| `su` granting | granting happens in a root manager's own UI, and the default form ships no manager (`ksud help` on this build lists no `grant` subcommand), so no command in this document can perform it - and installing a manager changes the unit under test. What *is* measured is where a grant lands and what follows: `/data/adb/ksu/.allowlist`, keyed by package name, loaded once at boot, and it survives reinstalling the manager under the same name (section 6). The test device was granted for `com.android.shell` and that grant was read back |
