APKO     ?= apko
REGISTRY ?= localhost

BASE_REF    := $(REGISTRY)/fips-base:latest
JAVA21_REF  := $(REGISTRY)/fips-java21:latest

BASE_TAR    := fips-base.tar
JAVA21_TAR  := fips-java21.tar

.PHONY: all base java21 load-base load-java21 clean

all: base java21

## Build the FIPS-hardened Wolfi base OS image
base: images/base/image.yaml
	$(APKO) build $< $(BASE_REF) $(BASE_TAR)

## Build the FIPS-hardened Java 21 JRE image
java21: images/java21/image.yaml
	$(APKO) build $< $(JAVA21_REF) $(JAVA21_TAR)

## Load built images into the local Docker daemon (requires docker)
load-base: $(BASE_TAR)
	docker load < $<

load-java21: $(JAVA21_TAR)
	docker load < $<

## Remove build artefacts
clean:
	rm -f *.tar *.sbom.json

## Show this help
help:
	@grep -E '^##' Makefile | sed 's/## //'
