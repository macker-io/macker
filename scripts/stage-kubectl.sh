#!/bin/sh
# Stage the official Darwin ARM64 client matching the pinned K3s server.
set -eu
dest="${1:?usage: stage-kubectl.sh <k3s-tools directory>}"
version=v1.34.3
sha=e51367d2107d605f4edd7c2fb25897b0c0695a7de1a9f9d04cd6c9356b890b14
cache="$(dirname "$0")/../.build/kubectl-downloads"
file="$cache/kubectl-$version-darwin-arm64"
mkdir -p "$cache" "$dest"
verify() { printf '%s  %s\n' "$sha" "$1" | shasum -a 256 -c -; }
if ! [ -f "$file" ] || ! verify "$file" >/dev/null; then
  tmp="$(mktemp "$cache/download.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL --retry 3 "https://dl.k8s.io/release/$version/bin/darwin/arm64/kubectl" -o "$tmp"
  verify "$tmp"
  mv "$tmp" "$file"
fi
install -m 755 "$file" "$dest/kubectl"
