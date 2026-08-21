#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="nobetsu"
BUNDLE_ID="dev.pochang6.nobetsu"
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
  <key>CFBundleDisplayName</key><string>nobetsu</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>話した内容を文字にするためにマイクを使用します。音声は端末内でのみ処理され、外部には送信されません。</string>
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
  -framework Speech -framework AVFoundation -framework AppKit -framework Carbon \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

# アクセシビリティ権限は署名の同一性に紐づく。アドホック署名だとビルドのたびに
# 署名が変わり、そのつど許可し直しになる。開発用の自己署名証明書があればそれを使う。
#
#   作り方: キーチェーンアクセス > 証明書アシスタント > 自分に証明書を作成
#           名前 "nobetsu-dev" / 証明書のタイプ「コード署名」
if security find-identity -v -p codesigning 2>/dev/null | grep -q "nobetsu-dev"; then
  echo "==> signing (nobetsu-dev)"
  codesign --force --sign "nobetsu-dev" --timestamp=none "$APP"
else
  echo "==> signing (ad-hoc)"
  echo "    ヒント: 自己署名証明書 nobetsu-dev を作ると、ビルドのたびの権限許可し直しがなくなります"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

# システム設定の一覧（アクセシビリティ / 入力監視）は、+ を押すと
# 「アプリケーション」フォルダを開く。リポジトリの中に置いたままだと
# ユーザーはそこから nobetsu を選べない。だから決まった場所に置く。
# パスが固定されることで、許可の登録も安定する。
INSTALLED="/Applications/$APP_NAME.app"
echo "==> installing to $INSTALLED"
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"

echo "==> built:     $(pwd)/$APP"
echo "==> installed: $INSTALLED"
echo
echo "起動するには: open \"$INSTALLED\""
