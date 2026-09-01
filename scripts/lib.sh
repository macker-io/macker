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

is_macho() {
  file -b "$1" 2>/dev/null | grep -q "Mach-O"
}

# Developer ID identity for release signing. Same names as mediaforge CI:
# CERT_NAME (workflow) or APPLE_CERT_NAME. Unset → ad-hoc (`-`).
sign_identity() {
  if [ -n "${CERT_NAME:-}" ]; then
    printf '%s\n' "$CERT_NAME"
  elif [ -n "${APPLE_CERT_NAME:-}" ]; then
    printf '%s\n' "$APPLE_CERT_NAME"
  else
    printf '%s\n' "-"
  fi
}

sign_bin() {
  bin="$1"
  entitlements="${2:-}"
  identity="$(sign_identity)"
  if [ ! -f "$bin" ]; then
    echo "binary not found: $bin" >&2
    exit 1
  fi
  if [ "$identity" = "-" ]; then
    if [ -n "$entitlements" ]; then
      codesign --force --sign - --timestamp=none --entitlements="$entitlements" "$bin"
    else
      codesign --force --sign - --timestamp=none "$bin"
    fi
  elif [ -n "$entitlements" ]; then
    codesign --force --sign "$identity" --options runtime --timestamp --entitlements="$entitlements" "$bin"
  else
    codesign --force --sign "$identity" --options runtime --timestamp "$bin"
  fi
}

# Sign Mach-O files under a prefix (deepest path first). `mackerd` gets Daemon.entitlements.
sign_macho_tree() {
  root="$1"
  if [ ! -d "$root" ]; then
    echo "sign tree missing: $root" >&2
    exit 1
  fi
  list="$(mktemp)"
  find "$root" -type f -print |
    awk '{ printf "%04d\t%s\n", length($0), $0 }' |
    sort -nr >"$list"
  while IFS="$(printf '\t')" read -r _len path; do
    [ -n "$path" ] || continue
    is_macho "$path" || continue
    case "$(basename "$path")" in
    mackerd) sign_bin "$path" "$ENTITLEMENTS" ;;
    *) sign_bin "$path" ;;
    esac
  done <"$list"
  rm -f "$list"
}
