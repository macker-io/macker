# Shared helpers for scripts/*.sh. Source from those scripts only:
#   . "$(dirname "$0")/lib.sh"
# shellcheck shell=sh

_this="${BASH_SOURCE[0]:-$0}"
_scripts_dir="$(CDPATH= cd "$(dirname -- "$_this")" && pwd)"
ROOT="$(CDPATH= cd "$_scripts_dir/.." && pwd)"
DAEMON_ROOT="$ROOT"
REPO_ROOT="$ROOT"
PIN="$ROOT/Sources/ContainerEngine/RuntimePin.json"
ENTITLEMENTS="$ROOT/Sources/Daemon/Daemon.entitlements"
STORE="${HOME}/Library/Application Support/io.macker.daemon"
SOCKET="$STORE/macker.sock"

product_version() {
  if [ -n "${VERSION:-}" ]; then
    printf '%s\n' "$VERSION"
  elif [ -n "${MACKER_VERSION:-}" ]; then
    printf '%s\n' "$MACKER_VERSION"
  else
    printf '%s\n' "0.0.0"
  fi
}

pin_field() {
  python3 -c "import json; print(json.load(open(r'''$PIN'''))['$1'])"
}

swift_bin_dir() {
  configuration="${1:-debug}"
  swift build -c "$configuration" --show-bin-path
}

is_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

sign_bin() {
  bin="$1"
  if [ ! -f "$bin" ]; then
    echo "binary not found: $bin" >&2
    exit 1
  fi
  if [ -n "${2:-}" ]; then
    codesign --force --sign - --timestamp=none --entitlements="$2" "$bin"
  else
    codesign --force --sign - --timestamp=none "$bin"
  fi
}
