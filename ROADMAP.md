# Fedora Distroless for Java - Roadmap

## Project Goals
- Build minimal Fedora/RHEL-based container images with Bazel
- Target Java applications for government environments
- Learn Bazel while building production-ready tooling
- Support FIPS compliance requirements

## Target Distribution
**Rocky Linux 9** (RHEL 9 clone, free, stable, long-term support)

## Phase 1: Foundation (Weeks 1-2)

### Milestone 1.1: Bazel Setup
- [ ] Initialize Bazel workspace with MODULE.bazel
- [ ] Set up basic project structure
- [ ] Configure .bazelrc with sensible defaults
- [ ] Add OCI image rules (rules_oci)
- [ ] Create hello-world build target

### Milestone 1.2: RPM Package Downloader
- [ ] Build HTTP downloader for RPM files
- [ ] Parse repodata (primary.xml) from Rocky repos
- [ ] Implement RPM signature verification
- [ ] Cache downloaded packages
- [ ] Create Bazel rule: `rpm_fetch`

### Milestone 1.3: Minimal Base Image
- [ ] Extract filesystem from base RPM (filesystem, setup)
- [ ] Create essential directories (/tmp, /var, /etc)
- [ ] Add /etc/passwd and /etc/group
- [ ] Build first OCI image with rules_oci
- [ ] Test with container runtime (podman/docker)

## Phase 2: Package Management (Weeks 3-4)

### Milestone 2.1: RPM Extraction
- [ ] Implement rpm2cpio extraction
- [ ] Handle RPM payload formats (xz, zstd)
- [ ] Filter files (exclude docs, man pages, headers)
- [ ] Preserve file permissions and ownership
- [ ] Create Bazel rule: `rpm_extract`

### Milestone 2.2: Dependency Resolution
- [ ] Parse RPM dependencies (Requires, Provides)
- [ ] Build dependency graph
- [ ] Resolve transitive dependencies
- [ ] Handle version constraints
- [ ] Create lockfile format for reproducibility

### Milestone 2.3: Java Runtime Base
- [ ] Install java-21-openjdk-headless
- [ ] Strip unnecessary files (javadoc, sources)
- [ ] Include CA certificates (ca-certificates package)
- [ ] Add timezone data (tzdata package)
- [ ] Test with simple Java app

## Phase 3: Advanced Features (Weeks 5-6)

### Milestone 3.1: Layer Optimization
- [ ] Deduplicate files across layers
- [ ] Order layers by change frequency
- [ ] Compress layers efficiently
- [ ] Measure and optimize image size

### Milestone 3.2: Java-specific Tooling
- [ ] Create `java_distroless_image` rule
- [ ] Support custom JVM flags
- [ ] Include jlink for custom JRE
- [ ] Add FIPS mode configuration
- [ ] Security hardening defaults

### Milestone 3.3: Multi-architecture
- [ ] Support x86_64 (primary)
- [ ] Support aarch64 (secondary)
- [ ] Cross-platform builds
- [ ] Multi-arch manifest generation

## Phase 4: Production Readiness (Weeks 7-8)

### Milestone 4.1: Testing & Validation
- [ ] Container structure tests
- [ ] Vulnerability scanning integration
- [ ] Size regression tests
- [ ] Runtime validation suite
- [ ] CI/CD pipeline (GitHub Actions)

### Milestone 4.2: Documentation & Examples
- [ ] Getting started guide
- [ ] API reference
- [ ] Example: Spring Boot app
- [ ] Example: Quarkus app
- [ ] Migration guide from UBI images

### Milestone 4.3: FIPS & Compliance
- [ ] FIPS 140-2 mode support
- [ ] Include FIPS-certified crypto
- [ ] STIG compliance considerations
- [ ] Documentation for ATO process

## Future Enhancements

- Debug variants (with busybox)
- Other language runtimes (Python, Node.js)
- Integration with SBOM generation
- Red Hat UBI compatibility layer
- Automated security updates

## Success Metrics

- Base image < 150MB (vs UBI minimal ~100MB)
- Java image < 250MB (vs UBI openjdk ~400MB)
- Build time < 5 minutes (cached)
- Zero HIGH/CRITICAL CVEs at release
- Clear documentation for Bazel newcomers

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Base Distro | Rocky Linux 9 | RHEL-compatible, free, stable |
| Java Version | OpenJDK 21 | LTS, modern, gov't approved |
| Build System | Bazel + rules_oci | Reproducible, cacheable |
| Package Format | RPM | Native to RHEL ecosystem |
| Image Format | OCI | Standard, portable |
| Repository | Rocky BaseOS + AppStream | Complete package set |

## Dependencies

### External Tools
- Bazel 7.x
- rpm2cpio
- libarchive (for tar/cpio)
- curl/wget (for downloads)

### Bazel Rules
- rules_oci (OCI image building)
- bazel_skylib (utilities)
- rules_pkg (optional, for tar operations)

## Repository Structure

```
bazel/
├── MODULE.bazel          # Bazel module definition
├── WORKSPACE             # Legacy workspace (if needed)
├── BUILD.bazel           # Root build file
├── .bazelrc              # Bazel configuration
├── ROADMAP.md            # This file
├── rpm/                  # RPM package rules
│   ├── BUILD.bazel
│   ├── fetch.bzl
│   ├── extract.bzl
│   └── resolve.bzl
├── distroless/           # Image building rules
│   ├── BUILD.bazel
│   ├── base.bzl
│   └── java.bzl
├── tools/                # Helper scripts
│   ├── rpm_downloader.py
│   └── repodata_parser.py
└── examples/             # Example applications
    ├── hello-java/
    └── spring-boot/
```

## Getting Started

1. Install Bazel 7.x
2. Initialize project: `bazel build //...`
3. Build base image: `bazel build //distroless:base`
4. Build Java image: `bazel build //distroless:java21`
5. Load to runtime: `bazel run //distroless:java21_tarball`
