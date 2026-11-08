# Natural landscape on a panel mounted portrait

## The problem, stated once

The Pad 5 Pro's panel is mounted physically **portrait**: its electrical coordinate system is
`X 0..1599 / Y 0..2559`, and the natural orientation the platform derives from that is
portrait. Nobody holds a 13-inch tablet in portrait. The posture this device is used in is
"facing the screen, charger on the right, keyboard contacts at the bottom".

Making that posture direction zero is not one setting. Four subsystems each have their own
notion of which way is up, and they are configured from three different places. If only some
of them move, you get a device whose boot animation is landscape while its touch is offset,
or whose auto-rotate works while a game's gravity is sideways. So the first thing to
understand is which knob each subsystem reads.

## The model

| Subsystem | Knob | Where it is set | Proof it took effect |
| --- | --- | --- | --- |
| Display (SurfaceFlinger) | `ro.surface_flinger.primary_display_orientation=ORIENTATION_90` | `vendor.prop` in the device tree, so it lands in `/vendor/build.prop` | `installOrientation 1` in `dumpsys display` |
| Input (touch, pen) | `touch.orientation = ORIENTATION_90` | `idc/*.idc`, copied to `/vendor/usr/idc` | `InputDeviceOrientation: Rotation90` and a `RawToDisplay` transform containing `ROTATE` |
| Sensors (everything an app sees) | one public device frame published by `SensorService` | `frameworks-native-device-frame-transform.patch` (+ `frameworks-av-sensor-orientation.patch`) | one boot log line naming the angle, and the cross-type check below |
| Camera (per-sensor mounting) | `android.sensor.orientation`, judged **by facing** | unchanged: both `BACK` and `FRONT` report `0` | `dumpsys media.camera` per-facing pairs |

The display row is the source of truth for the other three: the install angle is *one* number,
and the sensor patch propagates it into the sensor device frame instead of letting each
consumer compensate for it separately.

### Why the sensor row exists at all

An earlier approach patched `DisplayRotation` to add the install angle where needed. That
fixes what reads display rotation and leaves everything that reads *sensors* in the old
frame - and the frame is where gravity lives. The measurable symptom was that with the
tablet stood up, charger edge up, the raw accelerometer still reported the *old* frame's
`Y ~= -g`: the install angle had never reached the sensor device frame (the frame is set up
in the SLPI-side configuration and is not configurable there).

The consequence of leaving it there is wider than the camera: any app that derives an angle
from gravity - a game, a level tool, an icon that self-rotates, the camera's own rotation
metadata - computes it in the wrong frame. On an install-90 panel this shows up as "photos
are rotated by 90 degrees", "some apps' icons turn by themselves", and "the control area is
on the wrong edge", which look like three bugs and are one. Hence the shape of the fix:
transform once, at the point where a HAL event becomes a client-visible sensor reading, so
that the public device frame is the panel's real one:

```
v_public = Rz(+90) * v_hal          and TYPE_DEVICE_ORIENTATION steps by +3
```

Doing it in one place is also what makes the check in the next section possible: after this,
every orientation-family reading an app receives must describe the same frame, so they are
mutually constrained.

## Verifying it

Four checks, from cheapest (no hands needed) to most involved. The bare commands with
expected values are in [acceptance.md](acceptance.md); what belongs here is what each one can
and cannot prove.

**1. Display install orientation - one property, three readings.**

```sh
adb shell getprop ro.surface_flinger.primary_display_orientation   # ORIENTATION_90
adb shell grep -h primary_display_orientation /vendor/build.prop   # present in the image
adb shell 'dumpsys display | grep -m1 -o "installOrientation [0-9]"'   # installOrientation 1
```

The middle one matters: it distinguishes a property compiled into the partition from one
injected at runtime by a module. A ROM should not depend on a module for this.

**2. Touch and pen - read four fields, not one.**

```sh
adb shell input keyevent KEYCODE_WAKEUP; sleep 2
for d in NVTCapacitiveTouchScreen NVTCapacitivePen; do
  echo "--- $d"
  adb shell dumpsys input | sed -n "/Device [0-9]*: $d/,/Device [0-9]*: /p" \
    | grep -E "Touch Input Mapper|Orientation: Rotation|RawToDisplay|InputDeviceOrientation"
done
adb shell ls -l /vendor/usr/idc/ | grep NVT
```

| Field | Meaning | Expected |
| --- | --- | --- |
| `Orientation: Rotation0` *under the Keyboard Input Mapper* | keyboard mapping, unrelated to touch | `Rotation0` - **not a failure** |
| `Touch Input Mapper (mode - …)` | is the mapper live | `DIRECT` |
| `Orientation: Rotation90` *under the Touch Input Mapper* | the idc value was read | `Rotation90` |
| `InputDeviceOrientation` | the direction in force | `Rotation90` |
| `RawToDisplay Transform` | raw coordinates to logical viewport | contains `ROTATE` (a `SCALE` alone means misalignment) |

