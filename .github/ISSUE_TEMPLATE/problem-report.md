---
name: Problem report
about: Something on this build does not match what the documents say to expect
title: ''
labels: ''
assignees: ''
---

<!--
The acceptance document defines what "correct" means for each change, so a report that
quotes it saves the most time. Read its last two sections first: several readings there
are deliberately not judgements (a screen that is off, a clock with no network, an
untouched `/data`), and a number of reports turn out to be one of those.
-->

**Build** (both, please - the kernel's version string carries the build marker)

```
ro.lineage.version:
uname -r:
```

**How it was flashed**: route A (from the stock firmware) or route B (re-flash over an
existing install)? Was `/data` wiped?

**Which change** does this concern - orientation, root, root hiding, the camera app, the
network addresses, or something else?

**What the document expects, and what you got.** Quote the section of
[`docs/acceptance.md`](../../docs/acceptance.md) and paste the actual output of the bare
`adb` command it gives, rather than describing the behaviour.

**State that affects the reading**, if any: whether a root manager is installed and
registered as the dynamic manager, whether any KernelSU module is installed, how long the
device has been booted (kernel log lines age out), and whether there was a network
connection.
