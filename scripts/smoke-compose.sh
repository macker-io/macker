#!/bin/sh
# Test the relocatable CLI prefix, with neither a Docker installation on PATH
# nor any user Docker config/context. Requires an Apple Silicon MicroVM host.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
prefix="${1:-$root/dist/cli}"
tmp="$(mktemp -d /tmp/macker-compose.XXXXXX)"
cleanup() {
  if [ -n "${pid:-}" ]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir "$tmp/home"
"$prefix/bin/mackerd" --store "$tmp/store" >"$tmp/daemon.log" 2>&1 &
pid=$!
# Select the private store through Macker's persisted context, not DOCKER_HOST.
client() {
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin "$prefix/bin/macker" --config "$tmp/client" "$@"
}
client context create isolated --docker "host=unix://$tmp/store/macker.sock"
client context use isolated
compose() {
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin DOCKER_CONTEXT=unrelated \
    "$prefix/bin/macker" --config "$tmp/client" compose \
    -p smoke -f "$root/scripts/compat/fixtures/build/compose.yaml" "$@"
}
i=0
until [ -S "$tmp/store/macker.sock" ]; do
  if ! kill -0 "$pid" 2>/dev/null || [ "$i" -ge 100 ]; then tail -20 "$tmp/daemon.log" >&2; exit 1; fi
  i=$((i+1)); sleep 0.1
done
compose up -d --build
compose logs --no-color app | grep -F built-by-compose
[ "$(compose exec -T app printf '%s' -h)" = '-h' ]
compose down
[ -z "$(compose ps -aq)" ]
echo 'Packaged Compose smoke passed.'
