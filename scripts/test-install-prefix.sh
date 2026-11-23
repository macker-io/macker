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

# Guard/mock launchctl before ANY installer invocation (incl. --uninstall / --no-service).
: >"$tmp/launchctl.log"
cat >"$tmp/tools/launchctl" <<'EOF'
#!/bin/sh
# Record argv for ordering assertions; succeed without host side effects.
printf '%s\n' "$*" >>"${LAUNCHCTL_LOG:?}"
exit 0
EOF
chmod +x "$tmp/tools/launchctl"
export LAUNCHCTL_LOG="$tmp/launchctl.log"
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
if grep -E 'bootout|bootstrap|kickstart' "$LAUNCHCTL_LOG" >/dev/null; then
  echo 'no-service install/uninstall must not touch launchctl:' >&2
  cat "$LAUNCHCTL_LOG" >&2
  exit 1
fi
echo 'Shared-prefix installer test passed.'

# --- Literal --no-service flag (not only MACKER_NO_SERVICE) ---
flag_home="$tmp/flag-home"
flag_prefix="$tmp/flag-prefix"
mkdir -p "$flag_home" "$flag_prefix"
export HOME="$flag_home" MACKER_PREFIX="$flag_prefix"
unset MACKER_NO_SERVICE
: >"$LAUNCHCTL_LOG"
bash "$installer" 1 --no-service
[ -x "$MACKER_PREFIX/bin/macker" ]
[ ! -e "$HOME/Library/LaunchAgents/io.macker.daemon.plist" ] || {
  echo '--no-service created LaunchAgent plist' >&2
  exit 1
}
if grep -E 'bootout|bootstrap|kickstart' "$LAUNCHCTL_LOG" >/dev/null; then
  echo '--no-service must not touch launchctl:' >&2
  cat "$LAUNCHCTL_LOG" >&2
  exit 1
fi
echo 'Literal --no-service flag test passed.'

# --- --no-service uninstall leaves an existing matching LaunchAgent alone ---
nsu_home="$tmp/nsu-home"
nsu_prefix="$tmp/nsu-prefix"
mkdir -p "$nsu_home" "$nsu_prefix"
export HOME="$nsu_home" MACKER_PREFIX="$nsu_prefix"
unset MACKER_NO_SERVICE
: >"$LAUNCHCTL_LOG"
bash "$installer" 1
nsu_plist="$HOME/Library/LaunchAgents/io.macker.daemon.plist"
[ -f "$nsu_plist" ]
nsu_abs="$(CDPATH= cd -- "$MACKER_PREFIX" && pwd)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$nsu_plist")" = "$nsu_abs/libexec/macker/mackerd" ]
nsu_plist_body="$(cat "$nsu_plist")"
: >"$LAUNCHCTL_LOG"
bash "$installer" --uninstall --no-service
[ -f "$nsu_plist" ] || {
  echo '--no-service uninstall removed matching LaunchAgent plist' >&2
  exit 1
}
[ "$(cat "$nsu_plist")" = "$nsu_plist_body" ] || {
  echo '--no-service uninstall altered matching LaunchAgent plist' >&2
  exit 1
}
[ ! -e "$MACKER_PREFIX/libexec/macker" ] && [ ! -e "$MACKER_PREFIX/bin/macker" ] || {
  echo '--no-service uninstall left package files' >&2
  exit 1
}
if grep -E 'bootout|bootstrap|kickstart' "$LAUNCHCTL_LOG" >/dev/null; then
  echo '--no-service uninstall must not touch launchctl:' >&2
  cat "$LAUNCHCTL_LOG" >&2
  exit 1
fi
echo '--no-service uninstall (matching plist) test passed.'

# --- LaunchAgent plist: XML metacharacters + lint + decoded ProgramArguments ---
xml_home="$tmp/xml-home"
xml_prefix="$tmp/prefix & a<b>c"
mkdir -p "$xml_home" "$xml_prefix"
export HOME="$xml_home" MACKER_PREFIX="$xml_prefix"
unset MACKER_NO_SERVICE
: >"$LAUNCHCTL_LOG"

