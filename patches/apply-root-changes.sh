#!/bin/sh
# Builds root into the ROM: the ReSukiSU + SuSFS kernel side, the delivery of ksud, and
# an optional preinstalled manager. Idempotent: re-running never duplicates anything and
# never replaces pinned material. The two blocks this writes into device.mk and
# BoardConfig.mk are marker-delimited and rewritten whole, so switching form (preinstall
# or not) converges and cannot leave a line pointing at a module that is gone.
# Usage: sh apply-root-changes.sh [tree-root]   (or export LOS24_TREE; default: a sibling srcs/los24)
#        KSU_PREINSTALL_MANAGER=1 sh apply-root-changes.sh     # also preinstall a manager
#
# Why root needs kernel patches here (4.19 is not GKI, so there is no zero-delta route)
# is explained in the root doc. This script only handles what a patch cannot carry: the
# 91 M ReSukiSU clone and the 8.5 M manager APK that ksud is taken from. The source
# delta (hooks + SuSFS + wiring + config fragment) is
# generated/kernel-xiaomi-sm8250-ksu-susfs.patch.
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
# Where the manager APK is kept (ksud and the JNI libraries come out of it). Default is
# this project's material dir; point KSU_MATERIAL_DIR somewhere else if you keep it out
# of the tree.
PROJ=${KSU_MATERIAL_DIR:-$HERE/../material}
# find_apk: the pinned file if present, else the only APK in the material directory.
# A same-release APK from upstream is a legitimate input, so refusing to look at it would
# be pedantry; using it silently would be worse, so it is announced.
find_apk() {
    if [ -f "$PROJ/$KSU_MANAGER" ]; then echo "$PROJ/$KSU_MANAGER"; return 0; fi
    n=$(find "$PROJ" -maxdepth 1 -name '*.apk' 2>/dev/null | wc -l)
    if [ "$n" = 1 ]; then
        found=$(find "$PROJ" -maxdepth 1 -name '*.apk' | head -1)
        echo "  note: $KSU_MANAGER not in $PROJ; using $found instead (only APK there)." >&2
        echo "  its sha256 is $(sha256sum "$found" | cut -d' ' -f1 | cut -c1-16)... - set KSU_MANAGER/KSU_MANAGER_SHA256 to pin it." >&2
        echo "$found"; return 0
    fi
    echo "no $PROJ/$KSU_MANAGER and $n APKs in that directory (put exactly one manager APK there," >&2
    echo "    or point KSU_MATERIAL_DIR at one)" >&2
    return 1
}

# ---- The pinned values (each one's basis: the head of generated/kernel-xiaomi-sm8250-ksu-susfs.patch) ----
KSU_TAG=v4.2.0-rc1
KSU_COMMIT=a9216b04e29cc973ddbf845342f2cbf85b47b460
KSU_REVLINES=4361                     # Kbuild derives the version code from it: 30000 + 4361 + 700 = 35061
# The APK this build was made with. It is a build input, not something the platform needs:
# only the ksud binary inside it is delivered (next lines), so any manager APK of the same
# release works, and these two values are overridable for exactly that reason. If the named
# file is absent, the scripts use the single *.apk found in KSU_MATERIAL_DIR and say so.
# The default is the upstream release asset, because that is the file anyone else can fetch.
# The build documented here used a manager built from a private fork with a randomized package
# name: its whole-APK hash differs, while its lib/arm64-v8a/libksud.so is byte-identical to the
# official one below (measured: both sha256 fb049cdc...d85d). Pass KSU_MANAGER and
# KSU_MANAGER_SHA256 to use such an APK instead.
KSU_MANAGER=${KSU_MANAGER:-ReSukiSU_v4.2.0-rc1_35061-arm64-v8a-release.apk}
KSU_MANAGER_SHA256=${KSU_MANAGER_SHA256:-544cf6cb105acacf219b3db71e43b9818e3f335153763e56aa0356bd09d1b450}
# ksud is literally the manager APK's lib/arm64-v8a/libksud.so, and that hash is the real
# invariant here: the delivered userspace must be the same release as the manager the user
# installs. The ROM installs it as /product/bin/ksud and the rc execs that path.
KSUD_SHA=fb049cdcd2ffac43c43d6e1a52bfae5f0c5328f94c1398e977159020c026d85d

