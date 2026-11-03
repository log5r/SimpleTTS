#!/usr/bin/env bash
# Build and launch SimpleTTS.
#
#   ./start.sh           Launch the existing build, or build it first if missing.
#   ./start.sh rebuild   Clean, rebuild, and launch.
#
# Environment variables:
#   CONFIGURATION=Release   Build configuration (default: Debug).
#   NO_SIGN=1               Skip code signing for local development.
# Load local signing and bundle ID settings from Config/Signing.local.xcconfig, if present.
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
  *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild was not found. Install Xcode and select it with xcode-select." >&2
  exit 1
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
)
if [[ -f "$ROOT_DIR/Config/Signing.local.xcconfig" ]]; then
  XCODEBUILD_ARGS+=(-xcconfig "$ROOT_DIR/Config/Signing.local.xcconfig")
fi
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
  echo "==> No existing app found; building ($CONFIGURATION)"
  xcodebuild "${XCODEBUILD_ARGS[@]}" build
  BUILT=1
fi

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "App not found after building: $BINARY_PATH" >&2
  exit 1
fi

# Quit an older running build so open launches the newly built app.
if [[ $BUILT -eq 1 ]] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Quitting the running $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in {1..50}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

echo "==> Launching: $APP_PATH"
open "$APP_PATH"
