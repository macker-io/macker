#!/bin/sh
# Isolated daemon smoke: UNIX socket, CLI control plane, then alpine pull + MicroVM
# `run --rm`, `exec`, and `-p`. Set SMOKE_SKIP_VM=1 to stop after the control plane.
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
NAME="smokewww"
HOST_PORT=18080
cleanup() {
  if [ -n "${MACKER:-}" ] && [ -n "${MACKER_HOST:-}" ]; then
    "$MACKER" rm -f "$NAME" >/dev/null 2>&1 || true
  fi
  if [ -n "${PID:-}" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$STORE"
}
trap cleanup EXIT INT TERM

wait_running() {
  container="$1"
  i=0
  while :; do
    st="$("$MACKER" inspect -f '{{.State.Status}}' --type container "$container" 2>/dev/null || true)"
    st=$(printf '%s' "$st" | tr -d '\r\n')
    if [ "$st" = "running" ]; then
      return 0
    fi
    i=$((i + 1))
    if [ "$i" -ge 150 ]; then
      echo "container $container did not reach running (last status: ${st:-empty})" >&2
      "$MACKER" inspect --type container "$container" >&2 || true
      return 1
    fi
    sleep 2
  done
}

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

if [ "${SMOKE_SKIP_VM:-}" = "1" ]; then
  echo "smoke ok (no MicroVM) store=$STORE"
  exit 0
fi

echo "pulling alpine:latest…"
"$MACKER" pull alpine:latest

echo "run --rm alpine:latest echo smoke-ok…"
run_out="$("$MACKER" run --rm alpine:latest echo smoke-ok)"
printf '%s\n' "$run_out" | grep -q smoke-ok

echo "pulling nginx:alpine…"
"$MACKER" pull nginx:alpine

echo "run -d -p + exec + curl…"
"$MACKER" run -d --name "$NAME" -p "127.0.0.1:${HOST_PORT}:80" nginx:alpine >/dev/null
wait_running "$NAME"

exec_out="$("$MACKER" exec "$NAME" echo exec-ok)"
printf '%s\n' "$exec_out" | grep -q exec-ok

i=0
while :; do
  if body=$(curl -fsS --max-time 2 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null); then
    printf '%s\n' "$body" | grep -qi nginx && break
  fi
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "curl http://127.0.0.1:${HOST_PORT}/ did not return nginx" >&2
    "$MACKER" port "$NAME" >&2 || true
    exit 1
  fi
  sleep 1
done

"$MACKER" rm -f "$NAME" >/dev/null

echo "smoke ok store=$STORE"
