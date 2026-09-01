#!/bin/sh
# Install the Macker CLI prefix from a GitHub Release.
#
#   curl -fsSL https://raw.githubusercontent.com/macker-io/macker/main/scripts/install.sh | bash
#   curl -fsSL ... | bash -s -- 0.1.0-alpha.1
#   curl -fsSL ... | bash -s -- --uninstall
#
# Env:
#   MACKER_REPO      default macker-io/macker
#   MACKER_PREFIX    default ~/.macker
#   MACKER_VERSION   same as the version argument
#   MACKER_NO_SERVICE=1   skip LaunchAgent
#   MACKER_NO_PROFILE=1   do not edit ~/.zshrc / ~/.bashrc
set -euo pipefail

REPO="${MACKER_REPO:-macker-io/macker}"
PREFIX="${MACKER_PREFIX:-$HOME/.macker}"
LABEL="io.macker.daemon"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

usage() {
  cat <<EOF
usage: install.sh [VERSION] [--uninstall] [--no-service]

  VERSION     release without the leading v (default: newest GitHub release)
  --uninstall remove $PREFIX, PATH shims, and the LaunchAgent
  --no-service  do not install or start the LaunchAgent
EOF
}

UNINSTALL=0
NO_SERVICE="${MACKER_NO_SERVICE:-0}"
VERSION="${MACKER_VERSION:-}"

while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --uninstall)
    UNINSTALL=1
    ;;
  --no-service)
    NO_SERVICE=1
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
  *)
    if [ -n "$VERSION" ]; then
      echo "unexpected argument: $1" >&2
      exit 1
    fi
    VERSION="$1"
    ;;
  esac
  shift
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Macker is macOS only (got $(uname -s))" >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "Macker is Apple Silicon only (got $(uname -m))" >&2
  exit 1
fi

macos_major="$(sw_vers -productVersion | awk -F. '{ print $1 }')"
if [ "$macos_major" -lt 15 ]; then
  echo "macOS 15+ is required (found $(sw_vers -productVersion))" >&2
  exit 1
fi

uid="$(id -u)"
gui="gui/${uid}"

stop_service() {
  launchctl bootout "$gui/${LABEL}" >/dev/null 2>&1 || true
  rm -f "$PLIST"
}

remove_profile_line() {
  file="$1"
  [ -f "$file" ] || return 0
  grep -F "macker — CLI prefix" "$file" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  awk '
    /# macker — CLI prefix/ { skip=1; next }
    skip && /^export PATH=.*\.macker\/bin/ { skip=0; next }
    { skip=0; print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

uninstall() {
  stop_service
  rm -rf "$PREFIX"
  remove_profile_line "$HOME/.zshrc"
  remove_profile_line "$HOME/.bashrc"
  echo "removed $PREFIX"
}

if [ "$UNINSTALL" = "1" ]; then
  uninstall
  exit 0
fi

if [ "$macos_major" -lt 26 ]; then
  echo "warning: bridge/host networking needs macOS 26+ (found $(sw_vers -productVersion))" >&2
fi

latest_version() {
  python3 - "$REPO" <<'PY'
import json, sys, urllib.request
repo = sys.argv[1]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases?per_page=10",
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "macker-install",
    },
)
with urllib.request.urlopen(req) as resp:
    releases = json.load(resp)
for rel in releases:
    if rel.get("draft"):
        continue
    tag = rel["tag_name"]
    print(tag[1:] if tag.startswith("v") else tag)
    break
else:
    sys.exit("no GitHub releases found")
PY
}

if [ -z "$VERSION" ]; then
  VERSION="$(latest_version)"
fi
VERSION="${VERSION#v}"

TARBALL="macker-${VERSION}-darwin-arm64.tar.gz"
BASE="https://github.com/${REPO}/releases/download/v${VERSION}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/macker-install.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

echo "installing macker ${VERSION} → ${PREFIX}"
curl -fsSL "${BASE}/${TARBALL}" -o "${WORKDIR}/${TARBALL}"
curl -fsSL "${BASE}/SHA256SUMS" -o "${WORKDIR}/SHA256SUMS"

(
  cd "$WORKDIR"
  awk -v name="$TARBALL" '$2 == name { print }' SHA256SUMS | shasum -a 256 -c -
)

mkdir -p "$PREFIX"
rm -rf "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/share"
tar -C "$PREFIX" -xzf "${WORKDIR}/${TARBALL}"
# Downloads from a browser/curl pick up quarantine; drop it on our prefix.
xattr -dr com.apple.quarantine "$PREFIX" 2>/dev/null || true
chmod 755 "$PREFIX/bin/macker" "$PREFIX/bin/mackerd"
chmod 755 "$PREFIX/libexec/macker/macker" "$PREFIX/libexec/macker/mackerd"
if [ -x "$PREFIX/libexec/macker/macker-helper" ]; then
  chmod 755 "$PREFIX/libexec/macker/macker-helper"
fi

PREFIX_ABS="$(CDPATH= cd -- "$PREFIX" && pwd)"

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${PREFIX_ABS}/libexec/macker/mackerd</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF
}

start_service() {
  stop_service
  write_plist
  launchctl bootstrap "$gui" "$PLIST"
  launchctl enable "$gui/${LABEL}" 2>/dev/null || true
  launchctl kickstart -k "$gui/${LABEL}" 2>/dev/null || true
}

ensure_path() {
  bin="${PREFIX_ABS}/bin"
  case ":$PATH:" in
  *":${bin}:"*) return 0 ;;
  esac
  line="export PATH=\"${bin}:\$PATH\""
  if [ "${MACKER_NO_PROFILE:-0}" = "1" ]; then
    echo "add to PATH: $line"
    return 0
  fi
  shell="$(basename "${SHELL:-/bin/zsh}")"
  case "$shell" in
  bash) rc="$HOME/.bashrc" ;;
  *) rc="$HOME/.zshrc" ;;
  esac
  if [ -f "$rc" ] && grep -F "macker — CLI prefix" "$rc" >/dev/null 2>&1; then
    return 0
  fi
  {
    echo ""
    echo "# macker — CLI prefix"
    echo "$line"
  } >>"$rc"
  echo "added ${bin} to PATH in $rc (open a new terminal)"
}

if [ "$NO_SERVICE" != "1" ]; then
  start_service
  echo "LaunchAgent ${LABEL} loaded"
else
  echo "start the daemon: ${PREFIX_ABS}/bin/mackerd"
fi

ensure_path

echo ""
echo "next:"
echo "  ${PREFIX_ABS}/bin/macker doctor"
echo "  ${PREFIX_ABS}/bin/macker run --rm alpine echo hello"
echo "optional: sudo ${PREFIX_ABS}/bin/macker helper install"
echo "do not run macker setup unless you want to alias docker"
echo "uninstall: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash -s -- --uninstall"
