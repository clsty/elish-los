# framecheck: a real client for the "quaternion types vs. vector types" check

The self-consistency check in `docs/orientation.md` states a cross-type identity
(`gravity_device ~= R(Q)^T * (0,0,|g|)`) that could not be measured on this device with
what was installed: nothing in the system was a client of `gravity` or `rotation vector` -
Aperture does not subscribe to the orientation fusions, the `googlecamera.fishfood` that
comes with GApps is a stub (`monkey` returns 252), and the native SensorService has no
shell interface to force a subscription. This directory is the minimal client app plus the
judgement script that closes that gap.

## Files

| File | Purpose |
| --- | --- |
| `FrameCheck.java` | subscribes to 10 orientation-related sensor types, performs **no coordinate transformation**, and logs the received values verbatim as one `SNAP\|…` line every 400 ms |
| `AndroidManifest.xml` | one activity, no permissions, no network, no resources |
| `build.sh` | a two-line call into `../mkapk.sh`, the recipe shared with the other verification apps: it builds and signs the APK using only the toolchain already in the AOSP tree, so no SDK is needed on the host |
| `check.py` | starts the app, collects logcat, stops the app, computes the angle between `R(Q)^T * (0,0,|g|)` and the measured gravity on the host, and reports a verdict |

```sh
sh build.sh /path/to/los24               # or export LOS24_TREE; output: build/framecheck.apk (~12 KB)
adb install -r build/framecheck.apk
python3 check.py 12 "leaning at 45 degrees"   # all adb-driven, no hands needed on the device
```

## What it proves and what it does not

- **It proves self-consistency.** The quaternion types and `gravity` take two different
  transformation branches in this patch (`rotation_vector` right-multiplies by
  `q_z(-install)`; the vector types use `(x,y) -> (-y,x)`), while coming from one physical
  pose. If one branch multiplies on the wrong side or with a flipped sign, the identity
  breaks. **It does not prove absolute direction** - that is pinned by the four-edge walk
  in the pose section of `docs/acceptance.md`.
- **The convention comes from AOSP's defining equation, not from memory.**
  `frameworks/base/core/java/android/hardware/SensorManager.java` says R maps a vector in
  the *device* frame to the *world* frame and writes `By definition: [0 0 g] = R * gravity`.
  So device-frame gravity is `R^T * (0,0,|g|)`, which in row-major order is *the third row
  of R*. The script computes the third column as a control; measured here: third row 0.01
  degrees, third column 14.3 degrees - consistent with the AOSP definition.
- **The pose must be tilted enough (the script checks this itself).** A wrong side or sign
  of a rotation about z acts on world-frame gravity, and gravity is nearly along the world
  z axis: with the tablet nearly flat, every error about z predicts the same gravity and
  this check loses all resolving power. Below 20 degrees of tilt the script exits 3 and
  says plainly that the run only exercised the pipeline.
- **Fused types converge.** The first `Game Rotation Vector` sample was off by 8.9 degrees
  and then settled to zero, so the verdict uses only the settled tail (skipping the first
  4 samples) and reports the pre-convergence maximum separately. Do not read convergence as
  an error.

## Measured on this device

Lying flat (8.9 degrees of tilt): `R^T` off by 0.00-0.01 degrees, but exit code 3 - the
pose was too flat to exercise the side or the sign. Leaning (50.3 degrees, exit code 0):
still 0.00-0.01 degrees, where a wrong orientation convention would be off by 98, 66 or 50
degrees, so the side and the sign are both right. `TYPE_ORIENTATION` and the rotation
vector agree on `pitch`/`roll` to within 0.08 degrees (feeding the transposed matrix there
would be off by 98 degrees). **Uninstall it afterwards** (`adb uninstall com.framecheck`) so it does not end up in a
user's data backup.

## Facts about this device to know before running

- The app receives exactly one sensor per type, always the vendor one (`Rotation Vector`,
  `gravity` and `sns_geomag_rv` are all Qualcomm). `dumpsys sensorservice` does list the
  AOSP virtual sensor (handle prefix `0x5f`), but it does not appear as a second sensor of
  the same type in the app's list; the reason has not been investigated. So this measures
  whether a vendor quaternion, after this patch's transformation, is consistent with the
  vendor gravity.
- The main log buffer here is only 256 KiB and the `onCreate` lines are usually already
  gone. The judgement depends on the SNAP lines only, not on those.
- **A dozing device looks like a broken app.** With the keyguard up, the activity starts
  behind it and is paused before it registers a listener, so the log holds `BEGIN`, a few
  `PROBE` lines and `END`, never a `SNAP`, and `check.py` exits 1. Measured both ways on one
  pose: exit 1 without unlocking, exit 0 with it. `check.py` now sends `KEYCODE_WAKEUP` and
  `wm dismiss-keyguard` itself, which is not the same thing - waking does not unlock.

## Four host-side traps, all already worked around in `../mkapk.sh`

1. The `d8` and `apksigner` wrapper scripts in `prebuilts` are `#!/bin/bash` and resolve
   their jar through `/bin/ls`, and on NixOS there is neither `/bin/bash` nor `/bin/ls` -
   which gives "bad interpreter" or "can't find d8.jar". Call the jar directly:
   `java -cp <jar> com.android.tools.r8.D8` / `com.android.apksigner.ApkSignerTool`.
2. With JDK21, `-bootclasspath` is only accepted together with `-source/-target 8`; with
   9+ it errors out.
3. `aapt2 compile` does not take `AndroidManifest.xml` (compile takes resources only), so
   the manifest goes straight to `aapt2 link`.

A fourth, in `mkapk.sh` rather than in the toolchain: a method reference or a lambda needs
`java.lang.invoke.LambdaMetafactory`, which the public `android.jar` does not carry, so
`javac` fails with "cannot find symbol metafactory". Use an explicit anonymous class.
`attestcheck` hit this; nothing in `FrameCheck.java` uses one.

`.signing/debug.keystore` is a throwaway debug key the recipe generates (RSA 2048, password
hard-coded in `mkapk.sh`). It represents no identity and belongs in no repository, but it is
*kept* rather than deleted: it sits outside `build/` on purpose, because a new key per build
makes `adb install -r` refuse the APK with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
