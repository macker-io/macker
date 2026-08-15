#!/bin/sh
# Keep daemon runtime pins in sync with upstream release tags.
#
#   ./scripts/sync-runtime.sh                         # show pins
#   ./scripts/sync-runtime.sh --check                 # fail if containerization pin ≠ submodule
#   ./scripts/sync-runtime.sh containerization 0.42.0
#   ./scripts/sync-runtime.sh kata 3.28.0
#   ./scripts/sync-runtime.sh --latest                # both → GitHub latest stable
#   ./scripts/sync-runtime.sh --latest containerization
#   ./scripts/sync-runtime.sh --latest kata
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$ROOT/daemon/Sources/ContainerEngine/RuntimePin.json"
SUB="$ROOT/daemon/Vendor/containerization"
MODULES="$ROOT/.gitmodules"
CONTAINERIZATION_REPO="https://github.com/apple/containerization.git"
KATA_REPO="https://github.com/kata-containers/kata-containers.git"

usage() {
  echo "usage: $0 [--check] [--latest] [containerization|kata] [<version>]" >&2
}

pin_field() {
  python3 -c "import json; print(json.load(open(r'''$PIN'''))['$1'])"
}

submodule_tag() {
  git -C "$SUB" describe --tags --exact-match HEAD 2>/dev/null \
    || git -C "$SUB" describe --tags --always HEAD 2>/dev/null \
    || echo "missing"
}

write_pin_field() {
  python3 - "$PIN" "$1" "$2" <<'PY'
import json
import sys

path, field, version = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data[field] = version
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

write_gitmodules_comment() {
  python3 - "$MODULES" "$1" <<'PY'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
updated, count = re.subn(
    r"(# Pinned to release tag )[^\s]+",
    rf"\g<1>{version}",
    text,
    count=1,
)
if count == 0:
    sys.exit("could not find the pin comment in .gitmodules")
open(path, "w", encoding="utf-8").write(updated)
PY
}

normalize_tag() {
  version="$1"
  version="${version#refs/tags/}"
  version="${version#v}"
  printf '%s\n' "$version"
}

latest_from_api() {
  owner_repo="$1"
  python3 - "$owner_repo" <<'PY'
import json
import sys
import urllib.request

owner_repo = sys.argv[1]
url = f"https://api.github.com/repos/{owner_repo}/releases/latest"
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        data = json.load(response)
except Exception as error:
    sys.stderr.write(f"GitHub API failed for {owner_repo}: {error}\n")
    sys.exit(1)
tag = data.get("tag_name") or ""
if tag.startswith("v"):
    tag = tag[1:]
if not tag:
    sys.exit(f"no latest tag for {owner_repo}")
print(tag)
PY
}

latest_from_git() {
  repo="$1"
  git ls-remote --tags --refs "$repo" \
    | awk '{print $2}' \
    | sed 's|refs/tags/||; s|^v||' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -1
}

latest_tag() {
  component="$1"
  case "$component" in
    containerization)
      latest_from_api apple/containerization || latest_from_git "$CONTAINERIZATION_REPO"
      ;;
    kata)
      latest_from_api kata-containers/kata-containers || latest_from_git "$KATA_REPO"
      ;;
    *)
      echo "unknown component: $component" >&2
      exit 1
      ;;
  esac
}

require_submodule() {
  if [ ! -d "$SUB/.git" ] && [ ! -f "$SUB/.git" ]; then
    echo "missing submodule at $SUB — run: git submodule update --init" >&2
    exit 1
  fi
}

show_status() {
  pinned_cz="$(pin_field containerization)"
  pinned_kata="$(pin_field kata)"
  checked_out="$(submodule_tag)"
  echo "containerization pin:       $pinned_cz"
  echo "containerization submodule: $checked_out"
  echo "kata pin:                   $pinned_kata"
  if [ "$pinned_cz" = "$checked_out" ]; then
    echo "status:                     in sync"
    return 0
  fi
  echo "status:                     containerization out of sync"
  return 1
}

apply_containerization() {
  version="$(normalize_tag "$1")"
  echo "syncing containerization → $version"
  write_pin_field containerization "$version"
  write_gitmodules_comment "$version"
  git -C "$SUB" fetch --tags --force
  if ! git -C "$SUB" rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    echo "tag $version not found in $SUB" >&2
    exit 1
  fi
  git -C "$SUB" checkout --detach "refs/tags/$version"
  echo "updated $PIN"
  echo "updated $MODULES"
  echo "checked out $SUB @ $version"
}

apply_kata() {
  version="$(normalize_tag "$1")"
  echo "syncing kata → $version"
  write_pin_field kata "$version"
  echo "updated $PIN"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ ! -f "$PIN" ]; then
  echo "missing $PIN" >&2
  exit 1
fi

require_submodule

if [ $# -eq 0 ]; then
  show_status || true
  exit 0
fi

if [ "$1" = "--check" ]; then
  if ! show_status; then
    echo "containerization pin and submodule tag differ" >&2
    exit 1
  fi
  exit 0
fi

LATEST=0
if [ "$1" = "--latest" ]; then
  LATEST=1
  shift
fi

COMPONENT="${1:-}"
VERSION="${2:-}"

if [ "$LATEST" -eq 1 ]; then
  case "$COMPONENT" in
    "")
      apply_containerization "$(latest_tag containerization)"
      apply_kata "$(latest_tag kata)"
      ;;
    containerization|kata)
      if [ -n "$VERSION" ]; then
        usage
        exit 1
      fi
      "apply_$COMPONENT" "$(latest_tag "$COMPONENT")"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  echo "commit RuntimePin.json, .gitmodules, and the submodule gitlink when ready"
  exit 0
fi

case "$COMPONENT" in
  containerization|kata)
    if [ -z "$VERSION" ]; then
      echo "missing version (or use --latest $COMPONENT)" >&2
      usage
      exit 1
    fi
    "apply_$COMPONENT" "$VERSION"
    echo "commit RuntimePin.json, .gitmodules, and the submodule gitlink when ready"
    ;;
  *)
    usage
    exit 1
    ;;
esac
