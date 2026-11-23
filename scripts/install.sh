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
  --uninstall remove Macker package files, PATH entry, and the LaunchAgent
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

bootout_service() {
  launchctl bootout "$gui/${LABEL}" >/dev/null 2>&1 || true
}

stop_service() {
  bootout_service
  rm -f "$PLIST"
}

remove_profile_line() {
  file="$1"
  [ -f "$file" ] || return 0
  grep -F "macker — CLI prefix" "$file" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  awk -v line="export PATH=\"${PREFIX_ABS}/bin:\$PATH\"" '
    pending {
      if ($0 == line) { pending=0; next }
      print "# macker — CLI prefix"
      pending=0
    }
    $0 == "# macker — CLI prefix" { pending=1; next }
    { print }
    END { if (pending) print "# macker — CLI prefix" }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Only the two wrappers and private Macker directories belong to the CLI package.
check_prefix() {
  for path in bin libexec share bin/macker bin/mackerd libexec/macker share/macker; do
    if [ -L "$PREFIX/$path" ]; then
      echo "refusing linked install target: $PREFIX/$path" >&2; return 1
    fi
  done
  if [ -f "$PREFIX/share/macker/.cli-install" ] ||
     { [ -x "$PREFIX/libexec/macker/mackerd" ] &&
       [ -f "$PREFIX/share/macker/launchd/io.macker.daemon.plist.in" ] &&
       [ -f "$PREFIX/share/macker/runtime/RuntimePin.json" ]; }; then
    return 0 # Marked install, or the legacy packaged layout.
  fi
  for path in bin/macker bin/mackerd libexec/macker share/macker; do
    if [ -e "$PREFIX/$path" ]; then
      echo "refusing to replace unowned install target: $PREFIX/$path" >&2; return 1
    fi
  done
  [ "$UNINSTALL" != "1" ] || { echo "no Macker installation in $PREFIX" >&2; return 1; }
}

uninstall() {
  check_prefix
  PREFIX_ABS="$(CDPATH= cd -- "$PREFIX" && pwd)"
  # --no-service / MACKER_NO_SERVICE: leave LaunchAgent alone even if it matches.
  if [ "$NO_SERVICE" != "1" ] &&
     [ -f "$PLIST" ] &&
     [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null || true)" = "$PREFIX_ABS/libexec/macker/mackerd" ]; then
    stop_service
  fi
  rm -f "$PREFIX/bin/macker" "$PREFIX/bin/mackerd"
  rm -rf "$PREFIX/libexec/macker" "$PREFIX/share/macker"
  remove_profile_line "$HOME/.zshrc"
  remove_profile_line "$HOME/.bashrc"
  echo "removed Macker package files from $PREFIX"
}

if [ "$UNINSTALL" = "1" ]; then
  uninstall
  exit 0
fi

if [ "$macos_major" -lt 26 ]; then
  echo "warning: bridge/host networking needs macOS 26+ (found $(sw_vers -productVersion))" >&2
fi

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to install Macker" >&2
    exit 1
  fi
}

# latest_version + LaunchAgent serialization use python3 (plistlib) — only when invoked.
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
  require_python3
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

check_prefix
stage="$WORKDIR/prefix"
mkdir "$stage"
tar -C "$stage" -xzf "${WORKDIR}/${TARBALL}"
for path in bin/macker bin/mackerd libexec/macker/mackerd libexec/macker/macker share/macker/runtime/RuntimePin.json; do
  [ -f "$stage/$path" ] || { echo "incomplete CLI package: $path" >&2; exit 1; }
done
mv "$stage/LICENSE" "$stage/share/macker/LICENSE"
touch "$stage/share/macker/.cli-install"
xattr -dr com.apple.quarantine "$stage" 2>/dev/null || true
mkdir -p "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/share"
PREFIX_ABS="$(CDPATH= cd -- "$PREFIX" && pwd)"

# Serialize with plistlib so PREFIX_ABS XML metacharacters (& < > " ') stay well-formed.
write_plist() {
  dest="$1"
  program="${PREFIX_ABS}/libexec/macker/mackerd"
  python3 - "$dest" "$LABEL" "$program" <<'PY'
import plistlib
import sys

dest, label, program = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [program],
    "RunAtLoad": True,
    "KeepAlive": True,
}
with open(dest, "wb") as fh:
    plistlib.dump(payload, fh, fmt=plistlib.FMT_XML)
