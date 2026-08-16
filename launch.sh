#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/OpenCodexMenuBar" > /dev/null 2>&1 &
echo "OpenCodex 菜单栏监控已启动！"
