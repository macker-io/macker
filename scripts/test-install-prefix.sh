#!/bin/bash
# Exercise the release installer against a local fixture, never a real prefix or LaunchAgent.
set -euo pipefail
installer="$(cd "$(dirname "$0")" && pwd)/install.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" MACKER_PREFIX="$tmp/shared prefix" MACKER_NO_SERVICE=1 SHELL=/bin/zsh
export FIXTURE="$tmp/release"
mkdir -p "$HOME" "$tmp/tools" "$FIXTURE" "$tmp/pkg"/{bin,libexec/macker,share/macker/runtime}
for file in LICENSE bin/macker bin/mackerd libexec/macker/macker libexec/macker/mackerd share/macker/runtime/RuntimePin.json; do
  echo fixture >"$tmp/pkg/$file"
done
archive=macker-1-darwin-arm64.tar.gz
tar czf "$FIXTURE/$archive" -C "$tmp/pkg" .
(cd "$FIXTURE" && shasum -a256 "$archive" >SHA256SUMS)
printf '#!/bin/sh\ncp "$FIXTURE/${2##*/}" "$4"\n' >"$tmp/tools/curl"
chmod +x "$tmp/tools/curl"
export PATH="$tmp/tools:$PATH"
for dir in bin libexec share compose; do
  mkdir -p "$MACKER_PREFIX/$dir"; echo keep >"$MACKER_PREFIX/$dir/unrelated"
done
echo shared >"$MACKER_PREFIX/LICENSE"
echo foreign >"$MACKER_PREFIX/bin/macker"
if bash "$installer" 1; then echo 'overwrote foreign executable' >&2; exit 1; fi
grep -qx foreign "$MACKER_PREFIX/bin/macker"
rm "$MACKER_PREFIX/bin/macker"
bash "$installer" 1
bash "$installer" 1
bash "$installer" --uninstall
for dir in bin libexec share compose; do grep -qx keep "$MACKER_PREFIX/$dir/unrelated"; done
grep -qx shared "$MACKER_PREFIX/LICENSE"
[ ! -e "$MACKER_PREFIX/libexec/macker" ] && [ ! -e "$MACKER_PREFIX/bin/macker" ] || exit 1
if grep -F "$MACKER_PREFIX/bin" "$HOME/.zshrc"; then exit 1; fi
echo 'Shared-prefix installer test passed.'
