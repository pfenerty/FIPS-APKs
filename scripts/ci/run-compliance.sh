#!/bin/sh
# run-compliance.sh — run the FIPS compliance suite against the built APKs.
#
# Starts the same wolfi-base image the packages target, mounts the built APK
# repository and the checked-out source, and runs container-compliance.sh
# inside it. Report files land in REPORT_DIR on the runner.
#
# Inputs (environment, all optional except where noted):
#   WORKSPACE     checked-out repository root (default: current directory)
#   APK_DIR       built APK repository (default /tmp/apk-packages)
#   REPORT_DIR    report output directory on the runner (default /tmp/fips-report)
#   WOLFI_IMAGE   base image (default cgr.dev/chainguard/wolfi-base)
#   GITHUB_RUN_ID, GITHUB_SHA, GITHUB_REF_NAME, GITHUB_REPOSITORY
#                 passed through for report metadata
#
# This script does not fail the build on test failure: run-fips-tests.sh
# records the outcome in exit-code.txt so the report can be uploaded first.
# assert-compliance-passed.sh is what turns a failure into a red job.

set -eu

WORKSPACE="${WORKSPACE:-$PWD}"
APK_DIR="${APK_DIR:-/tmp/apk-packages}"
REPORT_DIR="${REPORT_DIR:-/tmp/fips-report}"
WOLFI_IMAGE="${WOLFI_IMAGE:-cgr.dev/chainguard/wolfi-base}"

mkdir -p "$REPORT_DIR"

docker run --rm \
    -v "${APK_DIR}":/apk-packages:ro \
    -v "${WORKSPACE}":/repo:ro \
    -v "${REPORT_DIR}":/tmp/fips-report \
    -e GITHUB_RUN_ID="${GITHUB_RUN_ID:-}" \
    -e GITHUB_SHA="${GITHUB_SHA:-}" \
    -e GITHUB_REF_NAME="${GITHUB_REF_NAME:-}" \
    -e GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}" \
    -e REPORT_DIR=/tmp/fips-report \
    "$WOLFI_IMAGE" \
    sh /repo/scripts/ci/container-compliance.sh
