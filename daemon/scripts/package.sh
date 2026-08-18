#!/bin/sh
# Release packaging.
#   VERSION=1.2.3 ./scripts/package.sh        # dist/MackerDaemon.app
#   VERSION=1.2.3 ./scripts/package.sh pkg    # .app + dist/MackerDaemon.pkg
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$DAEMON_ROOT"

MODE="${1:-app}"
case "$MODE" in
  app|pkg) ;;
  *)
    echo "usage: $0 [app|pkg]" >&2
    exit 1
    ;;
esac

VERSION="$(product_version)"
CONTAINERIZATION="$(pin_field containerization)"

swift build --product App -c release
swift build --product macker -c release
swift build --product macker-helper -c release
BIN_DIR="$(swift_bin_dir release)"
APP_BIN="$BIN_DIR/App"
CLI_BIN="$BIN_DIR/macker"
HELPER_BIN="$BIN_DIR/macker-helper"

if ! is_regular_file .runtime/vmlinux || ! is_regular_file .runtime/initfs.ext4; then
  ./scripts/fetch-runtime.sh .runtime
fi

APP="dist/MackerDaemon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"

cp "$APP_BIN" "$APP/Contents/MacOS/mackerd"
cp "$CLI_BIN" "$APP/Contents/MacOS/macker"
cp "$HELPER_BIN" "$APP/Contents/MacOS/macker-helper"
cp .runtime/vmlinux .runtime/initfs.ext4 "$APP/Contents/Resources/runtime/"
cp "$PIN" "$APP/Contents/Resources/runtime/RuntimePin.json"

# SPM resource bundles (RuntimePin.json via Bundle.module) live next to the binary.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>mackerd</string>
	<key>CFBundleIdentifier</key>
	<string>io.macker.daemon</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Macker</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

sign_bin "$APP/Contents/MacOS/mackerd" "$ENTITLEMENTS"
sign_bin "$APP/Contents/MacOS/macker"
sign_bin "$APP/Contents/MacOS/macker-helper"
codesign --force --sign - --timestamp=none --entitlements="$ENTITLEMENTS" "$APP"
echo "app $APP ($VERSION, containerization $CONTAINERIZATION)"

if [ "$MODE" = "pkg" ]; then
  mkdir -p dist
  pkgbuild \
    --component "$APP" \
    --install-location /Applications \
    --identifier io.macker.daemon \
    --version "$VERSION" \
    dist/MackerDaemon.pkg
  echo "pkg dist/MackerDaemon.pkg ($VERSION)"
fi
