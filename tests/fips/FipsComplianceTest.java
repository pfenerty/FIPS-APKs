import org.bouncycastle.crypto.fips.FipsStatus;
import org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider;
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.net.ssl.SSLContext;
import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.Security;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.util.ArrayList;
import java.util.List;

/**
 * FIPS compliance test suite for the bouncycastle-fips, bcutil-fips and
 * bctls-fips APK packages.
 *
 * Compiled and run with plain javac/java against the installed JARs:
 *   javac --release 11 -cp /usr/share/java/bc-fips.jar:/usr/share/java/bcutil-fips.jar:/usr/share/java/bctls-fips.jar \
 *         FipsComplianceTest.java -d /tmp/fips-classes
 *   java  -cp "/tmp/fips-classes:/usr/share/java/bc-fips.jar:/usr/share/java/bcutil-fips.jar:/usr/share/java/bctls-fips.jar" \
 *         FipsComplianceTest
 *
 * Output lines prefixed "TEST_RESULT:" are parsed by run-fips-tests.sh to
 * generate the compliance report.
 *
 * Tests catch Throwable rather than Exception on purpose: BC-FIPS signals
 * approved-mode violations with Errors (FipsUnapprovedOperationError), which
 * a catch of Exception does not intercept -- they would terminate the JVM
 * partway through the run instead of being reported as a failed test.
 *
 * Exit code: 0 = all tests pass, 1 = one or more tests failed.
 */
public class FipsComplianceTest {

    // ── Artifact constants ─────────────────────────────────────────────────────
    // These must match the expected-sha256 values in:
    //   packages/bouncycastle-fips/melange.yaml
    //   packages/bcutil-fips/melange.yaml
    //   packages/bctls-fips/melange.yaml
    // tests/fips/check-pins.sh fails CI if they drift apart.

    static final String BC_FIPS_JAR     = "/usr/share/java/bc-fips-2.1.1.jar";
    static final String BCUTIL_FIPS_JAR = "/usr/share/java/bcutil-fips-2.1.5.jar";
    static final String BCTLS_FIPS_JAR  = "/usr/share/java/bctls-fips-2.1.22.jar";

    static final String BC_FIPS_SYMLINK     = "/usr/share/java/bc-fips.jar";
    static final String BCUTIL_FIPS_SYMLINK = "/usr/share/java/bcutil-fips.jar";
    static final String BCTLS_FIPS_SYMLINK  = "/usr/share/java/bctls-fips.jar";

    // bc-fips 2.1.1 is the software version listed on CMVP #4943:
    // https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943
    static final String BC_FIPS_SHA256  = "a430d935ad6cec6d045930758457740f5a5f8f9715894e347f6800f7926a7321";
    static final String BCUTIL_SHA256   = "503aaf5c2c5b7c729547462efe13699b5f6dacf9be150b7c48bba974b793dc92";
    static final String BCTLS_SHA256    = "688410563445e1a65ff33cb67842499f0788994d752c3df8f7ea4a0d40ddbf50";

    // SHA-256("BouncyCastle FIPS") — used as a deterministic self-check for testSha256
    static final String KNOWN_SHA256_INPUT  = "BouncyCastle FIPS";
    static final String KNOWN_SHA256_OUTPUT = "deacb1797c79417204e8149f0db8d7cccbe19440b0ac4e2cb947c9b57128fe47";

    // ── Test result record ─────────────────────────────────────────────────────

    static class TestResult {
        final String  name;
        final boolean passed;
        final String  detail;

        TestResult(String name, boolean passed, String detail) {
            this.name   = name;
            this.passed = passed;
            this.detail = detail;
        }
    }

    // ── Shared provider instance ───────────────────────────────────────────────

    static BouncyCastleFipsProvider BC_PROVIDER;

    // ── Entry point ───────────────────────────────────────────────────────────

