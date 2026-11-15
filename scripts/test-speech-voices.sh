#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simpletts-voice-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

# Only resolves voice metadata; never plays audio or changes system preferences.
xcrun swiftc -parse-as-library -default-isolation MainActor \
  -module-cache-path "$TEST_BUILD_DIR/ModuleCache" \
  "$PROJECT_ROOT/SimpleTTS/SpeechTypes.swift" \
  "$PROJECT_ROOT/SimpleTTS/SpeechSynthesizer.swift" \
  "$PROJECT_ROOT/Tests/SpeechVoiceTests.swift" \
  -o "$TEST_BUILD_DIR/speech-voice-tests"
"$TEST_BUILD_DIR/speech-voice-tests"
