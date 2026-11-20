#!/bin/bash
# Build the ARM64 K3s guest kernel from pinned upstream Linux and a Kata config.
set -euo pipefail
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || { echo 'Native ARM64 Linux builder required' >&2; exit 1; }
base=${1:?usage: build-k3s-kernel-linux.sh <Kata vmlinux> <output directory>}
out=${2:?output directory required}
mkdir -p "$out"
out=$(cd "$out" && pwd)
script=$(realpath -- "${BASH_SOURCE[0]}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$base" "$work/kata.config" <<'PY'
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
    sys.exit('Expected a Kata Linux 6.12.28 ARM64 kernel')
pathlib.Path(sys.argv[2]).write_bytes(config)
PY
cd "$work"
source=linux-6.12.28.tar.xz
curl -fsSL --retry 3 "https://cdn.kernel.org/pub/linux/kernel/v6.x/$source" -o "$source"
echo "e8a099182562aecff781de72ce769461e706d97af42d740dff20eb450dd5771e  $source" | sha256sum -c -
tar xf "$source"
cd linux-6.12.28
cp ../kata.config .config
scripts/config --enable BRIDGE_NETFILTER --enable NETFILTER_XT_MATCH_PHYSDEV --set-str LOCALVERSION -macker-k3s-probe
make -s olddefconfig
grep -qx CONFIG_BRIDGE_NETFILTER=y .config
grep -qx CONFIG_NETFILTER_XT_MATCH_PHYSDEV=y .config
make -s -j "$(nproc)" Image
# Publish corresponding source and build inputs alongside, not inside, the CLI tarball.
cp .config ../k3s.config
cp "$script" ../build-k3s-kernel-linux.sh
cp COPYING ../COPYING
tar -C "$work" -cf "$out/k3s-kernel-source.tar" "$source" kata.config k3s.config build-k3s-kernel-linux.sh COPYING
install -m 644 arch/arm64/boot/Image "$out/vmlinux.partial"
mv "$out/vmlinux.partial" "$out/vmlinux"
printf 'K3s kernel: %s/vmlinux\n' "$out"
