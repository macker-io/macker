#!/bin/bash
# Official-client compatibility harness.
#
# Starts an isolated mackerd (own store + short /tmp socket) and drives it with the
# *official* `docker` CLI and `docker compose` plugin found on PATH. Every case prints
# PASS/FAIL and the run continues after failures; exit status is the number of failures.
#
#   scripts/compat/run.sh                 # all suites
#   scripts/compat/run.sh cli             # suites: cli cli2 compose compose2 build setup
#   ONLY=run_exit_code scripts/compat/run.sh cli   # one case (substring match)
#   COMPAT_STORE=/tmp/x CLEAN=1 ...       # fresh store (re-pulls images)
#
# Requires: built + signed debug mackerd (`make app`), runtime assets in the default
# store (`make fetch-runtime`), docker CLI + compose plugin. Never touches the user's
# docker context, /var/run/docker.sock, or the default Macker store (read-only copy).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STORE="${COMPAT_STORE:-/tmp/macker-compat}"
SOCK="$STORE/macker.sock"
MACKERD="${MACKERD:-$ROOT/.build/debug/mackerd}"
DEFAULT_STORE="$HOME/Library/Application Support/io.macker.daemon"
CASE_TIMEOUT="${CASE_TIMEOUT:-180}"
ONLY="${ONLY:-}"
FX="$HERE/fixtures"
SUITES="${*:-cli cli2 compose compose2 build setup}"
MACKER="${MACKER:-$ROOT/.build/debug/macker}"

export DOCKER_HOST="unix://$SOCK"
unset DOCKER_CONTEXT
export COMPOSE_MENU=0 COMPOSE_ANSI=never COMPOSE_PROGRESS=plain

PASS=0; FAIL=0; FAILED=""
OUT="$STORE/last.out"; ERR="$STORE/last.err"; RC=0

# ---- daemon lifecycle -------------------------------------------------------
start_daemon() {
  if [ "${CLEAN:-}" = "1" ]; then rm -rf "$STORE"; CLEAN=; fi
  mkdir -p "$STORE"
  if [ ! -f "$STORE/runtime/vmlinux" ]; then
    [ -f "$DEFAULT_STORE/runtime/vmlinux" ] || { echo "run 'make fetch-runtime' first" >&2; exit 99; }
    cp -R "$DEFAULT_STORE/runtime" "$STORE/" && cp -c "$DEFAULT_STORE/initfs.ext4" "$STORE/"
  fi
  [ -x "$MACKERD" ] || { echo "missing $MACKERD (run 'make app')" >&2; exit 99; }
  "$MACKERD" --store "$STORE" >>"$STORE/daemon.log" 2>&1 &
  DAEMON_PID=$!; echo "$DAEMON_PID" >"$STORE/daemon.pid"
  for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && return 0
    kill -0 "$DAEMON_PID" 2>/dev/null || { tail -20 "$STORE/daemon.log" >&2; exit 99; }
    sleep 0.1
  done
  echo "daemon did not listen on $SOCK" >&2; exit 99
}
stop_daemon() {
  # pid file, not a variable: cases restart the daemon from inside their subshell
  local pid; pid="$(cat "$STORE/daemon.pid" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  kill -INT "$pid" 2>/dev/null || true
  for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$STORE/daemon.pid"
}
trap 'stop_daemon' EXIT
trap 'exit 130' INT TERM

# ---- tiny test framework ----------------------------------------------------
# Case bodies run under `set -e`: the first failed assertion ends the case.
# Failure details are printed *above* the FAIL line they belong to.
# x [-t secs] cmd...   run with a hard timeout; stdout→$OUT stderr→$ERR status→$RC
x() {
  local t="$CASE_TIMEOUT"
  if [ "$1" = "-t" ]; then t="$2"; shift 2; fi
  # `d` / `c` are shell functions; timeout(1) needs a real argv
  case "$1" in
    d) shift; set -- docker "$@";;
    c) shift; set -- docker compose --project-directory "$FX/$PROJ" -f "$FX/$PROJ/compose.yaml" "$@";;
  esac
  timeout -s KILL "$t" "$@" >"$OUT" 2>"$ERR" </dev/null && RC=0 || RC=$?
}
# xi 'stdin text' cmd...   same, with stdin
xi() { local input="$1"; shift; printf '%s' "$input" | timeout -s KILL "$CASE_TIMEOUT" "$@" >"$OUT" 2>"$ERR" && RC=0 || RC=$?; }
fail() { echo "      $*"; echo "      rc=$RC"; sed 's/^/      out| /' "$OUT" | tail -15; sed 's/^/      err| /' "$ERR" | tail -15; return 1; }
rc()   { [ "$RC" = "$1" ] || fail "expected exit $1"; }
out()  { grep -qF -- "$1" "$OUT" || fail "stdout lacks: $1"; }
err()  { grep -qF -- "$1" "$ERR" || fail "stderr lacks: $1"; }
nout() { ! grep -qF -- "$1" "$OUT" || fail "stdout must not contain: $1"; }
eq()   { [ "$(tr -d '\r' <"$OUT")" = "$1" ] || fail "stdout != '$1'"; }
d()    { docker "$@"; }
reset_state() {
  local ids
  ids="$(docker ps -aq 2>/dev/null)"; [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
  docker network prune -f >/dev/null 2>&1; docker volume prune -af >/dev/null 2>&1
}
run_case() {
  local name="$1"
  [ -n "$ONLY" ] && case "$name" in *"$ONLY"*) ;; *) return 0;; esac
  # Not inside `if`: bash ignores `set -e` in condition context.
  ( trap - EXIT; set -e; "case_$name" ); local status=$?
  [ -S "$SOCK" ] || start_daemon
  if [ "$status" = 0 ]; then PASS=$((PASS+1)); echo "PASS  $name"
  else FAIL=$((FAIL+1)); FAILED="$FAILED $name"; echo "FAIL  $name"; fi
  reset_state
}

