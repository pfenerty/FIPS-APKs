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
| BC-FJA (`bouncycastle-fips`) | 2.1.1 | #4943 | [CMVP #4943](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943) |
| `bcutil-fips` | 2.1.5 | not a validated module | — |
| BCTLS-FJA (`bctls-fips`) | 2.1.22 | not a validated module | — |

**The pinned bc-fips version is load-bearing.** CMVP #4943 lists software
version **2.1.1**. Later bc-fips releases (2.1.2 and up) are *not* covered by
it, so bumping this package without checking the [CMVP active module
list](https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search)
would silently void the certification claim these packages exist to make.

BCTLS-FJA is a TLS layer built on top of BC-FJA, and `bcutil-fips` supplies
ASN.1 utilities it needs. Neither is a validated module in its own right — the
FIPS cryptographic boundary is the BC-FJA module. All three JARs are fetched
verbatim from Maven Central and never recompiled, preserving that boundary.

## Artifact Integrity

The expected SHA-256 digests below match the `.sha256` files published by
BouncyCastle on Maven Central alongside each JAR and are the canonical values
for the CMVP-certified artifacts.

| Artifact | Expected SHA-256 |
|---|---|
| `bc-fips-2.1.1.jar` | `a430d935ad6cec6d045930758457740f5a5f8f9715894e347f6800f7926a7321` |
| `bcutil-fips-2.1.5.jar` | `503aaf5c2c5b7c729547462efe13699b5f6dacf9be150b7c48bba974b793dc92` |
| `bctls-fips-2.1.22.jar` | `688410563445e1a65ff33cb67842499f0788994d752c3df8f7ea4a0d40ddbf50` |

These values are hardcoded as `expected-sha256` in the respective
`melange.yaml` files so Melange verifies them at APK build time, and again
by `FipsComplianceTest.java` at runtime against the installed files.

The `melange.yaml` files are the single source of truth for versions and
digests. `check-pins.sh` runs first in CI and fails the build if any other
file — the Java test, the report templates, this document, the README — has
drifted out of agreement with them.

## Test Suite

### Files

| File | Purpose |
|---|---|
| `FipsComplianceTest.java` | Java test program; compiled and run against the installed JARs |
| `run-fips-tests.sh` | Shell orchestrator; drives both runs and generates the compliance report |
| `check-pins.sh` | Version/digest consistency check; runs in its own CI job before anything is built |
| `../../tools/fips-verify/FipsVerify.java` | Approved-mode verification tool, shipped as the `fips-verify` package |

Tests catch `Throwable`, not `Exception`. BC-FIPS signals approved-mode
violations with `Error`s (`FipsUnapprovedOperationError`); catching only
`Exception` lets them terminate the JVM partway through a run instead of being
reported as a failed test.

### How it runs

The `fips-compliance` CI job delegates to `scripts/ci/run-compliance.sh`,
which in turn runs `scripts/ci/container-compliance.sh` inside the container.
Between them they:

1. Download the APKs built by the `build-packages` job
2. Start a `cgr.dev/chainguard/wolfi-base` Docker container (same base as production)
3. Install `openjdk-21-default-jdk` plus every package under test, verified
   against the build signing key (nothing uses `--allow-untrusted`)
4. Compile and run `FipsComplianceTest` in BC-FIPS **default mode**
5. Run `fips-verify` in **approved-only mode** under the shipped overlay
6. Generate `compliance-report.md` and `compliance-report.html` carrying both
7. Upload the report as a CI artifact, and fail the job if either failed

The two runs answer different questions and both appear in the report:

| | Mode | Attests to |
|---|---|---|
| `FipsComplianceTest` | default | **packaging integrity** -- the right JARs, unmodified, at the expected paths, and the provider loads and works |
| `fips-verify` | approved-only | **approved-mode operation** -- the module is in approved mode, non-approved algorithms are unavailable, published KATs match |

### Tests