# Delivery form. Default: deliver ksud only, preinstall no manager (the form this project
# ships).
#   0 = the image carries /product/bin/ksud and the user installs a manager - the official
#       release, or a build with a package name of their own. A randomised package name
#       is a secret, so it must not enter a published image.
#   1 = additionally preinstall KSU_PKG into /product/app (convenient, but the package
#       name then ships in the image).
# The ksud delivery is identical in both forms (same file, same rc line); only the
# manager itself differs, so section 4c has one migration to make.
KSU_PREINSTALL_MANAGER=${KSU_PREINSTALL_MANAGER:-0}
# Package name used by the preinstall form. The kernel identifies a manager by parsing its
# APK path (see the Android.bp comment below), so the name appears in three places:
# Android.bp, device.mk and the JNI directory. Changing KSU_PKG means replacing the whole set
# of materials, and section 4c is what migrates an existing tree (the old name is read out of
# Android.bp, never hard-coded here).
#
# The default is the upstream package name because that is what a reader who merely flips the
# flag wants. If root hiding matters to you, pass your own through this variable instead: a
# package name chosen to make a manager unrecognizable stops being a secret the moment it
# ships in a published image (see docs/root.md).
KSU_PKG=${KSU_PKG:-com.resukisu.resukisu}
# Optional shortcut for a fresh tree: KSU_LOCAL_CLONE=<path to a ReSukiSU git clone> places
# that clone instead of hitting the network. Left unset, the kernel project is cloned from
# the URL below (the clone already in the tree is always reused, so this only matters once).
KSU_LOCAL=${KSU_LOCAL_CLONE:-}

KERNEL=$TREE/kernel/xiaomi/sm8250
DEV=$TREE/device/xiaomi/elish
[ -d "$KERNEL" ] || { echo "no kernel at $KERNEL (run repo sync first)"; exit 1; }

# ---- 1) ReSukiSU itself: must be a clone with full history, at the kernel root ----
# Kbuild tests whether drivers/kernelsu/../.git exists (KSU_SRC is resolved through the
# symlink), so copying kernel/ files into drivers/kernelsu trips
#   "You should use ReSukiSU as a git submodule instead of copying code directly";
# and the version code counts rev-list, so a --depth clone is out too.
if [ -e "$KERNEL/KernelSU" ]; then
    echo "KernelSU already in the tree"
elif [ -d "$KSU_LOCAL/.git" ]; then
    cp -a "$KSU_LOCAL" "$KERNEL/KernelSU"   # no hardlinks
    echo "KernelSU placed from the local clone ($KSU_LOCAL)"
else
    git clone https://github.com/Baka-SU/BakaSU "$KERNEL/KernelSU"   # published as ReSukiSU at the pinned tag
    echo "KernelSU cloned (no local clone available, went to the network)"
fi
git -C "$KERNEL/KernelSU" checkout --quiet --detach "$KSU_COMMIT" 2>/dev/null || true

