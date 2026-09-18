#!/bin/sh
# check-pins.sh — fail if the package version/digest pins have drifted apart.
#
# The melange.yaml files are the single source of truth. Every other file that
# names a JAR version or repeats a SHA-256 must agree with them. A version bump
# touches six files; this script is what makes that safe.
#
# Checks performed, for each packages/*/melange.yaml:
#   1. The fetch URI, install command and symlink target all name
#      <jar>-<declared version>.jar.
#   2. Every reference to that JAR in the dependent files below names the same
#      version — no stale "bc-fips-2.1.2.jar" left behind anywhere.
#   3. The declared expected-sha256 appears in each file that publishes it.
#   4. No unrecognised SHA-256 appears in any dependent file, which is what
#      catches a digest updated in one place but not another.
#
# Usage: sh tests/fips/check-pins.sh   (exit 0 = consistent, 1 = drift)

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# Files that repeat versions and/or digests and must track melange.yaml.
DEPENDENT_FILES="tests/fips/FipsComplianceTest.java tests/fips/run-fips-tests.sh tests/fips/COMPLIANCE.md README.md"

# Files required to carry each package's digest verbatim.
DIGEST_FILES="tests/fips/FipsComplianceTest.java tests/fips/run-fips-tests.sh tests/fips/COMPLIANCE.md"

# SHA-256 values that are legitimately not package digests.
# deacb179... is SHA-256("BouncyCastle FIPS"), the known-answer test vector.
ALLOWED_EXTRA_DIGESTS="deacb1797c79417204e8149f0db8d7cccbe19440b0ac4e2cb947c9b57128fe47"

FAILURES=0
KNOWN_DIGESTS="$ALLOWED_EXTRA_DIGESTS"

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

for cfg in packages/*/melange.yaml; do
    name="$(sed -n 's/^  name: *//p' "$cfg" | head -1)"
    version="$(sed -n 's/^  version: *//p' "$cfg" | head -1)"
    sha="$(sed -n 's/^ *expected-sha256: *//p' "$cfg" | head -1)"
    uri="$(sed -n 's/^ *uri: *//p' "$cfg" | head -1)"
    jarfile="$(basename "$uri")"

    if [ -z "$name" ] || [ -z "$version" ] || [ -z "$sha" ] || [ -z "$uri" ]; then
        fail "$cfg: could not parse name/version/expected-sha256/uri"
        continue
    fi

    # jarbase is the Maven artifact id, which is not always the package name
    # (bouncycastle-fips ships bc-fips-<version>.jar).
    jarbase="${jarfile%-$version.jar}"
    if [ "$jarbase" = "$jarfile" ]; then
        fail "$cfg: fetch URI '$jarfile' does not carry declared version $version"
        continue
    fi

    echo "== $name $version ($jarfile)"
    KNOWN_DIGESTS="$KNOWN_DIGESTS $sha"

    # (1) Within melange.yaml: URI, install source, install destination and
    #     symlink target must all name the same versioned JAR.
    refs="$(grep -c -- "$jarfile" "$cfg" || true)"
    if [ "$refs" -lt 4 ]; then
        fail "$cfg: expected >=4 references to $jarfile (uri, install src, install dest, symlink), found $refs"
    fi

    # Any other version of this JAR mentioned in the config is drift.
    stale="$(grep -oE "${jarbase}-[0-9][0-9.]*\.jar" "$cfg" | grep -v "^${jarfile}$" | sort -u || true)"
    if [ -n "$stale" ]; then
        fail "$cfg: stale JAR reference(s): $(echo $stale)"
    fi

    # (2) Dependent files must name the same version.
    for f in $DEPENDENT_FILES; do
        [ -f "$f" ] || { fail "missing expected file: $f"; continue; }
        found="$(grep -oE "${jarbase}-[0-9][0-9.]*\.jar" "$f" | sort -u || true)"
        if [ -z "$found" ]; then
            fail "$f: no reference to ${jarbase}-*.jar (expected $jarfile)"
            continue
        fi
        bad="$(echo "$found" | grep -v "^${jarfile}$" || true)"
        if [ -n "$bad" ]; then
            fail "$f: references $(echo $bad) but melange.yaml pins $jarfile"
        fi
    done

    # (3) Digest must be published verbatim wherever we assert it.
    for f in $DIGEST_FILES; do
        if ! grep -q -- "$sha" "$f"; then
            fail "$f: missing $name digest $sha"
        fi
    done
done

# (4) No unrecognised digests anywhere — catches a digest bumped in melange.yaml
#     but left stale in the Java test or the report template.
for f in $DEPENDENT_FILES; do
    [ -f "$f" ] || continue
    for d in $(grep -oE '\b[0-9a-f]{64}\b' "$f" | sort -u); do
        case " $KNOWN_DIGESTS " in
            *" $d "*) ;;
            *) fail "$f: unrecognised SHA-256 $d (not pinned by any melange.yaml)" ;;
        esac
    done
done

if [ "$FAILURES" -ne 0 ]; then
    echo ""
    echo "$FAILURES pin consistency check(s) failed." >&2
    echo "The melange.yaml files are authoritative; update the others to match." >&2
    exit 1
fi

echo ""
echo "All version and digest pins are consistent."
