#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="NobetsuSpike"
BUNDLE_ID="dev.pochang6.nobetsu.spike"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Nobetsu Spike</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>音声入力の精度と遅延を計測するためにマイクを使用します。音声は端末内でのみ処理され、外部に送信されません。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>話した内容をこの Mac 上で文字に変換するために使用します。</string>
</dict>
</plist>
PLIST

echo "==> compiling"
swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos26.0 \
  -sdk "$SDK" \
  -framework Speech -framework AVFoundation -framework AppKit \
  Sources/App.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> built: $(cd "$BUILD_DIR" && pwd)/$APP_NAME.app"