ALPINE=alpine:3.20
NGINX=nginx:alpine

# ---- suite: cli -------------------------------------------------------------
case_version_info() {
  x d version -f '{{.Server.APIVersion}} {{.Server.Os}}/{{.Server.Arch}}'; rc 0; out "linux/arm64"
  x d info -f '{{.OSType}}/{{.Architecture}}'; rc 0
  grep -qE '^linux/(arm64|aarch64)$' "$OUT" || fail "info must report the guest platform"
}
case_api_version_policy() {
  # Older clients (docker-java, Testcontainers, old CLIs) pin lower versions; newer get a correct error.
  x curl -s --unix-socket "$SOCK" http://d/v1.24/_ping; eq OK
  x curl -s --unix-socket "$SOCK" http://d/v1.40/containers/json; eq '[]'
  x curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" http://d/v9.99/containers/json; eq 400
  x curl -s --unix-socket "$SOCK" http://d/v9.99/containers/json; out "too new"
}
case_pull_images() {
  x d pull $ALPINE; rc 0
  x d image inspect -f '{{.Os}}/{{.Architecture}}' $ALPINE; rc 0; eq linux/arm64
  x d images --format '{{.Repository}}:{{.Tag}}'; out "alpine:3.20"
  # a second run must not re-pull an image that is already present under its short name
  x d run --rm $ALPINE true; rc 0
  grep -q "Unable to find image" "$ERR" && fail "short name not resolved to the local image"; true
}
case_run_stdout() { x d run --rm $ALPINE echo hello; rc 0; eq hello; x d ps -aq; eq ""; }
case_run_exit_code() {
  x d run --rm $ALPINE sh -c 'echo out; echo err >&2; exit 7'; rc 7; eq out; err err
  grep -qx out "$ERR" && fail "stdout leaked into stderr"; true
}
case_run_stdin() { xi 'abc' docker run --rm -i $ALPINE cat; rc 0; eq abc; }
case_run_config() {
  x d run --rm -e FOO=bar -w /tmp -u 1000:1000 --hostname hx $ALPINE sh -c 'echo $FOO $(pwd) $(id -u) $(hostname)'
  rc 0; eq "bar /tmp 1000 hx"
  x d run --rm --entrypoint /bin/echo $ALPINE via-entrypoint; rc 0; eq via-entrypoint
}
case_run_tty() {
  # `script` gives the CLI a real terminal: exercises -t, raw mode, resize, CRLF output
  x script -q /dev/null docker run --rm -t $ALPINE sh -c 'test -t 1 && echo is-tty'; rc 0; out is-tty
}
case_detached_lifecycle() {
  x d run -d --name web -p 18080:80 $NGINX; rc 0
  grep -qE '^[0-9a-f]{64}$' "$OUT" || fail "run -d must print the 64-char id"
  x curl -s --retry 20 --retry-delay 1 --retry-all-errors -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/; eq 200
  x d ps --format '{{.Names}} {{.State}} {{.Ports}}'; out "web running"; out "18080->80/tcp"
  x d port web; out "80/tcp -> 0.0.0.0:18080"
  x d inspect -f '{{.State.Status}} {{.State.Running}} {{.Config.Image}}' web; eq "running true $NGINX"
  x d top web; rc 0; out nginx
  x d stats --no-stream --format '{{.Name}}'; rc 0; out web
  x d stop -t 3 web; rc 0
  x d inspect -f '{{.State.Status}}' web; eq exited
  x d start web; rc 0; x d restart -t 3 web; rc 0
  x d kill web; rc 0
  x d wait web; rc 0; eq 137
  x d rm web; rc 0; x d ps -aq; eq ""
}
case_exec() {
  x d run -d --name e $ALPINE sleep 300; rc 0
  x d exec e sh -c 'echo hi; echo oops >&2; exit 3'; rc 3; eq hi; err oops
  xi 'piped' docker exec -i e cat; rc 0; eq piped
  x d exec -e K=v -w /etc -u nobody e sh -c 'echo $K $(pwd) $(whoami)'; rc 0; eq "v /etc nobody"
  x d exec -d e touch /tmp/detached; rc 0
  x script -q /dev/null docker exec -t e sh -c 'test -t 1 && echo exec-tty'; rc 0; out exec-tty
  x d rm -f e; rc 0
}
case_logs() {
  x d run -d --name l $ALPINE sh -c 'echo o1; echo e1 >&2; sleep 2; echo o2'; rc 0
  x -t 60 d logs -f l; rc 0; out o1; out o2; err e1
  nout e1
  x d logs --tail 1 l; eq o2
  x d logs -t l; rc 0; grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* o1' "$OUT" || fail "no timestamps"
}
case_attach_foreground_signal() {
  # foreground `docker run` must forward SIGTERM (sig-proxy) and return 143
  docker run --name fg --init $ALPINE sleep 300 >"$OUT" 2>"$ERR" </dev/null &
  local pid=$!
  for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Running}}' fg 2>/dev/null)" = true ] && break; sleep 0.5; done
  kill -TERM "$pid"; ( sleep 30; kill -KILL "$pid" 2>/dev/null ) & local k=$!
  wait "$pid" && RC=0 || RC=$?; kill "$k" 2>/dev/null || true
  rc 143
}
case_cp() {
  x d run -d --name c $ALPINE sleep 300; rc 0
  echo payload >"$STORE/in.txt"
  x d cp "$STORE/in.txt" c:/tmp/in.txt; rc 0
  x d exec c cat /tmp/in.txt; eq payload
  rm -f "$STORE/out.txt"; x d cp c:/etc/alpine-release "$STORE/out.txt"; rc 0
  [ -s "$STORE/out.txt" ] || fail "cp out produced no file"
}
case_volumes_and_binds() {
  x d volume create data; rc 0; eq data
  x d run --rm -v data:/d $ALPINE sh -c 'echo keep >/d/f'; rc 0
  x d run --rm --mount type=volume,src=data,dst=/d $ALPINE cat /d/f; eq keep
  x d volume inspect -f '{{.Name}} {{.Driver}}' data; eq "data local"
  mkdir -p "$STORE/bind"; echo host >"$STORE/bind/h"
  x d run --rm -v "$STORE/bind:/b" $ALPINE sh -c 'cat /b/h; echo guest >/b/g'; eq host
  [ "$(cat "$STORE/bind/g")" = guest ] || fail "bind mount not writable back to host"
  x d run --rm -v "$STORE/bind:/b:ro" $ALPINE sh -c 'echo x >/b/ro 2>/dev/null; echo rc=$?'; out "rc=1"
  x d run --rm --tmpfs /t $ALPINE sh -c 'echo t >/t/x && cat /t/x'; eq t
  x d volume rm data; rc 0
  x d volume ls -q; eq ""
}
case_networks() {
  x d network create appnet; rc 0
  x d run -d --name srv --network appnet --network-alias backend $NGINX; rc 0
  x d run --rm --network appnet $ALPINE sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do wget -qO- http://srv/ >/dev/null && wget -qO- http://backend/ >/dev/null && echo reachable && exit 0; sleep 1; done; exit 1'
  rc 0; eq reachable
  x d network inspect -f '{{range .Containers}}{{.Name}}{{end}}' appnet; out srv
  x d inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}}{{end}}' srv
  grep -qE '^appnet=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$OUT" || fail "no per-network IP in inspect"
  x d run -d --name late $ALPINE sleep 300; rc 0
  x d network connect appnet late; rc 0
  x d exec late sh -c 'wget -qO- http://srv/ >/dev/null && echo ok'; eq ok
  x d network disconnect appnet late; rc 0
  x d run --rm $ALPINE sh -c 'wget -qO- -T 20 http://example.com >/dev/null && echo outbound'; eq outbound
  x d rm -f srv late; x d network rm appnet; rc 0
  x d network ls --format '{{.Name}}'; nout appnet; out bridge
}
case_env_stop_health_roundtrip() {
  x d run -d --name h --stop-signal SIGQUIT --stop-timeout 7 --label a=b --restart unless-stopped \
    --health-cmd 'true' --health-interval 1s --health-retries 2 $ALPINE sleep 300; rc 0
  x d inspect -f '{{.Config.StopSignal}} {{.Config.StopTimeout}} {{index .Config.Labels "a"}} {{.HostConfig.RestartPolicy.Name}}' h
  eq "SIGQUIT 7 b unless-stopped"
  for _ in $(seq 1 20); do x d inspect -f '{{.State.Health.Status}}' h; grep -qx healthy "$OUT" && break; sleep 1; done
  eq healthy
  x d ps --filter label=a=b --filter health=healthy --format '{{.Names}}'; eq h
  x d ps --filter label=a=nope -q; eq ""
}
case_unsupported_options_fail_loudly() {
  # privileged / capabilities are granted inside the container's own MicroVM kernel
  x d run --rm --privileged $ALPINE grep CapEff /proc/self/status; rc 0; out 000001ffffffffff
  x d run --rm --cap-add NET_ADMIN --cap-drop CHOWN $ALPINE grep CapEff /proc/self/status; rc 0; out 00000000a80435fa
  x d run --rm --cap-add NO_SUCH_CAP $ALPINE true; [ "$RC" != 0 ] || fail "unknown capability accepted"
  # options Macker cannot honor must be rejected, not silently ignored
  x d run --rm --network none $ALPINE true; rc 0
  x d run --rm --pid host $ALPINE true; [ "$RC" != 0 ] || fail "--pid host silently accepted"
  x d run --rm --device /dev/null $ALPINE true; [ "$RC" != 0 ] || fail "--device silently accepted"
}
case_wait_and_events() {
  docker events --filter label=ev=1 --format '{{.Type}} {{.Action}} {{index .Actor.Attributes "ev"}}' >"$STORE/ev.txt" 2>&1 &
  local ep=$!; sleep 1
  x d run -d --name other $ALPINE true
  x d run -d --name w --label ev=1 $ALPINE sh -c 'sleep 1; exit 5'; rc 0
  x -t 60 d wait w; rc 0; eq 5
  sleep 1; kill "$ep" 2>/dev/null || true; wait "$ep" 2>/dev/null || true
  cp "$STORE/ev.txt" "$OUT"
  out "container create 1"; out "container start 1"; out "container die 1"
  [ "$(grep -c 'container create' "$OUT")" = 1 ] || fail "label filter leaked other containers' events"
}
case_images() {
  x d tag $ALPINE compat/alpine:t; rc 0
  x d images -q compat/alpine:t; rc 0; grep -qE '^[0-9a-f]{12}$' "$OUT" || fail "no image id"
  x d save -o "$STORE/img.tar" compat/alpine:t; rc 0
  x d rmi compat/alpine:t; rc 0
  x d load -i "$STORE/img.tar"; rc 0; out "compat/alpine:t"
  x d history -q compat/alpine:t; rc 0
  x d rmi compat/alpine:t; rc 0
  x d system df; rc 0; out Images
  x d container prune -f; rc 0; x d image prune -f; rc 0; x d system prune -f; rc 0
}
case_commit_export() {
  x d run --name ce $ALPINE sh -c 'echo c >/committed'; rc 0
  x d commit ce compat/commit:1; rc 0
  x d run --rm compat/commit:1 cat /committed; eq c
  x d export -o "$STORE/ce.tar" ce; rc 0; tar tf "$STORE/ce.tar" | grep -q '^committed$' || fail "export lacks file"
  x d rm ce; x d rmi compat/commit:1; rc 0
}
suite_cli() {
  for c in version_info api_version_policy pull_images run_stdout run_exit_code run_stdin run_config run_tty \
           detached_lifecycle exec logs attach_foreground_signal cp volumes_and_binds networks \
           env_stop_health_roundtrip unsupported_options_fail_loudly wait_and_events images commit_export; do
    run_case "$c"
  done
}

