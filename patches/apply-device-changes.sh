#!/bin/sh
# The two device-tree changes that make landscape the natural orientation. Idempotent:
# running it twice does not duplicate anything.
# Usage: sh apply-device-changes.sh [tree-root]   (or export LOS24_TREE; default: a sibling srcs/los24)
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
DEV="$TREE/device/xiaomi/elish"
IDC_SRC="$HERE/files/idc"   # the only source of the idc files (same arrangement as files/config.fs)

PROP=ro.surface_flinger.primary_display_orientation
[ -d "$DEV" ] || { echo "no device tree at $DEV"; exit 1; }

# 1) vendor.prop - same kind of knob as the other ro.surface_flinger.* entries this
#    platform already sets, and the SELinux side expects an exact enum value.
if grep -q "^$PROP=" "$DEV/vendor.prop"; then
    echo "vendor.prop already has $PROP, skipping"
else
    cat >> "$DEV/vendor.prop" <<'EOF'

# Display orientation
# The panel is mounted physically portrait, so the display install orientation is 90
# degrees: that makes "facing the screen, charger on the right, keyboard contacts at
# the bottom" the natural direction (ROTATION_0), so boot animation, lock screen and
# natural orientation agree. Touch alignment comes from idc/ - both halves are needed.
ro.surface_flinger.primary_display_orientation=ORIENTATION_90
EOF
    echo "vendor.prop: $PROP appended"
fi

# 2) idc directory - content taken from the module directory so there is one truth.
mkdir -p "$DEV/idc"
cp -f "$IDC_SRC"/*.idc "$DEV/idc/"
echo "idc copied: $(ls "$DEV/idc" | tr '\n' ' ')"

# 3) device.mk - following the find-copy-subdir-files style this file already uses.
if grep -q "usr/idc" "$DEV/device.mk"; then
    echo "device.mk already has the idc copy rule, skipping"
else
    awk '
    { print }
    !done && /\$\(call find-copy-subdir-files,\*,\$\(LOCAL_PATH\)\/audio\// {
        print ""
        print "# Raw touch and pen coordinates stay in the panel electrical frame"
        print "# (X 0..1599 / Y 0..2559) while the display is installed at 90 degrees, so"
        print "# touch.orientation has to be declared - otherwise the input subsystem"
        print "# stretches them onto the logical viewport (RawToDisplay turns into SCALE)."
        print "PRODUCT_COPY_FILES += \\"
        print "    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/idc/,$(TARGET_COPY_OUT_VENDOR)/usr/idc)"
        done = 1
    }' "$DEV/device.mk" > "$DEV/device.mk.new" && mv "$DEV/device.mk.new" "$DEV/device.mk"
    grep -q "usr/idc" "$DEV/device.mk" || { echo "device.mk: anchor did not match"; exit 1; }
    echo "device.mk: idc copy rule inserted"
fi

# 4) No patch is written here: generated/ is computed by gen-patches.sh (the last step
#    of apply-all.sh).
echo
echo "review: git -C $DEV diff"
echo "revert: git -C $DEV reset -q && git -C $DEV checkout -- vendor.prop device.mk && rm -rf $DEV/idc"
