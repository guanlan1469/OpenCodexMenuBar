#!/usr/bin/env bash
# Prefer the selected toolchain; fall back locally if Xcode cannot run (e.g. license pending).
if ! /usr/bin/xcrun swiftc --version >/dev/null 2>&1; then
  if [[ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  fi
fi

# The standalone macOS 27 SDK currently omits the SwiftUI State macro plugin.
# Use the installed stable SDK for our macOS 13 deployment target, without changing xcode-select.
if [[ "${DEVELOPER_DIR:-}" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
