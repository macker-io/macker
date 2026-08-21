#!/bin/sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$DAEMON_ROOT"

if [ -n "${1:-}" ]; then
  BIN="$1"
else
  BIN="$(swift_bin_dir debug)/mackerd"
fi
if [ ! -f "$BIN" ]; then
  echo "mackerd binary not found: $BIN" >&2
  echo "Build it first: swift build --product mackerd" >&2
  exit 1
fi
sign_bin "$BIN" "$ENTITLEMENTS"
echo "signed $BIN"
