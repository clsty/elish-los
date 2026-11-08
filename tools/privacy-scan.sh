#!/bin/sh
# Public-repo gate #1: nothing that is only true on the author's machine may ship.
#
# Two classes, both easy to miss by eye:
#   PRIVATE  local paths, serials, container and directory names, and the manager
#            package name that exists precisely to *not* be public.
#   DANGLING a pointer to a file this repo does not ship (a working-note page, a
#            research snapshot, a log). A published doc that sends the reader to a
#            file that isn't here is a bug even when it contains no secret.
#
# Usage: sh tools/privacy-scan.sh [repo-root]     exit 0 = clean
# Add a token to the lists below when a new machine-specific name appears; the
# fix for a hit is to reword the doc, not to add an exception, unless the value
# really is part of the project (a fork URL a reader must clone, say).
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT"

PRIVATE='
/data/03
/home/dot
/dump/
/tmp/opencode
/tmp/ccache
4f328fac
9db02a9d
rmx
pctzoy
ask-expert
elish-build
los24-build
UNIT=
USD
'

# `BakaSU` is deliberately NOT in the list above, though it was. It is the public name of the
# upstream KernelSU fork (Baka-SU/BakaSU), which NOTICE and README must use; the private mirror
# of it carries the same word, so writing it leaks nothing. Do not add it back.

# Things that live in the working repository and are deliberately not published.
DANGLING='
STATUS.md
TODO.md
records/
research/
deprecated/
step1
step2
step3
step4
MATERIALS.sha256
acceptance.log
INFO-before
'

fail=0
scan() {   # $1 = category label, $2 = newline-separated token list
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        hits=$(git ls-files 2>/dev/null | grep -v '^tools/privacy-scan.sh$' |
               xargs grep -nF -- "$tok" 2>/dev/null || true)
        [ -n "$hits" ] || continue
        printf '%s: "%s"\n' "$1" "$tok"
        printf '%s\n' "$hits" | sed 's/^/    /'
        fail=$((fail + 1))
    done <<EOF
$2
EOF
}

scan PRIVATE "$PRIVATE"
scan DANGLING "$DANGLING"

# Non-ASCII check: the docs are English, so a leftover CJK line means an
# untranslated paragraph shipped by accident.
cjk=$(git ls-files '*.md' '*.sh' '*.py' '*.rc' '*.fs' '*.xml' '*.idc' 2>/dev/null |
      grep -v '^tools/privacy-scan.sh$' |
      xargs grep -lP '[\x{4e00}-\x{9fff}]' 2>/dev/null || true)
if [ -n "$cjk" ]; then
    echo "CJK: files that are not in English yet"
    printf '%s\n' "$cjk" | sed 's/^/    /'
    fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] && echo "privacy-scan: clean" || echo "privacy-scan: $fail item(s) to handle"
exit $(( fail > 0 ))