# ---- suite: compose ---------------------------------------------------------
c() { docker compose --project-directory "$FX/$PROJ" -f "$FX/$PROJ/compose.yaml" "$@"; }
case_compose_empty() { PROJ=basic; x d compose ls; rc 0; x c ps; rc 0; x c config -q; rc 0; }
case_compose_basic() {
  PROJ=basic
  x -t 300 c up -d; rc 0
  x c ps --format '{{.Service}} {{.State}}'; out "app running"
  x c logs --no-color app; rc 0; out "app started"
  x c exec -T app sh -c 'echo $GREETING'; rc 0; eq hello-compose
  x c top; rc 0
  x c stop; rc 0; x c start; rc 0; x c restart -t 2; rc 0
  x -t 300 c up -d; rc 0; err "Running"            # unchanged config: no recreate
  x c down; rc 0
  x d ps -aq; eq ""; x d network ls --format '{{.Name}}'; nout basic_default
}
case_compose_stack() {
  PROJ=stack
  x -t 400 c up -d --wait; rc 0
  x c ps --format '{{.Service}} {{.State}} {{.Health}}'; out "web running healthy"; out "client running"
  x curl -s --retry 10 --retry-delay 1 --retry-all-errors -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/; eq 200
  x c exec -T client sh -c 'wget -qO- http://web/ >/dev/null && wget -qO- http://frontend/ >/dev/null && echo dns-ok'; eq dns-ok
  x c exec -T client sh -c 'echo persisted >/data/marker'; rc 0
  x -t 300 c up -d --force-recreate client; rc 0
  x c exec -T client cat /data/marker; eq persisted
  x c exec -T client cat /cfg/bind.txt; eq from-host
  x -t 120 c run --rm -T client echo one-off; rc 0; out one-off
  x c ps -a --format '{{.Name}}'; nout run
  x d volume ls -q; out stack_data
  x c down -v; rc 0
  x d ps -aq; eq ""; x d volume ls -q; nout stack_data; x d network ls --format '{{.Name}}'; nout stack_
}
case_compose_project_isolation() {
  PROJ=basic
  x -t 300 c -p one up -d; rc 0; x -t 300 c -p two up -d; rc 0
  x c -p one down; rc 0
  x c -p two ps --format '{{.Service}} {{.State}}'; out "app running"
  x d compose ls --format json; out '"two"'; nout '"one"'
  x c -p two down; rc 0
}
case_compose_attached() {
  PROJ=attached
  x -t 300 c up --abort-on-container-exit --exit-code-from job; rc 4
  out "job-1"; out "tick"; out "job done"
  x c down; rc 0
  # log follow must end when the project stops
  x -t 300 c up -d; rc 0
  c logs -f >"$STORE/follow.txt" 2>&1 & local lp=$!
  sleep 3; x c down -t 2; rc 0
  ( sleep 20; kill -KILL "$lp" 2>/dev/null ) & local k=$!
  wait "$lp" && RC=0 || RC=$?; kill "$k" 2>/dev/null || true; cp "$STORE/follow.txt" "$OUT"
  [ "$RC" -lt 128 ] || fail "compose logs -f did not end after down"
  out tick
}
case_compose_events_scale() {
  PROJ=basic
  docker compose --project-directory "$FX/basic" -f "$FX/basic/compose.yaml" events --json >"$STORE/cev.txt" 2>&1 & local ep=$!
  sleep 1
  x -t 300 c up -d --scale app=2; rc 0
  x c ps -q; [ "$(wc -l <"$OUT" | tr -d ' ')" = 2 ] || fail "scale=2 did not yield 2 containers"
  x c down -t 2; rc 0
  sleep 1; kill "$ep" 2>/dev/null || true; wait "$ep" 2>/dev/null || true; cp "$STORE/cev.txt" "$OUT"
  out '"action":"start"'; out '"service":"app"'
}
suite_compose() {
  for c in compose_empty compose_basic compose_stack compose_project_isolation compose_attached compose_events_scale; do
    run_case "$c"
  done
}

