#!/bin/sh
# Builds the attestation client. The recipe is shared with the other verification apps
# (../mkapk.sh); this file only names this tool. See check.py next to it for the judgement.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec sh "$HERE/../mkapk.sh" "$HERE" attestcheck "$@"
