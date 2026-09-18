# FIPS APK Packages

[Melange](https://github.com/chainguard-dev/melange)-built APK packages for
FIPS-validated BouncyCastle cryptographic libraries, published as a
Wolfi-compatible APK repository via GitHub Pages.

## Packages

| Package | Version | Description | CMVP |
|---|---|---|---|
| `bouncycastle-fips` | 2.1.1 | BC-FJA — FIPS 140-3 Level 1 JCA/JCE provider | [#4943](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943) |
| `bcutil-fips` | 2.1.5 | BouncyCastle FIPS utility library — ASN.1 and supporting utilities required by `bctls-fips` | — |
| `bctls-fips` | 2.1.22 | BCTLS-FJA — FIPS 140-3 JSSE provider for TLS 1.2/1.3 | — |

All packages are built for `x86_64` and `aarch64`.

The JARs are fetched verbatim from Maven Central — they are **not recompiled**,
so the CMVP validation remains intact.

`bouncycastle-fips` is pinned to **2.1.1** because that is the software version
listed on CMVP certificate #4943. Newer bc-fips releases exist but are not
covered by an active certificate; see
[`tests/fips/COMPLIANCE.md`](tests/fips/COMPLIANCE.md) before bumping it.
`bcutil-fips` and `bctls-fips` are supporting libraries outside the validated
cryptographic boundary and carry no certificate of their own.

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
| `bouncycastle-fips` | `/usr/share/java/bc-fips-2.1.1.jar` (+ symlink `bc-fips.jar`) |
| `bcutil-fips` | `/usr/share/java/bcutil-fips-2.1.5.jar` (+ symlink `bcutil-fips.jar`) |
| `bctls-fips` | `/usr/share/java/bctls-fips-2.1.22.jar` (+ symlink `bctls-fips.jar`) |

## FIPS Compliance Testing

Every CI run executes a compliance test suite against the freshly-built APKs
before they are published. See [`tests/fips/COMPLIANCE.md`](tests/fips/COMPLIANCE.md)
for full details.

**What the tests verify:**

| Test | What it checks |
|---|---|
| `testJarIntegrity` | SHA-256 of all three installed JARs matches the Maven Central artifacts (for `bc-fips`, the CMVP-listed module) |
| `testFipsSelfTests` | BC-FIPS Power-On Self-Tests (POST) complete successfully on startup |
| `testProviderRegistration` | `BCFIPS` provider is registered and reachable via the JCA |
| `testAesGcm` | AES-256-GCM encrypt/decrypt round-trip works correctly |
| `testSha256` | SHA-256 produces the expected digest for a known input |
| `testRsa` | RSA-2048 `SHA256withRSA` sign/verify works correctly |
| `testEcdsa` | ECDSA P-256 `SHA256withECDSA` sign/verify works correctly |
| `testHmacSha256` | HMAC-SHA256 produces the correct output length |
| `testTlsProvider` | `BCJSSE` provider registers and provides a `TLSv1.3` `SSLContext` |
| `testSymlinkResolution` | Unversioned symlinks (`bc-fips.jar`, `bcutil-fips.jar`, `bctls-fips.jar`) resolve to the versioned files |

The compliance report (Markdown + HTML) is uploaded as a CI artifact on every
run and published to GitHub Pages alongside the APK repository on push to `main`.

**Scope.** These tests attest to *packaging integrity*: that the correct,
unmodified JAR is installed where consumers expect it and that the provider
initialises and works in the target runtime. They run BC-FIPS in its default
mode, not approved-only mode, so they do not attest that a consuming
application operates the module in its FIPS-approved mode. See
[`tests/fips/COMPLIANCE.md`](tests/fips/COMPLIANCE.md#what-is-not-tested).

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

1. **`check-pins`** — verifies that every file repeating a package version or
   SHA-256 agrees with the `melange.yaml` files; fails fast before anything builds
2. **`build-packages`** — builds all three packages for x86_64 and aarch64 using melange
3. **`fips-compliance`** — installs the freshly-built APKs into a Wolfi container and
   runs the compliance test suite; blocks publication on failure
4. **`deploy-pages`** (push/tag only) — deploys the APK repository and compliance
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
  bouncycastle-fips/melange.yaml   # BC-FJA 2.1.1  (CMVP #4943) — authoritative pin
  bcutil-fips/melange.yaml         # bcutil-fips 2.1.5 (ASN.1 utilities)
  bctls-fips/melange.yaml          # BCTLS-FJA 2.1.22
tests/
  fips/
    FipsComplianceTest.java        # Java compliance test program
    run-fips-tests.sh              # Orchestration + report generation
    check-pins.sh                  # Version/digest drift check (runs first in CI)
    COMPLIANCE.md                  # Compliance testing documentation
.github/workflows/build.yaml      # CI/CD pipeline
Makefile                           # Local build targets
```
