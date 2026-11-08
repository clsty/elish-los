#!/bin/sh
# The *device half* of the camera sidebar work: keep the camera app's landscape window
# request alive on this large screen instead of letting the framework discard it.
# Usage: sh apply-camera-compat-changes.sh [tree-root]   (or export LOS24_TREE; default: a sibling srcs/los24)
#
# The app half (manifest declares landscape, plus the compat property) lives in
# aperture-landscape-sidebar.patch; this half - a grant of compat change 236283604 for
# that package - can only come from the device. With either half missing you measured
# letterboxing (viewFinder 1600x453) or no effect at all, which is not a lock.
#
# The form of this half changed once: it used to be `am compat enable` run from an init
# rc at boot, and it is now a static declaration file in the image. The reason, and the
# trap each form has, are in the comment of files/compat_framework_overrides.xml (short
# version: CompatConfig reads /product/etc/appcompat/ before anything else, so a
# declaration is enough, while an init-run `am` hits SELinux's entrypoint check and
# would need another shell layer around it).
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
SRC="$HERE/files/compat_framework_overrides.xml"

[ -d "$DEV" ] || { echo "no device tree at $DEV"; exit 1; }
[ -f "$SRC" ] || { echo "missing the only source, $SRC"; exit 1; }

# 1) The declaration file. files/ is the only source and the copy in the tree is
#    overwritten every run - the same arrangement as the idc files and ksu-install.rc.
mkdir -p "$DEV/appcompat"
cp -f "$SRC" "$DEV/appcompat/compat_framework_overrides.xml"
echo "appcompat/compat_framework_overrides.xml in place (from files/)"
# Remove a leftover empty init/ directory from the old form: having both in the image
# would suggest the rc half is still doing something.
if [ -d "$DEV/init" ] && [ ! "$(ls -A "$DEV/init" 2>/dev/null)" ]; then rmdir "$DEV/init"; fi
[ -f "$DEV/init/elish-compat.rc" ] && { rm -f "$DEV/init/elish-compat.rc"; rmdir "$DEV/init" 2>/dev/null || true; echo "  removed the old init/elish-compat.rc"; }

# 2) The device.mk copy rule. The idempotency check is the directory name in the rule.
pm="$DEV/device.mk"
if grep -q 'appcompat' "$pm"; then
    echo "device.mk already has the appcompat copy rule, skipping"
else
    # The block travels in a file, not through awk -v: -v interprets escapes in the
    # value and eats the trailing backslash of a continuation line (same trap in
    # apply-root-changes.sh).
    blk="$pm.compat-block"
    cat > "$blk" <<'MK'

# Per-package compat override that keeps the camera app's landscape window request alive on this
# large screen, which Android 16 would otherwise discard. Why it is needed at all:
# appcompat/compat_framework_overrides.xml (CompatConfig's STATIC_OVERRIDES_PRODUCT_DIR).
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/appcompat,$(TARGET_COPY_OUT_PRODUCT)/etc/appcompat)
MK
    if ! awk -v blk="$blk" '
        /^# RRO Overlays$/ && !done {
            while ((getline line < blk) > 0) print line
            close(blk); print ""; done = 1
        }
        { print }
        END { if (!done) { print "anchor # RRO Overlays did not match" > "/dev/stderr"; exit 1 } }
    ' "$pm" > "$pm.new"; then
        rm -f "$pm.new" "$blk"
        echo "device.mk: anchor did not match"
        exit 1
    fi
    grep -q 'appcompat' "$pm.new" || { echo "rule still missing after insert"; rm -f "$pm.new" "$blk"; exit 1; }
    mv "$pm.new" "$pm"
    rm -f "$blk"
    echo "device.mk: appcompat copy rule inserted"
fi

# 3) The rc form's device.mk rule must go with it, or PRODUCT_COPY_FILES points at a
#    directory that no longer exists.
if grep -q 'LOCAL_PATH)/init,\$(TARGET_COPY_OUT_PRODUCT)' "$pm"; then
    python3 - "$pm" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
# Removes the whole block written before the form changed: 3 comment lines +
# PRODUCT_COPY_FILES += \ + the rule line.
pat = re.compile(
    r"\n# Keeps the camera app's landscape window request alive on this large screen, which Android 16\n"
    r"# would otherwise discard\. Why it is needed at all: init/elish-compat\.rc\.\n"
    r"PRODUCT_COPY_FILES \+= \\\n"
    r"    \$\(call find-copy-subdir-files,\*,\$\(LOCAL_PATH\)/init,\$\(TARGET_COPY_OUT_PRODUCT\)/etc/init\)\n")
s2, n = pat.subn("\n", s)
if n != 1:
    sys.exit("the old init/ copy rule did not match (%d places) - delete it by hand" % n)
io.open(p, 'w', encoding='utf-8').write(s2)
print("device.mk: the old init/ copy rule was removed")
PY
fi
