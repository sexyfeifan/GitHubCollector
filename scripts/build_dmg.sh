#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-}"

if [ -z "$OUT_DIR" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  OUT_DIR="$ROOT_DIR/dist/$TS"
fi

BUILD_CACHE_DIR="$ROOT_DIR/.build-cache"
CLANG_CACHE_DIR="$ROOT_DIR/.clang-cache"
APP_NAME="GitHubCollector"
APP_DIR="$OUT_DIR/${APP_NAME}.app"
DMG_STAGE_DIR="$OUT_DIR/dmg-root"
DMG_PATH="$OUT_DIR/${APP_NAME}.dmg"
SOURCE_TAR_PATH="$OUT_DIR/${APP_NAME}-source.tar.gz"

mkdir -p "$OUT_DIR" "$BUILD_CACHE_DIR" "$CLANG_CACHE_DIR"

cd "$ROOT_DIR"
SWIFTPM_ENABLE_PLUGINS=0 \
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR" \
swift build -c release

rm -rf "$APP_DIR" "$DMG_STAGE_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DMG_STAGE_DIR"

cp ".build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>GitHubCollector</string>
  <key>CFBundleDisplayName</key>
  <string>GitHubCollector</string>
  <key>CFBundleExecutable</key>
  <string>GitHubCollector</string>
  <key>CFBundleIdentifier</key>
  <string>com.sexyfeifan.GitHubCollector</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
PLIST

cp -R "$APP_DIR" "$DMG_STAGE_DIR/"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

tar \
  --exclude=.git \
  --exclude=.build \
  --exclude=.build-cache \
  --exclude=.clang-cache \
  --exclude=dist \
  --exclude=.DS_Store \
  -czf "$SOURCE_TAR_PATH" \
  -C "$ROOT_DIR" .

echo "OUT_DIR=$OUT_DIR"
echo "DMG_PATH=$DMG_PATH"
echo "SOURCE_TAR_PATH=$SOURCE_TAR_PATH"
