#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/install-app.sh
TEST_DIR="$(mktemp -d)"
trap 'command rm -rf "$TEST_DIR"' EXIT
# stop_app 自体は本番を使う。プロセス操作と待ち時間だけ模擬する。
pkill() { STOP_REQUESTED=1; }
sleep() { :; }
start_app() { STOP_REQUESTED=0; [ "$FAILURE" != start ]; }
app_is_running() {
  [ "${STOP_REQUESTED:-0}" != 1 ] || [ "$FAILURE" = stop ] ||
    { [ "$FAILURE" = rollback-stop ] && [ "${replaced:-0}" = 1 ]; }
}
verify_app() { [ "$FAILURE" != verify ]; }
wait_for_app() {
  case "$FAILURE" in wait|rollback-stop|remove|restore) return 1;; esac
}
ditto() { [ "$FAILURE" != copy ] && cp -R "$1" "$2"; }
mv() {
  if [ "$FAILURE" = move ] && [[ "$1" = */new.app ]]; then return 1; fi
  if [ "$FAILURE" = restore ] && [[ "$1" = */previous.app ]]; then return 1; fi
  command mv "$@"
}
rm() {
  if [ "$FAILURE" = remove ] && [ "$2" = "$installed" ]; then return 1; fi
  command rm "$@"
}
for FAILURE in copy verify stop move start wait rollback-stop remove restore success; do
  case_dir="$TEST_DIR/$FAILURE"
  mkdir "$case_dir"
  source_app="$case_dir/source.app"
  destination="$case_dir/installed.app"
  mkdir "$source_app" "$destination"
  echo new > "$source_app/version"
  echo old > "$destination/version"
  # 別プロセスにして、if の条件内で errexit が無効になる Bash の挙動を避ける。
  export FAILURE
  export -f install_app stop_app pkill sleep start_app app_is_running verify_app wait_for_app ditto mv rm
  if bash -c 'install_app "$1" "$2" 1 fixture' _ "$source_app" "$destination" >"$case_dir/output" 2>&1; then
    [ "$FAILURE" = success ]
    [ "$(cat "$destination/version")" = new ]
  else
    [ "$FAILURE" != success ]
    case "$FAILURE" in
      rollback-stop|remove|restore)
        backup=("$case_dir"/.nobetsu-update.*/previous.app)
        [ "${#backup[@]}" = 1 ]
        [ "$(cat "${backup[0]}/version")" = old ]
        grep -Fq "退避先を残します:" "$case_dir/output"
        grep -Fq "${backup[0]%/previous.app}" "$case_dir/output"
        if [ "$FAILURE" = restore ]; then
          [ ! -e "$destination" ]
        else
          [ "$(cat "$destination/version")" = new ]
        fi
        ! grep -Fq "旧アプリへ戻しました" "$case_dir/output"
        ;;
      *) [ "$(cat "$destination/version")" = old ] ;;
    esac
  fi
  case "$FAILURE" in
    rollback-stop|remove|restore) ;;
    *) [ -z "$(find "$case_dir" -name '.nobetsu-update.*' -print)" ] ;;
  esac
done
echo '✅ 更新失敗時の旧版保持と復元不能時の退避先表示（終了待ちを含む10シナリオ）'