# ---- suite: build -----------------------------------------------------------
case_build_classic() {
  export DOCKER_BUILDKIT=0
  x -t 600 d build -t compat/smoke:1 --build-arg GREETING=world "$ROOT/examples/build-smoke"; rc 0
  x d run --rm compat/smoke:1; rc 0; out world; out built
  x d image inspect -f '{{.Config.WorkingDir}} {{.Config.User}}' compat/smoke:1; eq "/app nobody"
  x -t 600 d build -q --target builder -t compat/smoke:builder "$ROOT/examples/build-smoke"; rc 0
  x d rmi compat/smoke:1 compat/smoke:builder; rc 0
  unset DOCKER_BUILDKIT
}
case_build_default_client() {
  # Stock `docker build` (BuildKit/buildx, no env overrides) must produce a runnable local image.
  x -t 900 d build -t compat/smoke:2 --build-arg GREETING=bk "$ROOT/examples/build-smoke"; rc 0
  x d run --rm compat/smoke:2; rc 0; out bk; out built
  # BuildKit-only Dockerfile features
  mkdir -p "$STORE/bk"; printf 'FROM alpine:3.20\nRUN --mount=type=cache,target=/c echo cached >/c/x && echo bk-only >/r\nCOPY <<EOF /heredoc\nhere\nEOF\n' >"$STORE/bk/Dockerfile"
  x -t 900 d build -t compat/bk:1 "$STORE/bk"; rc 0
  x d run --rm compat/bk:1 cat /r /heredoc; rc 0; out bk-only; out here
  x d rmi compat/smoke:2 compat/bk:1; rc 0
}
case_build_compose_default() {
  PROJ=build
  x -t 900 c up -d --build; rc 0
  x c logs --no-color app; out "built-by-compose"
  x c down --rmi local; rc 0
}
case_build_compose() {
  PROJ=build
  x -t 600 env DOCKER_BUILDKIT=0 COMPOSE_BAKE=false docker compose --project-directory "$FX/build" -f "$FX/build/compose.yaml" up -d --build; rc 0
  x c logs --no-color app; out "built-by-compose"
  x c down --rmi local; rc 0
}
suite_build() { for c in build_classic build_default_client build_compose build_compose_default; do run_case "$c"; done; }

