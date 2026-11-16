#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simpletts-fold-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

# Pure geometry; no UI, audio, or app data is involved.
xcrun swiftc -parse-as-library -default-isolation MainActor \
  -module-cache-path "$TEST_BUILD_DIR/ModuleCache" \
  "$PROJECT_ROOT/SimpleTTS/FoldSplit.swift" \
  "$PROJECT_ROOT/Tests/FoldSplitTests.swift" \
  -o "$TEST_BUILD_DIR/fold-split-tests"
"$TEST_BUILD_DIR/fold-split-tests"
