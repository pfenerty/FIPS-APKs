import org.bouncycastle.crypto.CryptoServicesRegistrar;
import org.bouncycastle.crypto.fips.FipsDRBG;
import org.bouncycastle.crypto.fips.FipsStatus;
import org.bouncycastle.crypto.util.BasicEntropySourceProvider;
import org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider;
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.io.BufferedInputStream;
import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.security.Provider;
import java.security.SecureRandom;
import java.security.Security;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * fips-verify -- reports whether THIS JVM is operating the BC-FIPS module in
 * FIPS-approved mode, and produces the evidence for that answer.
 *
 * Intended to be run inside a deployed container, not only at image build
 * time: build-time configuration can be overridden by the application, so the
 * only output that means anything is the one produced where the app runs.
 *
 * This tool VERIFIES, it does not VALIDATE. Validation is an assertion by an
 * accredited third party (NIST/CMVP). Everything here is a measurement the
 * reader can reproduce by re-running this program.
 *
 * Note on provider ordering: it is load-bearing, not cosmetic. BC-FIPS uses
 * the JVM's default SecureRandom when a caller does not supply one, so unless
 * BCFIPS is the first provider that default is NativePRNG and every implicit
 * symmetric key generation fails in approved mode.
 *
 * Exit codes:
 *   0  approved mode confirmed and all enforcement checks held
 *   1  not in approved mode, or a check failed
 *   2  the tool could not run (module missing, etc.)
 *
 * Usage: fips-verify [--json]
 */
public class FipsVerify {

    static final String CMVP_CERT = "4943";
    static final String CMVP_URL =
        "https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943";
    static final String CAVP_CERT = "A4270";
    static final String EXPECTED_MODULE_VERSION = "2.1.1";

    // Digests of the modules this image is built against. Kept in step with
    // packages/*/melange.yaml by tests/fips/check-pins.sh.
    static final String[][] MODULES = {
        {"bc-fips",     "/usr/share/java/bc-fips-2.1.1.jar",
                        "a430d935ad6cec6d045930758457740f5a5f8f9715894e347f6800f7926a7321",
                        "CMVP #4943"},
        {"bcutil-fips", "/usr/share/java/bcutil-fips-2.1.5.jar",
                        "503aaf5c2c5b7c729547462efe13699b5f6dacf9be150b7c48bba974b793dc92",
                        "outside the validated boundary"},
        {"bctls-fips",  "/usr/share/java/bctls-fips-2.1.22.jar",
                        "688410563445e1a65ff33cb67842499f0788994d752c3df8f7ea4a0d40ddbf50",
                        "outside the validated boundary"},
    };

    // ── Result plumbing ───────────────────────────────────────────────────────

    enum Status { PASS, FAIL, INFO, WARN }

    static class Check {
        final String section, name, detail;
        final Status status;
        Check(String section, String name, Status status, String detail) {
            this.section = section; this.name = name; this.status = status; this.detail = detail;
        }
    }

    static final List<Check> CHECKS = new ArrayList<>();
    static void add(String s, String n, Status st, String d) { CHECKS.add(new Check(s, n, st, d)); }

    interface Body { void run() throws Throwable; }

    /** Records PASS if the body completes, FAIL otherwise. Catches Throwable:
     *  BC-FIPS signals approved-mode violations with Errors, not Exceptions, so
     *  catching Exception silently lets them terminate the JVM instead. */
    static void expectOk(String section, String name, String okDetail, Body b) {
        try { b.run(); add(section, name, Status.PASS, okDetail); }
        catch (Throwable t) { add(section, name, Status.FAIL, describe(t)); }
    }

    /** Records PASS if the body throws -- used for algorithms that MUST be
     *  unavailable in approved mode. Proving enforcement, not asserting it. */
    static void expectRejected(String section, String name, Body b) {
        try { b.run(); add(section, name, Status.FAIL, "was ACCEPTED but must be rejected in approved mode"); }
        catch (Throwable t) { add(section, name, Status.PASS, "rejected: " + describe(t)); }
    }

