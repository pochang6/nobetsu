#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT="$PWD"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
git init -q --bare "$FIXTURE/remote.git"
git init -q -b main "$FIXTURE/author"
cd "$FIXTURE/author"
git config user.name 'Update Test'
git config user.email 'update-test@example.invalid'
git remote add origin "$FIXTURE/remote.git"
cp "$PROJECT/update.sh" .
cat > build.sh <<'SH'
#!/bin/bash
set -eu
case "${1:-}" in --check|--restart) exit 0 ;; *) exit 1 ;; esac
SH
chmod +x build.sh
echo '/dictionary.txt' > .gitignore
echo original > README.md
git add .gitignore README.md build.sh update.sh
git commit -qm original
git push -q -u origin main
git --git-dir="$FIXTURE/remote.git" symbolic-ref HEAD refs/heads/main
git clone -q "$FIXTURE/remote.git" "$FIXTURE/user"
echo '独自語彙 => Preserved' > "$FIXTURE/user/dictionary.txt"
echo updated > README.md
git add README.md
git commit -qm update
git push -q
(cd "$FIXTURE/user" && ./update.sh >/dev/null)
[ "$(cat "$FIXTURE/user/dictionary.txt")" = '独自語彙 => Preserved' ]
[ "$(cat "$FIXTURE/user/README.md")" = updated ]
[ -z "$(git -C "$FIXTURE/user" ls-files -- dictionary.txt)" ]

# 上流が誤って個人辞書を追跡した場合も、取り込む前に拒否する。
echo 'public fixture' > dictionary.txt
git add -f dictionary.txt
git commit -qm 'unsafe fixture'
git push -q
if (cd "$FIXTURE/user" && ./update.sh >/dev/null 2>&1); then
  echo '❌ 個人辞書を追跡する上流を拒否できませんでした' >&2
  exit 1
fi
[ "$(cat "$FIXTURE/user/dictionary.txt")" = '独自語彙 => Preserved' ]
[ -z "$(git -C "$FIXTURE/user" ls-files -- dictionary.txt)" ]
echo '✅ pullによる個人辞書の保持・危険な追跡の拒否（2シナリオ）'
