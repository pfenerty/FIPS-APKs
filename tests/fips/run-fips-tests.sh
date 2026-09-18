#!/bin/sh
# run-fips-tests.sh — compile, run, and report on FipsComplianceTest
#
# Runs inside a Wolfi container where bouncycastle-fips, bcutil-fips and
# bctls-fips are already installed via apk.
#
# Environment variables (set by GitHub Actions step):
#   REPORT_DIR        - output directory for report files (default: /tmp/fips-report)
#   GITHUB_RUN_ID     - CI run ID (optional, for report metadata)
#   GITHUB_SHA        - Git commit SHA (optional)
#   GITHUB_REF_NAME   - Git ref name (optional)
#   GITHUB_REPOSITORY - repository name (optional)
#
# Outputs (in $REPORT_DIR):
#   compliance-report.md    - Markdown compliance report
#   compliance-report.html  - HTML compliance report (published to GitHub Pages)
#   exit-code.txt           - test exit code (0=pass, 1=fail); CI reads this
#
# This script always exits 0 so that the "Upload compliance report" CI step
# runs even when tests fail. The CI "Fail job if tests failed" step reads
# exit-code.txt and exits accordingly.

set -e

REPORT_DIR="${REPORT_DIR:-/tmp/fips-report}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_SRC="${SCRIPT_DIR}/FipsComplianceTest.java"
CLASSES_DIR=/tmp/fips-classes
OUTPUT_FILE=/tmp/fips-output.txt

JARS="/usr/share/java/bc-fips.jar:/usr/share/java/bcutil-fips.jar:/usr/share/java/bctls-fips.jar"

mkdir -p "$REPORT_DIR" "$CLASSES_DIR"

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ARCH="$(uname -m)"
JAVA_VERSION="$(java -version 2>&1 | grep -i 'version' | head -1)"

# ── Collect package metadata ───────────────────────────────────────────────────

APK_BC_INFO="$(apk info -a bouncycastle-fips 2>/dev/null || echo 'not installed')"
APK_BCUTIL_INFO="$(apk info -a bcutil-fips 2>/dev/null || echo 'not installed')"
APK_BCTLS_INFO="$(apk info -a bctls-fips 2>/dev/null || echo 'not installed')"

# ── Compile ────────────────────────────────────────────────────────────────────

echo "=== Compiling FipsComplianceTest.java ==="
javac --release 11 -cp "$JARS" "$TEST_SRC" -d "$CLASSES_DIR"
echo "Compilation successful."
echo ""

# ── Run tests ─────────────────────────────────────────────────────────────────

echo "=== Running FIPS compliance tests ==="
set +e
java -cp "${CLASSES_DIR}:${JARS}" FipsComplianceTest >"$OUTPUT_FILE" 2>&1
TEST_EXIT=$?
set -e

cat "$OUTPUT_FILE"
echo ""
echo "Test exit code: $TEST_EXIT"

# -- Approved-mode evidence -------------------------------------------------
# The suite above runs in BC-FIPS default mode and attests to packaging
# integrity. fips-verify runs the module in approved mode under the shipped
# java.security overlay and attests to approved-mode operation. They answer
# different questions, so the report carries both.

VERIFY_FILE=/tmp/fips-verify.txt
VERIFY_EXIT=0
if command -v fips-verify >/dev/null 2>&1; then
    echo ""
    echo "=== Running fips-verify in approved mode ==="
    JAVA_TOOL_OPTIONS="-Dorg.bouncycastle.fips.approved_only=true -Djava.security.properties=/usr/share/java/fips/fips.java.security" \
        fips-verify >"$VERIFY_FILE" 2>&1 || VERIFY_EXIT=$?
    # The JVM announces JAVA_TOOL_OPTIONS on stderr; keep it out of the report.
    sed -i '/^Picked up JAVA_TOOL_OPTIONS/d' "$VERIFY_FILE" 2>/dev/null || true
    cat "$VERIFY_FILE"
    echo "fips-verify exit code: $VERIFY_EXIT"
else
    echo "fips-verify not installed; approved-mode evidence not collected." >"$VERIFY_FILE"
    VERIFY_EXIT=127
