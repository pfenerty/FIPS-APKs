# FIPS Base Images

Minimal, FIPS-hardened OCI container base images built with
[apko](https://github.com/chainguard-dev/apko) and
[Wolfi](https://github.com/wolfi-dev/os) open-source packages.

## Images

| Image | Definition | Description |
|---|---|---|
| `fips-base` | `images/base/image.yaml` | Wolfi baseOS with OpenSSL FIPS provider + jitterentropy |
| `fips-java21` | `images/java21/image.yaml` | Java 21 JRE on top of `fips-base` with BouncyCastle FIPS providers |

Both images target `x86_64` and `aarch64`.

## FIPS Architecture

### Kernel-Independent Design

Both images include `jitterentropy-library`, a NIST SP 800-90B validated
userspace entropy source. This decouples FIPS compliance from the host kernel —
the images run on GKE (COS), AWS Bottlerocket, Azure Linux, and standard kernels
without requiring a FIPS-mode kernel.

### Base image (`fips-base`)

| Package | Role |
|---|---|
| `openssl` | OpenSSL 3.4+ with built-in FIPS provider module (CMVP [#4282](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4282)) |
| `jitterentropy-library` | SP 800-90B userspace entropy source |
| `ca-certificates-bundle` | Trusted TLS root certificates |
| `wolfi-base` | BusyBox + musl libc minimal userspace |

### Java 21 image (`fips-java21`)

Uses a fully Java-native FIPS stack — no PKCS11 bridge required.

| Package | Role |
|---|---|
| `bouncycastle-fips` | BC-FJA 2.1.2 — JCA/JCE provider (CMVP [#4943](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943)) |
| `bctls-fips` | BCTLS-FJA 2.1.22 — JSSE provider for FIPS TLS 1.2/1.3 |
| `openjdk-21-jre` | OpenJDK 21 Java Runtime Environment |
| `openjdk-21-default-jvm` | Sets OpenJDK 21 as the default JVM |
| *(all base packages)* | OpenSSL FIPS + jitterentropy, as above |

`bouncycastle-fips` uses its built-in **BC-RNG-JENT** entropy provider, which
seeds the SHA-256 DRBG from `jitterentropy-library`. FIPS operation is
therefore fully kernel-independent at the Java layer too.

Security provider configuration is in `images/java21/fips.security`.

## Local Packages (melange)

`bouncycastle-fips` and `bctls-fips` are not in the public Wolfi repository.
This repo packages the official FIPS-validated JARs from Maven Central using
[melange](https://github.com/chainguard-dev/melange), Chainguard's APK builder.

```
packages/
  bouncycastle-fips/melange.yaml   # bc-fips-2.1.2.jar  (CMVP #4943)
  bctls-fips/melange.yaml          # bctls-fips-2.1.22.jar
```

The JARs are fetched verbatim from Maven Central — they are **not recompiled**,
so the CMVP validation remains intact.

## Prerequisites

```bash
# apko — OCI image builder
brew install apko
# or: go install chainguard.dev/apko@latest

# melange — APK package builder (required for java21 image only)
brew install melange
# or: go install chainguard.dev/melange@latest
```

## Building

```bash
# Generate a local APK signing key (run once)
make keys

# Build everything: local packages + both images
make all

# Or build individually:
make base       # no melange needed
make packages   # build bouncycastle-fips + bctls-fips APKs
make java21     # depends on `make packages`

# Load into local Docker daemon
make load-base
make load-java21

# Clean build artefacts (keeps signing keys)
make clean

# Clean everything including packages and keys
make clean-packages
```

## Activating FIPS in Java Applications

The image sets `CLASSPATH` to include the BC FIPS JARs automatically.
Apply the security properties override at startup:

```bash
# Via environment variable (recommended for containers)
docker run --rm \
  -e JAVA_TOOL_OPTIONS="-Djava.security.properties=/etc/java/fips.security" \
  fips-java21:latest java -version

# Or inline
docker run --rm fips-java21:latest \
  java -Djava.security.properties=/etc/java/fips.security -jar myapp.jar
```

The `fips.security` file configures:
- `BouncyCastleFipsProvider` as the primary JCA/JCE provider (DRBG seeded via JENT)
- `BouncyCastleJsseProvider` for FIPS TLS 1.2/1.3
- TLS 1.0/1.1, RC4, DES, 3DES, MD5, and sub-2048-bit keys disabled

## Verifying FIPS

```bash
# Base image: MD5 must be blocked
docker run --rm fips-base:latest sh -c \
  'openssl md5 /dev/null 2>&1 && echo "FAIL" || echo "OK: MD5 blocked"'

# Base image: show loaded providers (should include fips)
docker run --rm fips-base:latest openssl list -providers

# Java image: confirm BouncyCastle FIPS providers are active
docker run --rm \
  -e JAVA_TOOL_OPTIONS="-Djava.security.properties=/etc/java/fips.security" \
  fips-java21:latest java -XshowSettings:security -version 2>&1 | grep -i bouncy
```
