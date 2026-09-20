# OpenCodex MenuBar（额度看板）

原生 macOS 菜单栏工具，读取本机 OpenCodex 的额度缓存和调用记录。支持 macOS 13 及以上。

## 显示内容

- **OpenAI 账号池**：分别展示短周期和周额度、恢复时间、重置券；菜单栏显示两者中更少的剩余额度。周期名称来自实际窗口长度。
- **Google Antigravity**：展示 Gemini / Claude 短周期和周额度。
- **Cursor**：报告可用时展示第一方模型、API 用量或月度额度；无报告时明确提示不可用。
- **24 小时用量**：按实际模型与通道统计调用次数、Token 数量，展示前五名。

每 10 秒检查本地数据，通道额度报告最多每分钟自动读取一次，右上角可手动刷新。自动读取使用 `ocx provider quota --json`；手动刷新附加 `--refresh`，实际数据更新时间以 OpenCodex 报告为准。

### 状态含义

- `⚡️ 7%`：两个额度窗口都已返回，限制更严格的窗口剩余 7%。
- `⚡️ ≤7%`：只返回一个窗口，可用额度至多为 7%。
- `⚡️ --`：没有可用额度数据，不推测为满额。
- `·旧` / `缓存待更新`：源数据超过 5 分钟未更新，或更新时间未知、异常。
- `刷新失败 · 保留缓存`：通道刷新失败，保留最后一次有效值供参考。
- 底部的“本地检查”只表示读取本地数据的时间；每张卡片另列源数据时间。

## 安装与启动

双击 **`双击启动菜单栏工具.command`**，或运行：

```bash
./script/build_and_run.sh --install
```

脚本从源码编译并签名，成功后替换 `/Applications/OpenCodexMenuBar.app`，确认新进程启动。编译失败不会中止旧版；启动失败会恢复先前版本。`launch.sh` 和 Codex 的 Run 按钮使用相同安装入口，不再运行仓库内旧二进制。

需要 Apple 开发工具。若当前 Xcode 尚不可用，脚本尝试已安装的 Command Line Tools，不修改系统的工具链选择。独立 macOS 27 SDK 缺少 SwiftUI 宏插件时，使用已安装的 26.5 SDK 编译。

开发选项：

```bash
./script/build_and_run.sh --build   # 只构建到 dist，不停止运行中的应用
./script/build_and_run.sh --verify  # 构建并验证 dist 内开发版
./script/build_and_run.sh --logs    # 启动开发版并查看日志
./script/build_and_run.sh --debug   # 调试开发版
```

## 验证

```bash
./script/test.sh
# 可选：额外测量本机用量日志的首次/增量读取速度
./script/test.sh "$HOME/.opencodex/usage.jsonl"
```

回归检查覆盖额度缺失、数值边界、数据过期、Google 周额度、日志追加/半行/轮换/截断、24 小时滚动过期、通道区分，以及额度命令的大输出、错误退出和超时。测试使用临时文件，不修改真实配置或用量记录。

用量日志首次按块读取，之后只解析追加内容，内存只保留最近 24 小时的摘要记录。菜单栏标题随额度变化更新，不再每秒轮询。

## 项目结构

- `Sources/main.swift`：数据刷新、SwiftUI 界面、菜单栏生命周期。
- `Sources/QuotaCore.swift`：额度解析、增量用量统计、有限时命令执行。
- `Tests/main.swift`：独立回归检查。
- `OpenCodexMenuBar.bundle-template/Contents/Info.plist`：应用元数据；模板不携带旧可执行文件或签名。
- `script/`：构建、工具链选择、测试入口。

构建产物不提交到 Git。旧版独立预览器含重复界面和固定占位数据，已移除；界面验收以实际应用为准。

## 协议

MIT License
