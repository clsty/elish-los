#!/bin/sh
# Shared recipe for the verification apps in this repository: builds one APK from a directory
# holding *.java and an AndroidManifest.xml, using only the toolchain already inside an
# AOSP/LineageOS tree, so the host needs no SDK installed.
#
#   sh tools/mkapk.sh <tool-dir> <apk-name> [tree-root]      (or export LOS24_TREE)
#   Output: <tool-dir>/build/<apk-name>.apk
#
# Adding a tool therefore means writing a manifest, one Java class and a two-line build.sh;
# everything below is paid for once. Each oddity here was met while building one of them.
set -eu
[ $# -ge 2 ] || { echo "usage: sh mkapk.sh <tool-dir> <apk-name> [tree-root]" >&2; exit 2; }
DIR=$(cd "$1" && pwd)
NAME=$2

# The tree holds the toolchain: pass it here or in LOS24_TREE. The default is three levels up
# from this file - <repo>/tools -> the repository's sibling directory - because a reader from
# elsewhere will not have a tree at that path and gets the message below.
T=${3:-${LOS24_TREE:-}}
if [ -z "$T" ]; then T=$(cd "$DIR/../../../los24" 2>/dev/null && pwd) || T=""; fi
if [ -z "$T" ]; then
    echo "no source tree: sh mkapk.sh <dir> <name> /path/to/los24   (or export LOS24_TREE)" >&2
    exit 1
fi

JDK=$T/prebuilts/jdk/jdk21/linux-x86
AAPT2=$T/prebuilts/sdk/tools/linux/bin/aapt2
D8JAR=$T/prebuilts/sdk/tools/linux/lib/d8.jar
APKSIGNER_JAR=$T/prebuilts/sdk/tools/linux/lib/apksigner.jar
ZIPALIGN=$T/prebuilts/build-tools/linux-x86/bin/zipalign
JAR=$T/prebuilts/sdk/current/public/android.jar

for f in "$JDK/bin/javac" "$AAPT2" "$JAR" "$ZIPALIGN" "$D8JAR" "$APKSIGNER_JAR"; do
    [ -x "$f" ] || [ -f "$f" ] || { echo "missing tool: $f"; exit 1; }
done
export PATH=$JDK/bin:$PATH

OUT=$DIR/build
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

echo "== javac =="
# With JDK21, -bootclasspath is only accepted together with -source/-target 8 (9+ errors
# out), and these sources use nothing beyond Java 7/8 anyway.
"$JDK/bin/javac" -nowarn -Xlint:none -source 8 -target 8 \
    -bootclasspath "$JAR" -d "$OUT/classes" "$DIR"/*.java

echo "== d8 =="
# Not the prebuilts d8 / apksigner wrapper scripts: they are #!/bin/bash and resolve
# their jar through /bin/ls, and neither /bin/bash nor /bin/ls exists on a NixOS host
# ("bad interpreter", or "can't find d8.jar"). Call the jar directly with java -cp.
"$JDK/bin/java" -cp "$D8JAR" com.android.tools.r8.D8 \
    --lib "$JAR" --release --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

echo "== aapt2 link =="
# The manifest does not go through compile (that takes resources only); it goes
# straight to link.
"$AAPT2" link -o "$OUT/base.apk" -I "$JAR" --manifest "$DIR/AndroidManifest.xml" \
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
# Outside build/, because build/ is deleted at the top of every run and a regenerated key changes
# the APK signature - which makes `adb install -r` fail with INSTALL_FAILED_UPDATE_INCOMPATIBLE and
# forces an uninstall between rebuilds. Measured: two builds of the same tool, two signatures.
KS=$DIR/.signing/debug.keystore
mkdir -p "$DIR/.signing"
if [ ! -f "$KS" ]; then
    "$JDK/bin/keytool" -genkeypair -v -keystore "$KS" -storepass android \
        -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 \
        -validity 10000 -dname "CN=$NAME Debug, OU=-, O=-, L=-, S=-, C=US" >/dev/null 2>&1
fi
"$JDK/bin/java" -cp "$APKSIGNER_JAR" com.android.apksigner.ApkSignerTool sign \
    --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/$NAME.apk" "$OUT/aligned.apk"
"$JDK/bin/java" -cp "$APKSIGNER_JAR" com.android.apksigner.ApkSignerTool verify \
    --print-certs "$OUT/$NAME.apk" 2>/dev/null | head -2
