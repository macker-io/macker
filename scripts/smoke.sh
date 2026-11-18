#!/bin/sh
# Isolated daemon smoke: control plane, real VM lifecycle, logging, and published ports.
# Set SMOKE_SKIP_VM=1 to stop after the control plane.
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
ALPINE=alpine:3.24
NGINX=nginx:1.30-alpine
LIFECYCLE=smoke-lifecycle
cleanup() {
  if [ -n "${MACKER:-}" ] && [ -n "${MACKER_HOST:-}" ]; then
    "$MACKER" rm -f "$NAME" "$LIFECYCLE" >/dev/null 2>&1 || true
  fi
  if [ -n "${PID:-}" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$STORE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

start_daemon() {
  "$MACKERD" --store "$STORE" &
  PID=$!
  i=0
  until "$MACKER" version >/dev/null 2>&1; do
    i=$((i + 1))
    if ! kill -0 "$PID" 2>/dev/null || [ "$i" -ge 50 ]; then
      echo "mackerd did not start listening on $SOCK" >&2
      exit 1
    fi
    sleep 0.1
  done
}

stop_daemon() {
  kill -TERM "$PID"
  wait "$PID"
  PID=
}

export MACKER_HOST="unix://${SOCK}"
start_daemon
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

echo "pulling $ALPINE and ${NGINX}…"
"$MACKER" pull "$ALPINE"
"$MACKER" pull "$NGINX"

echo "run --rm $ALPINE echo smoke-ok…"
run_out="$("$MACKER" run --rm "$ALPINE" echo smoke-ok)"
printf '%s\n' "$run_out" | grep -q smoke-ok

echo "checking pinned image, writable layer, and historical streams…"
"$MACKER" tag "$ALPINE" smoke-pinned:local
"$MACKER" create --name "$LIFECYCLE" --restart always --network none --tmpfs /scratch smoke-pinned:local \
  sh -c 'echo stdout-marker; echo stderr-marker >&2; exec sleep 600' >/dev/null
"$MACKER" tag "$NGINX" smoke-pinned:local
"$MACKER" start "$LIFECYCLE" >/dev/null
"$MACKER" exec "$LIFECYCLE" grep -q '^ID=alpine' /etc/os-release
"$MACKER" exec "$LIFECYCLE" sh -c 'echo persistent >/marker; echo ephemeral >/scratch/marker'
"$MACKER" restart "$LIFECYCLE" >/dev/null
"$MACKER" exec "$LIFECYCLE" sh -c 'grep -qx persistent /marker && test ! -e /scratch/marker'

stop_daemon
start_daemon
wait_running "$LIFECYCLE"
"$MACKER" exec "$LIFECYCLE" grep -qx persistent /marker
"$MACKER" logs "$LIFECYCLE" >"$STORE/stdout" 2>"$STORE/stderr"
grep -qx stdout-marker "$STORE/stdout"
grep -qx stderr-marker "$STORE/stderr"
"$MACKER" logs --tail 2 "$LIFECYCLE" >"$STORE/stdout" 2>"$STORE/stderr"
test "$(wc -l <"$STORE/stdout" | tr -d ' ')" = 1
test "$(wc -l <"$STORE/stderr" | tr -d ' ')" = 1
! grep -q stderr-marker "$STORE/stdout" || exit 1
! grep -q stdout-marker "$STORE/stderr" || exit 1
"$MACKER" rm -f "$LIFECYCLE" >/dev/null

echo "checking bridge publishing and nginx HUP reload…"
"$MACKER" network create --ipv6 smoke-v6 >/dev/null
"$MACKER" run -d --name "$NAME" --network smoke-v6 -p '127.0.0.1::80' -p '[::1]::80' "$NGINX" >/dev/null
wait_running "$NAME"
bindings="$("$MACKER" port "$NAME" 80)"
HOST_PORT="$(printf '%s\n' "$bindings" | awk -F: '/^127[.]0[.]0[.]1:/ { print $NF }')"
HOST_PORT_V6="$(printf '%s\n' "$bindings" | awk -F: 'index($0, "[::1]:") == 1 { print $NF }')"
if [ -z "$HOST_PORT" ] || [ -z "$HOST_PORT_V6" ]; then
  printf 'expected both IPv4 and IPv6 bindings; got:\n%s\n' "$bindings" >&2
  exit 1
fi

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

curl --noproxy '*' -gfsS --max-time 3 "http://[::1]:${HOST_PORT_V6}/" | grep -qi nginx
"$MACKER" kill --signal HUP "$NAME" >/dev/null
# Wait until nginx acknowledges the signal, not just until the API accepts it.
i=0
until "$MACKER" logs "$NAME" 2>&1 | grep -q 'reconfiguring'; do
  i=$((i + 1))
  test "$i" -lt 30
  sleep 1
done
test "$("$MACKER" inspect -f '{{.State.Status}}' "$NAME")" = running
curl -fsS --max-time 3 "http://127.0.0.1:${HOST_PORT}/" | grep -qi nginx
"$MACKER" kill "$NAME" >/dev/null
test "$("$MACKER" wait "$NAME")" = 137
"$MACKER" rm "$NAME" >/dev/null

echo "smoke ok store=$STORE"
