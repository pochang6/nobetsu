#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="nobetsu"
BUNDLE_ID="dev.pochang6.nobetsu"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
MODE="${1:-}"
case "$MODE" in
  ""|--check|--build-only|--restart) ;;
  *) echo "使い方: ./build.sh [--check|--build-only|--restart]" >&2; exit 2 ;;
esac
BUILD_ID="$(uuidgen)"

# macOS の許可（入力監視 / アクセシビリティ）は、署名の同一性に紐づいて記録される。
# アドホック署名にはその同一性が無いため、ビルドのたびに別アプリ扱いになり、
# 入力監視にいたっては尋ねられることすらなく拒否される。
#
# つまりアドホック署名のアプリは「ビルドは通るが、使えない」。
# 黙って /Applications へ置くと、利用者は動かない理由に一切たどり着けない。
# 実際、会社の Mac へ移したときに丸一日これで溶けた。だから**置く前に止める**。
IDENTITY="nobetsu"
ALLOW_ADHOC="${NOBETSU_ALLOW_ADHOC:-0}"

certificate_help() {
  cat <<'MSG'
  自己署名の証明書を1つ作れば、この問題はまるごと消えます（1回だけの作業です）。

    1. 「キーチェーンアクセス」を開く
    2. メニューの「キーチェーンアクセス」>「証明書アシスタント」>「自分に証明書を作成」
    3. 名前            : nobetsu
       固有名のタイプ  : 自己署名ルート
       証明書のタイプ  : コード署名
    4. 作った証明書をダブルクリック >「信頼」>「コード署名」を「常に信頼」にする
    5. ./build.sh をやり直す（パスワードを聞かれたら「常に許可」を選ぶ）

  詳しくは README の「ソースからビルドする前に」を参照してください。
MSG
}

# 署名できるかどうかは、**実際に署名して**確かめる。
#
# security find-identity -v -p codesigning が 0 件を返すのに
# codesign --sign nobetsu は通る、という食い違いを実際に見た（信頼設定の差）。
# 知りたいのは「一覧に出るか」ではなく「署名できるか」なので、一覧は当てにしない。
SIGN_PROBE_ERROR=""
can_sign_with_identity() {
  local dir probe status
  dir="$(mktemp -d)"
  probe="$dir/probe"
  cp /bin/echo "$probe"   # 署名できる形（Mach-O）であれば中身は何でもよい
  # codesign の言い分はそのまま残す。「証明書が無い」のか「同じ名前が2枚あって選べない」のかで、
  # やることが違う。握りつぶすと、また推測で時間を溶かすことになる
  if SIGN_PROBE_ERROR="$(codesign --force --sign "$IDENTITY" --timestamp=none "$probe" 2>&1)"; then
    status=0
  else
    status=1
  fi
  rm -rf "$dir"
  return $status
}

# 署名した結果がアドホックになっていないか。codesign は adhoc のとき Signature=adhoc と言う
is_adhoc() {
  codesign -dv "$1" 2>&1 | grep -q "Signature=adhoc"
}

# ビルドせずに署名の可否だけ見る。rebuild スキルが最初に叩く
if [ "${1:-}" = "--check" ]; then
  if can_sign_with_identity; then
    echo "✅ 証明書「${IDENTITY}」で署名できます。許可はやり直しになりません"
    exit 0
  fi
  echo "❌ 証明書「${IDENTITY}」で署名できません。このままビルドしても許可が下りません"
  echo "   codesign の言い分: ${SIGN_PROBE_ERROR:-（なし）}"
  echo
  certificate_help
  exit 1
fi

# ビルドしてから止めても時間の無駄なので、いちばん先に見る
if can_sign_with_identity; then
  SIGNABLE=1
else
  SIGNABLE=0
  if [ "$ALLOW_ADHOC" != "1" ]; then
    echo "✋ 中止しました: 証明書「${IDENTITY}」で署名できません" >&2
    echo "   codesign の言い分: ${SIGN_PROBE_ERROR:-（なし）}" >&2
    echo >&2
    echo "  このままビルドするとアドホック署名になり、macOS の入力監視が" >&2
    echo "  「ダイアログすら出ずに拒否」されます。⌘ の長押しに一切反応しない" >&2
    echo "  アプリが /Applications に残るだけなので、設置する前に止めました。" >&2
    echo >&2
    certificate_help >&2
    echo >&2
    echo "  署名を諦めて、コンパイルが通ることだけ確かめたい場合はこちら（設置もされます）:" >&2
    echo >&2
    echo "    NOBETSU_ALLOW_ADHOC=1 ./build.sh" >&2
    echo >&2
    exit 1
  fi
  echo "⚠️  NOBETSU_ALLOW_ADHOC=1: アドホック署名で続行します（許可は下りません）"
fi

# 同時更新で辞書の引き継ぎやアプリの退避先が競合しないようにする。
LOCK="/tmp/nobetsu-install-$(id -u).lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "別の更新が進行中です。終了を待ってからやり直してください: $LOCK" >&2
  exit 1
fi
trap 'rmdir "$LOCK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
  <key>NobetsuBuildID</key><string>$BUILD_ID</string>
  <key>NobetsuDictionaryLayout</key><string>external-v1</string>
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

# 個人の語彙はアプリへ入れない。既存辞書の保護は設置直前に別途行う。
cp dictionary.sample.txt "$APP/Contents/Resources/dictionary.txt"
echo "==> dictionary: 公開サンプルのみ"

if [ "$SIGNABLE" = "1" ]; then
  echo "==> signing ($IDENTITY)"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
  # 署名できたはずが adhoc になっていたら、設置しても動かない。ここで止める
  if is_adhoc "$APP"; then
    echo "✋ 中止しました: 署名が adhoc になっています（証明書「${IDENTITY}」を確かめてください）" >&2
    echo "   ビルドしたものは $APP に残してあります（設置はしていません）" >&2
    exit 1
  fi
else
  echo "==> signing (ad-hoc / NOBETSU_ALLOW_ADHOC=1)"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

if [ "$MODE" = "--build-only" ]; then
  echo "==> built: $(pwd)/${APP}（設置・個人辞書へのアクセスなし）"
  exit 0
fi

INSTALLED="/Applications/$APP_NAME.app"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 -sdk "$SDK" \
  Sources/DictionaryStorage.swift Tools/PrepareDictionary.swift -o "$BUILD_DIR/prepare-dictionary"
"$BUILD_DIR/prepare-dictionary" "$(pwd)/dictionary.txt" \
  "$INSTALLED/Contents/Resources/dictionary.txt" "$(pwd)/dictionary.sample.txt"

source scripts/install-app.sh
RESTART=0
[ "$MODE" = "--restart" ] && RESTART=1
install_app "$APP" "$INSTALLED" "$RESTART" "$BUILD_ID"

echo "==> built:     $(pwd)/$APP"
echo "==> installed: $INSTALLED"
echo
if [ "$SIGNABLE" = "1" ]; then
  echo "起動するには: open \"$INSTALLED\""
else
  echo "⚠️  アドホック署名です。入力監視の許可は下りないため、⌘ の長押しには反応しません。"
  echo "   実際に使うには、証明書「${IDENTITY}」を作って ./build.sh をやり直してください。"
  echo
  certificate_help
fi
