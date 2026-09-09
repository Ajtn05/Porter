package app.porter.companion;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.math.BigInteger;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.util.Date;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.security.auth.x500.X500Principal;

/** Generates one Android Keystore-backed certificate and reuses it across runs. */
final class TlsIdentity {
    // v3 replaces earlier identities that did not authorize all operations
    // Conscrypt performs while serving TLS from Android Keystore.
    private static final String ALIAS = "porter-wifi-tls-v3";

    private final SSLContext context;
    private final String fingerprint;

    private TlsIdentity(SSLContext context, String fingerprint) {
        this.context = context;
        this.fingerprint = fingerprint;
    }

    static TlsIdentity load() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (!store.containsAlias(ALIAS)) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
            Date now = new Date();
            KeyGenParameterSpec spec = new KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_SIGN
                            | KeyProperties.PURPOSE_VERIFY
                            | KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(2048)
                    .setDigests(
                            KeyProperties.DIGEST_NONE,
                            KeyProperties.DIGEST_SHA256,
                            KeyProperties.DIGEST_SHA384,
                            KeyProperties.DIGEST_SHA512)
                    .setSignaturePaddings(
                            KeyProperties.SIGNATURE_PADDING_RSA_PKCS1,
                            KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                    .setEncryptionPaddings(
                            KeyProperties.ENCRYPTION_PADDING_NONE,
                            KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
                    .setRandomizedEncryptionRequired(false)
                    .setCertificateSubject(new X500Principal("CN=Porter Companion"))
                    .setCertificateSerialNumber(new BigInteger(64, new SecureRandom()))
                    .setCertificateNotBefore(new Date(now.getTime() - 60_000L))
                    .setCertificateNotAfter(new Date(now.getTime() + 3_650L * 24L * 60L * 60L * 1_000L))
                    .build();
            generator.initialize(spec);
            generator.generateKeyPair();
        }

        PrivateKey key = (PrivateKey) store.getKey(ALIAS, null);
        Certificate certificate = store.getCertificate(ALIAS);
        if (key == null || certificate == null) {
            throw new IllegalStateException("Could not load the local TLS identity.");
        }
        KeyManagerFactory manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        manager.init(store, null);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(manager.getKeyManagers(), null, new SecureRandom());
        return new TlsIdentity(context, hex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded())));
    }

    SSLContext context() { return context; }
    String fingerprint() { return fingerprint; }

    static String hex(byte[] bytes) {
        StringBuilder value = new StringBuilder(bytes.length * 2);
        for (byte item : bytes) { value.append(String.format("%02x", item & 0xff)); }
        return value.toString();
    }
}