got=$(git -C "$KERNEL/KernelSU" rev-parse HEAD)
n=$(git -C "$KERNEL/KernelSU" rev-list --count HEAD)
tag=$(git -C "$KERNEL/KernelSU" describe --abbrev=0 --tags 2>/dev/null || echo none)
dirty=$(git -C "$KERNEL/KernelSU" status --porcelain | wc -l)
[ "$got" = "$KSU_COMMIT" ] || { echo "wrong KernelSU commit: $got != $KSU_COMMIT"; exit 1; }
[ "$n" = "$KSU_REVLINES" ] || { echo "KernelSU history incomplete: rev-list=$n != $KSU_REVLINES (a shallow clone miscomputes the version code)"; exit 1; }
# ReSukiSU is its own git repository and carries one delta of ours: teach the scanner to
# recognise a manager preinstalled in /product/app. Without it the process's seccomp does
# not allow reboot(2), so the manager's exec of libksud.so dies with SIGSYS. So "clean"
# here does not mean zero changes - it means "exactly this patch".
KS_PATCH="$HERE/generated/kernelsu-preinstalled-manager.patch"
ks_dirty_ok() {
    [ "${1:-0}" = 0 ] && return 0
    [ -f "$KS_PATCH" ] && git -C "$KERNEL/KernelSU" apply --reverse --check "$KS_PATCH" 2>/dev/null
}
ks_dirty_ok "$dirty" || {
    echo "KernelSU work tree is dirty ($dirty changes) and that is not $KS_PATCH; look at git -C $KERNEL/KernelSU diff first"
    exit 1
}
echo "  commit=$got tag=$tag rev-list=$n -> kernel version code $((30000 + n + 700)) (the manager's versionCode must equal it)"

# ---- 2) The symlink: drivers/kernelsu -> ../KernelSU/kernel (the same one setup.sh makes) ----
ln -sfn ../KernelSU/kernel "$KERNEL/drivers/kernelsu"
[ -e "$(readlink -f "$KERNEL/drivers/kernelsu")/../.git" ] || {
    echo "the symlink does not resolve to something with ../.git; Kbuild would stop immediately"; exit 1; }
echo "drivers/kernelsu -> $(readlink "$KERNEL/drivers/kernelsu")"

# ---- 3) Source delta: hooks + SuSFS + drivers/{Makefile,Kconfig} wiring + config fragment ----
patch="$HERE/generated/kernel-xiaomi-sm8250-ksu-susfs.patch"
if git -C "$KERNEL" apply --reverse --check "$patch" 2>/dev/null; then
    echo "kernel patch already applied, skipping"
elif git -C "$KERNEL" apply --check "$patch" 2>/dev/null; then
    git -C "$KERNEL" apply "$patch"
    echo "kernel patch applied"
else
    echo "kernel patch context does not match (kernel revision changed?) - redo it by hand"
    exit 1
fi
h=$(grep -c "ksu_handle_" "$KERNEL/kernel/sys.c" "$KERNEL/fs/exec.c" "$KERNEL/fs/open.c" \
        "$KERNEL/fs/stat.c" "$KERNEL/kernel/reboot.c" "$KERNEL/drivers/input/input.c" |
    awk -F: '{s+=$2} END {print s+0}')
[ "$h" -gt 0 ] || { echo "zero ksu_handle_ hooks across the six files - the patch did not take"; exit 1; }
echo "  $h ksu_handle_ hook sites (these are what inline_hook_check.mk counts)"

# ---- 3b) The delta inside the ReSukiSU repository itself ----
[ -f "$KS_PATCH" ] || { echo "missing $KS_PATCH (run gen-patches.sh first)"; exit 1; }
if git -C "$KERNEL/KernelSU" apply --reverse --check "$KS_PATCH" 2>/dev/null; then
    echo "KernelSU-side patch already applied, skipping"
elif git -C "$KERNEL/KernelSU" apply --check "$KS_PATCH" 2>/dev/null; then
    git -C "$KERNEL/KernelSU" apply "$KS_PATCH"
    echo "KernelSU-side patch applied (throne_tracker also scans /product/app; package parsing tolerates a name without a hyphen)"
else
    echo "KernelSU-side patch context does not match (KernelSU revision changed?) - replay by hand"
    exit 1
fi

# ---- 4) Hook the config fragment into TARGET_KERNEL_CONFIG (it must come last) ----
bc="$DEV/BoardConfig.mk"
if grep -q "ksu-susfs.config" "$bc"; then
    echo "BoardConfig.mk already references ksu-susfs.config, skipping"
