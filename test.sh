#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# 副作用を持たない部分だけを取り出して確かめる。
# マイクもイベントタップも他アプリへの打ち込みも使わないので、
# アプリを起動せずに走ります。App.swift を含めないのは @main が衝突するため
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d)/nobetsu-tests"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -sdk "$SDK" \
  -framework AppKit -framework Carbon \
  Sources/Phrases.swift \
  Sources/DictionaryEditor.swift \
  Sources/PermissionAdvice.swift \
  Sources/Injector.swift \
  Sources/Trigger.swift \
  Sources/Log.swift \
  Tests/main.swift \
  -o "$OUT"

"$OUT"
