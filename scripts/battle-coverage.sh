#!/usr/bin/env bash
# Inspect branch regions after the XCTest coverage run; zero-hit regions stay visible.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN_PATH=$(swift build --show-bin-path)
BIN="$BIN_PATH/PokeTokenBarPackageTests.xctest/Contents/MacOS/PokeTokenBarPackageTests"
PROF="$BIN_PATH/codecov/default.profdata"
xcrun llvm-cov show "$BIN" -instr-profile="$PROF" --show-regions --show-line-counts-or-regions \
  Sources/PokeTokenBar/Core/BattleEngine.swift Sources/PokeTokenBar/Core/BattleSnapshot.swift Sources/PokeTokenBar/Core/PracticeBattle.swift \
  Sources/PokeTokenBar/Core/PracticeSession.swift Sources/PokeTokenBar/Core/PracticeText.swift
xcrun llvm-cov show "$BIN" -instr-profile="$PROF" --show-regions --show-line-counts-or-regions \
  --name-regex='applicationShouldHandleReopen|launchRequestsPractice|applyOpenRoute|menuLines|menuToolTip' \
  Sources/PokeTokenBar/PokeTokenBarApp.swift
