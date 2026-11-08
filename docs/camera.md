# The camera app on a natural-landscape tablet

Two separate problems, and it is worth keeping them apart because they have different owners.

1. **The layout.** `Aperture`, the LineageOS camera app, is built for phones: its mode strip,
   shutter and settings sit across the preview. On a 2560x1600 panel mounted portrait and given
   a landscape install orientation - the case [orientation.md](orientation.md) calls a *natural
   landscape* screen - that means controls on top of the viewfinder.
2. **The window direction.** The app asks for `landscape`. On this screen that request is
   discarded, so the app runs in a portrait-shaped window and the layout fix would never be
   selected.

The fix has two halves for the same reason: an app-side layout and manifest change, plus a
device-side permission for one compat change. With either half missing, the measured behaviour
is letterboxing (`viewFinder 1600x453`) or no visible effect at all - which is why they are
shipped together (`apply-camera-compat-changes.sh` applies the device half,
`aperture-landscape-sidebar.patch` the app half).

## Why an app cannot lock its own direction here

Two nested gates discard a fixed-orientation request from an app on a large screen. Both are in
this tree, and the names are used consistently below:

- **Gate 1**, in `ActivityRecord`: `isRestrictedFixedOrientation()` drops a fixed manifest
  orientation when the activity counts as *universally resizable* - which needs a large screen
  whose `ignoreOrientationRequest` is set, and no opt-out from the app. The log line quoted
  below is that path's own trace. An app can opt out of this gate by itself, and does not need
  the device: the manifest property `android.window.PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY`
  set to `true` reaches `allowRestrictedResizability()`, which takes the activity out of that
  path.
- **Gate 2**, the display's side, which no app can opt out of: compat change `236283604`
  (`OVERRIDE_RESPECT_REQUESTED_ORIENTATION`). `AppCompatOrientationOverrides` honours the request
  when the change is enabled *for that package*, and only in fullscreen windowing mode. So this
  half is the device's to grant.

The system log names the first one:

```
I ActivityTaskManager: Ignoring manifest-declared fixed orientation SCREEN_ORIENTATION_LANDSCAPE
                       of ActivityRecord{… org.lineageos.aperture/.CameraActivity} since target sdk 36
```

| Combination | What was tried | Result |
| --- | --- | --- |
| Gate 1 only stepped aside | manifest property | letterboxed: `mDisplayRotation=ROTATION_270`, `viewFinder 1600x453` |
| Gate 2 only protected | `am compat enable 236283604` | no effect at all - Gate 1 had already downgraded the request to `UNSPECIFIED` |
| **Both** | property + per-package compat grant | **full-screen landscape**: `ROTATION_0` with a `2133x1600` viewfinder |

So "an app alone cannot decide its orientation" is true, and "the device must be involved" is
the practical consequence: the app declares, and the device grants one compat change for that
package. Nothing about the display's global policy changes - leave the app and the tablet
rotates as before.

### How the device half should be declared

Compat change `236283604` (`OVERRIDE_RESPECT_REQUESTED_ORIENTATION`) can reach a device three
ways, and only one is good:

| Channel | Result |
| --- | --- |
| `am compat enable …` from an init `rc` at boot | works, but `am` is launched from init and trips SELinux's entrypoint check, so it needs another shell layer to survive |
| `device_config put compatibility_framework 236283604 …` | the value is written and readable, but it never reaches `dumpsys platform_compat` as a package override |
| **`/product/etc/appcompat/compat_framework_overrides.xml`** | **works.** `CompatConfig` reads this static file before anything else (`STATIC_OVERRIDES_PRODUCT_DIR`), so a declaration in the image is enough |

This ROM uses the file, generated from `patches/files/compat_framework_overrides.xml`. Two
notes from the measurements: `am compat enable` *is* persistent (it writes
`/data/misc/appcompat/`, not `/data/system/`, which is why it was first mistaken for
boot-only), and `pm compat` does not exist on this build.

## The layout

`layout-w840dp-h600dp-land/activity_camera.xml` moves the controls into a right-hand sidebar;
the qualifier is why this only affects tablets and never a phone. The new
`CaptureFrameMaskView` draws the white "what the saved frame actually covers" lines, whose
criteria are below.

## Criteria

**Geometry** - lock the rotation by hand, cold-start the app, and read the actual bounds:

```sh
adb shell 'settings put system accelerometer_rotation 0; settings put system user_rotation 3'
adb shell am force-stop org.lineageos.aperture
adb shell input keyevent KEYCODE_WAKEUP; adb shell wm dismiss-keyguard
adb logcat -c
adb shell am start -n org.lineageos.aperture/.CameraActivity; sleep 9
adb shell 'dumpsys window | grep -m1 -o "mDisplayRotation=ROTATION_[0-9]*"'
adb shell uiautomator dump /sdcard/w.xml && adb shell cat /sdcard/w.xml
adb logcat -d | grep -c "Ignoring manifest-declared fixed orientation"
```

Expected on this tablet: `mDisplayRotation=ROTATION_0`; `viewFinder` bounds
`[0,0][2133,1600]`; the mode-selector/controls sidebar starting at `x=2133`; and **zero** "Ignoring
manifest-declared fixed orientation" lines - a nonzero count means the request was discarded
again, whatever the window looks like. Restore afterwards (`accelerometer_rotation 1`,
`user_rotation 0`).

Two readings that look like judgements and are not: `user_rotation` is synchronized by the
system while an app forces a direction, so it is not evidence either way; and `wm
set-ignore-orientation-request` takes its **boolean as the first argument** and the display as
`-d 0`, while `… reset` leaves the value at `false` rather than unset - an experiment with it
must set `true` explicitly afterwards, or the device is left in a modified state nobody
remembers.

The compat grant itself:

```sh
adb shell dumpsys platform_compat | grep -o "ChangeId(236283604[^)]*packageOverrides={[^}]*}" | head -1
# expect org.lineageos.aperture=true
```

**The viewfinder mask, four states.** The mask must appear only where the saved frame differs
from the preview: it is drawn for 16:9 and for video, not for 4:3 or for SCAN. Rather than
judging screenshots by eye, detect the two white lines numerically - crop the preview area
(2133x1600), downscale, and look for a row whose brightness jumps:

```sh
adb shell am force-stop org.lineageos.aperture
adb shell am start -n org.lineageos.aperture/.CameraActivity; sleep 9
adb exec-out screencap -p > state.png      # repeat per state: 4:3, 16:9, VIDEO, SCAN
```

Expected: for 16:9 and VIDEO, lines at `y=200` and `y=1396` inside the crop; for 4:3 and SCAN,
nothing. (A 16:9 save area on a 2133-wide panel is 1200 px tall, centred, so 200/1400 is the
nominal boundary and a 2 dp line reads one pixel inside it. The HAL's own 1.757 aspect family
differs from the nominal 16:9 by about 7 px - the mask follows the nominal ratio because
CameraX does not publish the save-area getter.)

## The front camera's mirror is a preference, not a HAL bug

One finding worth keeping, because the obvious attribution was wrong: with the front camera,
the *preview* is mirrored and the *photo* should not be. The EXIF orientation value carried
the mirror bit (`2`, Mirror horizontal) instead of the pixels, and the writer is not the
vendor HAL's table - it is Aperture's own `photo_ffc_mirror` preference, applied by CameraX,
which rewrites `ImageCapture.Metadata.isReversedHorizontal` into the JPEG's EXIF orientation
only. Toggling that preference changes the EXIF from `2` to `1` and leaves the raster
untouched. The general lesson: a wrong orientation tag can be written by a *library* between
the app and the file, so checking the app's own EXIF helper is not enough.