# ---- suite: cli2 (breadth) --------------------------------------------------
case_error_codes() {
  x d run --rm $ALPINE /no/such/binary; rc 127
  x d run --rm compat/does-not-exist:nope true; rc 125
  x d run --rm --pull never compat/not-local:1 true; rc 125
  x d run -d --name stopped $ALPINE true; x -t 30 d wait stopped
  x d exec stopped true; [ "$RC" != 0 ] || fail "exec on a stopped container must fail"; err "is not running"
  x d run -d --name dup $ALPINE sleep 60; rc 0
  x d run -d --name dup $ALPINE sleep 60; rc 125; err "is already in use"
  x d rm dup; [ "$RC" != 0 ] || fail "rm of a running container must fail without -f"
  x d inspect nope-nope; rc 1
}
case_container_misc() {
  printf 'FROM_FILE=yes\n' >"$STORE/env.list"
  x d run -d --name m --env-file "$STORE/env.list" --add-host extra.test:10.9.8.7 $ALPINE sleep 300; rc 0
  x d exec m sh -c 'echo $FROM_FILE; grep -c extra.test /etc/hosts'; rc 0; out yes; out 1
  x d rename m m2; rc 0
  x d pause m2; rc 0; x d inspect -f '{{.State.Status}}' m2; eq paused
  x d unpause m2; rc 0
  x d exec m2 touch /newfile; x d diff m2; rc 0; out "A /newfile"
  x d update --memory 512m --memory-swap 512m m2; rc 0
  x d inspect -f '{{.HostConfig.Memory}}' m2; eq 536870912
  docker stats --format '{{.Name}}' m2 >"$STORE/stats.txt" 2>&1 & local sp=$!
  sleep 4; kill "$sp" 2>/dev/null || true; wait "$sp" 2>/dev/null || true
  grep -q m2 "$STORE/stats.txt" || fail "streaming stats produced nothing"
  x d kill -s USR1 m2; rc 0
}
case_resources_applied() {
  x d run --rm --memory 256m --cpus 2 $ALPINE sh -c 'awk "/MemTotal/{print (\$2<300000)?\"mem-ok\":\"mem-big\"}" /proc/meminfo; nproc'
  rc 0; out mem-ok; out 2
  x d run --rm --read-only $ALPINE sh -c 'touch /x 2>/dev/null; echo rc=$?'; out "rc=1"
  x d run --rm --init $ALPINE sh -c 'ps -o pid,comm | awk "\$1==1{print \$2}"'; rc 0; nout sh
}
case_ports_extended() {
  x d run -d --name p1 -P $NGINX; rc 0
  x d port p1 80/tcp; rc 0
  local hp; hp="$(sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' "$OUT" | head -1)"
  [ -n "$hp" ] || fail "-P assigned no host port"
  x curl -s --retry 20 --retry-delay 1 --retry-all-errors -o /dev/null -w '%{http_code}' "http://127.0.0.1:$hp/"; eq 200
  x d run -d --name u1 -p 127.0.0.1:18053:5353/udp $ALPINE sh -c 'nc -u -l -p 5353 >/got; sleep 300'; rc 0
  sleep 2; printf 'udp-ping\n' | nc -u -w1 127.0.0.1 18053 || true
  sleep 1; x d exec u1 cat /got; out udp-ping
  x d run -d --name clash -p 18053:5353/udp $ALPINE sleep 60
  [ "$RC" != 0 ] || fail "publishing an already-bound host port must fail"
}
case_network_modes() {
  x d network create --subnet 10.77.0.0/24 --gateway 10.77.0.1 fixed; rc 0
  x d run -d --name ip1 --network fixed --ip 10.77.0.50 $ALPINE sleep 300; rc 0
  x d inspect -f '{{(index .NetworkSettings.Networks "fixed").IPAddress}}' ip1; eq 10.77.0.50
  x d run --rm --network fixed $ALPINE ping -c1 -W3 10.77.0.50; rc 0
  x d network create --internal sealed; rc 0
  x d run --rm --network sealed $ALPINE sh -c 'wget -qO- -T 4 http://example.com >/dev/null 2>&1; echo rc=$?'; nout "rc=0"
  x d run --rm --network none $ALPINE sh -c 'ip -o link | grep -vc " lo:"'; eq 0
  x d run -d --name nsowner $NGINX; rc 0
  # shared network namespace: implement, or reject loudly — never silently give a separate stack
  x d run --rm --network container:nsowner $ALPINE sh -c 'wget -qO- -T 5 http://127.0.0.1/ >/dev/null && echo shared'
  if [ "$RC" = 0 ]; then eq shared; else grep -qi "not supported" "$ERR" || fail "container: mode neither works nor is clearly rejected"; fi
  x d network rm fixed; [ "$RC" != 0 ] || fail "removing a network with active endpoints must fail"
}
case_restart_policies() {
  x d run -d --name rf --restart on-failure:3 $ALPINE sh -c 'echo run >>/dev/stdout; exit 1'; rc 0
  for _ in $(seq 1 40); do x d inspect -f '{{.RestartCount}} {{.State.Status}}' rf; grep -qx "3 exited" "$OUT" && break; sleep 1; done
  eq "3 exited"
  x d run -d --name ra --restart always $ALPINE sleep 3600; rc 0
  x d run -d --name rn $ALPINE sleep 3600; rc 0
  stop_daemon; start_daemon
  for _ in $(seq 1 40); do x d inspect -f '{{.State.Status}}' ra; grep -qx running "$OUT" && break; sleep 1; done
  eq running
  x d inspect -f '{{.State.Status}}' rn; eq exited
  x d start rn; rc 0
}
case_image_misc() {
  x d image inspect -f '{{len .RepoDigests}} {{len .RootFS.Layers}} {{.Id}}' $ALPINE; rc 0
  grep -qE '^1 [1-9][0-9]* sha256:[0-9a-f]{64}$' "$OUT" || fail "image inspect lacks RepoDigests/RootFS/Id"
  x d pull -q alpine@$(docker image inspect -f '{{index .RepoDigests 0}}' $ALPINE | sed 's/.*@//'); rc 0
  x d images --filter reference='alpine*' --format '{{.Repository}}'; out alpine
  x d images --digests --no-trunc; rc 0
  x d pull --platform linux/amd64 $ALPINE
  [ "$RC" != 0 ] || { x d run --rm --platform linux/amd64 $ALPINE uname -m; rc 0; eq x86_64; }
  x d pull $ALPINE; rc 0
  x d search --limit 1 alpine; rc 0
}
case_stopped_container_fs() {
  # the writable layer survives stop/start; cp works on stopped and created containers
  x d run -d --name sf $ALPINE sh -c 'echo kept >/kept; sleep 300'; rc 0
  x d stop -t 1 sf; rc 0
  rm -f "$STORE/kept.out"; x d cp sf:/kept "$STORE/kept.out"; rc 0
  [ "$(cat "$STORE/kept.out")" = kept ] || fail "cp out of a stopped container"
  echo staged >"$STORE/staged.txt"; x d cp "$STORE/staged.txt" sf:/staged.txt; rc 0
  x d start sf; rc 0
  x d exec sf cat /kept /staged.txt; out kept; out staged
  x d create --name sc $ALPINE true; rc 0
  rm -f "$STORE/release.out"; x d cp sc:/etc/alpine-release "$STORE/release.out"; rc 0
  [ -s "$STORE/release.out" ] || fail "cp out of a created container"
}
suite_cli2() {
  for c in error_codes container_misc resources_applied ports_extended network_modes restart_policies image_misc \
           stopped_container_fs; do run_case "$c"; done
}

