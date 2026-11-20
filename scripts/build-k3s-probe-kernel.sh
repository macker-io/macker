#!/bin/bash
# Build a test-only ARM64 guest Image from the Kata config. No installed runtime is changed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
base=${1:-$root/dist/cli/share/macker/runtime/vmlinux}
output=${2:-$root/.build/k3s-probe}
mkdir -p "$output"
output=$(cd "$output" && pwd)
python3 - "$base" "$output/kata.config" <<'PY'
import gzip
import pathlib
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
start = image.find(b'IKCFG_ST')
end = image.find(b'IKCFG_ED', start + 8)
if start < 0 or end < 0:
    sys.exit('Kata kernel has no embedded configuration')
config = gzip.decompress(image[start + 8:end])
if b'# Linux/arm64 6.12.28 Kernel Configuration\n' not in config:
    sys.exit('This probe expects a Kata Linux 6.12.28 ARM64 kernel')
pathlib.Path(sys.argv[2]).write_bytes(config)
PY
docker run --rm --platform linux/arm64 --mount "type=bind,src=$output,dst=/out" \
  ubuntu:24.04 bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq bc bison build-essential ca-certificates curl flex libelf-dev libssl-dev xz-utils >/dev/null
  cd /tmp
  curl -fsSL --retry 3 https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.28.tar.xz -o linux.tar.xz
  echo "e8a099182562aecff781de72ce769461e706d97af42d740dff20eb450dd5771e  linux.tar.xz" | sha256sum -c -
  tar xf linux.tar.xz
  cd linux-6.12.28
  cp /out/kata.config .config
  scripts/config --enable BRIDGE_NETFILTER --enable NETFILTER_XT_MATCH_PHYSDEV --set-str LOCALVERSION -macker-k3s-probe
  make -s olddefconfig
  grep -qx CONFIG_BRIDGE_NETFILTER=y .config
  grep -qx CONFIG_NETFILTER_XT_MATCH_PHYSDEV=y .config
  make -s -j "$(nproc)" Image
  cp arch/arm64/boot/Image /out/vmlinux.partial
  mv /out/vmlinux.partial /out/vmlinux
'
printf 'Probe kernel: %s/vmlinux\n' "$output"
