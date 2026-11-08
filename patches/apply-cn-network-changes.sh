#!/bin/sh
# Makes the CN NTP and captive-portal (204) addresses apply regardless of the system
# language. Idempotent: skips anything already effective under values/.
# Usage: sh apply-cn-network-changes.sh [tree-root]   (or export LOS24_TREE; default: a sibling srcs/los24)
#
# Both resources already exist in the device tree with CN values - the problem was
# only where they sat: under values-zh-rCN/, so they took effect only when the system
# language was Chinese, and with English the platform fell back to time.android.com and
# connectivitycheck.gstatic.com. The system language is the user's to change, so
# network addresses should not follow it. What changes here is the *condition*, not
# the values.
#
# Readers (verified - overriding the wrong resource name fails silently):
#   NTP : frameworks/base/core/java/android/util/NtpTrustedTime.java
#         reads com.android.internal.R.array.config_ntpServers -> overlay package
#         "android", i.e. FrameworkResOverlayElish (AOSP default: ntp://time.android.com)
#   204 : packages/modules/Connectivity config_captive_portal_http_url / _https_url
#         -> overlay package com.android.networkstack, i.e. NetworkStackOverlayMIUI
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
RRO=$TREE/device/xiaomi/elish/rro_overlays
[ -d "$RRO" ] || { echo "no $RRO"; exit 1; }

# unlocalize <overlay dir> <resource name that proves it took effect> <block to insert>
# Writes the block into that overlay's res/values/config.xml just before </resources>,
# then deletes res/values-zh-rCN/config.xml (leaving it would create a second truth).
unlocalize() {
    dir="$RRO/$1"; marker="$2"; block=$3
    cur="$dir/res/values/config.xml"
    old="$dir/res/values-zh-rCN/config.xml"

    # Upstream may not have given this overlay a values/config.xml at all
    # (NetworkStackOverlayMIUI only had values-zh-rCN/). Then create one rather than
    # requiring it to exist.
    if [ ! -f "$cur" ] && [ -f "$old" ]; then
        mkdir -p "$dir/res/values"
        {
            printf '<?xml version="1.0" encoding="utf-8"?>\n'
            sed -n '/<!--/,/-->/p' "$old"    # carry the license header over from the old file
            printf '<resources>\n</resources>\n'
        } > "$cur"
        echo "$1 had no values/config.xml; created one (license header taken from the old file)"
    fi
    [ -f "$cur" ] || { echo "missing $cur and nothing to migrate from values-zh-rCN/"; exit 1; }

    if grep -q "$marker" "$cur"; then
        echo "$1: $marker already under values/, skipping"
    else
        # The block travels through ENVIRON: awk's -v re-parses escapes in its value and
        # would join the lines. Note the </resources> line is consumed by the match, so
        # the block has to put it back, or the XML loses its closing tag.
        BLOCK="$block" awk '
            /<\/resources>/ && !done {
                print ENVIRON["BLOCK"]
                print ""
                print "</resources>"
                done = 1
                next
            }
            { print }' "$cur" > "$cur.new" && mv "$cur.new" "$cur"
        grep -q "$marker" "$cur" || { echo "$1: insert failed ($marker not in values/config.xml)"; exit 1; }
        grep -q "^</resources>$" "$cur" || { echo "$1: values/config.xml lost its closing tag"; exit 1; }
        echo "$1: $marker written into values/config.xml"
    fi

    if [ -f "$old" ]; then
        rm "$old"
        rmdir "$dir/res/values-zh-rCN" 2>/dev/null || true
        echo "  removed the old values-zh-rCN/config.xml"
    fi
}

# $(cat) rather than read: read keeps only the first line and would truncate the
# multi-line comment and entries.
PORTAL=$(cat <<'EOF'
    <!-- Upstream kept these two only under values-zh-rCN/, so the MIUI probe
         addresses were used just when the system language was Chinese, and every
         other language fell back to connectivitycheck.gstatic.com. Both are
         reachable here, so the condition becomes unconditional (values unchanged). -->
    <string name="config_captive_portal_http_url">http://connect.rom.miui.com/generate_204</string>
    <string name="config_captive_portal_https_url">https://connect.rom.miui.com/generate_204</string>
EOF
)

NTP=$(cat <<'EOF'
    <!-- SNTP client config: NTP servers to use to obtain an accurate time.
         Items must be in the form: "ntp://<host>[:port]"
         This is not a registered IANA URI scheme.
         Upstream kept this only under values-zh-rCN/, so Aliyun NTP was used just
         when the system language was Chinese. NtpTrustedTime reads exactly this
         resource, so the condition becomes unconditional (value unchanged). -->
    <string-array translatable="false" name="config_ntpServers">
        <item>ntp://ntp.aliyun.com</item>
    </string-array>
EOF
)

unlocalize NetworkStackOverlayMIUI config_captive_portal_http_url "$PORTAL"
unlocalize FrameworkResOverlayElish config_ntpServers "$NTP"

echo
echo "after flashing:"
echo "  adb shell settings get global captive_portal_http_url   # empty = the config default is used; see the next line for the actual probe"
echo "  adb logcat -d -s ConnectivityManager | grep -i probe     # the probe address should be connect.rom.miui.com"
echo "review: git -C $TREE/device/xiaomi/elish diff"