# ---- suite: compose2 (breadth) ----------------------------------------------
case_compose_commands() {
  PROJ=stack
  x -t 300 c pull -q; rc 0
  x -t 400 c up -d --wait; rc 0
  x c images; rc 0; out nginx
  x c port web 80; rc 0; out "127.0.0.1:18081"
  echo cp-in >"$STORE/cp.txt"; x c cp "$STORE/cp.txt" client:/tmp/cp.txt; rc 0
  x c exec -T client cat /tmp/cp.txt; eq cp-in
  x c pause; rc 0; x c ps --format '{{.Service}} {{.State}}'; out "client paused"; x c unpause; rc 0
  x c kill -s SIGKILL client; rc 0
  x c ps -a --format '{{.Service}} {{.State}}'; out "client exited"
  x c rm -f client; rc 0
  x -t 300 c up -d; rc 0
  x c stats --no-stream; rc 0
  x c down -v; rc 0
}
case_compose_features() {
  PROJ=features
  x d network create ext_net; rc 0; x d volume create ext_vol; rc 0
  x -t 400 c up -d --wait; rc 0
  x c ps -a --format '{{.Service}} {{.State}} {{.ExitCode}}'; out "init exited 0"; out "app running"
  x c exec -T app sh -c 'cat /shared/from-init; echo $FROM_ENV_FILE; grep -c pinned.test /etc/hosts; hostname'
  out seeded; out env-file-ok; out 1; out app-host
  x c exec -T app sh -c 'ip -4 -o addr | grep -c 172.31.7.10'; eq 1
  x c exec -T app sh -c 'touch /ro 2>/dev/null; echo rc=$?; touch /scratch/ok && echo tmpfs-ok'; out "rc=1"; out tmpfs-ok
  x c --profile extra ps --format '{{.Service}}'; nout extra
  x -t 300 c --profile extra up -d; rc 0; x c --profile extra ps --format '{{.Service}}'; out extra
  # config change → only that service is recreated
  local before; before="$(docker compose --project-directory "$FX/$PROJ" -f "$FX/$PROJ/compose.yaml" ps -q init 2>/dev/null; docker compose --project-directory "$FX/$PROJ" -f "$FX/$PROJ/compose.yaml" ps -q app)"
  x -t 300 env APP_MARK=changed docker compose --project-directory "$FX/$PROJ" -f "$FX/$PROJ/compose.yaml" up -d; rc 0; err "Recreated"
  x c exec -T app sh -c 'echo $APP_MARK'; eq changed
  x -t 300 c up -d --remove-orphans; rc 0
  x c --profile extra down -v; rc 0
  x d network ls --format '{{.Name}}'; out ext_net; x d volume ls -q; out ext_vol
}
case_compose_unhealthy() {
  PROJ=unhealthy
  x -t 300 c up -d --wait; [ "$RC" != 0 ] || fail "up --wait must fail when a dependency is unhealthy"
  x c ps -a --format '{{.Service}} {{.Health}}'; out "bad unhealthy"
  x c ps --format '{{.Service}} {{.State}}'; nout "dependent running"
  x c down; rc 0
}
case_compose_daemon_restart() {
  PROJ=stack
  x -t 400 c up -d --wait; rc 0
  x c exec -T client sh -c 'echo survive >/data/marker'; rc 0
  stop_daemon; start_daemon
  x c ps -a --format '{{.Service}}'; out web; out client
  x -t 400 c up -d --wait; rc 0
  x c exec -T client cat /data/marker; eq survive
  x curl -s --retry 10 --retry-delay 1 --retry-all-errors -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/; eq 200
  x c down -v; rc 0
}
suite_compose2() { for c in compose_commands compose_features compose_unhealthy compose_daemon_restart; do run_case "$c"; done; }

