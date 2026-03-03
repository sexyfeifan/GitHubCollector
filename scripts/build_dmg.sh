#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-}"
TAG_NAME="${2:-}"

if [ -z "$OUT_DIR" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  OUT_DIR="$ROOT_DIR/dist/$TS"
fi

if [ -z "$TAG_NAME" ] && [ -f "$ROOT_DIR/VERSION" ]; then
  TAG_NAME="v$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
fi

if [ -z "$TAG_NAME" ]; then
  TAG_NAME="$(basename "$OUT_DIR")"
fi

APP_VERSION="${TAG_NAME#v}"
if [ -z "$APP_VERSION" ] || [ "$APP_VERSION" = "$TAG_NAME" ]; then
  if [ -f "$ROOT_DIR/VERSION" ]; then
    APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
  else
    APP_VERSION="1.0.0"
  fi
fi
BUILD_NUMBER="$(echo "$APP_VERSION" | awk -F. '{print $NF}')"
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  BUILD_NUMBER="1"
fi

BUILD_CACHE_DIR="$ROOT_DIR/.build-cache"
CLANG_CACHE_DIR="$ROOT_DIR/.clang-cache"
APP_NAME="GitHubCollector"
ICON_FILE_NAME="GitHubCollector.icns"
ICON_SOURCE_PATH="$ROOT_DIR/Resources/$ICON_FILE_NAME"
APP_DIR="$OUT_DIR/${APP_NAME}.app"
DMG_STAGE_DIR="$OUT_DIR/dmg-root"
DMG_PATH="$OUT_DIR/${APP_NAME}.dmg"
APP_ZIP_PATH="$OUT_DIR/${APP_NAME}.app.zip"
SOURCE_TAR_PATH="$OUT_DIR/${APP_NAME}-source.tar.gz"
ARCHIVE_ROOT="$ROOT_DIR/GitHubCollectorArchive"
ARCHIVE_VERSION_DIR="$ARCHIVE_ROOT/$TAG_NAME"
ARCHIVE_LATEST_DIR="$ARCHIVE_ROOT/latest"

mkdir -p "$OUT_DIR" "$BUILD_CACHE_DIR" "$CLANG_CACHE_DIR"

cd "$ROOT_DIR"
SWIFTPM_ENABLE_PLUGINS=0 \
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR" \
swift build -c release

rm -rf "$APP_DIR" "$DMG_STAGE_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DMG_STAGE_DIR"

cp ".build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
if [ -f "$ICON_SOURCE_PATH" ]; then
  cp "$ICON_SOURCE_PATH" "$APP_DIR/Contents/Resources/$ICON_FILE_NAME"
else
  echo "warning: icon file not found at $ICON_SOURCE_PATH, packaging without custom icon"
fi

cat >"$APP_DIR/Contents/Info.plist" <<PLIST
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
  <key>CFBundleIconFile</key>
  <string>${ICON_FILE_NAME}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
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

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_ZIP_PATH"

tar \
  --exclude=.git \
  --exclude=.build \
  --exclude=.build-cache \
  --exclude=.clang-cache \
  --exclude=dist \
  --exclude=.DS_Store \
  -czf "$SOURCE_TAR_PATH" \
  -C "$ROOT_DIR" .

rm -rf "$ARCHIVE_VERSION_DIR" "$ARCHIVE_LATEST_DIR"
mkdir -p "$ARCHIVE_VERSION_DIR" "$ARCHIVE_LATEST_DIR"

cp "$DMG_PATH" "$ARCHIVE_VERSION_DIR/${APP_NAME}.dmg"
cp "$APP_ZIP_PATH" "$ARCHIVE_VERSION_DIR/${APP_NAME}.app.zip"
cp "$SOURCE_TAR_PATH" "$ARCHIVE_VERSION_DIR/${APP_NAME}-source.tar.gz"
cp -R "$APP_DIR" "$ARCHIVE_VERSION_DIR/${APP_NAME}.app"

cp "$DMG_PATH" "$ARCHIVE_LATEST_DIR/${APP_NAME}.dmg"
cp "$APP_ZIP_PATH" "$ARCHIVE_LATEST_DIR/${APP_NAME}.app.zip"
cp "$SOURCE_TAR_PATH" "$ARCHIVE_LATEST_DIR/${APP_NAME}-source.tar.gz"
cp -R "$APP_DIR" "$ARCHIVE_LATEST_DIR/${APP_NAME}.app"

echo "OUT_DIR=$OUT_DIR"
echo "DMG_PATH=$DMG_PATH"
echo "APP_ZIP_PATH=$APP_ZIP_PATH"
echo "SOURCE_TAR_PATH=$SOURCE_TAR_PATH"
echo "ARCHIVE_VERSION_DIR=$ARCHIVE_VERSION_DIR"
echo "ARCHIVE_LATEST_DIR=$ARCHIVE_LATEST_DIR"
