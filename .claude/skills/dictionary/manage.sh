#!/bin/bash
set -euo pipefail

# 辞書を検索・upsert・置換・削除する、辞書スキルの唯一の編集入口。
# 実際の変更は左辺の完全一致に限り、曖昧検索は候補の表示だけに使う。

cd "$(dirname "$0")/../../.."

SDK="$(xcrun --show-sdk-path)"
HERE=".claude/skills/dictionary/manage"
OUT="$(mktemp -d)/dictionary-manage"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -sdk "$SDK" \
  -framework AppKit \
  Sources/Phrases.swift \
  Sources/DictionaryEditor.swift \
  Sources/Log.swift \
  "$HERE/Manage.swift" \
  -o "$OUT"

"$OUT" "$@"
