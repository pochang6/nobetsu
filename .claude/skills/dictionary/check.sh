#!/bin/bash
set -euo pipefail

# 辞書全体を点検する（辞書スキルのレベル3）。
#
#   .claude/skills/dictionary/check.sh                  dictionary.txt を見る
#   .claude/skills/dictionary/check.sh --on メモ.txt     その文章に当てて差分を見る
#
# アプリと同じ PhraseBook を呼びます。ここだけ別実装にすると、
# 通ったのに本番で壊れる、という一番たちの悪い形になります。

cd "$(dirname "$0")/../../.."

SDK="$(xcrun --show-sdk-path)"
HERE=".claude/skills/dictionary/check"
OUT="$(mktemp -d)/dictcheck"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -sdk "$SDK" \
  -framework AppKit \
  Sources/Phrases.swift \
  Sources/Log.swift \
  "$HERE/Check.swift" \
  -o "$OUT"

"$OUT" "$@"
