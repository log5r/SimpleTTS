#!/usr/bin/env bash
# SimpleTTS を起動するスクリプト。
#
#   ./start.sh           ビルド済みのアプリがあればそのまま起動。なければビルドしてから起動。
#   ./start.sh rebuild   clean してからリビルドし、起動。
#
# 環境変数:
#   CONFIGURATION=Release   ビルド構成（既定: Debug）
#   NO_SIGN=1               コード署名なしでビルド（署名用の Apple アカウントがない環境向け）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PROJECT="SimpleTTS.xcodeproj"
SCHEME="SimpleTTS"
APP_NAME="SimpleTTS"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
BINARY_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"

usage() {
  echo "Usage: $0 [rebuild]" >&2
}

REBUILD=0
case "${1:-}" in
  "") ;;
  rebuild) REBUILD=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "不明な引数です: $1" >&2; usage; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild が見つかりません。Xcode をインストールし、xcode-select で選択してください。" >&2
  exit 1
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
)
if [[ "${NO_SIGN:-0}" == "1" ]]; then
  XCODEBUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi

BUILT=0
if [[ $REBUILD -eq 1 ]]; then
  echo "==> clean ($CONFIGURATION)"
  xcodebuild "${XCODEBUILD_ARGS[@]}" clean
  rm -rf "$DERIVED_DATA"
  echo "==> rebuild ($CONFIGURATION)"
  xcodebuild "${XCODEBUILD_ARGS[@]}" build
  BUILT=1
elif [[ ! -x "$BINARY_PATH" ]]; then
  echo "==> ビルド済みのアプリがないためビルドします ($CONFIGURATION)"
  xcodebuild "${XCODEBUILD_ARGS[@]}" build
  BUILT=1
fi

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "ビルド後もアプリが見つかりません: $BINARY_PATH" >&2
  exit 1
fi

# ビルドし直した場合、古いアプリが動いていると open は古い方を前面に出すだけなので終了させる。
if [[ $BUILT -eq 1 ]] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> 起動中の $APP_NAME を終了します"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in {1..50}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

echo "==> 起動: $APP_PATH"
open "$APP_PATH"
