#!/bin/bash
# build.sh から読み込む。テストではプロセス操作だけ差し替える。
stop_app() {
  pkill -x nobetsu 2>/dev/null || true
  # 終了要求を送っただけで入れ替えると LaunchServices が旧プロセスを参照する。
  local attempt
  for ((attempt=0; attempt<40; attempt++)); do
    if ! app_is_running; then return 0; fi
    sleep 0.25
  done
  echo "アプリの終了を確認できませんでした。" >&2
  return 1
}
start_app() { open -n "$1"; }
app_is_running() { pgrep -x nobetsu >/dev/null; }
verify_app() { codesign --verify --deep --strict "$1"; }
wait_for_app() {
  local marker="$1" attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if grep -Fq "bootstrap: ready build=$marker" "$HOME/Library/Logs/nobetsu.log" 2>/dev/null && app_is_running; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

install_app() (
  set -euo pipefail
  source="$1" installed="$2" restart="$3" marker="$4"
  previous=0 replaced=0 was_running=0 committed=0
  stage="$(mktemp -d "$(dirname "$installed")/.nobetsu-update.XXXXXX")"
  app_is_running && was_running=1
  cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if [ "$committed" = 0 ]; then
      if [ "$replaced" = 1 ]; then
        if ! stop_app; then
          echo "更新を中止しましたが、新しいアプリを終了できないため復元できません。" >&2
          if [ "$previous" = 1 ]; then
            echo "アプリを終了してから旧版を戻してください。退避先を残します: $stage/previous.app" >&2
          else
            echo "設置したアプリを残します: $installed" >&2
          fi
          exit 1
        fi
        if ! rm -rf "$installed"; then
          echo "新しいアプリを取り除けないため復元できません。退避先を残します: $stage" >&2
          exit 1
        fi
      fi
      if [ "$previous" = 1 ]; then
        if ! mv "$stage/previous.app" "$installed"; then
          echo "旧アプリの復元に失敗しました。退避先を残します: $stage/previous.app" >&2
          exit 1
        fi
        if [ "$was_running" = 1 ] && ! start_app "$installed"; then
          echo "旧アプリを戻しましたが、再起動できませんでした: $installed" >&2
        fi
        echo "更新を中止し、旧アプリへ戻しました。" >&2
      fi
    fi
    if ! rm -rf "$stage"; then
      echo "更新用の一時フォルダを削除できませんでした: $stage" >&2
      exit 1
    fi
    exit "$status"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # コピー・署名検証が済むまで旧アプリを止めない。
  ditto "$source" "$stage/new.app"
  verify_app "$stage/new.app"
  stop_app
  if [ -e "$installed" ]; then
    mv "$installed" "$stage/previous.app"
    previous=1
  fi
  mv "$stage/new.app" "$installed"
  replaced=1
  if [ "$restart" = 1 ]; then
    start_app "$installed"
    if ! wait_for_app "$marker"; then
      echo "新しい版の起動・キー監視を確認できませんでした。" >&2
      exit 1
    fi
  fi
  committed=1
)
