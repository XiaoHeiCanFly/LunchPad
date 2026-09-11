#!/bin/bash
# Compile the actual gesture engines into a deterministic command-line replay.
set -euo pipefail

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
developer_path="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$developer_path" == /Library/Developer/CommandLineTools ]]; then
  developer_path=/Applications/Xcode.app/Contents/Developer
fi
swift_compiler="$developer_path/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_path="$developer_path/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ ! -x "$swift_compiler" || ! -d "$sdk_path" ]]; then
  echo "Xcode with the macOS 26.5 SDK is required; set DEVELOPER_DIR if it is installed elsewhere." >&2
  exit 1
fi

build_path="$(mktemp -d "${TMPDIR:-/tmp}/LunchPad-gesture-tests.XXXXXX")"
"$swift_compiler" \
  -sdk "$sdk_path" \
  -target "$(uname -m)-apple-macos26.5" \
  -swift-version 6 \
  -default-isolation MainActor \
  -module-cache-path "$build_path/module-cache" \
  "$repo_path/LunchPad/LauncherGestureAnimator.swift" \
  "$repo_path/LunchPad/TrackpadContactState.swift" \
  "$repo_path/tests/GestureRegressionTests.swift" \
  -o "$build_path/gesture-regressions"
"$build_path/gesture-regressions"
