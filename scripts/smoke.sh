#!/bin/sh
# Isolated daemon smoke: UNIX socket + CLI control plane. Does not use the
# default store. Optional `MACKER_SMOKE_PULL=1` pulls alpine and `run --rm`.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$ROOT"

BIN_DIR="$(swift_bin_dir debug)"
MACKERD="${BIN_DIR}/mackerd"
MACKER="${BIN_DIR}/macker"
if [ ! -f "$MACKERD" ] || [ ! -f "$MACKER" ]; then
  echo "build the daemon and CLI first: make app macker" >&2
  exit 1
fi

STORE="$(mktemp -d "${TMPDIR:-/tmp}/macker-smoke.XXXXXX")"
SOCK="${STORE}/macker.sock"
cleanup() {
  if [ -n "${PID:-}" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$STORE"
}
trap cleanup EXIT INT TERM

"$MACKERD" --store "$STORE" &
PID=$!

i=0
while [ ! -S "$SOCK" ]; do
  i=$((i + 1))
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "mackerd exited before listening on $SOCK" >&2
    exit 1
  fi
  if [ "$i" -ge 50 ]; then
    echo "mackerd did not create $SOCK" >&2
    exit 1
  fi
  sleep 0.1
done

export MACKER_HOST="unix://${SOCK}"
"$MACKER" version >/dev/null
"$MACKER" info >/dev/null
"$MACKER" volume create smokevol >/dev/null
"$MACKER" volume ls | grep -q smokevol
"$MACKER" volume rm smokevol >/dev/null
"$MACKER" network ls | grep -q bridge
"$MACKER" images >/dev/null

if [ "${MACKER_SMOKE_PULL:-}" = "1" ]; then
  "$MACKER" pull alpine:latest
  "$MACKER" run --rm alpine:latest echo smoke-ok
fi

echo "smoke ok store=$STORE"
