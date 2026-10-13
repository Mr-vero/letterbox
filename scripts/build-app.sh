#!/bin/zsh
# Builds Letterbox.app into ./build
#   scripts/build-app.sh            # native architecture
#   UNIVERSAL=1 scripts/build-app.sh  # arm64 + x86_64
#   VERSION=1.2.0 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)
APP=build/Letterbox.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Letterbox" "$APP/Contents/MacOS/Letterbox"

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Letterbox</string>
  <key>CFBundleDisplayName</key><string>Letterbox</string>
  <key>CFBundleIdentifier</key><string>io.github.mr-vero.letterbox</string>
  <key>CFBundleExecutable</key><string>Letterbox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP" >/dev/null
echo "Built $APP ($VERSION)"
