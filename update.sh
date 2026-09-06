#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# 利用者の編集を自動退避・reset しない。個人辞書は Git に渡さない。
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "追跡ファイルに変更があります。変更を整理してから更新してください（自動で消すことはありません）。" >&2
  exit 1
fi
./build.sh --check
git fetch origin
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
if [ -n "$(git ls-files -- dictionary.txt)" ] || [ -n "$(git ls-tree --name-only "$upstream" -- dictionary.txt)" ]; then
  echo "個人辞書が Git の追跡対象にあるため、保護のため更新を止めました。" >&2
  exit 1
fi
git merge --ff-only "$upstream"
./build.sh --restart
echo "更新と起動確認が完了しました。個人辞書・設定は引き継がれています。"