    static String describe(Throwable t) {
        String m = t.getMessage();
        if (t.getCause() != null && m == null) { t = t.getCause(); m = t.getMessage(); }
        return t.getClass().getSimpleName() + (m == null ? "" : ": " + m);
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x));
        return sb.toString();
    }

    static byte[] unhex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++)
            out[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        return out;
    }

    public static void main(String[] args) {
        boolean json = args.length > 0 && "--json".equals(args[0]);

        BouncyCastleFipsProvider bc;
        try {
            bc = new BouncyCastleFipsProvider();
            Security.addProvider(bc);
        } catch (Throwable t) {
            System.err.println("fips-verify: cannot instantiate BouncyCastleFipsProvider: " + describe(t));
            System.exit(2); return;
        }

        moduleIdentity();
        moduleState(bc);
        providerOrdering();
        boolean approved = CryptoServicesRegistrar.isInApprovedOnlyMode();
        knownAnswerTests();
        if (approved) enforcement(); else enforcementSkipped();
        entropy();
        callerObligations(approved);

        if (json) printJson(approved); else printText(approved);

        boolean failed = CHECKS.stream().anyMatch(c -> c.status == Status.FAIL);
        System.exit((approved && !failed) ? 0 : 1);
    }

    // ── 1. Module identity ────────────────────────────────────────────────────

    static void moduleIdentity() {
        for (String[] m : MODULES) {
            String name = m[0], path = m[1], expect = m[2], coverage = m[3];
            try {
                if (!Files.exists(Paths.get(path))) {
                    add("Module identity", name, Status.FAIL, "not installed at " + path);
                    continue;
                }
                MessageDigest md = MessageDigest.getInstance("SHA-256", "SUN");
                try (InputStream in = new BufferedInputStream(new FileInputStream(path))) {
                    byte[] buf = new byte[8192]; int n;
                    while ((n = in.read(buf)) != -1) md.update(buf, 0, n);
                }
                String actual = hex(md.digest());
                if (!expect.equals(actual))
                    add("Module identity", name, Status.FAIL,
                        "SHA-256 MISMATCH expected=" + expect + " got=" + actual);
                else
                    add("Module identity", name, Status.PASS,
                        actual.substring(0, 16) + "...  (" + coverage + ")");
            } catch (Throwable t) {
                add("Module identity", name, Status.FAIL, describe(t));
            }
        }
    }

    // ── 2. Module state ───────────────────────────────────────────────────────

    static void moduleState(BouncyCastleFipsProvider bc) {
        boolean approved = CryptoServicesRegistrar.isInApprovedOnlyMode();
        add("Module state", "approved-only mode", approved ? Status.PASS : Status.FAIL,
            "CryptoServicesRegistrar.isInApprovedOnlyMode()=" + approved
            + (approved ? "" : "  -- set -Dorg.bouncycastle.fips.approved_only=true"));

        boolean ready = FipsStatus.isReady();
        add("Module state", "power-on self-tests", ready ? Status.PASS : Status.FAIL,
            "FipsStatus.isReady()=" + ready
            + (ready ? " (KATs and integrity check passed at load)" : ": " + FipsStatus.getStatusMessage()));

        String ver = bc.getVersionStr();
        add("Module state", "module version", Status.INFO,
            "BCFIPS " + ver + "  (BC-FJA " + EXPECTED_MODULE_VERSION + ", " + CMVP_URL + ")");
        add("Module state", "algorithm certificate", Status.INFO,
            "CAVP " + CAVP_CERT + " under CMVP #" + CMVP_CERT);
    }

    // ── 3. Provider ordering ──────────────────────────────────────────────────

    static void providerOrdering() {
        Provider[] ps = Security.getProviders();
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < ps.length; i++) {
            if (i > 0) sb.append(", ");
            sb.append(i + 1).append(':').append(ps[i].getName());
        }
        boolean first = ps.length > 0 && "BCFIPS".equals(ps[0].getName());
        add("Provider ordering", "BCFIPS is first", first ? Status.PASS : Status.WARN,
            first ? sb.toString()
                  : "BCFIPS is NOT the highest-priority provider -- JCA lookups without an "
                    + "explicit provider may resolve elsewhere. Order: " + sb);
    }

    // ── 4. Known-answer tests against published vectors ───────────────────────

    static void knownAnswerTests() {
        final String S = "Known-answer tests";

        // FIPS 180-2 / NIST: SHA-256("abc")
        expectOk(S, "SHA-256 (FIPS 180-2 'abc')", "matches published digest", () -> {
            String want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
            String got = hex(MessageDigest.getInstance("SHA-256", "BCFIPS").digest("abc".getBytes("UTF-8")));
            if (!want.equals(got)) throw new AssertionError("expected=" + want + " got=" + got);
        });

        // RFC 4231 test case 1: HMAC-SHA-256
        expectOk(S, "HMAC-SHA-256 (RFC 4231 TC1)", "matches published MAC", () -> {
            String want = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
            byte[] key = new byte[20]; java.util.Arrays.fill(key, (byte) 0x0b);
            Mac mac = Mac.getInstance("HmacSHA256", "BCFIPS");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            String got = hex(mac.doFinal("Hi There".getBytes("UTF-8")));
            if (!want.equals(got)) throw new AssertionError("expected=" + want + " got=" + got);
        });

        // FIPS 197 Appendix C.3: AES-256 single block
        expectOk(S, "AES-256 block (FIPS 197 C.3)", "matches published ciphertext", () -> {
            String want = "8ea2b7ca516745bfeafc49904b496089";
            byte[] key = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
            byte[] pt  = unhex("00112233445566778899aabbccddeeff");
            Cipher c = Cipher.getInstance("AES/ECB/NoPadding", "BCFIPS");
            c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"));
            String got = hex(c.doFinal(pt));
            if (!want.equals(got)) throw new AssertionError("expected=" + want + " got=" + got);
        });

        // GCM spec (McGrew & Viega) test case 13: AES-256-GCM, empty PT and AAD
        expectOk(S, "AES-256-GCM tag (GCM TC13)", "matches published tag", () -> {
            String want = "530f8afbc74536b9a963b4f1c4cb738b";
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding", "BCFIPS");
            c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(new byte[32], "AES"),
                   new GCMParameterSpec(128, new byte[12]));
            String got = hex(c.doFinal(new byte[0]));
            if (!want.equals(got)) throw new AssertionError("expected=" + want + " got=" + got);
        });
    }

    // ── 5. Enforcement: non-approved algorithms must be unavailable ───────────

    static void enforcement() {
        final String S = "Enforcement (non-approved algorithms)";
        expectRejected(S, "MD5", () -> MessageDigest.getInstance("MD5", "BCFIPS").digest(new byte[1]));
        expectRejected(S, "RC4/ARC4", () -> Cipher.getInstance("ARC4", "BCFIPS"));
        expectRejected(S, "single DES", () -> Cipher.getInstance("DES/CBC/PKCS5Padding", "BCFIPS"));
        expectRejected(S, "MD5withRSA", () -> java.security.Signature.getInstance("MD5withRSA", "BCFIPS"));
        expectRejected(S, "RSA-1024 key generation", () -> {
            java.security.KeyPairGenerator g = java.security.KeyPairGenerator.getInstance("RSA", "BCFIPS");
            g.initialize(1024);
            g.generateKeyPair();
        });
    }

    static void enforcementSkipped() {
        add("Enforcement (non-approved algorithms)", "all checks", Status.FAIL,
            "SKIPPED -- the module is not in approved-only mode, so non-approved "
            + "algorithms are available by design. Nothing here is enforced.");
    }

    // ── 6. Entropy chain ──────────────────────────────────────────────────────

    /** Reports where key material ultimately comes from. This is disclosure,
     *  not a pass/fail: the seed source is the host kernel unless a userspace
     *  entropy source has been wired in, and a reader is entitled to know. */
    static void entropy() {
        final String S = "Entropy chain";
        add(S, "seed source", Status.INFO,
            "securerandom.source=" + Security.getProperty("securerandom.source")
            + " (host kernel -- no userspace entropy source is configured)");
        try {
            add(S, "JVM default SecureRandom", Status.INFO, new SecureRandom().getAlgorithm());
        } catch (Throwable t) { add(S, "JVM default SecureRandom", Status.WARN, describe(t)); }
        try {
            add(S, "SecureRandom.getInstanceStrong", Status.INFO,
                SecureRandom.getInstanceStrong().getAlgorithm());
        } catch (Throwable t) { add(S, "SecureRandom.getInstanceStrong", Status.WARN, describe(t)); }

        expectOk(S, "approved DRBG constructible", "FipsDRBG SHA-512/HMAC, 256-bit security strength", () -> {
            SecureRandom drbg = FipsDRBG.SHA512_HMAC
                .fromEntropySource(new BasicEntropySourceProvider(new SecureRandom(), true))
                .setSecurityStrength(256).setEntropyBitsRequired(256)
                .build(null, false);
            byte[] b = new byte[32];
            drbg.nextBytes(b);
        });

        add(S, "SP 800-90B validation", Status.INFO,
            "NOT CLAIMED. The entropy source is the host kernel and carries no ESV "
            + "certificate. Only the cryptographic module (CMVP #" + CMVP_CERT + ") is validated.");
    }

    // ── 7. Obligations this image cannot discharge for the application ────────

    static void callerObligations(boolean approved) {
        final String S = "Caller obligations";
        if (!approved) {
            add(S, "symmetric key generation", Status.INFO,
                "not evaluated outside approved mode");
            return;
        }
        // Demonstrate, rather than assert, that plain init(bits) fails and the
        // explicit-DRBG form succeeds.
        boolean plainWorks;
        try {
            KeyGenerator g = KeyGenerator.getInstance("AES", "BCFIPS");
            g.init(256); g.generateKey();
            plainWorks = true;
        } catch (Throwable t) { plainWorks = false; }

        if (plainWorks) {
            add(S, "symmetric key generation", Status.PASS,
                "KeyGenerator.init(256) succeeds: the JVM default SecureRandom resolves to "
                + "an approved DRBG (" + defaultRandomAlgorithm() + ")");
        } else {
            add(S, "symmetric key generation", Status.FAIL,
                "KeyGenerator.init(256) is REJECTED. The JVM default SecureRandom is "
                + defaultRandomAlgorithm() + ", which is not an approved DRBG, so implicit key "
                + "generation fails. Fix by making BCFIPS the first provider -- apply "
                + "fips.java.security. Applications otherwise have to pass a DRBG at every "
                + "call site.");
        }

        expectOk(S, "  ...with an explicit DRBG", "KeyGenerator.init(256, drbg) succeeds", () -> {
            SecureRandom drbg = FipsDRBG.SHA512_HMAC
                .fromEntropySource(new BasicEntropySourceProvider(new SecureRandom(), true))
                .setSecurityStrength(256).setEntropyBitsRequired(256).build(null, false);
            KeyGenerator g = KeyGenerator.getInstance("AES", "BCFIPS");
            g.init(256, drbg);
            g.generateKey();
        });

        try {
            Security.addProvider(new BouncyCastleJsseProvider(
                (BouncyCastleFipsProvider) Security.getProvider("BCFIPS")));
            javax.net.ssl.SSLContext.getInstance("TLSv1.3", "BCJSSE");
            add(S, "TLS 1.3 via BCJSSE", Status.PASS, "SSLContext obtained");
        } catch (Throwable t) {
            add(S, "TLS 1.3 via BCJSSE", Status.WARN, describe(t));
        }
    }

    static String defaultRandomAlgorithm() {
        try { return new SecureRandom().getAlgorithm(); }
        catch (Throwable t) { return "unknown"; }
    }

    // ── Output ────────────────────────────────────────────────────────────────

    static void printText(boolean approved) {
        System.out.println();
        System.out.println("  fips-verify -- BC-FIPS approved-mode verification");
        System.out.println("  " + (approved
            ? "RESULT: module is operating in FIPS-approved mode"
            : "RESULT: module is NOT in approved mode"));
        System.out.println();
        String current = null;
        for (Check c : CHECKS) {
            if (!c.section.equals(current)) {
                current = c.section;
                System.out.println("  " + current);
            }
            System.out.printf("    %-5s %-34s %s%n", c.status, c.name, c.detail);
        }
        System.out.println();
        System.out.println("  This tool verifies; it does not validate. Validation is an assertion by an");
        System.out.println("  accredited laboratory. Every line above is a measurement you can reproduce");
        System.out.println("  by re-running this program in this container.");
        System.out.println();
    }

    static void printJson(boolean approved) {
        Map<String, List<Check>> bySection = new LinkedHashMap<>();
        for (Check c : CHECKS) bySection.computeIfAbsent(c.section, k -> new ArrayList<>()).add(c);
        StringBuilder sb = new StringBuilder();
        sb.append("{\n  \"approvedMode\": ").append(approved).append(",\n");
        sb.append("  \"cmvpCertificate\": \"").append(CMVP_CERT).append("\",\n");
        sb.append("  \"cavpCertificate\": \"").append(CAVP_CERT).append("\",\n");
        sb.append("  \"entropySourceValidated\": false,\n");
        sb.append("  \"sections\": {\n");
        int si = 0;
        for (Map.Entry<String, List<Check>> e : bySection.entrySet()) {
            sb.append("    \"").append(esc(e.getKey())).append("\": [\n");
            for (int i = 0; i < e.getValue().size(); i++) {
                Check c = e.getValue().get(i);
                sb.append("      {\"name\": \"").append(esc(c.name))
                  .append("\", \"status\": \"").append(c.status)
                  .append("\", \"detail\": \"").append(esc(c.detail)).append("\"}")
                  .append(i < e.getValue().size() - 1 ? "," : "").append("\n");
            }
            sb.append("    ]").append(++si < bySection.size() ? "," : "").append("\n");
        }
        sb.append("  }\n}");
        System.out.println(sb);
    }

    static String esc(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ");
    }
}
