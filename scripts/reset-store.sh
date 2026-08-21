#!/bin/sh
# Wipe local engine state (images, containers, volumes, networks).
# Keeps the guest kernel, initfs, and daemon-id.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if [ -e "$SOCKET" ]; then
  echo "daemon is running ($SOCKET) — stop it first" >&2
  exit 1
fi

if [ ! -d "$STORE" ]; then
  echo "store not found: $STORE"
  exit 0
fi

echo "reset $STORE"
for name in content containers volumes networks unpacked; do
  path="$STORE/$name"
  if [ -e "$path" ]; then
    rm -rf "$path"
    echo "  removed $name/"
  fi
done
if [ -f "$STORE/state.json" ]; then
  rm -f "$STORE/state.json"
  echo "  removed state.json"
fi
echo "kept runtime/ initfs.ext4 daemon-id"
