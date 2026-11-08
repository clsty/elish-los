#!/usr/bin/env python3
"""Runs sh -n over every ```sh code block in the documentation, one block at a time.

Usage: python3 check-sh-blocks.py [directory...]   default: *.md in the current directory
Code inside a blockquote (lines starting with "> ") has that prefix stripped first, or
sh -n trips on the ">" - that character is markdown quoting, not part of the command. The
verdict is sh -n's return code; its output is ignored.
"""
import glob
import os
import re
import subprocess
import sys

FENCE = re.compile(r"```sh\n(.*?)```", re.S)


def blocks(path):
    text = open(path, encoding="utf-8").read()
    for block in FENCE.findall(text):
        # Code inside a blockquote: strip the quote prefix line by line to recover the
        # lines that would actually be executed.
        yield "\n".join(re.sub(r"^> ?", "", line) for line in block.splitlines())


def main():
    roots = sys.argv[1:] or ["."]
    files, seen = [], set()
    for root in roots:
        found = [root] if os.path.isfile(root) else (
            sorted(glob.glob(os.path.join(root, "*.md")))
            + sorted(glob.glob(os.path.join(root, "*/*.md"))))
        for path in found:
            # Overlapping arguments ("docs" plus ".") must not check a file twice: a duplicate
            # FAIL is noise, and a duplicated count makes the total meaningless.
            key = os.path.realpath(path)
            if key not in seen:
                seen.add(key)
                files.append(path)
    bad = 0
    for path in files:
        for i, block in enumerate(blocks(path), 1):
            r = subprocess.run(["sh", "-n"], input=block, text=True, capture_output=True)
            if r.returncode:
                bad += 1
                last = (r.stderr.strip().splitlines() or [""])[-1]
                print(f"FAIL {path} block {i}: {last}")
                for line in block.strip().splitlines()[:4]:
                    print(f"      {line}")
    print(f"{len(files)} md files, {bad} blocks failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
