MELANGE ?= melange

PACKAGES_DIR := $(CURDIR)/packages/out
SIGNING_KEY  := $(CURDIR)/melange.rsa

.PHONY: packages packages-bc packages-bctls keys clean clean-packages help

## ── Keys ─────────────────────────────────────────────────────────────────────

## Generate a local melange signing key pair (run once)
keys: $(SIGNING_KEY)

$(SIGNING_KEY):
	$(MELANGE) keygen $(SIGNING_KEY)

## ── Local APK packages ───────────────────────────────────────────────────────

## Build bouncycastle-fips and bctls-fips APKs for x86_64 and aarch64
packages: packages-bc packages-bctls

packages-bc: $(SIGNING_KEY)
	$(MELANGE) build packages/bouncycastle-fips/melange.yaml \
	    --arch x86_64,aarch64 \
	    --signing-key $(SIGNING_KEY) \
	    --out-dir $(PACKAGES_DIR)

## bctls-fips depends on bouncycastle-fips, so packages-bc must run first and
## its output directory is passed as --dependency-dir for resolution.
packages-bctls: packages-bc
	$(MELANGE) build packages/bctls-fips/melange.yaml \
	    --arch x86_64,aarch64 \
	    --signing-key $(SIGNING_KEY) \
	    --out-dir $(PACKAGES_DIR) \
	    --dependency-dir $(PACKAGES_DIR)

## ── Maintenance ──────────────────────────────────────────────────────────────

## Remove build artefacts
clean:
	@echo "Nothing to clean (packages cleaned via clean-packages)"

## Remove locally built APK packages and signing keys
clean-packages:
	rm -rf $(PACKAGES_DIR) $(SIGNING_KEY) $(SIGNING_KEY).pub

## Show this help
help:
	@grep -E '^##' Makefile | sed 's/^## //'
