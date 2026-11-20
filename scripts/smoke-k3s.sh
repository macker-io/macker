#!/bin/bash
# Experimental K3s readiness probe on an isolated Macker MicroVM.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mackerd="${MACKERD:-$root/dist/cli/bin/mackerd}"
macker="${MACKER:-$root/dist/cli/bin/macker}"
[[ -x "$mackerd" && -x "$macker" ]] || { echo "Run 'make cli' first, or set MACKERD and MACKER." >&2; exit 1; }
# Exercise the normal kernel selection alongside K3s, even if the caller
# previously ran the daemon-wide kernel override experiment.
unset MACKER_KERNEL
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
    for log in daemon nodes host-api ordinary-image; do
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
  endpoint=$(m 460 start --wait)
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
[[ "$(m 15 status)" == not-created ]]
start_cluster
[[ "$(m 20 status | head -n 1)" == ready ]]
if m 10 reset --confirm >"$store/refused.log" 2>&1; then
  echo 'Reset unexpectedly succeeded while K3s was running.' >&2
  exit 1
fi
echo 'K3s node is Ready.'
# Boot an ordinary container while K3s is running. This catches accidentally
# caching the K3s manager as the default, or selecting the default for K3s.
k3s_release=$(k 10 get nodes -o 'jsonpath={.items[0].status.nodeInfo.kernelVersion}')
timeout 120 "$macker" -H "$DOCKER_HOST" pull docker.io/library/alpine:3.24 >"$store/ordinary-image.log" 2>&1
default_release=$(timeout 60 "$macker" -H "$DOCKER_HOST" run --rm docker.io/library/alpine:3.24 uname -r)
if [[ ! "$default_release" =~ ^[0-9][^[:space:]]*$ || "$k3s_release" != *-macker-k3s-probe || "$default_release" == *-macker-k3s-probe ]]; then
  printf 'Unexpected kernels: K3s=%s ordinary=%s\n' "$k3s_release" "$default_release" >&2
  exit 1
fi
printf 'Same daemon, separate kernels: K3s=%s ordinary=%s\n' "$k3s_release" "$default_release"
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
kind: PersistentVolumeClaim
metadata:
  name: smoke-data
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 16Mi
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
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: smoke-data
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
k 10 exec smoke-client -- sh -ec 'printf %s persistent > /data/marker'
service_uid=$(k 10 get service smoke-server -o 'jsonpath={.metadata.uid}')
[[ -n "$service_uid" ]]
[[ -s "$store/k3s/state.ext4" ]]
m 50 stop
[[ "$(m 15 status | head -n 1)" == stopped ]]
start_cluster
[[ "$(k 10 get service smoke-server -o 'jsonpath={.metadata.uid}')" == "$service_uid" ]] || {
  echo 'Cluster state did not survive restart.' >&2
  exit 1
}
verify_service
[[ "$(k 10 exec smoke-client -- cat /data/marker)" == persistent ]]
echo 'K3s Service and PVC data survived a MicroVM stop/start.'

# Use the same unpublished reference twice; the second Pod must see the new
# build even though the node already has the original tag cached.
ctx="$store/build-context"
mkdir "$ctx"
printf 'FROM docker.io/library/alpine:3.24\nCOPY payload /payload\nCMD ["/bin/cat", "/payload"]\n' >"$ctx/Dockerfile"
ref=macker-smoke-local:dev
for version in first second; do
  printf '%s\n' "$version" >"$ctx/payload"
  timeout 330 "$macker" -H "$DOCKER_HOST" build --k3s -t "$ref" "$ctx"
  pod="local-image-$version"
  k 15 run "$pod" --image="$ref" --image-pull-policy=Never --restart=Never
  k 45 wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=40s
  [[ "$(k 10 logs "$pod")" == "$version" ]]
done
echo 'Both builds ran from the same synced tag with imagePullPolicy: Never.'
printf '%s\n' manual >"$ctx/payload"
timeout 120 "$macker" -H "$DOCKER_HOST" build -t "$ref" "$ctx"
m 330 image sync "$ref"
k 15 run local-image-manual --image="$ref" --image-pull-policy=Never --restart=Never
k 45 wait --for=jsonpath='{.status.phase}'=Succeeded pod/local-image-manual --timeout=40s
[[ "$(k 10 logs local-image-manual)" == manual ]]

m 50 stop
if m 10 reset >"$store/refused.log" 2>&1; then
  echo 'Reset unexpectedly succeeded without confirmation.' >&2
  exit 1
fi
[[ -s "$store/k3s/state.ext4" ]]
m 15 reset --confirm
m 15 reset --confirm
[[ ! -e "$store/k3s/state.ext4" && "$(m 15 status)" == not-created ]]
timeout 10 "$macker" -H "$DOCKER_HOST" image inspect "$ref" >/dev/null
echo 'Reset removed only cluster state; the local build image is still available.'
