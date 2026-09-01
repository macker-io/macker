#!/bin/sh
# Notarize signed Mach-O in the CLI prefix. Apple will not staple a tar.gz or
# a bare executable; Gatekeeper looks up the ticket by cdhash on first run.
#
#   NOTARIZE=1 VERSION=0.1.0 ./scripts/notarize-cli.sh
#
# Required environment (same names as mediaforge):
#   APPLE_ID
#   APPLE_TEAM_ID
#   APPLE_APP_SPECIFIC_PASSWORD
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$DAEMON_ROOT"

PREFIX_ROOT="$DAEMON_ROOT/dist/cli"
LIBEXEC="$PREFIX_ROOT/libexec/macker"
VERSION="$(product_version)"
ZIP="$DAEMON_ROOT/dist/macker-${VERSION}-darwin-arm64-notarize.zip"

if [ -z "${APPLE_ID:-}" ]; then
  echo "missing required environment variable: APPLE_ID" >&2
  exit 1
fi
if [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "missing required environment variable: APPLE_TEAM_ID" >&2
  exit 1
fi
if [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
  echo "missing required environment variable: APPLE_APP_SPECIFIC_PASSWORD" >&2
  exit 1
fi

if [ ! -x "$LIBEXEC/mackerd" ]; then
  echo "CLI prefix missing; run: ./scripts/package-cli.sh prefix" >&2
  exit 1
fi

identity="$(sign_identity)"
if [ "$identity" = "-" ]; then
  echo "notarization requires CERT_NAME or APPLE_CERT_NAME (Developer ID Application)" >&2
  exit 1
fi

codesign --verify --verbose "$LIBEXEC/mackerd"
codesign --verify --verbose "$LIBEXEC/macker"
codesign --verify --verbose "$LIBEXEC/macker-helper"

mkdir -p "$DAEMON_ROOT/dist"
rm -f "$ZIP"
# Submit only Darwin code. Guest kernel / initfs are Linux images.
ditto -c -k "$LIBEXEC" "$ZIP"

echo "notarytool submit $ZIP (identity $identity)"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait
rm -f "$ZIP"
echo "notarized libexec/macker ($VERSION)"
