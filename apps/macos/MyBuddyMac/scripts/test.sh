#!/usr/bin/env bash
# Runs the Swift Testing suites. With Xcode installed plain `swift test` works;
# with only the Command Line Tools, Testing.framework needs explicit search paths.
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="$(xcode-select -p)"
ARGS=()
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  LIB="$DEV_DIR/Library/Developer/usr/lib"
  PLUGINS="$DEV_DIR/usr/lib/swift/host/plugins/testing"
  ARGS=(-Xswiftc -F -Xswiftc "$FW" -Xswiftc -plugin-path -Xswiftc "$PLUGINS"
        -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB")
fi
exec swift test --package-path "$PKG" "${ARGS[@]}" "$@"
