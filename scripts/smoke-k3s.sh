#!/bin/bash
# Experimental K3s readiness probe on an isolated Macker MicroVM.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mackerd="${MACKERD:-$root/dist/cli/bin/mackerd}"
macker="${MACKER:-$root/dist/cli/bin/macker}"
[[ -x "$mackerd" && -x "$macker" ]] || { echo "Run 'make cli' first, or set MACKERD and MACKER." >&2; exit 1; }
: "${MACKER_KERNEL:?Set MACKER_KERNEL to the experimental kernel}"
for tool in kubectl lsof timeout; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done
store=$(mktemp -d /tmp/macker-k3s.XXXXXX)
export DOCKER_HOST="unix://$store/macker.sock"
unset DOCKER_CONTEXT DOCKER_API_VERSION
MACKER_EXPERIMENTAL_K3S=1 "$mackerd" --store "$store" >"$store/daemon.log" 2>&1 &
pid=$!
cleanup() {
  local status=$?
  if [[ "$status" != 0 && -f "$store/kubeconfig" ]]; then
    timeout 5 kubectl --kubeconfig "$store/kubeconfig" get pods -A -o wide --request-timeout=3s >&2 || true
  fi
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" || true
  if [[ "$status" != 0 ]]; then
    for log in daemon nodes host-api; do
      if [[ -f "$store/$log.log" ]]; then
        printf '\n--- %s ---\n' "$log" >&2
        tail -20 "$store/$log.log" >&2
      fi
    done
  fi
  rm -rf "$store"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for ((i=0; i<100; i++)); do
  [[ -S "$store/macker.sock" ]] && break
  kill -0 "$pid" 2>/dev/null || exit 1
  sleep 0.2
done
[[ -S "$store/macker.sock" ]] || { echo 'Test daemon did not open its socket' >&2; exit 1; }
m() { local limit=$1; shift; timeout "$limit" "$macker" -H "$DOCKER_HOST" k3s "$@"; }
k() { local limit=$1; shift; timeout "$limit" kubectl --kubeconfig "$store/kubeconfig" "$@"; }
start_cluster() {
  local endpoint binding port listeners i
  endpoint=$(m 310 start)
  if [[ ! "$endpoint" =~ ^https://127\.0\.0\.1:([0-9]+)$ ]]; then
    echo "Unexpected API endpoint: $endpoint" >&2
    return 1
  fi
  port="${BASH_REMATCH[1]}"
  binding="127.0.0.1:$port"
  listeners=$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN -Fn)
  [[ "$(printf '%s\n' "$listeners" | grep '^n')" == "n$binding" ]]
  rm -f "$store/kubeconfig"
  for ((i=0; i<30; i++)); do
    if m 12 kubeconfig "$store/kubeconfig" >"$store/host-api.log" 2>&1; then break; fi
    sleep 2
  done
  [[ "$(stat -f '%Lp' "$store/kubeconfig")" == 600 ]]
  if m 12 kubeconfig "$store/kubeconfig" >"$store/refused.log" 2>&1; then
    echo 'Kubeconfig unexpectedly overwrote an existing file.' >&2
    return 1
  fi
  for ((i=0; i<30; i++)); do
    if k 8 --request-timeout=5s get --raw /readyz >"$store/host-api.log" 2>&1 &&
       k 8 --request-timeout=5s get nodes --no-headers >"$store/nodes.log" 2>&1 &&
       grep -Eq '[[:space:]]Ready[[:space:]]' "$store/nodes.log"; then
      echo 'Host kubectl reached the loopback API with TLS verification.'
      return 0
    fi
    sleep 2
  done
  echo 'Host kubectl could not reach a ready node.' >&2
  return 1
}
start_cluster
echo 'K3s node is Ready.'
# Node readiness can precede creation of the default ServiceAccount.
for ((i=0; i<30; i++)); do
  if k 5 get serviceaccount default --request-timeout=3s >/dev/null 2>&1; then break; fi
  sleep 1
done
k 5 get serviceaccount default --request-timeout=3s >/dev/null
k 20 apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: smoke-server
  labels:
    app: smoke-server
spec:
  containers:
  - name: http
    image: docker.io/library/busybox:1.37.0
    command: ["sh", "-ec", "mkdir -p /www; echo macker-k3s > /www/index.html; exec httpd -f -p 8080 -h /www"]
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-client
spec:
  containers:
  - name: client
    image: docker.io/library/busybox:1.37.0
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Service
metadata:
  name: smoke-server
spec:
  selector:
    app: smoke-server
  ports:
  - port: 8080
YAML
verify_service() {
  local service_ip endpoint target ok i
  k 140 wait --for=condition=Ready pod/smoke-server pod/smoke-client --timeout=130s
  service_ip=$(k 10 get service smoke-server -o 'jsonpath={.spec.clusterIP}')
  for endpoint in pod-ip "$service_ip" smoke-server; do
    [[ -n "$endpoint" ]] || return 1
    ok=0
    for ((i=0; i<18; i++)); do
      # Pod status can still advertise its old IP just after the VM boots.
      target="$endpoint"
      if [[ "$endpoint" == pod-ip ]]; then
        target=$(k 5 get pod smoke-server -o 'jsonpath={.status.podIP}' 2>>"$store/nodes.log") || target=
      fi
      if [[ -n "$target" && "$(k 8 exec smoke-client -- wget -T 3 -qO- "http://$target:8080/" 2>>"$store/nodes.log")" == macker-k3s ]]; then
        ok=1
        break
      fi
      sleep 2
    done
    [[ "$ok" == 1 ]] || { echo "Pod could not reach $endpoint:8080" >&2; return 1; }
  done
  echo 'K3s Pod IP, ClusterIP and Service DNS passed.'
}
verify_service
service_uid=$(k 10 get service smoke-server -o 'jsonpath={.metadata.uid}')
[[ -n "$service_uid" ]]
[[ -s "$store/k3s/state.ext4" ]]
m 50 stop
start_cluster
[[ "$(k 10 get service smoke-server -o 'jsonpath={.metadata.uid}')" == "$service_uid" ]] || {
  echo 'Cluster state did not survive restart.' >&2
  exit 1
}
verify_service
echo 'K3s Service survived a MicroVM stop/start.'
