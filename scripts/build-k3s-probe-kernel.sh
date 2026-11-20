#!/bin/bash
# Local Docker wrapper for the same ARM64 kernel build used in release CI.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
base=${1:-$root/dist/cli/share/macker/runtime/vmlinux}
output=${2:-$root/.build/k3s-probe}
base=$(cd "$(dirname "$base")" && pwd)/$(basename "$base")
mkdir -p "$output"
output=$(cd "$output" && pwd)
docker run --rm --platform linux/arm64 \
  --mount "type=bind,src=$base,dst=/kata-vmlinux,readonly" \
  --mount "type=bind,src=$root/scripts/build-k3s-kernel-linux.sh,dst=/build-k3s-kernel-linux.sh,readonly" \
  --mount "type=bind,src=$output,dst=/out" \
  ubuntu:24.04 bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq bc bison build-essential ca-certificates curl flex libelf-dev libssl-dev python3 xz-utils >/dev/null
  bash /build-k3s-kernel-linux.sh /kata-vmlinux /out
'
printf 'K3s kernel: %s/vmlinux\n' "$output"
