#!/bin/sh
# Builds a minimal orientation-sensor client and installs nothing itself: it uses only
# the toolchain already in the AOSP tree, so no SDK has to be installed on the host.
# Usage: sh build.sh [tree-root]   (or export LOS24_TREE; default: the tree kept beside this
#                                  repository, which a reader from elsewhere will not have)
# Output: build/framecheck.apk; the judgement script next to it (check.py) uses it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# The toolchain comes from an AOSP/LineageOS tree: pass it here or in LOS24_TREE. The default is
# three levels up from this file - the repository root, then its sibling - because HERE is
# tools/framecheck, not the repository root. It used to say ../../srcs/los24, which is one level
# short and points inside this repository, so the documented bare invocation always failed to find
# a tree and only the explicit argument ever worked. A wrong directory that does exist still gets
# the clear `missing tool` line from the check below.
T=${1:-${LOS24_TREE:-}}
if [ -z "$T" ]; then T=$(cd "$HERE/../../../los24" 2>/dev/null && pwd) || T=""; fi
if [ -z "$T" ]; then
    echo "no source tree: sh build.sh /path/to/los24   (or export LOS24_TREE)" >&2
    exit 1
fi
OUT=$HERE/build
JDK=$T/prebuilts/jdk/jdk21/linux-x86
AAPT2=$T/prebuilts/sdk/tools/linux/bin/aapt2
D8=$T/prebuilts/sdk/tools/linux/bin/d8
APKSIGNER=$T/prebuilts/sdk/tools/linux/bin/apksigner
ZIPALIGN=$T/prebuilts/build-tools/linux-x86/bin/zipalign
JAR=$T/prebuilts/sdk/current/public/android.jar

for f in "$JDK/bin/javac" "$AAPT2" "$D8" "$APKSIGNER" "$ZIPALIGN" "$JAR"; do
    [ -x "$f" ] || [ -f "$f" ] || { echo "missing tool: $f"; exit 1; }
done
export PATH=$JDK/bin:$PATH

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

echo "== javac =="
# With JDK21, -bootclasspath is only accepted together with -source/-target 8 (9+ errors
# out), and the source uses nothing beyond Java 7/8 anyway.
"$JDK/bin/javac" -nowarn -Xlint:none -source 8 -target 8 \
    -bootclasspath "$JAR" -d "$OUT/classes" "$HERE/FrameCheck.java"

echo "== d8 =="
# Not the prebuilts d8 / apksigner wrapper scripts: they are #!/bin/bash and resolve
# their jar through /bin/ls, and neither /bin/bash nor /bin/ls exists on a NixOS host
# ("bad interpreter", or "can't find d8.jar"). Call the jar directly with java -cp.
D8JAR=$T/prebuilts/sdk/tools/linux/lib/d8.jar
"$JDK/bin/java" -cp "$D8JAR" com.android.tools.r8.D8 \
    --lib "$JAR" --release --output "$OUT/dex" "$OUT"/classes/com/framecheck/*.class

echo "== aapt2 link =="
# The manifest does not go through compile (that takes resources only); it goes
# straight to link.
"$AAPT2" link -o "$OUT/base.apk" -I "$JAR" --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 34 --target-sdk-version 36

echo "== add classes.dex (python for the zip, so the host needs no zip command) =="
python3 - "$OUT/base.apk" "$OUT/unsigned.apk" "$OUT/dex/classes.dex" <<'PY'
import sys, zipfile, shutil
src, dst, dex = sys.argv[1], sys.argv[2], sys.argv[3]
shutil.copyfile(src, dst)
with zipfile.ZipFile(dst, 'a', zipfile.ZIP_DEFLATED) as z:
    z.write(dex, 'classes.dex')
PY

echo "== zipalign + apksigner =="
"$ZIPALIGN" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
KS=$OUT/debug.keystore
if [ ! -f "$KS" ]; then
    "$JDK/bin/keytool" -genkeypair -v -keystore "$KS" -storepass android \
        -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 \
        -validity 10000 -dname "CN=FrameCheck Debug, OU=-, O=-, L=-, S=-, C=US" >/dev/null 2>&1
fi
APKSIGNER_JAR=$T/prebuilts/sdk/tools/linux/lib/apksigner.jar
"$JDK/bin/java" -cp "$APKSIGNER_JAR" com.android.apksigner.ApkSignerTool sign \
    --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/framecheck.apk" "$OUT/aligned.apk"
"$JDK/bin/java" -cp "$APKSIGNER_JAR" com.android.apksigner.ApkSignerTool verify \
    --print-certs "$OUT/framecheck.apk" 2>/dev/null | head -2

echo
echo "output: $OUT/framecheck.apk"
echo "install and run: adb install -r -g $OUT/framecheck.apk && python3 $HERE/check.py 12"
