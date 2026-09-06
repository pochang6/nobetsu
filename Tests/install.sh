#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/install-app.sh
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
stop_app() { :; }
start_app() { [ "$FAILURE" != start ]; }
app_is_running() { return 0; }
verify_app() { [ "$FAILURE" != verify ]; }
wait_for_app() { [ "$FAILURE" != wait ]; }
ditto() { [ "$FAILURE" != copy ] && cp -R "$1" "$2"; }
mv() {
  if [ "$FAILURE" = move ] && [[ "$1" = */new.app ]]; then return 1; fi
  command mv "$@"
}
for FAILURE in copy verify move start wait success; do
  source_app="$TEST_DIR/$FAILURE-source.app"
  destination="$TEST_DIR/$FAILURE.app"
  mkdir "$source_app" "$destination"
  echo new > "$source_app/version"
  echo old > "$destination/version"
  # 別プロセスにして、if の条件内で errexit が無効になる Bash の挙動を避ける。
  export FAILURE
  export -f install_app stop_app start_app app_is_running verify_app wait_for_app ditto mv
  if bash -c 'install_app "$1" "$2" 1 fixture' _ "$source_app" "$destination"; then
    [ "$FAILURE" = success ]
    [ "$(cat "$destination/version")" = new ]
  else
    [ "$FAILURE" != success ]
    [ "$(cat "$destination/version")" = old ]
  fi
done
echo '✅ コピー・署名・入れ替え・起動・起動確認の失敗時に旧版を保持（6シナリオ）'