    public static void main(String[] args) {
        // Register BC-FIPS provider once; POST runs during construction.
        try {
            BC_PROVIDER = new BouncyCastleFipsProvider();
            Security.addProvider(BC_PROVIDER);
        } catch (Throwable e) {
            System.err.println("FATAL: failed to instantiate BouncyCastleFipsProvider: " + e.getMessage());
            System.exit(1);
        }

        List<TestResult> results = new ArrayList<>();
        results.add(testJarIntegrity());
        results.add(testFipsSelfTests());
        results.add(testProviderRegistration());
        results.add(testAesGcm());
        results.add(testSha256());
        results.add(testRsa());
        results.add(testEcdsa());
        results.add(testHmacSha256());
        results.add(testTlsProvider());
        results.add(testSymlinkResolution());

        long passed = 0;
        for (TestResult r : results) {
            if (r.passed) passed++;
            System.out.printf("TEST_RESULT: %-4s  %-30s  %s%n",
                r.passed ? "PASS" : "FAIL", r.name, r.detail);
        }
        System.out.printf("SUMMARY: %d/%d passed%n", passed, results.size());
        System.exit(passed == results.size() ? 0 : 1);
    }

    // ── Test: JAR integrity ───────────────────────────────────────────────────

    /**
     * Verifies that all three installed JARs are bit-for-bit identical to the
     * artifacts published on Maven Central by comparing SHA-256 digests. For
     * bc-fips that artifact is the module covered by CMVP #4943.
     * Uses the SUN provider explicitly so this test is independent of
     * BC-FIPS initialization state.
     */
    static TestResult testJarIntegrity() {
        String[][] artifacts = {
            {"bc-fips",     BC_FIPS_JAR,     BC_FIPS_SHA256},
            {"bcutil-fips", BCUTIL_FIPS_JAR, BCUTIL_SHA256},
            {"bctls-fips",  BCTLS_FIPS_JAR,  BCTLS_SHA256},
        };
        StringBuilder detail = new StringBuilder();
        try {
            for (String[] a : artifacts) {
                String actual = sha256File(a[1]);
                if (!a[2].equals(actual)) {
                    return new TestResult("testJarIntegrity", false,
                        a[0] + " SHA-256 MISMATCH: expected=" + a[2] + " got=" + actual);
                }
                if (detail.length() > 0) detail.append("  ");
                detail.append(a[0]).append('=').append(actual, 0, 16).append("...");
            }
            return new TestResult("testJarIntegrity", true, detail.toString());
        } catch (Throwable e) {
            return new TestResult("testJarIntegrity", false, e.getMessage());
        }
    }

