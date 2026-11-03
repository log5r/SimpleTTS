#!/usr/bin/env bash
# コミット済みのソースだけを配布用 ZIP にする。作業フォルダ全体は圧縮しない。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -gt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [output.zip]" >&2
  if [[ $# -gt 1 ]]; then exit 1; fi
  exit 0
fi

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "未コミットの変更があります。公開する変更をコミットしてから実行してください。" >&2
  exit 1
fi

OUTPUT="${1:-$ROOT_DIR/build/SimpleTTS-source.zip}"
if [[ "$OUTPUT" != /* ]]; then OUTPUT="$PWD/$OUTPUT"; fi
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  echo "出力先がすでに存在します: $OUTPUT" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
git -C "$ROOT_DIR" archive --format=zip --prefix=SimpleTTS/ --output="$OUTPUT" HEAD
echo "作成しました: $OUTPUT"
