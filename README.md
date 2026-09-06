# AIReelStudio

AI 短剧/短视频创作工作台：把「剧本 + 素材 + 季集目录」做成桌面三栏应用，并在右侧嵌入终端对接 Agent。

> 状态：**可用预览 v0.1**（Windows 优先）  
> 最后更新：2026-09-06

---

## 定位

创作侧通常用一套本地目录（常见为挂载后的剧本根目录）管理 Markdown 剧本与图/视/音频物料。本应用不替代文件系统，而是：

- 用**项目树**识别剧本 / 季 / 集 / 物料夹
- 用**文档编辑器**写 Markdown（高亮、大纲、行号、预览切换）
- 用**素材网格**浏览与预览媒体
- 用**嵌入式 Shell** 启动 opencode、dsh-tui 等，并把当前文件/选区引用填进智能体

首次启动需选择**项目根目录**（本地路径或 UNC，例如 `\\nas\share\...`），不必绑定仓库内的 `scripts/` 打包目录。

---

## 能做什么（以当前代码为准）

| 能力 | 说明 |
|---|---|
| **三栏工作台** | 左：项目树；中：文档 / 素材；右：Shell。可拖拽调宽，Shell 可折叠（不销毁会话） |
| **项目树** | 自动识别剧本/季/集；过滤；新建剧本/子文件夹；右键打开、资源管理器、重命名、复制、删除、创作进度；视频可截首/末帧 |
| **文档编辑** | 多 Tab Markdown；语法高亮；行号；大纲轨（可钉，`Ctrl+Shift+O`）；章节跳转；编辑↔预览；`Ctrl+S` 保存 |
| **工作区记忆** | Tabs、选中项、树展开、文档光标/滚动/选区跨启动恢复 |
| **素材浏览** | 网格导航、类型过滤、导入、分类汇总；图片/视频/音频预览；右键文件操作 |
| **全局搜索** | `Ctrl+P`：文件名 + Markdown 正文（内存扫描，非 SQLite） |
| **Shell / Agent** | 多 Tab PTY；可配置快捷启动与 cwd（项目根 / 当前选中目录）；`Ctrl+Alt+K`（可改）向智能体填入 `@路径` / `#L行` 引用 |
| **会话恢复（一期）** | 按项目记住 Shell Tab、cwd、启动命令、面板显隐；重启后重建并重拉 Agent（不恢复屏幕滚动缓冲） |
| **设置** | 项目根、主题、字号、快捷启动、引用快捷键 |

---

## 技术栈（实际依赖）

| 用途 | 选型 |
|---|---|
| 框架 | Flutter / Dart 3.6+，Material 3 |
| 状态 | Riverpod |
| 终端 | `kyroon_pty` + `xterm` |
| 媒体 | `media_kit`（libmpv） |
| 配置与记忆 | SharedPreferences |
| 窗口 | `window_manager` + `screen_retriever` |
| 选路径 | `file_picker` / `file_selector` |
| Markdown 预览 | `flutter_markdown`（编辑区高亮为自研） |

平台优先级：**Windows（主）** → Linux（有壳，非正式分发）→ Android（后续）。仓库当前无 macOS 工程目录。

目标架构与缺口见 [docs/方案.md](docs/方案.md)。

---

## 快速开始

```bash
flutter pub get
flutter run -d windows

# Release 绿色包（zip；可选 Inno 安装器需本机 Inno Setup 6）
powershell -ExecutionPolicy Bypass -File scripts/pack_windows.ps1
```

产物默认在 `dist/`：

- `AIReelStudio-0.1.0-windows-x64.zip` — 绿色包
- `AIReelStudio-0.1.0-Setup.exe` — 安装程序（若已安装 Inno Setup）

---

## 仓库结构

```
ai_reel_studio/
├── docs/                 # 方案与实现状态
├── lib/
│   ├── core/             # 配置、解析、记忆、搜索、进度等
│   └── features/         # tree / editor / asset / media / shell / search / settings / layout
├── scripts/              # 本仓库打包脚本（pack_windows.ps1），不是创作项目根
├── installer/windows/    # Inno Setup
├── windows/ linux/ android/
└── dist/                 # 打包输出（本地生成）
```

---

## 实现进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| Phase 0 | PTY / 目录解析 / 媒体预览 | ✅ |
| Phase 1 | 三栏布局 / 项目树 / Markdown / 设置 | ✅ |
| Phase 2 | 物料网格 / 预览 / 搜索 | 🟨 有网格与预览、搜索；缺拖拽、标签、SQLite FTS |
| Phase 3 | Shell 多 Tab / 快捷启动 / 会话恢复一期 | ✅ 主体完成（无滚动缓冲回放） |
| Phase 4 | 季集 / 进度 | 🟨 季集识别与进度徽章有；进度存本地偏好，非 meta.json |
| Phase 5 | Release 打包 | 🟨 zip 可用；安装器依赖本机 Inno |
| Phase 6 | Android | ⏳ 后续 |

---

## 已知限制

- 无 SQLite/drift；搜索为内存 + 按需读 Markdown
- 无角色管理、生成清单专页；无拖拽上传/移动与标签
- Shell 不恢复终端屏幕历史；进程退出后靠「重拉启动命令」重建
- 面板宽度不持久化；部分顶栏按钮尚未接线
- Linux / Android 非正式分发目标；无 macOS 工程

---

*更细的目标架构与对照表见 [docs/方案.md](docs/方案.md)*
