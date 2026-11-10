#!/usr/bin/env python3
"""Reads the attestation this device actually produces, and says what it is worth.

Runs the app in this directory, takes the DER chain out of its log, and decodes it. Nothing here
trusts a property or a log line: an attestation is a signature over a structure, so the fields that
matter are read from that structure (docs/acceptance.md section 11).

Why the fields matter more than the mechanics. `verifiedbootstate` and friends are properties that a
KernelSU module rewrites for any reader (docs/root.md). This certificate is signed by the key
material behind KeyMint and carries its own boot-state fields, so it is the channel that spoofing
does not reach - which is only useful if you read *it* rather than assuming it agrees.

Two things this prints that are easy to get wrong from the command line alone:

  - `openssl x509 -ext <oid>` answers "No extensions in certificate" for this leaf even though the
    extension is there (measured on this build, openssl 3.6.1). The OID is located with `asn1parse`
    instead, which does see it.
  - A chain of one certificate is not an attestation, it is the self-signed public-key certificate
    KeyStore returns when no attestation was requested. So the chain length is printed first.

Usage: python3 check.py [seconds=8]
Exit: 0 = a chain with our challenge came back; 2 = not (see the printed reason);
      1 = the app produced nothing to read (not installed, or the screen put it to sleep).
"""
import base64
import os
import re
import shutil
import subprocess
import sys
import time

TAG = "AttestCheck"
ATTEST_OID = "1.3.6.1.4.1.11129.2.1.17"
# The same string is in AttestCheck.java, and it is duplicated on purpose. The app reports the
# challenge it sent, so comparing the signed value against that report alone would be circular: it
# could never notice a challenge that was dropped, zeroed or replaced, only that both sides of one
# run agree. Holding the expected value here as well makes a one-sided edit to either file a failure
# rather than a silent pass. Measured: changing only the Java constant was reported as a mismatch.
EXPECTED_CHALLENGE = "elish-los24-attestcheck-20261110"
SEC_LEVEL = {0: "DEFAULT", 1: "SOFTWARE", 2: "TRUSTED_ENVIRONMENT", 3: "STRONGBOX"}
BOOT_STATE = {0: "VERIFIED", 1: "SELF_SIGNED", 2: "UNVERIFIED", 3: "FAILED"}
# Tag numbers, taken from the tree's own definition rather than from memory:
# hardware/interfaces/security/keymint/aidl/aidl_api/android.hardware.security.keymint/1/.../Tag.aidl
# lists each Tag as an enum whose high nibble encodes the value's type, so the DER tag is the low
# 28 bits of that number (PURPOSE = 536870913 -> 1, ROOT_OF_TRUST = -1879047488 -> 704). Two of
# these were written from memory first and were wrong: ROOT_OF_TRUST is 704, not 708, and
# ATTESTATION_CHALLENGE is 708. Anything not listed here prints as its number.
TAG_NAME = {
    1: "PURPOSE", 2: "ALGORITHM", 3: "KEY_SIZE", 4: "BLOCK_MODE", 5: "DIGEST", 6: "PADDING",
    7: "CALLER_NONCE", 8: "MIN_MAC_LENGTH", 10: "EC_CURVE",
    700: "APPLICATION_DATA", 701: "CREATION_DATETIME", 702: "ORIGIN", 704: "ROOT_OF_TRUST",
    705: "OS_VERSION", 706: "OS_PATCHLEVEL", 707: "UNIQUE_ID", 708: "ATTESTATION_CHALLENGE",
    709: "ATTESTATION_APPLICATION_ID", 710: "ATTESTATION_ID_BRAND", 711: "ATTESTATION_ID_DEVICE",
    712: "ATTESTATION_ID_PRODUCT", 713: "ATTESTATION_ID_SERIAL", 718: "VENDOR_PATCHLEVEL",
    719: "BOOT_PATCHLEVEL", 720: "DEVICE_UNIQUE_ATTESTATION",
}
# These carry an INTEGER whose value the reader wants, not just a name.
VALUE_TAGS = (3, 701, 702, 705, 706, 718, 719)


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw).stdout