PY
}

restore_service_plist() {
  backup="$1"
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    if ! mv -f "$backup" "$PLIST"; then
      echo "failed to restore prior LaunchAgent plist (backup left at $backup)" >&2
      return 1
    fi
    if ! launchctl bootstrap "$gui" "$PLIST"; then
      echo "restored LaunchAgent plist but failed to load prior ${LABEL}" >&2
      return 1
    fi
    launchctl enable "$gui/${LABEL}" 2>/dev/null || true
    launchctl kickstart -k "$gui/${LABEL}" 2>/dev/null || true
    return 0
  fi
  rm -f "$PLIST"
  return 1
}

# Install an already-prepared+linted staged plist. Does not write or lint.
start_service() {
  staged="$1"
  mkdir -p "$HOME/Library/LaunchAgents"
  backup=""
  if [ -f "$PLIST" ]; then
    # Backup stays outside WORKDIR so EXIT trap cannot lose the sole copy.
    backup="$(mktemp "${TMPDIR:-/tmp}/macker-plist-bak.XXXXXX")"
    if ! cp "$PLIST" "$backup"; then
      echo "failed to backup LaunchAgent plist" >&2
      return 1
    fi
  fi
  bootout_service
  if ! mv -f "$staged" "$PLIST"; then
    rm -f "$staged"
    if [ -n "$backup" ] && [ -f "$backup" ]; then
      if ! restore_service_plist "$backup"; then
        echo "failed to install LaunchAgent plist" >&2
        return 1
      fi
    fi
    echo "failed to install LaunchAgent plist" >&2
    return 1
  fi
  if ! launchctl bootstrap "$gui" "$PLIST"; then
    if [ -n "$backup" ] && [ -f "$backup" ]; then
      if ! restore_service_plist "$backup"; then
        echo "failed to load LaunchAgent ${LABEL}" >&2
        return 1
      fi
    else
      rm -f "$PLIST"
    fi
    echo "failed to load LaunchAgent ${LABEL}" >&2
    return 1
  fi
  rm -f "$backup"
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

# Prepare + lint LaunchAgent BEFORE live rm/mv so a bad plist cannot replace
# a working daemon payload. Staged file lives under WORKDIR (EXIT trap).
STAGED_PLIST=""
if [ "$NO_SERVICE" != "1" ]; then
  require_python3
  STAGED_PLIST="$WORKDIR/LaunchAgent.plist.staged"
  rm -f "$STAGED_PLIST"
  if ! write_plist "$STAGED_PLIST"; then
    rm -f "$STAGED_PLIST"
    echo "failed to write LaunchAgent plist" >&2
    exit 1
  fi
  if ! plutil -lint "$STAGED_PLIST" >/dev/null; then
    rm -f "$STAGED_PLIST"
    echo "invalid LaunchAgent plist for prefix: $PREFIX_ABS" >&2
    exit 1
  fi
fi

# Live payload swap — only after plist prepare/lint succeeded (or --no-service).
rm -rf "$PREFIX/libexec/macker" "$PREFIX/share/macker"
for path in libexec/macker share/macker bin/macker bin/mackerd; do
  mv -f "$stage/$path" "$PREFIX/$path"
done
chmod 755 "$PREFIX/bin/macker" "$PREFIX/bin/mackerd"
chmod 755 "$PREFIX/libexec/macker/macker" "$PREFIX/libexec/macker/mackerd"
if [ -x "$PREFIX/libexec/macker/macker-helper" ]; then
  chmod 755 "$PREFIX/libexec/macker/macker-helper"
fi

if [ "$NO_SERVICE" != "1" ]; then
  start_service "$STAGED_PLIST"
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
echo "Compose project: macker compose up -d --build (no Docker CLI needed)"
echo "official docker CLI: run 'macker setup', then 'docker --context macker ...' (your active context is not changed)"
echo "uninstall: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash -s -- --uninstall"