| Test | Description |
|---|---|
| `testJarIntegrity` | Computes SHA-256 of all three installed versioned JARs using the JDK `SUN` provider (before BC-FIPS is registered) and compares against the expected digests above. A mismatch means the packaged JAR differs from the upstream artifact — for `bc-fips`, from the CMVP-validated module. |
| `testFipsSelfTests` | Checks `FipsStatus.isReady()` after `BouncyCastleFipsProvider` construction. BC-FIPS runs its Power-On Self-Tests (algorithm known-answer tests and integrity checks) during initialization; `isReady()` returns `false` if any POST failed. |
| `testProviderRegistration` | Verifies that `Security.getProvider("BCFIPS")` returns a non-null provider after registration, confirming the JCA service lookup works correctly. |
| `testAesGcm` | Generates an AES-256 key via `BCFIPS`, encrypts 20 bytes with AES-256-GCM, decrypts, and checks the round-trip produces the original plaintext. |
| `testSha256` | Computes SHA-256 of a fixed string via `BCFIPS` and compares against a precomputed expected digest, verifying both correctness and determinism. |
| `testRsa` | Generates an RSA-2048 key pair, signs a byte array with `SHA256withRSA`, and verifies the signature — all via `BCFIPS`. |
| `testEcdsa` | Generates a P-256 key pair, signs a byte array with `SHA256withECDSA`, and verifies the signature — all via `BCFIPS`. |
| `testHmacSha256` | Generates an HMAC-SHA256 key, computes a MAC over a test string, and checks the output is the expected 32 bytes. |
| `testTlsProvider` | Registers `BouncyCastleJsseProvider` (from `bctls-fips`) backed by the already-registered `BCFIPS` provider, then obtains a `TLSv1.3` `SSLContext` from `BCJSSE`. |
| `testSymlinkResolution` | Checks that all three unversioned symlinks (`/usr/share/java/bc-fips.jar`, `bcutil-fips.jar`, `bctls-fips.jar`) exist and resolve to their versioned targets. |

### What is not tested

**SP 800-90B entropy validation.** The DRBG is seeded from the host kernel
(`securerandom.source=file:/dev/random`). No userspace entropy source is
configured and no ESV certificate is claimed. `fips-verify` reports the entropy
chain explicitly rather than omitting it. Only the cryptographic module is
validated (CMVP #4943); the entropy source feeding it is not.

Note that BC-FJA is pure Java and has never required a FIPS-mode kernel to
operate. What is missing is entropy *independence*, not the ability to run on
an ordinary kernel.

**aarch64 functional tests.** The CI runner is x86_64, so functional tests
execute only for x86_64. The aarch64 APK integrity is implicitly covered by
`testJarIntegrity`: because the JAR content is architecture-independent (pure
Java), both architectures' APKs contain identical JAR bytes. The Melange build
verifies the SHA-256 at build time for both architectures.

## Approved-Mode Configuration

Approved mode needs two settings, and **neither is sufficient alone**:

```
-Dorg.bouncycastle.fips.approved_only=true
-Djava.security.properties=/usr/share/java/fips/fips.java.security
```

The first selects approved mode. The second, shipped by the
`bouncycastle-fips-config` package, makes `BCFIPS` the first JCA provider.

Provider ordering is load-bearing, not cosmetic. BC-FIPS uses the JVM's default
`SecureRandom` when a caller does not supply one. If `BCFIPS` is not first, that
default is `NativePRNG`, which is not an approved DRBG, and every implicit
symmetric key generation fails with:

```
FipsUnapprovedOperationError: Attempt to create key with unapproved RNG: AES
```

With `BCFIPS` first, the default resolves to the module's approved DRBG and
`KeyGenerator.init(256)` succeeds. **No application code change is required**,
provided the configuration is applied. The `fips-jre` image sets both settings
via `JAVA_TOOL_OPTIONS` so the application and `fips-verify` inherit the same
configuration.

## Compliance Report

The report is generated by `run-fips-tests.sh` and contains:

- Pass/fail status for every test
- SHA-256 of the installed JARs vs. expected values
- `apk info` metadata for each installed package
- CI run ID, Git SHA, and timestamp for audit traceability

On push to `main`, the HTML report is published to GitHub Pages alongside the
APK repository at `compliance-report.html`.
