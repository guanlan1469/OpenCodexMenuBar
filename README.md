# OpenCodex MenuBar (额度看板) ⚡️

一个专为 **OpenCodex** 设计的原生 macOS 菜单栏额度与模型状态监控工具。使用 Swift + SwiftUI 构建，轻量常驻后台，深度贴合 macOS 现代毛玻璃设计风格。

---

## ✨ 核心特性

- **⚡️ 菜单栏常驻概览**：顶部状态栏实时显示主力账号剩余可用额度百分比（如 `⚡️ 82%`），不占 Dock 栏空间。
- **📊 核心模型通道配额聚合**：
  - **OpenAI · 账号池**：统一聚合主账号（Main）与多个备用账号，展示周额度进度条、已用/剩余百分比、重置时间与重置券。
  - **Google · Antigravity**：读取本机 OpenCodeX provider quota 报告，分别展示 Gemini（自研池）与 Claude（第三方池）的实时配额水位、更新时间和最近恢复时间；数据不可用时明确提示，不使用固定占位百分比。
  - **Cursor · Included in Pro**：读取本机 OpenCodeX 的实验性 provider quota 报告，拆分展示 `Cursor Models`（第一方模型）与 `Other Models`（API 用量）配额水位、更新时间和真实重置时间；数据不可用时明确提示，不使用固定占位百分比。
- **🔥 24小时模型消耗排行**：自动解析 `~/.opencodex/usage.jsonl`，按模型统计过去 24 小时的调用频次与 Token 吞吐。
- **🔄 自动与手动同步**：每 10 秒后台自动检测本地配置与缓存变动，右上角支持一键立即刷新。
- **🔗 便捷管理**：内置一键直达本地 OpenCodex 控制台管理链接。

---

## 🛠️ 项目结构

- `Sources/main.swift`：菜单栏应用主程序源码 (SwiftUI + AppKit)
- `Sources/render_preview.swift`：离线高保真位图渲染器
- `OpenCodexMenuBar.app`：标准 macOS 应用 Bundle
- `双击启动菜单栏工具.command`：一键启动脚本
- `opencodex_menubar_preview.png`：预览效果截图

---

## 🚀 编译与运行

### 方式一：直接双击运行（最简便）
双击运行根目录下的 **`双击启动菜单栏工具.command`** 即可在后台常驻启动。

### 方式二：手动编译与运行
在终端中执行：
```bash
swiftc -O Sources/main.swift -o OpenCodexMenuBar -framework Cocoa -framework SwiftUI
./OpenCodexMenuBar > /dev/null 2>&1 &
```

---

## 📝 开源协议

MIT License
