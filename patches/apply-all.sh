#!/bin/sh
# Replays every source change this ROM needs onto a LOS 24 tree. Idempotent: run it
# again any time, and run it once after a fresh `repo sync`.
# Usage: sh apply-all.sh [tree-root]   (or export LOS24_TREE; default: a sibling srcs/los24)
#
# Five themes; the reasoning for each one lives in the script that applies it:
#   natural landscape (display install orientation, touch, camera mount angles)
#   one sensor device-frame transform (replaces the older DisplayRotation compensation)
#   built-in root (ReSukiSU + SuSFS; ksud is delivered, a manager is not preinstalled)
#   CN NTP and captive-portal addresses, independent of the system language
#   the camera app's landscape sidebar (app layer only)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# The tree is a build input kept outside this repository: pass it here or in LOS24_TREE.
# The default is where this project happens to keep its own tree, which a reader from
# elsewhere will not have - so say what to pass rather than letting cd complain.
TREE=${1:-${LOS24_TREE:-}}
if [ -z "$TREE" ]; then TREE=$(cd "$HERE/../srcs/los24" 2>/dev/null && pwd) || TREE=""; fi
if [ -z "$TREE" ]; then
    echo "no source tree: sh $(basename "$0") /path/to/los24   (or export LOS24_TREE)" >&2
    exit 1
fi

# 1) Device tree: the orientation truth in vendor.prop, the touch idc files, and the
#    device.mk rules that copy them.
sh "$HERE/apply-device-changes.sh" "$TREE"

# 2) Device tree: move config_ntpServers and config_captive_portal_*_url out of
#    values-zh-rCN/ into values/ so they apply regardless of the system language.
sh "$HERE/apply-cn-network-changes.sh" "$TREE"

# 3) Root: ReSukiSU material plus the kernel integration patch, and ksud delivery.
sh "$HERE/apply-root-changes.sh" "$TREE"

# 4) Framework changes: skipped when already applied (--reverse --check passes).
apply_patch() { # <project path> <patch file>
    proj="$TREE/$1"; patch="$HERE/generated/$2"
    [ -d "$proj" ] || { echo "missing project $1 (run repo sync first)"; exit 1; }
    if git -C "$proj" apply --reverse --check "$patch" 2>/dev/null; then
        echo "$2 already applied, skipping"
    elif git -C "$proj" apply --check "$patch" 2>/dev/null; then
        git -C "$proj" apply "$patch"
        echo "$2 applied"
    else
        echo "$2 does not apply cleanly (upstream revision moved?) - redo it by hand"
        exit 1
    fi
}

apply_patch frameworks/native frameworks-native-device-frame-transform.patch
apply_patch frameworks/av   frameworks-av-sensor-orientation.patch

# 5) The camera app's landscape sidebar. Both halves are needed: the device half (a
#    per-package grant of compat change 236283604, whose only source is
#    files/compat_framework_overrides.xml) and the app half (layout plus manifest).
#    With one half missing you measured letterboxing or no effect at all.
sh "$HERE/apply-camera-compat-changes.sh" "$TREE"
apply_patch packages/apps/Aperture aperture-landscape-sidebar.patch

# 6) Finally freeze everything in the tree into generated/*.patch (the only place
#    patches are produced, including the files added above).
sh "$HERE/gen-patches.sh" "$TREE"
