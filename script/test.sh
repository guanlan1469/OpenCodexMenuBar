#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/toolchain.sh"
mkdir -p "$ROOT_DIR/.build/tests"
xcrun swiftc -O "$ROOT_DIR/Sources/QuotaCore.swift" "$ROOT_DIR/Tests/main.swift" -o "$ROOT_DIR/.build/tests/quota-tests"
"$ROOT_DIR/.build/tests/quota-tests" "$@"
