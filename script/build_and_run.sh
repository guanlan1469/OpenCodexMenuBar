#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---install}"
case "$MODE" in
  run|--build|--install|--verify|verify|--debug|debug|--logs|logs|--telemetry|telemetry) ;;
  *) echo "usage: $0 [run|--build|--install|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/toolchain.sh"
APP_NAME=OpenCodexMenuBar
BUILD_DIR="$ROOT_DIR/.build"
mkdir -p "$BUILD_DIR"
LOCK="$BUILD_DIR/build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "已有构建任务正在运行；如上次任务被强制中止，请删除 .build/build.lock 后重试。" >&2
  exit 1
fi
STAGING="$(mktemp -d "$BUILD_DIR/staging.XXXXXX")"
trap 'rm -rf "$STAGING"; rmdir "$LOCK"' EXIT
APP_BUNDLE="$STAGING/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$BUILD_DIR/ModuleCache"
cp "$ROOT_DIR/OpenCodexMenuBar.bundle-template/Contents/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
xcrun swiftc -module-cache-path "$BUILD_DIR/ModuleCache" \
  -target "$(uname -m)-apple-macos13.0" -O \
  "$ROOT_DIR/Sources/QuotaCore.swift" "$ROOT_DIR/Sources/main.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" -framework Cocoa -framework SwiftUI
/usr/bin/codesign --force --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist"
DESTINATION="$ROOT_DIR/dist/$APP_NAME.app"
if [[ "$MODE" == --install ]]; then DESTINATION="/Applications/$APP_NAME.app"; fi
mkdir -p "$(dirname "$DESTINATION")"
BACKUP="$STAGING/previous.bundle"
# Keep the running version until the replacement has compiled and passed signing checks.
if [[ "$MODE" != --build ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for attempt in 1 2 3 4 5; do
    if ! pgrep -x "$APP_NAME" >/dev/null; then break; fi
    sleep 1
  done
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "旧进程仍在退出，暂不替换应用。" >&2
    exit 1
  fi
fi
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$BACKUP"; fi
if ! mv "$APP_BUNDLE" "$DESTINATION"; then
  if [[ -e "$BACKUP" ]]; then mv "$BACKUP" "$DESTINATION"; fi
  exit 1
fi
APP_BINARY="$DESTINATION/Contents/MacOS/$APP_NAME"
launch_and_verify() {
  local launched=false
  for attempt in 1 2 3 4 5; do
    /usr/bin/open -n "$DESTINATION" || true
    sleep 1
    while IFS= read -r pid; do
      if [[ "$(ps -p "$pid" -o comm=)" == "$APP_BINARY" ]]; then launched=true; break; fi
    done < <(pgrep -x "$APP_NAME" || true)
    if [[ "$launched" == true ]]; then break; fi
  done
  if [[ "$launched" != true ]]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    rm -rf "$DESTINATION"
    if [[ -e "$BACKUP" ]]; then mv "$BACKUP" "$DESTINATION"; /usr/bin/open "$DESTINATION"; fi
    echo "新版启动失败，已恢复先前版本。" >&2
    return 1
  fi
  echo "已启动并验证：$DESTINATION"
}
case "$MODE" in
  --build) echo "构建完成：$DESTINATION" ;;
  --debug|debug) xcrun lldb -- "$APP_BINARY" ;;
  --logs|logs) launch_and_verify; /usr/bin/log stream --info --style compact --predicate 'process == "OpenCodexMenuBar"' ;;
  --telemetry|telemetry) launch_and_verify; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.zhoujie.opencodex.menubar"' ;;
  *) launch_and_verify ;;
esac
