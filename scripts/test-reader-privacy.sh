#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simpletts-reader-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

# The synthetic engine in the test replaces speech synthesis. Audio is never played.
xcrun swiftc -parse-as-library -default-isolation MainActor -swift-version 5 \
  -module-cache-path "$TEST_BUILD_DIR/ModuleCache" \
  "$PROJECT_ROOT/SimpleTTS/Models.swift" \
  "$PROJECT_ROOT/SimpleTTS/Storage.swift" \
  "$PROJECT_ROOT/SimpleTTS/Notes.swift" \
  "$PROJECT_ROOT/SimpleTTS/TextFileLoader.swift" \
  "$PROJECT_ROOT/SimpleTTS/SpeechTypes.swift" \
  "$PROJECT_ROOT/SimpleTTS/SpeechPlayer.swift" \
  "$PROJECT_ROOT/SimpleTTS/ReaderModel.swift" \
  "$PROJECT_ROOT/Tests/ReaderModelPrivacyTests.swift" \
  -o "$TEST_BUILD_DIR/reader-privacy-tests"
"$TEST_BUILD_DIR/reader-privacy-tests"
