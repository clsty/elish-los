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
adb shell 'grep -F "Panel installed at" /data/local/tmp/boot-log.txt'
# Panel installed at 90 degrees: publishing one public device frame, v_public = Rz(+90) * v_hal, TYPE_DEVICE_ORIENTATION step +3
```

Camera, judged by facing (expect `BACK 0` and `FRONT 0`; the HAL block numbers are not camera ids):

```sh
adb shell dumpsys media.camera | grep -A1 -E "android.lens.facing \(80005|android.sensor.orientation \(e000e" \
  | grep -E "^\s{4,}\S" | paste - - | column -t
```

## 3. Sensor self-consistency (no hands on the device)

```sh
sh tools/framecheck/build.sh && adb install -r tools/framecheck/build/framecheck.apk
python3 tools/framecheck/check.py 12 "leaning at 45 degrees"
echo $?          # 0 = PASS, 3 = pose too flat (pipeline only), 2 = FAIL
adb uninstall com.framecheck
```

Pass: exit 0 with the worst angle well under the 2-degree threshold under the `R^T` convention,
and the `TYPE_ORIENTATION` pair check agreeing on pitch and roll. Reference readings from this
tablet: 0.00-0.01 degrees settled, and the two branches agreeing within 0.08 degrees.

## 4. Absolute direction (poses - these need hands)

Internal consistency cannot prove that direction zero is the direction you intend.

| Pose | Command | Expected |
| --- | --- | --- |
| Each of the four edges down, once each | `adb shell 'dumpsys sensorservice | grep -iE "gravity|accelerometer"'` or read the framecheck SNAP line | the gravity vector points down the edge that is physically down |
| Landscape, charger right | `adb shell 'dumpsys window | grep -m1 -o "mRotation=[0-9]*"'` | `mRotation=0` |
| Rotate to the other landscape | the same command | `3` (or `1`), and the UI follows |
| Landscape, **burst** of several photos | `adb shell 'dumpsys media.camera'` + EXIF of each saved frame | every photo's EXIF `Orientation` is `1`. One photo proves nothing: the symptom was two-state |

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
adb shell dumpsys connectivity | grep -oE "https?://[A-Za-z0-9._/-]*generate_204" | sort -u
adb shell dumpsys time_detector | grep -iE "ntp|Network suggestion|systemClockConfidence"
```

The last two need a working default route. Without one, `Network suggestion history: {Empty}` and
`systemClockConfidence()=0` are **precondition unmet, not judgements** (section 10). With a
connection, `ntp.aliyun.com` and `connect.rom.miui.com/generate_204` are the expected names. Run
once with the system language set to English.

## 8. GApps

```sh
for p in com.google.android.gms com.google.android.gsf com.android.vending; do printf '%-26s ' $p; adb shell pm path $p; done
```

All three must resolve to a path. The GApps major version must match the ROM's Android version.

## 9. SELinux baseline

```sh
adb shell 'dmesg | grep "avc.*denied"' | sed 's/.*avc:/avc:/' | sort | uniq -c
```

On this build there are ~13 denials at boot, all from vendor components and GApps (`getopt` on
`usap_pool_primary`, and similar). The judgement to make is a *set comparison*: none of them
should mention `ksu`, `/product/bin`, or any file this project adds. New denials for files this
project introduces are a real finding; the existing noise is not.

## 10. Readings that are not judgements

| Reading | Why it is not a failure |
| --- | --- |
| Touch mapper `mode - DISABLED`, `InputDeviceOrientation: Rotation0` | the screen was off; those are defaults |
| `Orientation: Rotation0` under the *Keyboard* Input Mapper | a different mapper, unrelated to touch |
| `verifiedbootstate=orange` on the first boot after wiping data, or after deleting `/data/adb/ksud` | nothing was seeded yet; it returns next boot |
| `su: inaccessible or not found` after reinstalling a manager | grants are keyed by uid; grant again in the manager |
| No crowning line while no manager is installed | there is nothing to crown |
| `Network suggestion history: {Empty}`, `systemClockConfidence()=0` with no default route | precondition unmet, do not judge |
| framecheck exit 3 with a small tilt | correct verdict for a flat pose: pipeline OK, side/sign untested |
| `user_rotation` not matching the app's direction | the system synchronizes it while an app forces a direction |
| `dmesg | grep -c …` for the three stages returns 0 hours after boot | the kernel ring buffer has wrapped; judge by the seeding result |
| `orange` and no dynamic-manager line on a ROM-only device | the susfs4ksu module is not installed; and a manager that matched one of the kernel's own keys adds no dynamic-manager line at all - judge it by the crowning line |

## 11. Not covered here

Any acceptance run should say what it skipped and why. Not covered on the build this document
describes, each with its reason:

| Item | Why it is not judged here |
| --- | --- |
| `su` granting | needs a manager, and the default form installs none; installing one changes its uid, so the grant has to be made in the app first. The `sucompat` path *is* covered: the three stages, the seeding, and the absence of `syscall 142` failures |
| KeyStore attestation | not measured. It is a separate channel from `verifiedbootstate`: a TEE-signed certificate carrying its own boot-state fields, anchored on hardware rather than on anything in this image. Section 6 judges the channels `adb` can reach; a verdict about attestation would need a client and a reference point, neither of which exists here yet ([root.md](root.md), "What this does not claim") |
| Captive portal 204 and NTP | no wireless network was configured on the test device, so the precondition was unmet |
| Power-state timings, Bluetooth, deep-power-down and reboot timing (the `A*` items of route A in [flash.md](flash.md)) | only meaningful after a change to `boot` / `vendor_boot`; this iteration changed neither |
