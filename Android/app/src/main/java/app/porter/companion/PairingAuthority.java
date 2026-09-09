package app.porter.companion;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HashSet;
import java.util.Set;
import java.util.Collections;

/** Issues revocable bearer tokens after a rate-limited six-digit pairing check. */
final class PairingAuthority {
    private static final String PREFERENCES = "porter-pairings-v1";
    private static final String TOKEN_HASHES = "token-hashes";
    private static final int MAX_FAILURES = 5;
    private static final long BLOCK_MILLIS = 60_000L;

    private final SharedPreferences preferences;
    private final SecureRandom random = new SecureRandom();
    private final String code;
    private int failures;
    private long blockedUntil;

    PairingAuthority(Context context) {
        preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE);
        code = String.format("%06d", random.nextInt(1_000_000));
    }

    String code() { return code; }

    synchronized PairingResult pair(String candidate) {
        long now = System.currentTimeMillis();
        if (now < blockedUntil) {
            return PairingResult.failure("Too many incorrect codes. Wait a minute, then try again.");
        }
        if (!MessageDigest.isEqual(code.getBytes(StandardCharsets.UTF_8), candidate.getBytes(StandardCharsets.UTF_8))) {
            failures += 1;
            if (failures >= MAX_FAILURES) {
                failures = 0;
                blockedUntil = now + BLOCK_MILLIS;
                return PairingResult.failure("Too many incorrect codes. Wait a minute, then try again.");
            }
            return PairingResult.failure("That pairing code is not correct.");
        }
        failures = 0;
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        String token = Base64.encodeToString(bytes, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
        Set<String> hashes = new HashSet<>(preferences.getStringSet(TOKEN_HASHES, Collections.emptySet()));
        hashes.add(hash(token));
        preferences.edit().putStringSet(TOKEN_HASHES, hashes).apply();
        return PairingResult.success(token);
    }

    boolean authorizes(String token) {
        if (token == null || token.isEmpty()) { return false; }
        Set<String> hashes = preferences.getStringSet(TOKEN_HASHES, Collections.emptySet());
        String candidate = hash(token);
        for (String hash : hashes) {
            if (MessageDigest.isEqual(hash.getBytes(StandardCharsets.UTF_8), candidate.getBytes(StandardCharsets.UTF_8))) {
                return true;
            }
        }
        return false;
    }

    private static String hash(String token) {
        try {
            return TlsIdentity.hex(MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception error) {
            throw new IllegalStateException("SHA-256 is unavailable", error);
        }
    }

    static final class PairingResult {
        final String token;
        final String error;

        private PairingResult(String token, String error) {
            this.token = token;
            this.error = error;
        }

        static PairingResult success(String token) { return new PairingResult(token, null); }
        static PairingResult failure(String error) { return new PairingResult(null, error); }
    }
}