fi

if [ "$VERIFY_EXIT" -eq 0 ]; then
    VERIFY_SUMMARY="PASS -- module confirmed operating in FIPS-approved mode"
else
    VERIFY_SUMMARY="FAIL -- approved-mode verification did not pass (exit ${VERIFY_EXIT})"
fi

# ── Parse TEST_RESULT lines ────────────────────────────────────────────────────

# Extract each "TEST_RESULT: PASS/FAIL  name  detail" line
PASS_COUNT=0
FAIL_COUNT=0
RESULT_ROWS=""

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*)
            # Remove "TEST_RESULT: " prefix
            rest="${line#TEST_RESULT: }"
            status="${rest%% *}"
            rest2="${rest#* }"   # strip status
            rest2="${rest2#  }"  # strip extra spaces
            name="${rest2%%  *}"
            detail="${rest2#*  }"
            detail="${detail#  }"  # strip leading spaces if any

            if [ "$status" = "PASS" ]; then
                PASS_COUNT=$((PASS_COUNT + 1))
                STATUS_MD="**PASS**"
                STATUS_BADGE="pass"
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                STATUS_MD="**FAIL**"
                STATUS_BADGE="fail"
            fi

            # Escape pipe characters in detail for Markdown tables
            detail_md="$(printf '%s' "$detail" | sed 's/|/\\|/g')"

            RESULT_ROWS="${RESULT_ROWS}| ${name} | ${STATUS_MD} | ${detail_md} |
"
            RESULT_ROWS_HTML="${RESULT_ROWS_HTML}<tr><td><code>${name}</code></td><td class=\"${STATUS_BADGE}\">${status}</td><td>${detail}</td></tr>
"
        ;;
    esac
done < "$OUTPUT_FILE"

TOTAL_COUNT=$((PASS_COUNT + FAIL_COUNT))

if [ "$TEST_EXIT" -eq 0 ]; then
    OVERALL="PASS"
    OVERALL_DETAIL="All ${TOTAL_COUNT} tests passed."
else
    OVERALL="FAIL"
    OVERALL_DETAIL="${FAIL_COUNT} of ${TOTAL_COUNT} tests failed."
fi

# ── Build CI run URL ──────────────────────────────────────────────────────────

if [ -n "$GITHUB_REPOSITORY" ] && [ -n "$GITHUB_RUN_ID" ]; then
    RUN_URL="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    RUN_LINK="[${GITHUB_RUN_ID}](${RUN_URL})"
    RUN_LINK_HTML="<a href=\"${RUN_URL}\">${GITHUB_RUN_ID}</a>"
else
    RUN_LINK="${GITHUB_RUN_ID:-local}"
    RUN_LINK_HTML="${GITHUB_RUN_ID:-local}"
fi

SHA_SHORT="$(printf '%s' "${GITHUB_SHA:-unknown}" | cut -c1-12)"

# ── Generate Markdown report ──────────────────────────────────────────────────

cat >"${REPORT_DIR}/compliance-report.md" <<MARKDOWN
# FIPS Compliance Report

**Result: ${OVERALL}** — ${OVERALL_DETAIL}

| Field | Value |
|---|---|
| Generated | ${TIMESTAMP} |
| Architecture | ${ARCH} |
| Java runtime | ${JAVA_VERSION} |
| Git SHA | ${SHA_SHORT} |
| Git ref | ${GITHUB_REF_NAME:-n/a} |
| CI run | ${RUN_LINK} |

---

## CMVP Certificate References

