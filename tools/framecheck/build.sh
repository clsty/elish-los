#!/bin/sh
# Builds the orientation-sensor client. The recipe is shared with the other verification apps
# (../mkapk.sh) because it is the same six tools from the same AOSP tree; this file only names
# this tool. The tree is taken from an argument or LOS24_TREE, and a sibling los24 otherwise -
# which a reader from elsewhere will not have, so pass it.
# Output: build/framecheck.apk; check.py next to this file uses it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec sh "$HERE/../mkapk.sh" "$HERE" framecheck "$@"