bash "$installer" 1
plist="$HOME/Library/LaunchAgents/io.macker.daemon.plist"
[ -f "$plist" ]
plutil -lint "$plist" >/dev/null
prefix_abs="$(CDPATH= cd -- "$MACKER_PREFIX" && pwd)"
expected="${prefix_abs}/libexec/macker/mackerd"
got="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")"
[ "$got" = "$expected" ] || {
  echo "ProgramArguments mismatch: got=$got expected=$expected" >&2
  exit 1
}
# Raw XML must escape dynamic path metacharacters.
grep -F '&amp;' "$plist" >/dev/null || {
  echo "expected escaped ampersand in staged plist XML" >&2
  exit 1
}
grep -F '&lt;' "$plist" >/dev/null || {
  echo "expected escaped less-than in staged plist XML" >&2
  exit 1
}
grep -F '&gt;' "$plist" >/dev/null || {
  echo "expected escaped greater-than in staged plist XML" >&2
  exit 1
}
grep -F 'bootout ' "$LAUNCHCTL_LOG" >/dev/null
grep -F 'bootstrap ' "$LAUNCHCTL_LOG" >/dev/null
echo 'XML-safe LaunchAgent plist test passed.'

# --- Lint failure must not replace live daemon bytes OR a different agent plist ---
# Distinct daemon bytes: fixture always writes "fixture"; prior claim that only
# checking plist was enough was false — live rm/mv before lint would still pass.
prior_program="/prior/different/mackerd"
/usr/libexec/PlistBuddy -c "Clear dict" \
  -c "Add :Label string io.macker.daemon" \
  -c "Add :ProgramArguments array" \
  -c "Add :ProgramArguments:0 string ${prior_program}" \
  -c "Add :RunAtLoad bool true" \
  "$plist" >/dev/null
old_body="$(cat "$plist")"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")" = "$prior_program" ]
printf 'old-daemon-bytes-must-survive-lint-fail\n' >"$MACKER_PREFIX/libexec/macker/mackerd"
old_daemon="$(cat "$MACKER_PREFIX/libexec/macker/mackerd")"
[ "$old_daemon" != "fixture" ] || {
  echo 'test setup: old daemon must differ from fixture tarball content' >&2
  exit 1
}
: >"$LAUNCHCTL_LOG"
mkdir -p "$tmp/fail-plutil"
cat >"$tmp/fail-plutil/plutil" <<'EOF'
#!/bin/sh
echo "mock plutil: refusing lint" >&2
exit 1
EOF
chmod +x "$tmp/fail-plutil/plutil"
# Prefer mock plutil; keep launchctl mock and fixture curl.
export PATH="$tmp/fail-plutil:$tmp/tools:$PATH"
if bash "$installer" 1; then
  echo 'install succeeded despite plutil lint failure' >&2
  exit 1
fi
[ -f "$plist" ] || {
  echo 'existing LaunchAgent plist was removed after lint failure' >&2
  exit 1
}
[ "$(cat "$plist")" = "$old_body" ] || {
  echo 'prior different LaunchAgent payload changed after lint failure' >&2
  exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")" = "$prior_program" ] || {
  echo 'prior different ProgramArguments overwritten after lint failure' >&2
  exit 1
}
[ "$(cat "$MACKER_PREFIX/libexec/macker/mackerd")" = "$old_daemon" ] || {
  echo 'live daemon bytes replaced before plist lint passed' >&2
  exit 1
}
if grep -E 'bootout|bootstrap|kickstart' "$LAUNCHCTL_LOG" >/dev/null; then
  echo 'launchctl was invoked before/despite lint failure:' >&2
  cat "$LAUNCHCTL_LOG" >&2
  exit 1
fi
echo 'LaunchAgent lint-failure ordering test passed.'