    static String sha256File(String path) throws Exception {
        // Use SUN provider — must not depend on BC-FIPS being ready yet
        MessageDigest md = MessageDigest.getInstance("SHA-256", "SUN");
        try (InputStream in = new BufferedInputStream(new FileInputStream(path))) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) md.update(buf, 0, n);
        }
        byte[] digest = md.digest();
        StringBuilder sb = new StringBuilder(64);
        for (byte b : digest) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    // ── Test: FIPS self-tests (POST) ──────────────────────────────────────────

    /**
     * Verifies that BC-FIPS Power-On Self-Tests completed successfully.
     * The POST runs during BouncyCastleFipsProvider construction (done in main()).
     */
    static TestResult testFipsSelfTests() {
        try {
            boolean ready = FipsStatus.isReady();
            if (!ready) {
                return new TestResult("testFipsSelfTests", false,
                    "FipsStatus.isReady()=false: " + FipsStatus.getStatusMessage());
            }
            return new TestResult("testFipsSelfTests", true, "FipsStatus.isReady()=true");
        } catch (Throwable e) {
            return new TestResult("testFipsSelfTests", false, e.getMessage());
        }
    }

    // ── Test: provider registration ───────────────────────────────────────────

    static TestResult testProviderRegistration() {
        try {
            java.security.Provider p = Security.getProvider("BCFIPS");
            if (p == null) {
                return new TestResult("testProviderRegistration", false,
                    "Security.getProvider(\"BCFIPS\") returned null");
            }
            return new TestResult("testProviderRegistration", true,
                "provider=" + p.getName() + " version=" + p.getVersionStr());
        } catch (Throwable e) {
            return new TestResult("testProviderRegistration", false, e.getMessage());
        }
    }

    // ── Test: AES-GCM (FIPS-approved symmetric cipher) ────────────────────────

    static TestResult testAesGcm() {
        try {
            KeyGenerator kg = KeyGenerator.getInstance("AES", "BCFIPS");
            kg.init(256);
            SecretKey key = kg.generateKey();

            byte[] iv        = new byte[12];
            byte[] plaintext = "FIPS compliance test".getBytes("UTF-8");

            Cipher enc = Cipher.getInstance("AES/GCM/NoPadding", "BCFIPS");
            enc.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, iv));
            byte[] ciphertext = enc.doFinal(plaintext);

            Cipher dec = Cipher.getInstance("AES/GCM/NoPadding", "BCFIPS");
            dec.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, iv));
            byte[] decrypted = dec.doFinal(ciphertext);

            String result = new String(decrypted, "UTF-8");
            if (!"FIPS compliance test".equals(result)) {
                return new TestResult("testAesGcm", false,
                    "round-trip mismatch: got=" + result);
            }
            return new TestResult("testAesGcm", true,
                "AES-256-GCM encrypt/decrypt round-trip ok");
        } catch (Throwable e) {
            return new TestResult("testAesGcm", false, e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    // ── Test: SHA-256 (FIPS-approved hash) ───────────────────────────────────

    static TestResult testSha256() {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256", "BCFIPS");
            byte[] digest = md.digest(KNOWN_SHA256_INPUT.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(64);
            for (byte b : digest) sb.append(String.format("%02x", b));
            String actual = sb.toString();

            if (!KNOWN_SHA256_OUTPUT.equals(actual)) {
                return new TestResult("testSha256", false,
                    "digest mismatch: expected=" + KNOWN_SHA256_OUTPUT + " got=" + actual);
            }
            return new TestResult("testSha256", true,
                "SHA-256(\"" + KNOWN_SHA256_INPUT + "\")=" + actual.substring(0, 16) + "...");
        } catch (Throwable e) {
            return new TestResult("testSha256", false, e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    // ── Test: RSA sign + verify (FIPS-approved asymmetric) ───────────────────

    static TestResult testRsa() {
        try {
            KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA", "BCFIPS");
            kpg.initialize(2048);
            KeyPair kp = kpg.generateKeyPair();

            byte[] data = "RSA FIPS test data".getBytes("UTF-8");

            Signature signer = Signature.getInstance("SHA256withRSA", "BCFIPS");
            signer.initSign(kp.getPrivate());
            signer.update(data);
            byte[] sig = signer.sign();

            Signature verifier = Signature.getInstance("SHA256withRSA", "BCFIPS");
            verifier.initVerify(kp.getPublic());
            verifier.update(data);
            boolean valid = verifier.verify(sig);

            if (!valid) {
                return new TestResult("testRsa", false, "signature verification failed");
            }
            return new TestResult("testRsa", true,
                "RSA-2048 SHA256withRSA sign/verify ok, sigLen=" + sig.length);
        } catch (Throwable e) {
            return new TestResult("testRsa", false, e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    // ── Test: ECDSA sign + verify (FIPS-approved ECC) ────────────────────────

    static TestResult testEcdsa() {
        try {
            KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC", "BCFIPS");
            kpg.initialize(new ECGenParameterSpec("P-256"));
            KeyPair kp = kpg.generateKeyPair();

            byte[] data = "ECDSA FIPS test data".getBytes("UTF-8");

            Signature signer = Signature.getInstance("SHA256withECDSA", "BCFIPS");
            signer.initSign(kp.getPrivate());
            signer.update(data);
            byte[] sig = signer.sign();

            Signature verifier = Signature.getInstance("SHA256withECDSA", "BCFIPS");
            verifier.initVerify(kp.getPublic());
            verifier.update(data);
            boolean valid = verifier.verify(sig);

            if (!valid) {
                return new TestResult("testEcdsa", false, "ECDSA signature verification failed");
            }
            return new TestResult("testEcdsa", true,
                "ECDSA P-256 SHA256withECDSA sign/verify ok");
        } catch (Throwable e) {
            return new TestResult("testEcdsa", false, e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    // ── Test: HMAC-SHA256 (FIPS-approved MAC) ────────────────────────────────

    static TestResult testHmacSha256() {
        try {
            KeyGenerator kg = KeyGenerator.getInstance("HmacSHA256", "BCFIPS");
            SecretKey key = kg.generateKey();

            Mac mac = Mac.getInstance("HmacSHA256", "BCFIPS");
            mac.init(key);
            byte[] result = mac.doFinal("HMAC test data".getBytes("UTF-8"));

            if (result.length != 32) {
                return new TestResult("testHmacSha256", false,
                    "expected 32-byte output, got " + result.length);
            }
            return new TestResult("testHmacSha256", true,
                "HmacSHA256 output=" + result.length + " bytes");
        } catch (Throwable e) {
            return new TestResult("testHmacSha256", false, e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    // ── Test: TLS provider (bctls-fips) ──────────────────────────────────────

    /**
     * Verifies that the BouncyCastle JSSE provider (bctls-fips) registers
     * successfully and can provide a TLSv1.3 SSLContext.
     */
    static TestResult testTlsProvider() {
        try {
            BouncyCastleJsseProvider jsseProvider = new BouncyCastleJsseProvider(BC_PROVIDER);
            Security.addProvider(jsseProvider);

            SSLContext ctx = SSLContext.getInstance("TLSv1.3", "BCJSSE");
            if (ctx == null) {
                return new TestResult("testTlsProvider", false,
                    "SSLContext.getInstance(\"TLSv1.3\", \"BCJSSE\") returned null");
            }
            return new TestResult("testTlsProvider", true,
                "BCJSSE registered; TLSv1.3 SSLContext obtained");
        } catch (Throwable e) {
            return new TestResult("testTlsProvider", false,
                e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    // ── Test: symlink resolution ──────────────────────────────────────────────

    /**
     * Verifies that every unversioned symlink installed by the APKs
     * (bc-fips.jar, bcutil-fips.jar, bctls-fips.jar) resolves to its
     * versioned target.
     */
    static TestResult testSymlinkResolution() {
        String[][] links = {
            {BC_FIPS_SYMLINK,     "bc-fips-2.1.1.jar"},
            {BCUTIL_FIPS_SYMLINK, "bcutil-fips-2.1.5.jar"},
            {BCTLS_FIPS_SYMLINK,  "bctls-fips-2.1.22.jar"},
        };
        StringBuilder detail = new StringBuilder();
        try {
            for (String[] l : links) {
                File link = new File(l[0]);
                if (!link.exists()) {
                    return new TestResult("testSymlinkResolution", false,
                        l[0] + " does not exist or symlink is broken");
                }
                String canon = link.getCanonicalPath();
                if (!canon.endsWith(l[1])) {
                    return new TestResult("testSymlinkResolution", false,
                        l[0] + " -> " + canon + " (expected to end with " + l[1] + ")");
                }
                if (detail.length() > 0) detail.append("  ");
                detail.append(l[0]).append(" -> ").append(canon);
            }
            return new TestResult("testSymlinkResolution", true, detail.toString());
        } catch (Throwable e) {
            return new TestResult("testSymlinkResolution", false, e.getMessage());
        }
    }
}
