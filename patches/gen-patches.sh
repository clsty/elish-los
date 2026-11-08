#!/bin/sh
# The only place generated/ patches are produced: computed from each project's git diff.
# Never edit a patch file by hand.
# Usage: sh gen-patches.sh [tree-root]   (or export LOS24_TREE; default: a sibling srcs/los24)
#
# Two traps, both paid for:
#   1) A new file that is not intent-to-add'ed does not show up in `git diff` at all, so
#      a replay onto another tree silently loses it. Each project therefore lists its
#      own "files added by this change".
#   2) Material is not patch content: the ReSukiSU clone (91 M, and Kbuild wants a git
#      repository with full history), the manager APK (8.5 M), and the binaries taken out
#      of that APK (ksud, the JNI libraries). apply-root-changes.sh places and verifies
#      those by commit / sha256; the patches carry source deltas only. So the test for
#      "does this belong in gen's new-file list" is: content written by this change ->
#      list it; content from the APK or from a git repository -> do not.
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
OUT="$HERE/generated"
mkdir -p "$OUT"

# gen <project path> <patch name> <files this change adds...>
#
# MAT_SKIP lists what is *material* rather than patch content (the binaries taken out of
# the manager APK). Anything else in the project that is still untracked after the list is
# applied means the list is incomplete - the patch would silently lose that file on a
# replay onto another tree, which is exactly how the CN 204 override once disappeared. So
# this is an error, not a note.
MAT_SKIP='^ksu/bin/|^ksu/lib/|\.apk$|^KernelSU/|^drivers/kernelsu$'
gen() {
    proj="$TREE/$1"; name="$2"; list="$1"; shift 2
    [ -d "$proj" ] || { echo "skipping $name (no $proj)"; return 0; }
    for f in "$@"; do
        # Intent-to-add only what exists. When it does not exist (no ksu/Android.bp in
        # the no-preinstall form, say), clear any stale intent-to-add instead, or the
        # diff gains a bogus "deletion of an empty file" record.
        if [ -e "$proj/$f" ]; then git -C "$proj" add -N "$f" 2>/dev/null || true
        else git -C "$proj" reset -q -- "$f" 2>/dev/null || true; fi
    done
    left=$(git -C "$proj" ls-files --others --exclude-standard | grep -Ev "$MAT_SKIP" || true)
    if [ -n "$left" ]; then
        echo "  $name: untracked files not in the new-file list (they would be lost on replay):"
        printf '    %s\n' $left
        echo "  add them to the gen line for $1"
        exit 1
    fi
    git -C "$proj" diff > "$OUT/$name.tmp"
    # A patch generated from a partially applied tree is smaller than the published one,
    # and shrinking silently is the worst failure this script can have: the replay works,
    # the build works, and one change is simply gone. So compare file counts with the
    # published patch and stop on a decrease (an increase is normal: new files added).
    if [ -s "$OUT/$name" ]; then
        old=$(grep -c '^diff --git ' "$OUT/$name")
        new=$(grep -c '^diff --git ' "$OUT/$name.tmp")
        if [ "$new" -lt "$old" ]; then
            mv "$OUT/$name.tmp" "$OUT/$name.lost"
            echo "  $name would shrink from $old to $new files - the tree is only partially"
            echo "  applied. Run apply-all.sh first; the previous patch is kept as $name.lost"
            exit 1
        fi
    fi
    mv "$OUT/$name.tmp" "$OUT/$name"
    # Only a passing reverse --check proves the patch describes the current work tree.
    if git -C "$proj" apply --reverse --check "$OUT/$name" 2>/dev/null; then
        printf "  %-44s %s (reversible)\n" "$name" "$(git -C "$proj" diff --stat | tail -1 | sed 's/^ *//')"
    else
        echo "  $name failed reverse --check after generation - do not replay with it, look at $proj"
        exit 1
    fi
}

gen device/xiaomi/elish    device-xiaomi-elish.patch \
    idc/NVTCapacitiveTouchScreen.idc idc/NVTCapacitivePen.idc ksu/Android.bp \
    ksu/etc/init/ksu-install.rc appcompat/compat_framework_overrides.xml config.fs \
    rro_overlays/NetworkStackOverlayMIUI/res/values/config.xml
gen kernel/xiaomi/sm8250   kernel-xiaomi-sm8250-ksu-susfs.patch \
    arch/arm64/configs/vendor/xiaomi/ksu-susfs.config \
    fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
# ReSukiSU itself is *another git repository* (cloned in as material), so its delta needs
# its own patch. The outer kernel project's diff does not contain it, and without this
# file a replay onto another tree would lose it silently.
gen kernel/xiaomi/sm8250/KernelSU kernelsu-preinstalled-manager.patch
gen frameworks/native      frameworks-native-device-frame-transform.patch \
    services/sensorservice/DeviceFrameTransform.h services/sensorservice/DeviceFrameTransform.cpp
gen frameworks/av          frameworks-av-sensor-orientation.patch
# The camera app's new layout directory is a *new file*, so it has to be listed here: if
# it is not, `git diff` hides it and a replay loses the sidebar (only on the tablet,
# because that is where the resource qualifier applies).
gen packages/apps/Aperture aperture-landscape-sidebar.patch \
    app/src/main/res/layout-w840dp-h600dp-land/activity_camera.xml \
    app/src/main/java/org/lineageos/aperture/ui/views/CaptureFrameMaskView.kt

echo
echo "material (not in any patch; placed and verified by apply-root-changes.sh):"
KS=$TREE/kernel/xiaomi/sm8250/KernelSU
[ -d "$KS" ] && printf "  ReSukiSU %s %s (full history, rev-list %s)\n" \
    "$(git -C "$KS" describe --tags 2>/dev/null || echo '?')" \
    "$(git -C "$KS" rev-parse --short HEAD)" "$(git -C "$KS" rev-list --count HEAD)"
DEV=$TREE/device/xiaomi/elish
ksud=$DEV/ksu/bin/ksud
[ -f "$ksud" ] && printf "  ksud %s... (from the APK, 0755 -> /product/bin/ksud)\n" "$(sha256sum "$ksud" | cut -c1-16)"
apk=$(find "$DEV/ksu" -maxdepth 1 -name '*.apk' 2>/dev/null | head -1)
if [ -n "$apk" ]; then
    printf "  %s %s... (preinstalled manager)\n" "$(basename "$apk")" "$(sha256sum "$apk" | cut -c1-16)"
    find "$DEV/ksu/lib/arm64" -name '*.so' 2>/dev/null | sort | while read -r f; do
        printf "  %s %s... (from the same APK, 0755)\n" "$(basename "$f")" "$(sha256sum "$f" | cut -c1-16)"
    done
else
    echo "  manager APK: not in the tree (KSU_PREINSTALL_MANAGER=0 - the user installs one)"
fi
