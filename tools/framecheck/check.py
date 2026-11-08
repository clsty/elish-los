#!/usr/bin/env python3
"""Runs the cross-check of orientation section 5.4: gravity_device ~= Q^T * (0,0,|g|),
where Q is the quaternion the framework reported.

Why this catches anything: the quaternion types and gravity (a vector type) go through two
different transformation branches in this patch, while coming from one physical pose. The
wrong side, a flipped sign, one family missed, one family transformed twice - each breaks
this identity. The judgement and the measured readings are in section 5.4 of the
orientation doc.

The convention is taken from AOSP's defining equation, not from memory:
frameworks/base/core/java/android/hardware/SensorManager.java says "By definition:
[0 0 g] = R * gravity", and that R takes a vector in the *device* frame to the *world*
frame. Gravity in the world frame is known to be (0,0,|g|), and what is wanted is gravity
in the device frame, so R^T is the one to use: gravity_device = R^T * (0,0,|g|), which in
row-major order means taking the third row of R. The script also computes the third column
for comparison (that is the reading in which R maps world -> device). If one day only the
column matches, the convention has changed - that is not a pass, it is something to
explain.

**The pose has to be tilted enough.** A wrong side or sign of a rotation about z acts on
the world-frame gravity vector, and gravity is almost along the world z axis, so with the
tablet nearly flat this class of error is invisible (lying flat, any error about z predicts
the same gravity). The script computes the tilt and says out loud when it is too small for
the run to count.

Usage: python3 check.py [seconds=12] [pose name]
Everything is driven over adb: it starts the app, collects logcat, and stops the app.
"""
import math
import re
import subprocess
import sys
import time

TAG = "FrameCheck"
RV_TYPES = {"11": "rotation_vector", "15": "game_rotation_vector",
            "20": "geomagnetic_rotation_vector"}
# Sensor type numbers, from frameworks/base/core/java/android/hardware/Sensor.java:
# TYPE_ACCELEROMETER = 1, TYPE_GRAVITY = 9, TYPE_ORIENTATION = 3. (Type 2 is the magnetic
# field, so an accelerometer fallback written as "2" would silently read the compass.)
GRAV_TYPE, ACC_TYPE, ORI_TYPE = "9", "1", "3"
THRESHOLD = 2.0          # degrees
MIN_TILT = 20.0          # degrees: below this, an error about z is invisible
WARMUP = 4               # the first samples of a fused sensor are still converging and do
                         # not count towards the verdict (400 ms per sample ~ 1.6 s)


