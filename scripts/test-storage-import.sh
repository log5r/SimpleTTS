#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simpletts-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

xcrun swiftc -parse-as-library -default-isolation MainActor \
  -module-cache-path "$TEST_BUILD_DIR/ModuleCache" \
  "$PROJECT_ROOT/SimpleTTS/Models.swift" \
  "$PROJECT_ROOT/SimpleTTS/Storage.swift" \
  "$PROJECT_ROOT/SimpleTTS/Notes.swift" \
  "$PROJECT_ROOT/SimpleTTS/TextFileLoader.swift" \
  "$PROJECT_ROOT/Tests/StorageAndImportTests.swift" \
  -o "$TEST_BUILD_DIR/storage-import-tests"
"$TEST_BUILD_DIR/storage-import-tests"
