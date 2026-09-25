#!/bin/bash
# ログイン中の Mac で実行する実機検証。目印を一時表示する。
# 通常の test.sh（アプリを起動しない検証）とは分ける。
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${SDKROOT:-$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk}"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 -sdk "$SDK" \
  -framework AppKit -framework SwiftUI -framework ColorSync \
  Sources/Indicator.swift Sources/IndicatorPlacement.swift Sources/IndicatorScreenPreference.swift \
  Sources/Overlay.swift Tests/IndicatorSpaces.swift -o "$CHECK_DIR/indicator-spaces"
"$CHECK_DIR/indicator-spaces"