def sh(args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def collect(seconds):
    sh(["adb", "logcat", "-c"])
    sh(["adb", "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
    time.sleep(0.6)
    sh(["adb", "shell", "am", "start", "-n", "com.framecheck/.FrameCheck"])
    time.sleep(seconds)
    out = sh(["adb", "logcat", "-d", "-s", "%s:I" % TAG])
    sh(["adb", "shell", "am", "force-stop", "com.framecheck"])
    return [ln.split("FrameCheck: ", 1)[1] for ln in out.splitlines() if "FrameCheck: " in ln]


def parse(body):
    out = {}
    for part in body.split("|")[1:]:
        if "=" not in part:
            continue
        key, vals = part.split("=", 1)
        try:
            f = [float(x) for x in vals.split(",")]
        except ValueError:
            continue
        m = re.match(r"(\d+)#(\d+):([^:]*):(.*)", key)
        if m:
            out.setdefault(m.group(1), {}).setdefault((int(m.group(2)), m.group(3)), []).append(f)
    return out


def quat_to_r(q):
    """Copied from AOSP SensorManager.getRotationMatrixFromVector (frameworks/base)."""
    x, y, z = q[0], q[1], q[2]
    if len(q) > 3 and abs(q[3]) > 1e-9:
        w = q[3]
    else:
        t = 1.0 - x * x - y * y - z * z
        w = math.sqrt(t) if t > 0 else 0.0
    sq1, sq2, sq3 = 2 * x * x, 2 * y * y, 2 * z * z
    q12, q30, q13 = 2 * x * y, 2 * z * w, 2 * x * z
    q20, q23, q10 = 2 * y * w, 2 * y * z, 2 * x * w
    return [1 - sq2 - sq3, q12 - q30, q13 + q20,
            q12 + q30, 1 - sq1 - sq3, q23 - q10,
            q13 - q20, q23 + q10, 1 - sq1 - sq2]


def norm(a):
    return math.sqrt(sum(i * i for i in a))


def ang(a, b):
    na, nb = norm(a), norm(b)
    if na < 1e-6 or nb < 1e-6:
        return float("nan")
    c = max(-1.0, min(1.0, sum(i * j for i, j in zip(a, b)) / (na * nb)))
    return math.degrees(math.acos(c))


def extract_ypr(m):
    """The extraction formulas copied from AOSP OrientationSensor::process
    (frameworks/native/services/sensorservice/OrientationSensor.cpp):
    azimuth = atan2(-R10, R00), pitch = atan2(-R21, R22), roll = asin(R20), converted to
    degrees, azimuth normalised to [0, 360)."""
    az = math.degrees(math.atan2(-m[3], m[0]))      # R[1][0] = m[3]
    pi = math.degrees(math.atan2(-m[7], m[8]))
    ro = math.degrees(math.asin(max(-1.0, min(1.0, m[6]))))
    return az % 360.0, pi, ro


def transpose(m):
    return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]


def wrap180(d):
    return (d + 180.0) % 360.0 - 180.0


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0
    pose = sys.argv[2] if len(sys.argv) > 2 else "unnamed pose"
    lines = collect(seconds)
    snaps = [parse(l) for l in lines if l.startswith("SNAP|")]
    if not snaps:
        print("!! no SNAP lines: the app did not start, or the log was pushed out (the\n"
              "   main buffer here is only 256 KiB)")
        return 1

    print("== sensors the app actually received data from (two per type = vendor + AOSP virtual) ==")
    for t in sorted({k for s in snaps for k in s}, key=int):
        for (idx, name) in sorted({k for s in snaps for k in s.get(t, {})}):
            print("  type %-2s #%d  %s" % (t, idx, name))
    print("  Note: on this tablet each type reaches the app as a single sensor, always the\n"
          "  vendor one (Rotation Vector, gravity and sns_geomag_rv are all Qualcomm).\n"
          "  dumpsys sensorservice also lists the AOSP virtual one (handle prefix 0x5f),\n"
          "  but it does not appear as a second sensor of the same type in the app's list;\n"
          "  the reason has not been investigated.")

    # Pose tilt: the angle between gravity and the device z axis.
    tilts, gsrc = [], "none"
    for s in snaps:
        g = None
        if GRAV_TYPE in s:
            g, gsrc = next(iter(s[GRAV_TYPE].values()))[-1][:3], "gravity"
        elif ACC_TYPE in s:
            g, gsrc = next(iter(s[ACC_TYPE].values()))[-1][:3], "accelerometer (used when gravity is absent)"
        if g:
            tilts.append(ang(g, [0, 0, 1]))
    if not tilts:
        print("!! %s never reported a reading, cannot judge" % gsrc)
        return 1
    tilt = sum(tilts) / len(tilts)

    print("\n== pose: %s ==" % pose)
    print("  %d snapshot lines, gravity taken from %s" % (len(snaps), gsrc))
    print("  angle between gravity and the device z axis: mean %.1f deg (min %.1f deg)"
          % (tilt, min(tilts)))
    discriminating = tilt >= MIN_TILT
    if not discriminating:
        print("  !! Too close to horizontal: a wrong side or sign about z is INVISIBLE in\n"
              "  this pose (lying flat, any error about z predicts the same gravity). This\n"
              "  run can only check the pipeline, not the side or the sign.")

    print("\n== per quaternion-type sensor: angle between Q^T*(0,0,|g|) and measured gravity ==")
    worst_row, worst_col = 0.0, 0.0
    rows = []
    for t in sorted(RV_TYPES, key=int):
        keys = {k for s in snaps for k in s.get(t, {})}
        for key in sorted(keys):
            idx, name = key
            e_row, e_col, n = [], [], 0
            for s in snaps:
                for q in s.get(t, {}).get(key, []):
                    grav = None
                    if GRAV_TYPE in s:
                        grav = next(iter(s[GRAV_TYPE].values()))[-1][:3]
                    elif ACC_TYPE in s:
                        grav = next(iter(s[ACC_TYPE].values()))[-1][:3]
                    if grav is None:
                        continue
                    r = quat_to_r(q)
                    g = norm(grav)
                    e_row.append(ang([r[6] * g, r[7] * g, r[8] * g], grav))   # R^T: AOSP definition
                    e_col.append(ang([r[2] * g, r[5] * g, r[8] * g], grav))   # R: comparison
                    n += 1
            if not n:
                continue
            # A fused type has a convergence phase (measured: the first game_rotation_vector
            # sample was off by 8.9 deg, then it settled to zero), so the verdict looks only
            # at the settled tail; the pre-convergence maximum is reported separately.
            warm = min(WARMUP, len(e_row) - 1)
            settled = e_row[warm:] or e_row
            rows.append((t, idx, name, max(settled), max(e_row), e_row[0], e_row[-1],
                         max(e_col), n))
            worst_row = max(worst_row, max(settled))
            worst_col = max(worst_col, max(e_col[len(e_col) - len(settled):]))
    for t, idx, name, mx, mx_all, first, last, col, n in rows:
        tag = "" if abs(mx - mx_all) < 1e-9 else "  (incl. %.2f before convergence)" % mx_all
        print("  type %-2s #%d %-30s settled max %6.2f%s  first %5.2f  last %5.2f  "
              "compare %6.2f  samples %d" % (t, idx, name, mx, tag, first, last, col, n))
    if not rows:
        print("  (no quaternion-type sensor at all)")
        return 1

    # TYPE_ORIENTATION pair check. It goes through the *other* branch of this patch
    # (rebuild the world->device matrix with the extraction formulas, left-multiply by
    # Rz(+install), then extract unchanged), whereas the check above is the "right-multiply
    # q_z(-install)" branch. Both must describe the same pose, so comparing against a
    # rotation vector just shown to be self-consistent is valid here.
    # Both matrix orientations are tried (R and R^T) and whichever matches is reported.
    # Azimuth is looked at separately: two fused sources need not handle magnetic declination
    # the same way, so a constant offset there is not a bug.
    print("\n== TYPE_ORIENTATION paired against the rotation vector ==")
    ori = {}
    for s in snaps:
        if ORI_TYPE not in s or "11" not in s:
            continue
        o = next(iter(s[ORI_TYPE].values()))[-1]
        r = quat_to_r(next(iter(s["11"].values()))[-1])
        for label, m in (("R", r), ("R^T", transpose(r))):
            az0, p0, ro0 = extract_ypr(m)
            ori.setdefault(label, []).append((wrap180(az0 - o[0]), p0 - o[1], ro0 - o[2]))
    best = None
    for label, ds in ori.items():
        mp = max(abs(d[1]) for d in ds)
        mr = max(abs(d[2]) for d in ds)
        azs = sorted(abs(d[0]) for d in ds)
        print("  extracted with %-3s: max |delta pitch| %.2f   max |delta roll| %.2f   "
              "median |delta azimuth| %.1f  max %.1f"
              % (label, mp, mr, azs[len(azs) // 2], azs[-1]))
        if best is None or max(mp, mr) < best[1]:
            best = (label, max(mp, mr))
    if best is None:
        print("  (no snapshot had both orientation and rotation vector)")
    elif best[1] < 3.0:
        print("  => extracting with %s gives pitch and roll matching the reported values "
              "(max %.2f): the rebuild-the-matrix branch and the quaternion branch describe "
              "the same pose" % (best[0], best[1]))
    else:
        print("  => neither orientation matches (best was %s, still %.2f off). Either this "
              "vendor orientation sensor uses extraction formulas different from AOSP's _ypr, "
              "or the rebuild-the-matrix branch is wrong. NOT a pass: settling it needs a "
              "comparison against an unpatched boot." % (best[0], best[1]))

    print("\n== verdict ==")
    print("  worst angle overall: R^T convention (AOSP definition) %.2f (threshold %.1f),  "
          "comparison R convention %.2f" % (worst_row, THRESHOLD, worst_col))
    if worst_row > THRESHOLD and worst_col <= THRESHOLD:
        print("  only the comparison side matches => the convention changed. Not a pass; "
              "find out why.")
        return 2
    if worst_row > THRESHOLD:
        print("  FAIL - neither side matches: the quaternion types and the vector types are "
              "not self-consistent")
        return 2
    if not discriminating:
        print("  pipeline OK (self-consistency holds), but the POSE IS TOO FLAT, so the side "
              "and sign were not exercised. Tilt the tablet past %.0f degrees and run again."
              % MIN_TILT)
        return 3
    print("  PASS - self-consistency holds and the pose is tilted enough, so the quaternion "
          "branch multiplies on the same side with the same sign as the vector types")
    return 0


if __name__ == "__main__":
    sys.exit(main())
