package com.attestcheck;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.util.Log;

import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;

/**
 * One job: ask the Android keystore for a key whose certificate chain is an *attestation*, and
 * hand the DER bytes to the host unchanged. Nothing is interpreted here - the chain is what is
 * under test, so decoding it in the process that produced it would replace the thing being
 * measured (the same reason framecheck does no arithmetic).
 *
 * Why an app is needed at all: the device's own CLI cannot ask for this. Measured on this build -
 * `keystore_cli_v2` has no attestation command, its 22 brillo tests contain none, `generate`
 * leaves every attestation field out of `get-chars`, and `export` returns a self-signed 803-byte
 * certificate rather than a chain. Requesting an attestation needs
 * KeyGenParameterSpec.Builder.setAttestationChallenge(), which is an app-facing API.
 *
 * What is logged, on purpose:
 *   BEGIN   | sdk, build id, the challenge in hex so the host can confirm it came back
 *   CHAIN   | number of certificates. 1 means the device did not attest (a self-signed
 *           certificate), >= 2 is a chain; which is a finding either way, not an error here
 *   CERT    | index, DER length, base64 of the bytes - base64 in the log because it needs no
 *           root shell and no file path the host has to guess
 *   ERR     | the exception class and message, if the keystore refused
 *   END     | done
 *
 * No UI, no permission, no network: the activity does its work in onCreate and finishes.
 */
public class AttestCheck extends Activity {
    private static final String TAG = "AttestCheck";
    private static final String KS = "AndroidKeyStore";   // the provider name is case-sensitive:
                                                           // "androidkeystore" answers
                                                           // NoSuchProviderException
    private static final String ALIAS = "elish-attestcheck";
    /* Fixed and printed at the top: the point of a challenge is that it comes back inside the
     * signed structure, so the host compares it against what it expects, not against a value
     * the app made up at run time. check.py repeats this constant - deliberately, so that
     * changing it in one file only is caught instead of passing. */
    private static final String CHALLENGE = "elish-los24-attestcheck-20261110";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // An explicit Runnable, not a lambda or method reference: javac lowers those through
        // java.lang.invoke.LambdaMetafactory, which the public android.jar does not carry, so a
        // method reference here fails to compile with "cannot find symbol metafactory". Measured
        // on this recipe; nothing else in these tools uses one, which is why it was not seen
        // before.
        new Thread(new Runnable() {
            public void run() { attest(); }
        }, "attest").start();
    }

    private void attest() {
        byte[] challenge = CHALLENGE.getBytes();
        Log.i(TAG, "BEGIN|" + Build.VERSION.SDK_INT + "|" + Build.ID + "|" + hex(challenge));
        try {
            KeyStore ks = KeyStore.getInstance(KS);
            ks.load(null);
            // A previous run's key would be returned instead of a fresh attestation, and its
            // challenge would be the old one, so remove it first rather than reuse it.
            if (ks.containsAlias(ALIAS)) ks.deleteEntry(ALIAS);

            KeyGenParameterSpec.Builder b =
                    new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN
                            | KeyProperties.PURPOSE_VERIFY)
                            .setDigests(KeyProperties.DIGEST_SHA256)
                            .setAttestationChallenge(challenge);
            // Deliberately nothing else: no strongbox, no authentication requirement, no
            // attestation application id override. Each of those would move a field the host
            // reads (security level, the app list) away from what a plain app asks for.
            KeyPairGenerator g = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KS);
            g.initialize(b.build());
            g.generateKeyPair();

            Certificate[] chain = ks.getCertificateChain(ALIAS);
            if (chain == null) {
                Log.i(TAG, "ERR|NullPointerException|getCertificateChain returned null");
            } else {
                Log.i(TAG, "CHAIN|" + chain.length);
                for (int i = 0; i < chain.length; i++) {
                    byte[] der = chain[i].getEncoded();
                    Log.i(TAG, "CERT|" + i + "|" + der.length + "|"
                            + Base64.encodeToString(der, Base64.NO_WRAP));
                    if (chain[i] instanceof X509Certificate) {
                        X509Certificate c = (X509Certificate) chain[i];
                        Log.i(TAG, "DN|" + i + "|" + c.getSubjectX500Principal().getName()
                                + "|" + c.getIssuerX500Principal().getName());
                    }
                }
            }
            ks.deleteEntry(ALIAS);   // leaves no key behind on the device
        } catch (Throwable t) {
            Log.i(TAG, "ERR|" + t.getClass().getName() + "|" + t.getMessage());
        }
        Log.i(TAG, "END");
        finish();
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x & 0xff));
        return sb.toString();
    }
}
