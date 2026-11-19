#!/bin/sh
# Stage pinned upstream Darwin arm64 clients; never resolve providers from PATH.
set -eu
dest="${1:?usage: stage-compose-tools.sh <compose-tools directory>}"
cache="$(dirname "$0")/../.build/compose-downloads"
mkdir -p "$cache" "$dest/cli-plugins"
tmp="$(mktemp -d "$cache/tmp.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

stage() {
  asset="$1"; sha="$2"; target="$3"
  file="$cache/${asset##*/}-$sha"
  if ! [ -f "$file" ] || ! printf '%s  %s\n' "$sha" "$file" | shasum -a 256 -c - >/dev/null; then
    curl --fail --location --silent --show-error --retry 3 "https://github.com/docker/$asset" -o "$tmp/download"
    printf '%s  %s\n' "$sha" "$tmp/download" | shasum -a 256 -c -
    mv "$tmp/download" "$file"
  fi
  install -m 755 "$file" "$target"
}

stage compose/releases/download/v5.5.0/docker-compose-darwin-aarch64 \
  6777710e5a5db5709e5f4b5985844e74b73cc1a6123e3a6690b6ababf2deaf51 "$dest/docker-compose"
stage buildx/releases/download/v0.37.2/buildx-v0.37.2.darwin-arm64 \
  149e6a006edaa430f297b2bdcf65baaa6d7ee5ccfc7aa67dd50ce1c2b1db47e2 "$dest/cli-plugins/docker-buildx"