\`bouncycastle-fips\` distributes BC-FJA 2.1.1, the software version listed on
NIST CMVP certificate #4943. \`bcutil-fips\` and \`bctls-fips\` are supporting
libraries outside the validated cryptographic boundary. All JARs are fetched
verbatim from Maven Central and never recompiled, preserving the certification
boundary.

| Module | Version | CMVP Certificate | NIST URL |
|---|---|---|---|
| BC-FJA (bouncycastle-fips) | 2.1.1 | #4943 | https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943 |
| bcutil-fips | 2.1.5 | not a validated module | — |
| BCTLS-FJA (bctls-fips) | 2.1.22 | not a validated module | — |

---

## Artifact Integrity

SHA-256 digests of the installed JARs are compared against the values
recorded at build time (from the upstream \`.sha256\` files on Maven Central)
to confirm the packaged artifacts are identical to the upstream binaries —
for \`bc-fips\`, to the CMVP-validated module.

| Artifact | Expected SHA-256 | Status |
|---|---|---|
| bc-fips-2.1.1.jar | \`a430d935ad6cec6d045930758457740f5a5f8f9715894e347f6800f7926a7321\` | see test results below |
| bcutil-fips-2.1.5.jar | \`503aaf5c2c5b7c729547462efe13699b5f6dacf9be150b7c48bba974b793dc92\` | see test results below |
| bctls-fips-2.1.22.jar | \`688410563445e1a65ff33cb67842499f0788994d752c3df8f7ea4a0d40ddbf50\` | see test results below |

---

## Test Results

${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total).

| Test | Status | Detail |
|---|---|---|
${RESULT_ROWS}

---

## Approved-Mode Verification

The test results above are produced in BC-FIPS **default mode** and attest to
packaging integrity. This section is produced by \`fips-verify\` running the
module in **approved-only mode** under the shipped \`java.security\` overlay,
and attests to approved-mode operation.

**${VERIFY_SUMMARY}**

\`\`\`
$(cat "$VERIFY_FILE")
\`\`\`

Reproduce this inside any image built from these packages:

\`\`\`
fips-verify
\`\`\`

---

## Package Metadata

### bouncycastle-fips

\`\`\`
${APK_BC_INFO}
\`\`\`

### bctls-fips

\`\`\`
${APK_BCTLS_INFO}
\`\`\`
MARKDOWN

# ── Generate HTML report ──────────────────────────────────────────────────────

if [ "$OVERALL" = "PASS" ]; then
    BANNER_CLASS="banner-pass"
    BANNER_ICON="&#10003;"
else
    BANNER_CLASS="banner-fail"
    BANNER_ICON="&#10007;"
fi

cat >"${REPORT_DIR}/compliance-report.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>FIPS Compliance Report</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
           max-width: 960px; margin: 2rem auto; padding: 0 1rem; color: #1a1a1a; }
    h1, h2 { border-bottom: 1px solid #e0e0e0; padding-bottom: .3rem; }
    table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
    th, td { border: 1px solid #d0d0d0; padding: .5rem .75rem; text-align: left; }
    th { background: #f5f5f5; font-weight: 600; }
    tr:nth-child(even) { background: #fafafa; }
    .banner { display: inline-block; padding: .5rem 1.25rem; border-radius: 4px;
              font-size: 1.25rem; font-weight: 700; margin: .5rem 0 1.5rem; }
    .banner-pass { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
    .banner-fail { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
    .pass { color: #155724; font-weight: 700; }
    .fail { color: #721c24; font-weight: 700; }
    code { font-family: "SFMono-Regular", Consolas, monospace; font-size: .875em;
           background: #f0f0f0; padding: .1rem .3rem; border-radius: 3px; }
    pre  { background: #f6f8fa; border: 1px solid #e0e0e0; border-radius: 4px;
           padding: 1rem; overflow-x: auto; font-size: .875em; }
    .meta-table td:first-child { font-weight: 600; width: 140px; }
  </style>
</head>
<body>
  <h1>FIPS Compliance Report</h1>

  <div class="banner ${BANNER_CLASS}">${BANNER_ICON} ${OVERALL} &mdash; ${OVERALL_DETAIL}</div>

  <table class="meta-table">
    <tr><td>Generated</td><td>${TIMESTAMP}</td></tr>
    <tr><td>Architecture</td><td>${ARCH}</td></tr>
    <tr><td>Java runtime</td><td>${JAVA_VERSION}</td></tr>
    <tr><td>Git SHA</td><td><code>${SHA_SHORT}</code></td></tr>
    <tr><td>Git ref</td><td>${GITHUB_REF_NAME:-n/a}</td></tr>
    <tr><td>CI run</td><td>${RUN_LINK_HTML}</td></tr>
  </table>

  <h2>CMVP Certificate References</h2>
  <p><code>bouncycastle-fips</code> distributes BC-FJA 2.1.1, the software
  version listed on NIST CMVP certificate #4943. <code>bcutil-fips</code> and
  <code>bctls-fips</code> are supporting libraries outside the validated
  cryptographic boundary and carry no certificate of their own. All JARs are
  fetched verbatim from Maven Central and never recompiled, preserving the
  certification boundary.</p>
  <table>
    <thead><tr><th>Module</th><th>Version</th><th>Certificate</th><th>NIST URL</th></tr></thead>
    <tbody>
      <tr>
        <td>BC-FJA (<code>bouncycastle-fips</code>)</td>
        <td>2.1.1</td>
        <td>#4943</td>
        <td><a href="https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943"
               target="_blank">CMVP #4943</a></td>
      </tr>
      <tr>
        <td><code>bcutil-fips</code></td>
        <td>2.1.5</td>
        <td>not a validated module</td>
        <td>&mdash;</td>
      </tr>
      <tr>
        <td>BCTLS-FJA (<code>bctls-fips</code>)</td>
        <td>2.1.22</td>
        <td>not a validated module</td>
        <td>&mdash;</td>
      </tr>
    </tbody>
  </table>

  <h2>Artifact Integrity</h2>
  <p>SHA-256 digests of installed JARs compared against values recorded
  at build time (from Maven Central upstream) to confirm the packaged
  artifacts are identical to the upstream binaries &mdash; for
  <code>bc-fips</code>, to the CMVP-validated module.</p>
  <table>
    <thead><tr><th>Artifact</th><th>Expected SHA-256</th></tr></thead>
    <tbody>
      <tr>
        <td><code>bc-fips-2.1.1.jar</code></td>
        <td><code>a430d935ad6cec6d045930758457740f5a5f8f9715894e347f6800f7926a7321</code></td>
      </tr>
      <tr>
        <td><code>bcutil-fips-2.1.5.jar</code></td>
        <td><code>503aaf5c2c5b7c729547462efe13699b5f6dacf9be150b7c48bba974b793dc92</code></td>
      </tr>
      <tr>
        <td><code>bctls-fips-2.1.22.jar</code></td>
        <td><code>688410563445e1a65ff33cb67842499f0788994d752c3df8f7ea4a0d40ddbf50</code></td>
      </tr>
    </tbody>
  </table>
  <p><em>See <code>testJarIntegrity</code> in the test results below for actual vs. expected comparison.</em></p>

  <h2>Test Results</h2>
  <p>${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total).</p>
  <table>
    <thead><tr><th>Test</th><th>Status</th><th>Detail</th></tr></thead>
    <tbody>
      ${RESULT_ROWS_HTML}
    </tbody>
  </table>

  <h2>Approved-Mode Verification</h2>
  <p>The test results above are produced in BC-FIPS <em>default mode</em> and
  attest to packaging integrity. This section is produced by
  <code>fips-verify</code> running the module in <em>approved-only mode</em>
  under the shipped <code>java.security</code> overlay, and attests to
  approved-mode operation.</p>
  <p><strong>${VERIFY_SUMMARY}</strong></p>
  <pre>$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$VERIFY_FILE")</pre>
  <p>Reproduce this inside any image built from these packages by running
  <code>fips-verify</code>.</p>

  <h2>Package Metadata</h2>

  <h3><code>bouncycastle-fips</code></h3>
  <pre>${APK_BC_INFO}</pre>

  <h3><code>bcutil-fips</code></h3>
  <pre>${APK_BCUTIL_INFO}</pre>

  <h3><code>bctls-fips</code></h3>
  <pre>${APK_BCTLS_INFO}</pre>

</body>
</html>
HTML

# ── Write exit code for CI to read ───────────────────────────────────────────

printf '%s' "$TEST_EXIT" >"${REPORT_DIR}/exit-code.txt"

echo "=== Reports written to ${REPORT_DIR} ==="
ls -lh "${REPORT_DIR}/"

# Always exit 0 — CI reads exit-code.txt and exits in a dedicated step,
# which allows the artifact upload step (if: always()) to run first.
exit 0