else
    awk '
    { print }
    !done && /^TARGET_KERNEL_CONFIG \+= vendor\/xiaomi\/elish\.config$/ {
        print "# ReSukiSU + SuSFS: root lives in the ROM itself, not in a separately flashed"
        print "# boot image. This fragment must come last, or an earlier fragment overrides its symbols."
        print "TARGET_KERNEL_CONFIG += vendor/xiaomi/ksu-susfs.config"
        done = 1
    }' "$bc" > "$bc.new" && mv "$bc.new" "$bc"
    grep -q "ksu-susfs.config" "$bc" || { echo "BoardConfig.mk: anchor did not match"; exit 1; }
    echo "BoardConfig.mk: ksu-susfs.config inserted"
fi

# ---- 4c) Manager material migration (a package-name change and the form switch both land here) ----
# What the tree has (the module name in bp, i.e. the old package name; no bp means "no
# preinstall") versus what the target form wants. On a mismatch the whole manager set is
# retired and rebuilt by sections 5 / 5b from the current pins. The old name is read from
# bp, never hard-coded; device.mk is not sed'ed because section 6 rewrites that block
# whole (see the region marker).
tree_pkg=$(sed -n 's/^[[:space:]]*name: "\([^"]*\)",/\1/p' "$DEV/ksu/Android.bp" 2>/dev/null | head -1)
want_pkg=""
[ "$KSU_PREINSTALL_MANAGER" = 1 ] && want_pkg=$KSU_PKG
if [ "${tree_pkg:-}" != "$want_pkg" ]; then
    [ -n "${tree_pkg:-}" ] && echo "manager material retired: $tree_pkg (what the tree had)"
    [ -n "$want_pkg" ] && echo "manager material added: $want_pkg"
    rm -f "$DEV/ksu"/*.apk "$DEV/ksu/Android.bp" "$DEV/ksu/lib/arm64"/*.so
    rmdir "$DEV/ksu/lib/arm64" "$DEV/ksu/lib" 2>/dev/null || true
fi

# ---- 5) The preinstalled manager APK (only when KSU_PREINSTALL_MANAGER=1) ----
if [ "$KSU_PREINSTALL_MANAGER" = 1 ]; then
    mkdir -p "$DEV/ksu"
    if [ -f "$DEV/ksu/$KSU_MANAGER" ]; then
        echo "manager APK already in the tree"
    else
        src=$(find_apk) || exit 1
        cp "$src" "$DEV/ksu/$KSU_MANAGER"
        echo "manager APK copied from $(basename "$src")"
    fi
    got=$(sha256sum "$DEV/ksu/$KSU_MANAGER" | cut -d" " -f1)
    [ "$got" = "$KSU_MANAGER_SHA256" ] || { echo "APK hash mismatch: $got (expected $KSU_MANAGER_SHA256). If this is another manager APK of the same release, that is expected - set KSU_MANAGER_SHA256 to its hash once you have verified libksud.so against KSUD_SHA."; exit 1; }
    echo "  sha256=$got"
    if [ -f "$DEV/ksu/Android.bp" ]; then
        echo "ksu/Android.bp already there, skipping"
    else
        cat > "$DEV/ksu/Android.bp" <<'BP'
// ReSukiSU manager, preinstalled. This is the optional form: this ROM delivers root
// through /product/bin/ksud (see ksu/etc/init/ksu-install.rc), and a manager is not
// required for that. Preinstalling one is convenient but costs the package-name
// randomisation, since the package name becomes visible in the shipped image.
//
// The module name and the installed file name are not free choices here. The kernel
// crowns the manager by parsing its APK path (KernelSU
// manager/apk_sign.c:get_pkg_from_apk_path), which takes the second-to-last path
// segment as the package name, and its directory scan only accepts a file named
// exactly base.apk (manager/throne_tracker.c:my_actor). So the install dir has to be
// the package name and the APK has to be called base.apk.
//
// The kernel's version code is what Kbuild computes from this checkout:
// 30000 + <ReSukiSU rev-list> + 700 = 30000 + 4361 + 700 = 35061. A manager of the same
// release normally carries the same number. What has to agree is the release line and its
// uapi (2 here), not the version code digit for digit: a manager built one CI run ahead
// (35066) was measured working against this kernel (35061), showing both versions side by
// side in the app's own status page.
//
// The APK is kept byte-for-byte as released (presigned: the build must not re-sign
// it, or the manager would stop matching the kernel's uapi checks).
//
// preprocessed is required here, not cosmetic: for a presigned APK with
// targetSdkVersion >= 30 the build refuses it otherwise, because it would re-zip and
// re-sign and thereby wreck the v2 signature. skip_preprocessed_apk_checks is the
// second half of that: with preprocessed on, the build then insists the APK's JNI
// libraries are stored uncompressed, and the upstream release APK ships them
// compressed. Uncompressing them would mean repacking, which breaks the very
// signature preprocessed exists to protect - so the check is skipped. Compressed JNI
// is survivable only because the libraries are also shipped next to the APK as files
// (device.mk): for an APK sitting on a partition nothing ever unpacks it, which is
// the measured "libksud.so was not found in the application native library path".
android_app_import {
    name: "@KSU_PKG@",
    filename: "base.apk",
    owner: "ReSukiSU",
    apk: "@KSU_APK@",
    presigned: true,
    preprocessed: true,
    skip_preprocessed_apk_checks: true,
    product_specific: true,
    dex_preopt: {
        enabled: false,
    },
}
BP
        sed -i "s/@KSU_PKG@/$KSU_PKG/g; s/@KSU_APK@/$KSU_MANAGER/g" "$DEV/ksu/Android.bp"
        echo "ksu/Android.bp written"
    fi
else
    echo "no manager preinstalled (KSU_PREINSTALL_MANAGER=0): the ROM delivers ksud, the user installs a manager"
fi

check_sha() {   # $1 = file $2 = expected sha256
    got=$(sha256sum "$1" | cut -d" " -f1)
    [ "$got" = "$2" ] || { echo "$(basename "$1") hash mismatch: $got"; exit 1; }
    printf '  %-12s sha256 %s...\n' "$(basename "$1")" "$(cut -c1-16 <<<"$got")"
}

# ---- 5b) Material on disk: the ksud binary (both forms), the JNI libraries (preinstall only) ----
# ksud comes out of the APK, so userspace and a manager of that release always agree.
mkdir -p "$DEV/ksu/bin"
if [ ! -f "$DEV/ksu/bin/ksud" ]; then
    src=$(find_apk) || exit 1
    echo "  extracting ksud from $(basename "$src")"
    python3 - "$src" "$DEV/ksu/bin/ksud" <<'PY'
import sys, zipfile
apk, dst = sys.argv[1:3]
open(dst, "wb").write(zipfile.ZipFile(apk).read("lib/arm64-v8a/libksud.so"))
PY
fi
chmod 0755 "$DEV/ksu/bin/ksud"
check_sha "$DEV/ksu/bin/ksud" "$KSUD_SHA"

if [ "$KSU_PREINSTALL_MANAGER" = 1 ]; then
    # The manager looks libksud.so up by path and execs it (it does not dlopen it), and a
    # partition APK is never unpacked, so these .so files have to be delivered as files.
    # Without them the measured result is
    #   "libksud.so was not found in the application native library path".
    # The x bit is not decoration: libksud.so is exec'd, and a file without +x cannot be
    # exec'd even by root (measured).
    LIBDIR=$DEV/ksu/lib/arm64
    mkdir -p "$LIBDIR"
    for lib in libadbroot.so libandroidx.graphics.path.so libdatastore_shared_counter.so \
               libkernelsu.so libksud.so; do
        if [ ! -f "$LIBDIR/$lib" ]; then
            python3 - "$DEV/ksu/$KSU_MANAGER" "$LIBDIR/$lib" "$lib" <<'PY'
import sys, zipfile
apk, dst, name = sys.argv[1:4]
open(dst, "wb").write(zipfile.ZipFile(apk).read("lib/arm64-v8a/" + name))
PY
            echo "  $lib extracted from the APK"
        fi
        chmod 0755 "$LIBDIR/$lib"
    done
    check_sha "$LIBDIR/libadbroot.so"                  55693ea2b3b3000a498f827d8efdc856a58bffc1d5489cc0ebaa5f59bec51ee6
    check_sha "$LIBDIR/libandroidx.graphics.path.so"   41e9a793c43a0f4fddb19e33f346bace464f30f888ba7b9eaf96294ea115bfb6
    check_sha "$LIBDIR/libdatastore_shared_counter.so" 178f89a2c6c9234ddf980dd4cd1f3616186a46b2b932aafa6707abd04c5fd76a
    check_sha "$LIBDIR/libkernelsu.so"                 424f2c7590862f02e91267cd5965e37991d7100052831f34ade0f88370851957
    check_sha "$LIBDIR/libksud.so"                     fb049cdcd2ffac43c43d6e1a52bfae5f0c5328f94c1398e977159020c026d85d
fi

# The rc and config.fs: files/ is the only source (same arrangement as the idc files), and
# the copy in the tree is overwritten every run. The rc no longer contains a package name
# (it execs /product/bin/ksud). config.fs expands @KSU_PKG@ in the preinstall form and
# drops that whole block otherwise - the package name is the user's secret and should not
# appear in the image.
mkdir -p "$DEV/ksu/etc/init"
cp "$HERE/files/ksu-install.rc" "$DEV/ksu/etc/init/ksu-install.rc"
if [ "$KSU_PREINSTALL_MANAGER" = 1 ]; then
    sed "s/@KSU_PKG@/$KSU_PKG/g" "$HERE/files/config.fs" > "$DEV/config.fs"
else
    sed -e 's/@KSU_PKG@/none/g' -e '/# BEGIN manager-jni/,/# END manager-jni/d' \
        "$HERE/files/config.fs" > "$DEV/config.fs"
fi
grep -q "@KSU_PKG@" "$DEV/config.fs" && { echo "config.fs: placeholder left unexpanded"; exit 1; }

# ---- 5c) The root block in BoardConfig.mk (marker-delimited, rewritten every run) ----
beg="# --- root: managed by lineageos/patches/apply-root-changes.sh ---"
end="# --- end root ---"
blk="$DEV/.root-block"
{
    printf '%s\n' "$beg"
    cat <<'CFG'
# The manager execs ksud; the image's file modes come from fs_config, not from the
# staging directory (measured: 0755 in out/, 0644 on device), so the delivered ksud
# needs an explicit 0755 there. Why the entries are what they are: config.fs.
TARGET_FS_CONFIG_GEN += $(DEVICE_PATH)/config.fs

# ksud and the JNI libraries are ELF files shipped through PRODUCT_COPY_FILES, because
# their destinations are not somewhere a cc_prebuilt_* module can install to. That
# trips the ELF-in-COPY_FILES hint; this is the opt-out it lacks.
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
CFG
    printf '%s\n' "$end"
} > "$blk"
# Strip = remove the marked block, one adjacent blank line before it, and any blank lines
# at end of file. The inserter adds one leading blank line and no trailing one, so the two
# are exact inverses: repeated runs are byte-stable (verified by running twice and
# diffing).
strip_block() {   # $1 = file
    awk -v beg="$beg" -v end="$end" '
        {
            if ($0 == beg) { skip = 1; while (m > 0 && out[m - 1] == "") m--; next }
            if (skip) { if ($0 == end) skip = 0; next }
            out[m++] = $0
        }
        END { while (m > 0 && out[m - 1] == "") m--; for (i = 0; i < m; i++) print out[i] }
    ' "$1" > "$1.new" && mv "$1.new" "$1"
}
# An earlier version of this script wrote an unmarked block. Detect it, do not guess at
# its end: guessing cost one incident (in BoardConfig.mk the guessed end never matched, so
# the strip swallowed everything to end of file, including the include of
# BoardConfigVendor.mk). A leftover duplicate is recoverable; a wrongly deleted section is
# a whole missing partition, so the human removes it and is told exactly what to remove.
no_legacy() {   # $1 = file
    grep -q "^# Root$" "$1" || return 0
    cat >&2 <<EOF
$1 still contains an unmarked "# Root" section from an older version of this script.
Delete the line "# Root" through the end of that section: the block this script manages
starts with "$beg". Leaving it behind duplicates the ksud and JNI copy rules, and in the
no-preinstall form it would still point at the deleted ksu/lib/arm64, which fails the
build with a missing-file error.
EOF
    exit 1
}
no_legacy "$bc"
strip_block "$bc"
awk -v blk="$blk" '
    { print }
    !done && /^\$\(call soong_config_set_bool,recovery,/ {
        print ""
        while ((getline line < blk) > 0) print line
        close(blk); done = 1
    }' "$bc" > "$bc.new" && mv "$bc.new" "$bc"
rm -f "$blk"
grep -qF "$beg" "$bc" || { echo "BoardConfig.mk: anchor did not match"; exit 1; }
echo "BoardConfig.mk: root block rewritten"

# ---- 6) The root block in device.mk (marker-delimited, rewritten every run) ----
pm="$DEV/device.mk"
blk="$DEV/.root-mk-block"
{
    printf '%s\n' "$beg"
    cat <<'MK'
# The kernel side (ReSukiSU + SuSFS) is in kernel/xiaomi/sm8250, see
# arch/arm64/configs/vendor/xiaomi/ksu-susfs.config. The ROM delivers the userspace
# half too, so root needs nothing beyond this ROM - but it delivers only ksud. The
# manager is left to the user on purpose: a package name used to hide root is a secret,
# and shipping one in the image would publish it for everyone.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/ksu/bin/ksud:$(TARGET_COPY_OUT_PRODUCT)/bin/ksud

# Seeds /data/adb/ksud, which is where the kernel's own appended init.rc execs ksud
# from. Why it is needed at all: ksu/etc/init/ksu-install.rc.
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/ksu/etc/init,$(TARGET_COPY_OUT_PRODUCT)/etc/init)
MK
    if [ "$KSU_PREINSTALL_MANAGER" = 1 ]; then
        cat <<'MK2'

# Optional form only: the preinstalled manager. The module is named after the package
# because the kernel parses the APK path to crown the manager (see ksu/Android.bp), and
# its JNI dir has to be provided as files because nothing unpacks a partition APK.
PRODUCT_PACKAGES += \
    @KSU_PKG@
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/ksu/lib/arm64,$(TARGET_COPY_OUT_PRODUCT)/app/@KSU_PKG@/lib/arm64)
MK2
    fi
    printf '%s\n' "$end"
} > "$blk"
sed -i "s/@KSU_PKG@/$KSU_PKG/g" "$blk"
no_legacy "$pm"
strip_block "$pm"
if grep -q "^# RRO Overlays$" "$pm"; then
    awk -v blk="$blk" '
        /^# RRO Overlays$/ && !done {
            while ((getline line < blk) > 0) print line
            print ""; close(blk); done = 1
        }
        { print }' "$pm" > "$pm.new" && mv "$pm.new" "$pm"
else
    printf '\n' >> "$pm"; cat "$blk" >> "$pm"; printf '\n' >> "$pm"
fi
rm -f "$blk"
grep -qF "$beg" "$pm" || { echo "device.mk: anchor # RRO Overlays did not match"; exit 1; }
grep -q "ksu/bin/ksud" "$pm" || { echo "device.mk has no ksud line"; exit 1; }
echo "device.mk: root block rewritten (form: $([ "$KSU_PREINSTALL_MANAGER" = 1 ] && echo "ksud + preinstalled manager" || echo "ksud only"))"

echo
echo "review: git -C $KERNEL diff && git -C $DEV diff"
echo "revert: rm -rf $KERNEL/KernelSU $KERNEL/drivers/kernelsu, then git reset -q && git checkout -- . in both repos,"
echo "        rm -rf $DEV/ksu $DEV/config.fs, and delete the marker-delimited root blocks from the two .mk files"
echo "        (or git checkout them)"
