#!/bin/sh
# assert-compliance-passed.sh — turn the recorded test outcome into a job result.
#
# run-fips-tests.sh always exits 0 and records the real outcome in
# exit-code.txt, so the report artifact uploads even on failure. This runs
# after that upload and fails the job if the suite did not pass.
#
# Inputs (environment):
#   REPORT_DIR   directory holding exit-code.txt (default /tmp/fips-report)

set -eu

REPORT_DIR="${REPORT_DIR:-/tmp/fips-report}"
EXIT_CODE_FILE="${REPORT_DIR}/exit-code.txt"

if [ ! -f "$EXIT_CODE_FILE" ]; then
    echo "::error::${EXIT_CODE_FILE} was not written. The compliance suite did" \
         "not reach the end of its run — check the job log above for a" \
         "compilation or installation failure." >&2
    exit 1
fi

code="$(cat "$EXIT_CODE_FILE")"

case "$code" in
    ''|*[!0-9]*)
        echo "::error::${EXIT_CODE_FILE} contains '${code}', which is not an exit code." >&2
        exit 1
        ;;
esac

if [ "$code" -ne 0 ]; then
    echo "::error::FIPS compliance tests failed (exit code ${code}). Download" \
         "the fips-compliance-report artifact for the per-test breakdown." >&2
    exit "$code"
fi

echo "FIPS compliance tests passed."