**With the screen off, the mapper mode becomes `DISABLED` and `InputDeviceOrientation` falls
back to `Rotation0` with an `IDENTITY` transform.** Those are defaults, not a regression: the
first FAIL ever recorded on this check was the screen being off. Wake the screen first.

**3. The sensor device frame - a boot-time log line, no poses needed.**

```sh
adb reboot
for i in $(seq 1 100); do sleep 1; adb get-state >/dev/null 2>&1 && break; done
adb shell 'nohup logcat -v time > /data/local/tmp/boot-log.txt 2>&1 &'
# after boot completes:
adb shell 'grep -F "Panel installed at" /data/local/tmp/boot-log.txt'
```

Expect exactly one line:

```
Panel installed at 90 degrees: publishing one public device frame, v_public = Rz(+90) * v_hal, TYPE_DEVICE_ORIENTATION step +3
```

Start capturing as soon as `adbd` answers, not when `sys.boot_completed` appears: the latter
is a dozen seconds later and the line has already been pushed out of the log buffer.

**4. Cross-type self-consistency - the check that catches the interesting mistakes.**
Quaternion-type sensors and `gravity` take *different* transformation branches in the patch
(a quaternion is right-multiplied by `q_z(-install)`; a vector's `x,y` are swapped and
negated) while describing one physical pose. So they must satisfy

```
gravity_device = R^T * (0,0,|g|)        # in row-major order: the third row of R
```

The convention is taken from AOSP rather than from memory: `SensorManager` defines
`[0 0 g] = R * gravity` with `R` mapping the *device* frame to the *world* frame, so
device-frame gravity needs `R^T`. Multiplying on the wrong side, negating 90 degrees,
transforming one family twice or not at all - each breaks this identity.

`tools/framecheck/` runs it: a 12 KB app that subscribes and logs raw values without
transforming anything (computing the numbers in the app would replace the thing under test),
plus a script that drives it entirely over adb.

```sh
sh tools/framecheck/build.sh && adb install -r tools/framecheck/build/framecheck.apk
python3 tools/framecheck/check.py 12 "leaning at 45 degrees"
adb uninstall com.framecheck
```

Two conditions the script enforces, because ignoring them turns a pass into a fiction:

- **The pose must be tilted** (20 degrees minimum). With the tablet nearly flat, gravity is
  nearly along the world z axis, so *any* error about z predicts the same gravity and the
  check has no resolving power. The script reports the tilt and exits 3 with that explanation
  instead of reporting PASS.
- **Fused types converge.** The first `Game Rotation Vector` sample was off by 8.9 degrees and
  then settled; the verdict uses the settled tail and reports the pre-convergence maximum
  separately.

Absolute direction is a separate, physical check - walk the four edges, one per reading, and
compare against what the pose should be (see [acceptance.md](acceptance.md)). No amount of
internal consistency proves that the direction called 0 is the one you intend.

**5. Camera sensor orientation, judged by facing.**

```sh
adb shell dumpsys media.camera | grep -A1 -E "android.lens.facing \(80005|android.sensor.orientation \(e000e" \
  | grep -E "^\s{4,}\S" | paste - - | column -t
```

Expect `0` for `BACK` and `FRONT` alike. Judge by `facing`, never by "the nth camera": the
dump on this device lists six HAL devices (`v3.5 legacy`), and the number in each block header
comes from the HAL version, not from a camera id. `-A1` is required - without it the grep
shows key names with no values.

## What this fixed, and what is still an open edge

Fixed by propagating the install angle into the sensor frame, all three at once, because they
shared the root cause: photos written with the wrong EXIF orientation, app icons that
self-rotated, and an on-screen control area on the wrong edge. Verifying the photo case needs
a specific method, and it is worth repeating: **the symptom was two-state, not a constant
offset**, so one photo proves nothing - hold the tablet landscape and take a burst, then check
that every frame's EXIF `Orientation` is `1`. The reason a single shot is inconclusive is that
the rotation metadata is written from a gravity-derived angle, and the layer above the HAL
uses `0` both for "no orientation information" and for "0 degrees", so a fixed-offset patch
would fix one state and break the other.

Still an open edge, and it is not in this ROM's reach: the vendor camera HAL writes its own
EXIF orientation from CamX metadata and does not read the framework's `SENSOR_ORIENTATION`
value, which is why "preview says 0" and "EXIF was off by 90" were both true at the same time
without contradicting each other. The blob is closed and its mapping table would have to be
patched in six four-byte instructions across two functions (the thumbnail path has its own copy) - a change
that measurably drags the pixel pipeline along with it. That route is documented and
deliberately not taken.
