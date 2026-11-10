# attestcheck: a client that asks the keystore to attest

`docs/acceptance.md` section 10 judges the KeyStore attestation, because it is the one root and
unlock channel that property spoofing does not reach. Nothing on the device can produce one to
judge: `keystore_cli_v2` has no attestation command, its 22 brillo tests contain none, `generate`
leaves every attestation field out of `get-chars`, and `export` returns a self-signed 803-byte
certificate instead of a chain. Asking for an attestation means
`KeyGenParameterSpec.Builder.setAttestationChallenge()`, which is app-facing. This directory is
that app plus the judgement script.

## Files

| File | Purpose |
| --- | --- |
| `AttestCheck.java` | creates one EC key with an attestation challenge, logs each certificate of the returned chain as base64 DER, deletes the key, finishes. **Decodes and interprets nothing** - the chain is the thing under test |
| `AndroidManifest.xml` | one activity, no permissions, no network, no resources |
| `build.sh` | a two-line call into `../mkapk.sh`, the recipe shared with the other verification apps |
| `check.py` | drives it over adb, decodes the leaf's `1.3.6.1.4.1.11129.2.1.17` extension, and reports mechanics / readings / what they are worth as three separate things |

```sh
sh build.sh /path/to/los24                # or export LOS24_TREE; output: build/attestcheck.apk (~12 KB)
adb install -r build/attestcheck.apk
python3 check.py 8                        # exit 0 = a chain carrying our challenge; 2 = not; 1 = nothing ran
adb uninstall com.attestcheck
```

## Why the expected challenge is written down twice

The app logs the challenge it sent, so comparing the signed value against *that* would be
circular: it could only ever show that two halves of one run agree, and could not notice a
challenge that was dropped, zeroed or replaced. `check.py` therefore holds the same constant
itself, and both comparisons are reported. Poisoned on purpose: changing the constant in
`AttestCheck.java` alone exits 2 with a named mismatch; an uninstalled app exits 1; an intact run
exits 0.

## What the readings are worth

The script prints the chain, the security levels and the root's issuer rather than a single
verdict, because on this device those three do not point the same way, and a number would hide it.
See `docs/acceptance.md` section 10 for the measured values and their meaning; the short version is
that the structure is a real attestation, that it reports the device unlocked, and that it is
anchored on a self-signed root with a reported security level of `SOFTWARE`.

## Traps met while reading the structure

All four are handled in `check.py`, and all four cost a run before they were seen:

1. `openssl x509 -ext 1.3.6.1.4.1.11129.2.1.17` answers **"No extensions in certificate"** for this
   leaf although the extension is present. `openssl asn1parse -i` sees it, so the value is located
   there. (openssl 3.6.1, the one in `prebuilts/build-tools`.)
2. Tag numbers are the **low 28 bits** of the enum values in the tree's
   `hardware/interfaces/security/keymint/aidl/aidl_api/android.hardware.security.keymint/1/android/
   hardware/security/keymint/Tag.aidl` (`PURPOSE = 536870913` -> 1). From memory they were wrong
   twice: `ROOT_OF_TRUST` is 704, not 708.
3. An `AuthorizationList` element is **one context-tagged TLV with no SEQUENCE wrapper** (`0xa1` =
   [1] PURPOSE, `0xbf 0x85 0x44` = [704] ROOT_OF_TRUST), so the element's own tag is the tag number.
   Descending one level first produced a list of value bytes read as tags - "ALGORITHM, ALGORITHM,
   DIGEST" - which looks plausible and is meaningless.
4. The provider name is case-sensitive: `KeyStore.getInstance("androidkeystore")` answers
   `NoSuchProviderException`; `AndroidKeyStore` is the name.

`ATTESTATION_APPLICATION_ID` is deeper than it looks - `OCTET STRING` wrapping `SEQUENCE { SET {
SEQUENCE { OCTET STRING "package", ... } } }` - so `app_package()` searches for the first primitive
octet string that reads as a package name instead of hard-coding the depth.

## Before running

The script wakes the device and dismisses the keyguard, for the same reason `framecheck` does: a
paused activity never reaches the keystore, and the run then looks like an app failure rather than a
screen state. It needs `openssl`: the tree's `prebuilts/build-tools/linux-x86/bin/openssl` is found
by the same path rule `mkapk.sh` uses, or point `ELISH_OPENSSL` at one, or have one in `PATH`.
