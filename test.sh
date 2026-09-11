#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# 副作用を持たない部分だけを取り出して確かめる。
# マイクもイベントタップも他アプリへの打ち込みも使わないので、
# アプリを起動せずに走ります。App.swift を含めないのは @main が衝突するため
# SDK は -target と同じ版に合わせる（理由は build.sh の SDK の項を参照）
MACOS_MAJOR=26
SDK="${SDKROOT:-$(dirname "$(xcrun --show-sdk-path)")/MacOSX${MACOS_MAJOR}.sdk}"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
TEST_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
OUT="$TEST_BUILD_DIR/nobetsu-tests"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -sdk "$SDK" \
  -framework AppKit -framework Carbon \
  Sources/DictionaryStorage.swift \
  Sources/Phrases.swift \
  Sources/PermissionAdvice.swift \
  Sources/Injector.swift \
  Sources/Trigger.swift \
  Sources/DictationLifecycle.swift \
  Sources/IndicatorPlacement.swift \
  Sources/IndicatorScreenPreference.swift \
  Sources/Log.swift \
  Tests/main.swift Tests/DictionaryStorageTests.swift Tests/PhraseBookTests.swift Tests/IndicatorPlacementTests.swift \
  -o "$OUT"

"$OUT"
bash Tests/install.sh
bash Tests/update.sh
