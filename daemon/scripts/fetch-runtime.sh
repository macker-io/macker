#!/bin/sh
# Install the pinned guest kernel and vminit into the daemon store.
# Pass a directory to also stage a copy for packaging (daemon/.runtime).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$DAEMON_ROOT"

swift build --product macker
BIN="$(swift_bin_dir debug)/macker"
if [ -n "${1:-}" ]; then
  "$BIN" fetch-runtime --output "$1"
else
  "$BIN" fetch-runtime
fi
