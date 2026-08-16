#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
pkill -f OpenCodexMenuBar 2>/dev/null || true
nohup "$DIR/OpenCodexMenuBar" > /dev/null 2>&1 &
osascript -e 'display notification "OpenCodex 菜单栏额度看板已在顶部启动！" with title "启动成功"'
exit 0
