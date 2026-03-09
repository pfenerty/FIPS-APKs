# FIPS Compliance Testing

This document describes the compliance test suite for the `bouncycastle-fips`,
`bcutil-fips`, and `bctls-fips` APK packages.

## Purpose

The tests exist to provide evidence that:

1. The JARs distributed in these APK packages are **cryptographically identical**
   to the artifacts covered by NIST CMVP certificate [#4943](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943).
2. The BC-FIPS library **initializes correctly** and passes its internal
   Power-On Self-Tests (POST) in the target runtime environment (Wolfi/Alpine).
3. **FIPS-approved algorithms** function correctly end-to-end after installation.
4. The **package layout** (file paths, symlinks) is correct so consumers can
   reliably reference the JARs.

## CMVP References

| Module | Version | Certificate | NIST URL |
|---|---|---|---|
| BC-FJA (`bouncycastle-fips`) | 2.1.2 | #4943 | [CMVP #4943](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943) |
| BCTLS-FJA (`bctls-fips`) | 2.1.22 | uses #4943 | [CMVP #4943](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943) |

BCTLS-FJA is a TLS layer built on top of BC-FJA. The FIPS cryptographic
boundary is the BC-FJA module. Both JARs are fetched verbatim from Maven
Central and never recompiled, preserving the certification boundary.

## Artifact Integrity

The expected SHA-256 digests below match the `.sha256` files published by
BouncyCastle on Maven Central alongside each JAR and are the canonical values
for the CMVP-certified artifacts.

| Artifact | Expected SHA-256 |
|---|---|
| `bc-fips-2.1.2.jar` | `044fcd8a29d236edea8a5b414406cdae63b475f9ad9f05fe2dc904a277941115` |
| `bcutil-fips-2.1.5.jar` | `503aaf5c2c5b7c729547462efe13699b5f6dacf9be150b7c48bba974b793dc92` |
| `bctls-fips-2.1.22.jar` | `688410563445e1a65ff33cb67842499f0788994d752c3df8f7ea4a0d40ddbf50` |

These values are also hardcoded as `expected-sha256` in the respective
`melange.yaml` files so Melange verifies them at APK build time, and again
by `FipsComplianceTest.java` at runtime against the installed files.

## Test Suite

### Files

| File | Purpose |
|---|---|
| `FipsComplianceTest.java` | Java test program; compiled and run against the installed JARs |
| `run-fips-tests.sh` | Shell orchestrator; installs packages, drives compilation and execution, generates the compliance report |

### How it runs

The `fips-compliance` CI job:

1. Downloads the APKs built by the `build-packages` job
2. Starts a `cgr.dev/chainguard/wolfi-base` Docker container (same base as production)
3. Installs `openjdk-21-default-jdk` for compilation and `bouncycastle-fips`,
   `bcutil-fips`, `bctls-fips` from the local APK repository
4. Compiles `FipsComplianceTest.java` against the installed JARs
5. Runs the compiled test and captures output
6. Generates `compliance-report.md` and `compliance-report.html`
7. Uploads the report as a CI artifact (retained 90 days)
8. Fails the CI job if any test fails, blocking APK publication

### Tests

| Test | Description |
|---|---|
| `testJarIntegrity` | Computes SHA-256 of the installed versioned JARs using the JDK `SUN` provider (before BC-FIPS is registered) and compares against the expected digests above. A mismatch means the packaged JAR differs from the CMVP artifact. |
| `testFipsSelfTests` | Checks `FipsStatus.isReady()` after `BouncyCastleFipsProvider` construction. BC-FIPS runs its Power-On Self-Tests (algorithm known-answer tests and integrity checks) during initialization; `isReady()` returns `false` if any POST failed. |
| `testProviderRegistration` | Verifies that `Security.getProvider("BCFIPS")` returns a non-null provider after registration, confirming the JCA service lookup works correctly. |
| `testAesGcm` | Generates an AES-256 key via `BCFIPS`, encrypts 20 bytes with AES-256-GCM, decrypts, and checks the round-trip produces the original plaintext. |
| `testSha256` | Computes SHA-256 of a fixed string via `BCFIPS` and compares against a precomputed expected digest, verifying both correctness and determinism. |
| `testRsa` | Generates an RSA-2048 key pair, signs a byte array with `SHA256withRSA`, and verifies the signature — all via `BCFIPS`. |
| `testEcdsa` | Generates a P-256 key pair, signs a byte array with `SHA256withECDSA`, and verifies the signature — all via `BCFIPS`. |
| `testHmacSha256` | Generates an HMAC-SHA256 key, computes a MAC over a test string, and checks the output is the expected 32 bytes. |
| `testTlsProvider` | Registers `BouncyCastleJsseProvider` (from `bctls-fips`) backed by the already-registered `BCFIPS` provider, then obtains a `TLSv1.3` `SSLContext` from `BCJSSE`. |
| `testSymlinkResolution` | Checks that the unversioned symlinks (`/usr/share/java/bc-fips.jar`, `/usr/share/java/bctls-fips.jar`) exist and resolve to their versioned targets. |

### What is not tested

**Algorithm rejection in approved-only mode.** BC-FIPS only blocks non-approved
algorithms (RC4, DES, MD5withRSA, etc.) when explicitly initialized in
approved-only mode via the `org.bouncycastle.fips.approved_only=true` system
property. In the default mode used here, the library runs POST self-tests and
makes approved algorithms available but does not restrict non-approved ones.
Testing this behavior is outside the scope of APK packaging compliance.

**aarch64 functional tests.** The CI runner is x86_64, so functional tests
execute only for x86_64. The aarch64 APK integrity is implicitly covered by
`testJarIntegrity`: because the JAR content is architecture-independent (pure
Java), both architectures' APKs contain identical JAR bytes. The Melange build
verifies the SHA-256 at build time for both architectures.

## Compliance Report

The report is generated by `run-fips-tests.sh` and contains:

- Pass/fail status for every test
- SHA-256 of the installed JARs vs. expected values
- `apk info` metadata for each installed package
- CI run ID, Git SHA, and timestamp for audit traceability

On push to `main`, the HTML report is published to GitHub Pages alongside the
APK repository at `compliance-report.html`.
