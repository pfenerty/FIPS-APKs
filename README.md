# FIPS APK Packages

[Melange](https://github.com/chainguard-dev/melange)-built APK packages for
FIPS-validated BouncyCastle cryptographic libraries, published as a
Wolfi-compatible APK repository via GitHub Pages.

## Packages

| Package | Version | Description | CMVP |
|---|---|---|---|
| `bouncycastle-fips` | 2.1.2 | BC-FJA — FIPS 140-3 Level 1 JCA/JCE provider | [#4943](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943) |
| `bcutil-fips` | 2.1.5 | BouncyCastle FIPS utility library — ASN.1 and supporting utilities required by `bctls-fips` | — |
| `bctls-fips` | 2.1.22 | BCTLS-FJA — FIPS 140-3 JSSE provider for TLS 1.2/1.3 | — |

All packages are built for `x86_64` and `aarch64`.

The JARs are fetched verbatim from Maven Central — they are **not recompiled**,
so the CMVP validation remains intact.

## Installation

Packages are published to GitHub Pages as a standard APK repository. Add the
repository and signing key to your apko image configuration:

```yaml
contents:
  repositories:
    - https://packages.wolfi.dev/os
    - https://<org>.github.io/<repo>
  keyring:
    - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
    - https://<org>.github.io/<repo>/melange.rsa.pub
  packages:
    - bouncycastle-fips
    - bcutil-fips
    - bctls-fips
```

Or install directly with `apk`:

```bash
# Add the repository and key
echo "https://<org>.github.io/<repo>" >> /etc/apk/repositories
wget -qO /etc/apk/keys/melange.rsa.pub https://<org>.github.io/<repo>/melange.rsa.pub

apk add bouncycastle-fips bcutil-fips bctls-fips
```

### Installed files

| Package | Files |
|---|---|
| `bouncycastle-fips` | `/usr/share/java/bc-fips-2.1.2.jar` (+ symlink `bc-fips.jar`) |
| `bcutil-fips` | `/usr/share/java/bcutil-fips-2.1.5.jar` (+ symlink `bcutil-fips.jar`) |
| `bctls-fips` | `/usr/share/java/bctls-fips-2.1.22.jar` (+ symlink `bctls-fips.jar`) |

## FIPS Architecture

### Kernel-Independent Design

`bouncycastle-fips` depends on `jitterentropy-library`, a NIST SP 800-90B
validated userspace entropy source. The BC-RNG-JENT entropy provider seeds its
SHA-256 DRBG from `jitterentropy-library`, so FIPS operation is fully
kernel-independent — no FIPS-mode kernel required on the host.

This means the packages work on GKE (COS), AWS Bottlerocket, Azure Linux, and
standard kernels without any special kernel configuration.

## FIPS Compliance Testing

Every CI run executes a compliance test suite against the freshly-built APKs
before they are published. See [`tests/fips/COMPLIANCE.md`](tests/fips/COMPLIANCE.md)
for full details.

**What the tests verify:**

| Test | What it checks |
|---|---|
| `testJarIntegrity` | SHA-256 of installed JARs matches the CMVP-certified Maven Central artifacts |
| `testFipsSelfTests` | BC-FIPS Power-On Self-Tests (POST) complete successfully on startup |
| `testProviderRegistration` | `BCFIPS` provider is registered and reachable via the JCA |
| `testAesGcm` | AES-256-GCM encrypt/decrypt round-trip works correctly |
| `testSha256` | SHA-256 produces the expected digest for a known input |
| `testRsa` | RSA-2048 `SHA256withRSA` sign/verify works correctly |
| `testEcdsa` | ECDSA P-256 `SHA256withECDSA` sign/verify works correctly |
| `testHmacSha256` | HMAC-SHA256 produces the correct output length |
| `testTlsProvider` | `BCJSSE` provider registers and provides a `TLSv1.3` `SSLContext` |
| `testSymlinkResolution` | Unversioned symlinks (`bc-fips.jar`, `bctls-fips.jar`) resolve to the versioned files |

The compliance report (Markdown + HTML) is uploaded as a CI artifact on every
run and published to GitHub Pages alongside the APK repository on push to `main`.

## Local Development

### Prerequisites

```bash
# melange — APK package builder
brew install melange
# or: go install chainguard.dev/melange@latest
```

### Building

```bash
# Generate a local APK signing key (run once)
make keys

# Build all APKs (bouncycastle-fips, bcutil-fips, bctls-fips)
make packages

# Clean build artefacts (keeps signing keys)
make clean

# Clean everything including packages and keys
make clean-packages
```

## CI/CD

The GitHub Actions workflow (`.github/workflows/build.yaml`) runs on every push
to `main` and on pull requests:

1. **`build-packages`** — builds all three packages for x86_64 and aarch64 using melange
2. **`fips-compliance`** — installs the freshly-built APKs into a Wolfi container and
   runs the compliance test suite; blocks publication on failure
3. **`deploy-pages`** (push/tag only) — deploys the APK repository and compliance
   report to GitHub Pages

### Repository secret

The `MELANGE_SIGNING_KEY` repository secret must contain the base64-encoded
melange RSA private key used to sign published packages:

```bash
# Generate a key locally, then base64-encode it for the secret
melange keygen melange.rsa
base64 -w0 melange.rsa  # paste this value into the repository secret
```

## Repository layout

```
packages/
  bouncycastle-fips/melange.yaml   # BC-FJA 2.1.2  (CMVP #4943)
  bcutil-fips/melange.yaml         # bcutil-fips 2.1.5 (ASN.1 utilities)
  bctls-fips/melange.yaml          # BCTLS-FJA 2.1.22
tests/
  fips/
    FipsComplianceTest.java        # Java compliance test program
    run-fips-tests.sh              # Orchestration + report generation
    COMPLIANCE.md                  # Compliance testing documentation
.github/workflows/build.yaml      # CI/CD pipeline
Makefile                           # Local build targets
```
