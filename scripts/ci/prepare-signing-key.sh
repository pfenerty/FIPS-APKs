#!/bin/sh
# prepare-signing-key.sh — put a melange signing key at KEY_PATH.
#
# Pull requests get an ephemeral key: their packages are built and tested but
# never published, so the key only has to exist. Pushes and tags use the stable
# key from the MELANGE_SIGNING_KEY repository secret, so every published APK
# carries the same key consumers have already trusted.
#
# Inputs (environment):
#   EVENT_NAME           GitHub event name; "pull_request" selects the
#                        ephemeral path. Required.
#   MELANGE_SIGNING_KEY  base64-encoded RSA private key. Required unless
#                        EVENT_NAME is "pull_request".
#   KEY_PATH             where to write the key (default /tmp/melange.rsa).
#
# Writes KEY_PATH and KEY_PATH.pub. The secret is never echoed.

set -eu

KEY_PATH="${KEY_PATH:-/tmp/melange.rsa}"

if [ -z "${EVENT_NAME:-}" ]; then
    echo "::error::EVENT_NAME is not set" >&2
    exit 1
fi

if [ "$EVENT_NAME" = "pull_request" ]; then
    echo "Pull request build: generating an ephemeral signing key."
    melange keygen "$KEY_PATH"
    exit 0
fi

if [ -z "${MELANGE_SIGNING_KEY:-}" ]; then
    echo "::error::MELANGE_SIGNING_KEY secret is not set. Generate a key with" \
         "'melange keygen melange.rsa', then store 'base64 -w0 melange.rsa' as" \
         "the MELANGE_SIGNING_KEY repository secret." >&2
    exit 1
fi

echo "Restoring the stable signing key from MELANGE_SIGNING_KEY."
printf '%s' "$MELANGE_SIGNING_KEY" | base64 -d > "$KEY_PATH"
chmod 600 "$KEY_PATH"

# Derive the public key rather than storing it separately, so the two halves
# can never disagree.
if ! openssl pkey -in "$KEY_PATH" -pubout -out "${KEY_PATH}.pub" 2>/dev/null; then
    echo "::error::MELANGE_SIGNING_KEY did not decode to a usable private key." \
         "Check that it was encoded with 'base64 -w0' (no line wrapping)." >&2
    rm -f "$KEY_PATH"
    exit 1
fi

echo "Signing key ready at ${KEY_PATH}."
