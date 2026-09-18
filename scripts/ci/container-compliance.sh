#!/bin/sh
# container-compliance.sh — runs INSIDE the Wolfi test container.
#
# Installs a JDK and the freshly-built APKs from the local repository mounted
# at /apk-packages, then hands off to the compliance suite. Kept as a file
# rather than inline YAML so it can be read, linted and changed like any other
# shell script.
#
# Expects:
#   /apk-packages   the built APK repository, including melange.rsa.pub
#   /repo           the checked-out repository (read-only)
#   REPORT_DIR      where run-fips-tests.sh writes the report

set -eu

echo "=== Installing JDK and APK tooling ==="
apk add --no-cache openjdk-21-default-jdk apk-tools

# Trust the key the packages were signed with, then register the local
# repository. Packages are verified against this key; nothing is installed
# with --allow-untrusted.
echo "=== Registering the local APK repository ==="
cp /apk-packages/melange.rsa.pub /etc/apk/keys/
echo "/apk-packages" >> /etc/apk/repositories
apk update

echo "=== Installing the packages under test ==="
apk add --no-cache bouncycastle-fips bcutil-fips bctls-fips \
    bouncycastle-fips-config fips-verify

echo "=== Running the compliance suite ==="
sh /repo/tests/fips/run-fips-tests.sh
