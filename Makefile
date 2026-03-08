APKO    ?= apko
MELANGE ?= melange

REGISTRY    ?= localhost
PACKAGES_DIR := $(CURDIR)/packages/out
SIGNING_KEY  := $(CURDIR)/melange.rsa

BASE_REF   := $(REGISTRY)/fips-base:latest
JAVA21_REF := $(REGISTRY)/fips-java21:latest

.PHONY: all base java21 packages packages-bc packages-bctls \
        load-base load-java21 keys clean clean-packages help

## Build everything (packages then images)
all: base java21

## ── Keys ─────────────────────────────────────────────────────────────────────

## Generate a local melange signing key pair (run once)
keys: $(SIGNING_KEY)

$(SIGNING_KEY):
	$(MELANGE) keygen $(SIGNING_KEY)

## ── Local APK packages ───────────────────────────────────────────────────────

## Build bouncycastle-fips and bctls-fips APKs
packages: packages-bc packages-bctls

packages-bc: $(SIGNING_KEY)
	$(MELANGE) build packages/bouncycastle-fips/melange.yaml \
	    --arch x86_64,aarch64 \
	    --signing-key $(SIGNING_KEY) \
	    --out-dir $(PACKAGES_DIR)

packages-bctls: packages-bc
	$(MELANGE) build packages/bctls-fips/melange.yaml \
	    --arch x86_64,aarch64 \
	    --signing-key $(SIGNING_KEY) \
	    --out-dir $(PACKAGES_DIR)

## ── Images ───────────────────────────────────────────────────────────────────

## Build the FIPS-hardened Wolfi base OS image (no local packages needed)
base: images/base/image.yaml
	$(APKO) build $< $(BASE_REF) fips-base.tar

## Build the FIPS-hardened Java 21 JRE image (requires `make packages` first)
java21: packages images/java21/image.yaml
	$(APKO) build images/java21/image.yaml \
	    --repository-append "file://$(PACKAGES_DIR)" \
	    --keyring-append "$(SIGNING_KEY).pub" \
	    $(JAVA21_REF) fips-java21.tar

## Load images into the local Docker daemon
load-base: fips-base.tar
	docker load < $<

load-java21: fips-java21.tar
	docker load < $<

## ── Maintenance ──────────────────────────────────────────────────────────────

## Remove image build artefacts
clean:
	rm -f *.tar *.sbom.json

## Remove locally built APK packages and signing keys
clean-packages: clean
	rm -rf $(PACKAGES_DIR) $(SIGNING_KEY) $(SIGNING_KEY).pub

## Show this help
help:
	@grep -E '^##' Makefile | sed 's/^## //'
