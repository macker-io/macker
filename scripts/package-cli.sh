#!/bin/sh
# CLI prefix layout used by `make dist` and `scripts/install.sh`.
#   ./scripts/package-cli.sh            # dist/cli
#   ./scripts/package-cli.sh archive    # tarball + sha256 (needs dist/cli)
#   ./scripts/package-cli.sh dist       # prefix + archive
#   ./scripts/package-cli.sh install    # copy dist/cli → $DESTDIR$PREFIX
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$DAEMON_ROOT"

MODE="${1:-prefix}"
case "$MODE" in
prefix | archive | dist | install) ;;
*)
  echo "usage: $0 [prefix|archive|dist|install]" >&2
  exit 1
  ;;
esac

if [ "$(uname -m)" != "arm64" ]; then
  echo "CLI packages are Apple Silicon only (got $(uname -m))" >&2
  exit 1
fi

VERSION="$(product_version)"
CONTAINERIZATION="$(pin_field containerization)"
PREFIX_ROOT="$DAEMON_ROOT/dist/cli"
LIBEXEC="$PREFIX_ROOT/libexec/macker"
BIN_WRAP="$PREFIX_ROOT/bin"
SHARE="$PREFIX_ROOT/share/macker"
RUNTIME="$SHARE/runtime"
TARBALL_NAME="macker-${VERSION}-darwin-arm64.tar.gz"

write_wrapper() {
  dest="$1"
  target="$2"
  cat >"$dest" <<EOF
#!/bin/sh
bindir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
exec "\$bindir/../libexec/macker/${target}" "\$@"
EOF
  chmod 755 "$dest"
}

write_plist() {
  cat >"$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>io.macker.daemon</string>
	<key>ProgramArguments</key>
	<array>
		<string>@PREFIX@/libexec/macker/mackerd</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF
}

build_prefix() {
  swift build --product mackerd -c release
  swift build --product macker -c release
  swift build --product macker-helper -c release
  BIN_DIR="$(swift_bin_dir release)"

  if ! is_regular_file .runtime/vmlinux || ! is_regular_file .runtime/initfs.ext4; then
    ./scripts/fetch-runtime.sh .runtime
  fi

  rm -rf "$PREFIX_ROOT"
  mkdir -p "$LIBEXEC" "$BIN_WRAP" "$RUNTIME" "$SHARE/launchd"

  cp "$BIN_DIR/mackerd" "$LIBEXEC/mackerd"
  cp "$BIN_DIR/macker" "$LIBEXEC/macker"
  cp "$BIN_DIR/macker-helper" "$LIBEXEC/macker-helper"
  chmod 755 "$LIBEXEC/mackerd" "$LIBEXEC/macker" "$LIBEXEC/macker-helper"

  for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    name="$(basename "$bundle")"
    case "$name" in
    *Tests* | *xctest*) continue ;;
    esac
    cp -R "$bundle" "$LIBEXEC/"
  done

  cp .runtime/vmlinux .runtime/initfs.ext4 "$RUNTIME/"
  if [ -n "${MACKER_K3S_KERNEL:-}" ]; then
    cp "$MACKER_K3S_KERNEL" "$RUNTIME/vmlinux-k3s"
  fi
  cp "$PIN" "$RUNTIME/RuntimePin.json"
  cp "$ENTITLEMENTS" "$SHARE/mackerd.entitlements"
  printf '%s\n' "$VERSION" >"$SHARE/VERSION"
  cp "$REPO_ROOT/LICENSE" "$PREFIX_ROOT/LICENSE"

  write_wrapper "$BIN_WRAP/macker" macker
  write_wrapper "$BIN_WRAP/mackerd" mackerd
  write_plist "$SHARE/launchd/io.macker.daemon.plist.in"

  ./scripts/stage-compose-tools.sh "$LIBEXEC/compose-tools"
  cp "$REPO_ROOT/scripts/compose-NOTICE" "$SHARE/compose-NOTICE"
  cp "$REPO_ROOT/LICENSE" "$SHARE/compose-LICENSE"
  ./scripts/stage-kubectl.sh "$LIBEXEC/k3s-tools"
  cp "$REPO_ROOT/LICENSE" "$SHARE/kubectl-LICENSE"
  cp "$REPO_ROOT/scripts/kubectl-NOTICE" "$SHARE/kubectl-NOTICE"

  sign_macho_tree "$LIBEXEC"
  echo "signed libexec with $(sign_identity)"

  echo "cli $PREFIX_ROOT ($VERSION, containerization $CONTAINERIZATION)"
}

require_prefix() {
  if [ ! -x "$LIBEXEC/mackerd" ] || [ ! -x "$LIBEXEC/macker" ]; then
    echo "CLI prefix missing; run: $0 prefix" >&2
    exit 1
  fi
}

archive_prefix() {
  require_prefix
  mkdir -p "$DAEMON_ROOT/dist"
  tarball="$DAEMON_ROOT/dist/$TARBALL_NAME"
  tar -C "$PREFIX_ROOT" -czf "$tarball" \
    LICENSE bin libexec share
  (
    cd "$DAEMON_ROOT/dist"
    shasum -a 256 "$TARBALL_NAME" >SHA256SUMS
  )
  sha="$(awk '{ print $1; exit }' "$DAEMON_ROOT/dist/SHA256SUMS")"
  if [ "${NOTARIZE:-}" = "1" ]; then
    ./scripts/notarize-cli.sh
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "tarball=dist/$TARBALL_NAME" >>"$GITHUB_OUTPUT"
  fi
  echo "dist $tarball"
  echo "sha256 $sha"
}

install_prefix() {
  require_prefix
  dest="${DESTDIR-}${PREFIX:-/usr/local}"
  mkdir -p "$dest/bin" "$dest/libexec" "$dest/share"
  cp -R "$PREFIX_ROOT/bin/macker" "$PREFIX_ROOT/bin/mackerd" "$dest/bin/"
  rm -rf "$dest/libexec/macker"
  cp -R "$PREFIX_ROOT/libexec/macker" "$dest/libexec/"
  rm -rf "$dest/share/macker"
  cp -R "$PREFIX_ROOT/share/macker" "$dest/share/"
  plist_in="$dest/share/macker/launchd/io.macker.daemon.plist.in"
  plist_out="$dest/share/macker/launchd/io.macker.daemon.plist"
  python3 - "$plist_in" "$plist_out" "${PREFIX:-/usr/local}" <<'PY'
import pathlib, sys
src, dest, prefix = sys.argv[1:]
pathlib.Path(dest).write_text(pathlib.Path(src).read_text().replace("@PREFIX@", prefix))
PY
  echo "install $dest"
  echo "LaunchAgent template: $plist_out"
  echo "Start: launchctl bootstrap gui/$(id -u) $plist_out"
}

case "$MODE" in
prefix) build_prefix ;;
archive) archive_prefix ;;
dist)
  build_prefix
  archive_prefix
  ;;
install) install_prefix ;;
esac
