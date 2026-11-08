# The source delta

Two representations of the same thing, and both are kept because each is useful at a different
moment:

- **`apply-*.sh`** - idempotent scripts that *make* the changes. Use these when you work on the
  tree, because they are readable, they refuse to do something half-right, and they converge:
  running a script twice, or running it after switching a form, produces the same tree.
- **`generated/*.patch`** - the same changes frozen as patches, produced by `gen-patches.sh`
  from each project's `git diff`. Use these to review the delta, or to apply it to a tree you
  do not want to run the scripts against.

```
apply-all.sh                    runs 1-5 below, then gen-patches.sh
apply-device-changes.sh         1) landscape: vendor.prop + idc + device.mk copy rules
apply-cn-network-changes.sh     2) NTP / captive portal moved out of values-zh-rCN
apply-root-changes.sh           3) root: ReSukiSU clone + kernel patch + ksud delivery
apply-camera-compat-changes.sh  4) the device half of the camera sidebar (compat grant)
                                5) the framework and app patches, applied by apply-all.sh
gen-patches.sh                  6) freeze the result into generated/*.patch
files/                          content with no upstream counterpart (see below)
generated/                      the patches - generated, never edited by hand
```

```sh
sh apply-all.sh /path/to/los24        # idempotent; run it once after a fresh repo sync
```

## What a patch cannot carry, and how the scripts compensate

Two kinds of input are not patch content, and both caused a silent failure before being
handled:

- **A git repository.** ReSukiSU must be a clone with full history: its `Kbuild` derives the
  kernel version code from `git rev-list --count`, and tests that `../.git` exists. So
  `apply-root-changes.sh` places a clone (or clones it), pins the commit, and checks
  `rev-list` exactly - a shallow clone would otherwise build a ROM whose userspace refuses the
  kernel.
- **Binaries taken out of the manager APK.** `ksud` is literally that APK's
  `lib/arm64-v8a/libksud.so`. It is placed and sha256-checked by the script, never put in a
  patch. (In the optional preinstall form, the JNI libraries are extracted the same way, because
  nothing unpacks a partition APK.)

`files/` holds what has no upstream file to patch against: `ksu-install.rc`, `config.fs`,
`idc/*.idc`, `compat_framework_overrides.xml`. The tree copy is overwritten from `files/` on
every run, so there is exactly one source for each.

## `gen-patches.sh` guards, each of which is a scar

A patch that silently loses something is the worst failure mode here: the replay succeeds, the
build succeeds, and one change is simply absent. So generation fails loudly instead.

1. **A new file must be listed** in the `gen` line for its project, or `git diff` does not
   contain it at all (git needs intent-to-add). This is how the CN 204 override once vanished on
   a replay: git had recorded it as a rename of the `values-zh-rCN` file, and after a `reset`
   the rename disappeared from the diff.
2. **Any remaining untracked file must be explained.** Files matching `MAT_SKIP` are material
   (the binaries and the clone); anything else untracked means the list is incomplete, and that
   is an error, not a note.
3. **A patch may not shrink.** If the new patch would cover fewer files than the published one,
   the tree is only partially applied; generation stops and keeps the old patch as
   `<name>.lost`. (This guard exists because it happened: regenerating after running three of
   the four device-side scripts produced a "valid, reversible" device patch with the root block
   missing.)
4. **The result must pass `git apply --reverse --check`.** That, not the exit code of `git diff`,
   is what proves the patch describes the current work tree.

## Marker-delimited blocks in the two `.mk` files

The blocks this project writes into `device/xiaomi/elish/device.mk` and `BoardConfig.mk` are
delimited by a begin/end marker pair and **rewritten whole** on every run:

```
# --- root: managed by lineageos/patches/apply-root-changes.sh ---
…
# --- end root ---
```

Rewriting whole is what makes the two delivery forms converge - switching
`KSU_PREINSTALL_MANAGER` removes the lines that would otherwise point at a module that no longer
exists, which fails the build with a missing-file error. Stripping and inserting are exact
inverses (strip removes the block, one adjacent blank line, and trailing blank lines; insert adds
one leading blank line), so repeated runs are byte-stable.

The script **refuses to guess** where an unmarked block from an older version ends, and asks the
human to remove it. That rule is not caution for its own sake: a guessed end that never matched
once swallowed everything to end of file, including the `BoardConfigVendor.mk` include. A
duplicated block is recoverable; a silently deleted section is a missing partition.

## Verifying a change to these scripts

Comment-only or not, the test is the same and it is cheap:

```sh
TREE=/path/to/los24
sh apply-all.sh "$TREE"                                  # the scripts produce the tree
git -C "$TREE/device/xiaomi/elish" diff > /tmp/by-scripts.diff
# wipe that project, then apply only the generated patch:
git -C "$TREE/device/xiaomi/elish" reset -q && git -C "$TREE/device/xiaomi/elish" checkout -- . \
  && git -C "$TREE/device/xiaomi/elish" clean -fdq
git -C "$TREE/device/xiaomi/elish" apply patches/generated/device-xiaomi-elish.patch
git -C "$TREE/device/xiaomi/elish" ls-files --others --exclude-standard \
  | xargs -r -n1 git -C "$TREE/device/xiaomi/elish" add -N --
git -C "$TREE/device/xiaomi/elish" diff > /tmp/by-patch.diff
diff /tmp/by-scripts.diff /tmp/by-patch.diff             # must differ only in material
```

Script state and patch state must agree byte for byte except for material (`ksu/bin/ksud` and
anything else `MAT_SKIP` covers). That comparison is the reason the published patches can be
trusted without re-deriving them.

## Form switch

```sh
TREE=/path/to/los24
KSU_PREINSTALL_MANAGER=1 sh apply-root-changes.sh "$TREE"        # also preinstall a manager
KSU_MATERIAL_DIR=/path/to/apk/dir sh apply-root-changes.sh "$TREE"   # where the manager APK is kept
KSU_LOCAL_CLONE=/path/to/ReSukiSU sh apply-root-changes.sh "$TREE"   # place that clone, not a clone
```

The default (no preinstall) is what the ROM ships; the reasoning is in
[docs/root.md](../docs/root.md).
