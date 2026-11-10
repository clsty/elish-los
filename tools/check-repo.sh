#!/bin/sh
# Everything that can be checked without a device. Run this before publishing a change:
#
#   sh tools/check-repo.sh            exit 0 = the repository is self-consistent
#
# Five gates, each one because something slipped past a human once:
#   syntax      every shell script parses, every python file compiles
#   doc blocks  every ```sh block in every md file parses (documentation that cannot run is
#               not documentation - commands here are written to be copied)
#   links       every relative link in the markdown points at a file that is in the repository
#   privacy     nothing that is only true on the author's machine shipped, and no pointer to a
#               file this repository does not publish (see tools/privacy-scan.sh)
#   urls        every external address answers 2xx and does not rely on a redirect
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT"
fail=0
say() { printf '%-12s %s\n' "$1" "$2"; }

# 1) Syntax.
for f in $(git ls-files '*.sh'); do
    sh -n "$f" || { say syntax "FAIL $f"; fail=1; }
done
for f in $(git ls-files '*.py'); do
    python3 -m py_compile "$f" || { say syntax "FAIL $f"; fail=1; }
done
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
[ "$fail" -eq 0 ] && say syntax ok

# 2) The commands inside the documentation.
python3 tools/check-sh-blocks.py docs . tools patches | tail -1 | sed 's/^/doc blocks /'
python3 tools/check-sh-blocks.py docs . tools patches >/dev/null || { say doc-blocks FAIL; fail=1; }

# 3) Links. A published document that points at a page this repository does not publish is a
#    bug even when it contains no secret, so this is checked, not eyeballed.
links=$(git ls-files '*.md' | xargs grep -hoE '\]\(([^)#?]*)(#[^)]*)?\)' 2>/dev/null | sed 's/^](//; s/)$//; s/#.*$//' | sort -u | grep -v '^http' || true)
broken=0
for l in $links; do
    [ -n "$l" ] || continue
    # Links are relative to the file that contains them; check them from every markdown file,
    # which is simpler and conservative: a link resolves if it resolves somewhere.
    found=0
    for d in . docs patches tools tools/framecheck; do
        [ -e "$d/${l#./}" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
        where=$(git ls-files '*.md' | xargs grep -lF "]($l" 2>/dev/null | head -1)
        say links "FAIL $l (referenced by ${where:-?})"
        broken=1
    fi
done
[ "$broken" -eq 0 ] && say links ok
[ "$broken" -eq 1 ] && fail=1

# 4) Privacy and dangling pointers.
out=$(mktemp)
if sh tools/privacy-scan.sh >"$out" 2>&1; then
    say privacy ok
else
    say privacy "see below"
    sed 's/^/  /' "$out"
    fail=1
fi
rm -f "$out"

# 5) External addresses. Gate 3 covers relative links; an address that 404s, or that answers
#    only because GitHub still redirects an old repository name, is invisible to it - and two
#    upstreams referenced here have already renamed themselves once. Absent network is a note,
#    not a failure: what this gate is for is the moment of publishing, when there is one.
ext=$(git ls-files '*.md' NOTICE | xargs grep -hoE 'https?://[^ )"'"'"'>`]+' 2>/dev/null | sed 's/[.,;>]$//' | sort -u)
# `>` is not part of an address: markdown autolinks are written <https://…>, and including it turned a
# correct link into a 404 (measured while poisoning this gate).
gh_pair() { printf '%s' "$1" | sed -n 's|.*github\.com/\([^/]*\)/\([^/]*\).*|\1/\2|p'; }
url_fail=0; url_warn=0; url_off=0; url_n=0
for u in $ext; do
    url_n=$((url_n + 1))
    # HEAD, not GET: an address gate that downloads what it mentions pulls 1.7 GB here (the three
    # release assets), and a gate that costs minutes does not get run. HEAD answers the only two
    # things this needs - status and effective URL. Measured 2026-11-10: asset URLs answer 200 under
    # HEAD, and so do repository pages. Fall back to GET only where HEAD itself is not understood.
    got=$(curl -sS -o /dev/null -I --max-time 25 -L -w '%{http_code} %{url_effective}' "$u" 2>/dev/null || echo '000 none')
    code=${got%% *}; final=${got#* }
    case "$code" in
      000|405|501)
          got=$(curl -sS -o /dev/null --max-time 25 -L -w '%{http_code} %{url_effective}' "$u" 2>/dev/null || echo '000 none')
          code=${got%% *}; final=${got#* } ;;
    esac
    # A 5xx here is GitHub's edge timing out under anonymous load (measured: the same address
    # returns 200 seconds later), so retry it; if it persists, say so without failing. A 4xx is
    # definitive - 404 and 410 are what this gate is for - and a changed owner/repo is a rename.
    case "$code" in
      5*) i=0
          while [ "$i" -lt 3 ]; do
              sleep 3; i=$((i + 1))
              got=$(curl -sS -o /dev/null --max-time 25 -L -w '%{http_code} %{url_effective}' "$u" 2>/dev/null || echo '000 none')
              code=${got%% *}; final=${got#* }
              case "$code" in 5*) : ;; *) break ;; esac
          done ;;
    esac
    src=$(gh_pair "$u"); dst=$(gh_pair "$final")
    if [ "$code" = "000" ]; then
        url_off=$((url_off + 1))
    elif [ "${code:-0}" -ge 500 ] 2>/dev/null; then
        say urls "note $code now from $u (not a broken link)"
    elif [ "${code:-0}" -ge 400 ] 2>/dev/null; then
        say urls "FAIL $code $u"; url_fail=1
    elif [ -n "$src" ] && [ -n "$dst" ] && [ "$src" != "$dst" ]; then
        # Both sides must carry an owner/repo before a difference can mean anything. A release asset
        # leaves github.com for release-assets.githubusercontent.com, where there is no pair to read,
        # and comparing a pair against an empty string had every asset URL reported as renamed. A
        # real rename still lands on github.com with a different pair, and that is what this catches.
        say urls "renamed $u -> $final"; url_warn=$((url_warn + 1))
    fi
done
if [ "$url_fail" -eq 1 ]; then
    fail=1
elif [ "$url_n" -eq 0 ]; then
    # A gate that examined nothing must not report ok: exit 0 with zero items checked is
    # the vacuous pass, not a pass.
    say urls "FAIL nothing to check (no markdown or no address found?)"
    fail=1
elif [ "$url_off" -eq "$url_n" ]; then
    say urls "skipped (no network)"
elif [ "$url_warn" -gt 0 ]; then
    say urls "ok, $url_warn renamed upstream (update the address)"
else
    say urls ok
fi

[ "$fail" -eq 0 ] && echo "check-repo: all five gates pass" || echo "check-repo: something failed"
exit $fail
