#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="nobetsu"
BUNDLE_ID="dev.pochang6.nobetsu"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
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

# 辞書はアプリの中へ焼き込む。
# git で管理されるので、複数の Mac で同じ辞書を共有できる。
# その Mac だけの調整は ~/Library/Application Support/nobetsu/dictionary.txt へ書く
# 自分用の dictionary.txt があればそれを、無ければ見本を焼き込む。
# dictionary.txt は .gitignore してある（辞書には仕事の固有名詞が溜まるため）
DICT="dictionary.sample.txt"
[ -f dictionary.txt ] && DICT="dictionary.txt"
if [ -f "$DICT" ]; then
  cp "$DICT" "$APP/Contents/Resources/dictionary.txt"
  echo "==> dictionary: $(grep -cE '^[^#]*(=>|→)' "$DICT") 件 ($DICT)"
fi

# macOS の許可（アクセシビリティ / 入力監視）は、署名の同一性に紐づいて記録される。
# アドホック署名にはその同一性が無いため、ビルドのたびに別アプリ扱いになり、
# 入力監視にいたっては尋ねられることすらなく拒否されることがある。
#
# 自己署名の証明書を1つ作れば同一性が固定され、この問題がまるごと消える。
#
#   作り方: キーチェーンアクセス > 証明書アシスタント > 自分に証明書を作成
#           名前「nobetsu」/ 固有名のタイプ「自己署名ルート」/ 証明書のタイプ「コード署名」
IDENTITY="nobetsu"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "==> signing ($IDENTITY)"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "==> signing (ad-hoc)"
  echo "    警告: 自己署名証明書「$IDENTITY」が見つかりません。"
  echo "    アドホック署名では入力監視の許可が下りない場合があります。README を参照してください。"
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