# ---- suite: setup (docker context integration) ------------------------------
case_setup_context() {
  # `macker setup` registers a docker context; it must not hijack the user's environment.
  local cfg="$STORE/dockercfg" home="$STORE/home"; rm -rf "$cfg" "$home"; mkdir -p "$cfg" "$home"
  local run="env -u DOCKER_HOST DOCKER_CONFIG=$cfg HOME=$home SHELL=/bin/zsh"
  x $run "$MACKER" setup; rc 0
  x $run docker context inspect macker -f '{{.Endpoints.docker.Host}}'; rc 0
  grep -qE '^unix:///.+/macker\.sock$' "$OUT" || fail "context endpoint is not the macker socket"
  x $run docker context show; eq default                       # active context untouched
  [ -z "$(find "$home" -type f 2>/dev/null)" ] || fail "setup wrote shell startup files: $(find "$home" -type f)"
  x $run "$MACKER" setup; rc 0                                  # idempotent
  x $run docker context update macker --docker host=unix:///tmp/foreign.sock; rc 0
  x $run "$MACKER" setup; [ "$RC" != 0 ] || fail "setup must refuse to overwrite a context that points elsewhere"
  x $run "$MACKER" setup --force; rc 0
  x $run "$MACKER" setup --uninstall; rc 0
  x $run docker context inspect macker; [ "$RC" != 0 ] || fail "context not removed"
}
case_doctor() {
  x env DOCKER_HOST="unix://$SOCK" "$MACKER" doctor; rc 0
  out "docker CLI"; out "compose"; out "API"
}
suite_setup() { for c in setup_context doctor; do run_case "$c"; done; }

# ---- main -------------------------------------------------------------------
start_daemon
echo "docker $(docker version -f '{{.Client.Version}}' 2>/dev/null) / compose $(docker compose version --short 2>/dev/null) / store $STORE"
reset_state
for s in $SUITES; do echo "== suite: $s"; "suite_$s"; done
echo
echo "passed=$PASS failed=$FAIL"
[ -n "$FAILED" ] && echo "failed:$FAILED"
exit "$FAIL"