def openssl_tool():
    """The tree's own openssl if there is one (the APK build needs the tree anyway), else PATH.

    Three levels up from this file is the repository's sibling directory, where a LineageOS tree
    sits in this project's layout - the same rule mkapk.sh uses, and the same place where writing
    two levels instead of three points at the repository itself.
    """
    global _OPENSSL
    if _OPENSSL:
        return _OPENSSL
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [os.environ.get("ELISH_OPENSSL", "")]
    tree = os.environ.get("LOS24_TREE", "") or os.path.abspath(os.path.join(here, "..", "..", "..", "los24"))
    cands.append(os.path.join(tree, "prebuilts/build-tools/linux-x86/bin/openssl"))
    cands.append(shutil.which("openssl") or "")
    for c in cands:
        if c and os.path.exists(c):
            _OPENSSL = c
            return c
    sys.exit("needs openssl (in PATH, or ELISH_OPENSSL, or a LineageOS tree)")


_OPENSSL = ""


def collect(seconds):
    sh(["adb", "logcat", "-c"])
    sh(["adb", "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
    # Same lesson as framecheck: waking is not unlocking. Behind a keyguard the activity is paused
    # before it reaches the keystore, and the log has nothing in it.
    sh(["adb", "shell", "wm", "dismiss-keyguard"])
    time.sleep(0.6)
    sh(["adb", "shell", "am", "start", "-n", "com.attestcheck/.AttestCheck"])
    time.sleep(seconds)
    out = sh(["adb", "logcat", "-d", "-s", "%s:I" % TAG])
    sh(["adb", "shell", "am", "force-stop", "com.attestcheck"])
    return [ln.split("AttestCheck: ", 1)[1] for ln in out.splitlines() if "AttestCheck: " in ln]


# --- a small DER reader, enough for the structure below and nothing more -----------------------
def tlv(b, i):
    """Returns (tag_class_constructed_byte, tag_number, is_constructed, content_start, content_end)."""
    tag = b[i]
    j = i + 1
    if tag & 0x1f == 0x1f:                      # high-tag-number form: the number follows in
        num = 0                                 # base-128, which is how tags >= 31 are encoded
        while b[j] & 0x80:
            num = (num << 7) | (b[j] & 0x7f)
            j += 1
        num = (num << 7) | (b[j] & 0x7f)
        j += 1
    else:
        num = tag & 0x1f
    ln = b[j]
    j += 1
    if ln & 0x80:
        n = ln & 0x7f
        ln = int.from_bytes(b[j:j + n], "big")
        j += n
    return tag, num, bool(tag & 0x20), j, j + ln


def items(b, s=0, e=None):
    """Every TLV in the byte range [s,e) - the body of a constructed value."""
    e = len(b) if e is None else e
    out = []
    i = s
    while i < e:
        tag, num, cons, cs, ce = tlv(b, i)
        out.append((tag, num, cons, b[cs:ce]))
        i = ce
    return out


def children(b):
    """The children of `b`, where b is one complete TLV (a SEQUENCE, typically)."""
    _, _, _, s, e = tlv(b, 0)
    return items(b, s, e)


def find_extension(der_path, oid):
    """The bytes of the extension value, located by asn1parse because `x509 -ext` misses it here."""
    dump = sh([openssl_tool(), "asn1parse", "-inform", "DER", "-in", der_path, "-i"])
    lines = dump.splitlines()
    for i, ln in enumerate(lines):
        if oid in ln and i + 1 < len(lines):
            m = re.search(r"\[HEX DUMP\]:([0-9a-fA-F]+)", lines[i + 1])
            if m:
                return bytes.fromhex(m.group(1))
            # A short value is shown inline rather than as a hex dump.
            m = re.search(r"OCTET STRING\s+:(.*)$", lines[i + 1])
            if m:
                return m.group(1).encode()
    return None


def decode(data):
    """KeyDescription -> a dict of what this judgement reads. Field order is fixed by the spec,
    so it is followed by position; anything that does not look like it is reported, not guessed."""
    top = children(data)
    if len(top) < 8:
        raise ValueError("KeyDescription has %d fields, expected 8" % len(top))
    iv = lambda x: int.from_bytes(x, "big") if x else -1
    out = {
        "attestationVersion": iv(top[0][3]),
        "attestationSecurityLevel": SEC_LEVEL.get(top[1][3][0], "?"),
        "keymasterVersion": iv(top[2][3]),
        "keymasterSecurityLevel": SEC_LEVEL.get(top[3][3][0], "?"),
        "attestationChallenge": top[4][3],
        "uniqueId": len(top[5][3]),
    }
    for name, lst in (("softwareEnforced", top[6]), ("teeEnforced", top[7])):
        # Measured shape of an AuthorizationList on this device: each entry is one context-tagged
        # element directly - [1] PURPOSE, [2] ALGORITHM, [704] ROOT_OF_TRUST - with no SEQUENCE
        # wrapper, and the tag number is the KeyMint Tag value. So the entry's own tag *is* the
        # tag number, and its content is the value's complete TLV (these entries are all
        # constructed, so even an INTEGER arrives wrapped). Descending one level here produced a
        # list of value bytes read as tag numbers, which is how "ALGORITHM, ALGORITHM, DIGEST"
        # came out the first time.
        entries = [(num, content) for _t, num, _c, content in items(lst[3])]
        out[name] = entries
    return out


def der_int(v):
    """The integer inside a value that may or may not be wrapped in its own INTEGER TLV."""
    if v and v[0] == 0x02:
        _, _, _, s, e = tlv(v, 0)
        return int.from_bytes(v[s:e], "big")
    return int.from_bytes(v, "big") if v else -1


def root_of_trust(entries):
    for tag_num, v in entries:
        if tag_num == 704:
            # Whether the value arrived wrapped in its own SEQUENCE depends on EXPLICIT versus
            # IMPLICIT tagging, and both are in the wild. A leading SEQUENCE tag tells them apart.
            fields = children(v) if v and v[0] == 0x30 else items(v)
            r = {}
            # SEQUENCE { verifiedBootKey OCTET STRING, deviceLocked BOOLEAN,
            #            verifiedBootState ENUMERATED, verifiedBootHash OCTET STRING }
            if len(fields) >= 3:
                r["verifiedBootKey"] = fields[0][3].hex()
                r["deviceLocked"] = bool(fields[1][3][0]) if fields[1][3] else None
                r["verifiedBootState"] = BOOT_STATE.get(fields[2][3][0], "?")
                r["verifiedBootHash"] = fields[3][3].hex() if len(fields) >= 4 else ""
            return r
    return None


def app_package(v, depth=0):
    """The package name inside ATTESTATION_APPLICATION_ID. Measured layout, from the outermost OCTET
    STRING inward:  SEQUENCE { SET { SEQUENCE { OCTET STRING "package", INTEGER, ... }, ... }, ... }
    - the name sits four levels down, inside the app-description set. Rather than hard-code that
    depth, this returns the first primitive OCTET STRING that reads as a package name, which keeps
    working if the nesting moves and cannot invent a value."""
    if depth > 6 or not v:
        return "?"
    tag, _n, cons, cs, ce = tlv(v, 0)
    body = v[cs:ce]
    if not cons and tag == 0x04:
        try:
            txt = body.decode("ascii")
        except UnicodeDecodeError:
            txt = ""
        if txt and re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+", txt):
            return txt
    if cons or tag == 0x04:
        i = 0
        while i < len(body):
            found = app_package(body[i:], depth + 1)
            if found != "?":
                return found
            _t, _n2, _c, _cs, e2 = tlv(body, i)
            i = e2
    return "?"


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
    openssl_tool()      # resolve it here: failing after printing half a report reads like a device
                        # problem, and this exit does not reach the reason line below
    lines = collect(seconds)
    if not lines:
        print("!! nothing from the app. Check it is installed\n"
              "   (`adb shell dumpsys package com.attestcheck | grep versionName`), and that the\n"
              "   screen came on: a paused activity never reaches the keystore.")
        return 1

    for ln in lines:
        if ln.startswith("ERR|"):
            print("!! the keystore refused:", ln[4:])
            print("   That is the answer on this device for this request; the rest of the check has")
            print("   nothing to decode.")
            return 2
    if not any(ln.startswith("CHAIN|") for ln in lines):
        print("!! no CHAIN line; the app did not finish. Lines seen:", len(lines))
        return 2

    nchain = int([l for l in lines if l.startswith("CHAIN|")][0].split("|")[1])
    der = {}
    for ln in lines:
        if ln.startswith("CERT|"):
            _, i, length, b64 = ln.split("|")
            raw = base64.b64decode(b64)
            der[int(i)] = raw
            if len(raw) != int(length):
                print("!! cert %s: log said %s B, decoded %s B" % (i, length, len(raw)))
                return 2

    # Names come from openssl: X500Principal output in the log is truncated by the line limit.
    tmp = os.environ.get("TMPDIR", "/tmp")
    print("== chain: %d certificate(s) ==" % nchain)
    paths = []
    for i in sorted(der):
        p = os.path.join(tmp, "attest-%d.der" % i)
        with open(p, "wb") as f:
            f.write(der[i])
        paths.append(p)
        print("  [%d] %6d B  %s" % (i, len(der[i]),
              sh([openssl_tool(), "x509", "-inform", "DER", "-in", p, "-noout",
                  "-subject", "-issuer"]).replace("\n", "  ").strip()))
    if nchain == 1:
        print("\n  One certificate means this was not an attestation: it is the self-signed public")
        print("  key certificate KeyStore returns when no challenge was asked for.")
        return 2
    dn = sh([openssl_tool(), "x509", "-inform", "DER", "-in", paths[-1], "-noout",
             "-subject", "-issuer"]).strip().split("\n")
    root_selfsigned = (len(dn) == 2
                       and dn[0].split("=", 1)[1] == dn[1].split("=", 1)[1])
    print("  root is %s" % ("self-signed - the device generated it, so a remote verifier has no\n"
                            "  trust anchor to check it against; the chain proves internal agreement\n"
                            "  only" if root_selfsigned else "issued by someone else - see its issuer above"))

    ext = find_extension(paths[0], ATTEST_OID)
    if ext is None:
        print("\n!! the leaf carries no %s extension, so it attests nothing." % ATTEST_OID)
        return 2
    kd = decode(ext)
    want = None
    for ln in lines:
        if ln.startswith("BEGIN|"):
            want = ln.split("|")[3]
    got = kd["attestationChallenge"].hex()
    exp = EXPECTED_CHALLENGE.encode().hex()
    print("\n== %s extension (%d B) ==" % (ATTEST_OID, len(ext)))
    print("  attestationVersion %d, security level %s" % (kd["attestationVersion"], kd["attestationSecurityLevel"]))
    print("  keymasterVersion   %d, security level %s" % (kd["keymasterVersion"], kd["keymasterSecurityLevel"]))
    print("  challenge          %s" % got)
    print("    as text          %r" % kd["attestationChallenge"].decode("latin1"))
    verdict = "  ok (matches this tool's constant and what the app sent)"
    if got != exp:
        verdict = ("  MISMATCH against this tool's constant (%s): the value did not survive,\n"
                   "  or the two files disagree about what was asked." % exp)
    elif want != got:
        verdict = ("  MISMATCH against the app's own report (%s): the certificate does not answer\n"
                   "  this request." % want)
    print("   %s" % verdict)
    for list_name in ("teeEnforced", "softwareEnforced"):
        entries = kd[list_name]
        print("  %s: %d entries -> %s" % (list_name, len(entries),
              ", ".join(TAG_NAME.get(t, "tag%d" % t) for t, _ in entries) or "none"))
        for t, v in entries:
            if t in VALUE_TAGS:
                print("      %-26s %d" % (TAG_NAME.get(t, "tag%d" % t), der_int(v)))
            elif t == 709:
                print("      %-26s %s" % (TAG_NAME[t], app_package(v)))
        rot = root_of_trust(entries)
        if rot:
            print("    ROOT_OF_TRUST: deviceLocked=%s verifiedBootState=%s"
                  % (rot["deviceLocked"], rot["verifiedBootState"]))
            print("                   verifiedBootKey=%s…  verifiedBootHash=%s…"
                  % (rot["verifiedBootKey"][:16], rot["verifiedBootHash"][:16]))
            print("                   (this is the boot state as the signing side recorded it; it is")
            print("                    not the `ro.boot.*` properties, which other code can rewrite)")

    if got != exp or want != got:
        return 2
    print("\nPASS - attested chain of %d, challenge confirmed inside the signed structure." % nchain)
    return 0


if __name__ == "__main__":
    sys.exit(main())
