# AIReelStudio

面向 **AI 短剧 / 短视频** 创作的桌面工作台：在真实本地（或 UNC）项目目录上，把「看目录、改剧本、预览物料、跟 Agent 协作」收进同一个三栏窗口。

> 状态：**可用预览 v0.1**（Windows 优先）  
> 最后更新：2026-09-07

---

## 这是什么

短剧团队往往用一套**本地目录**管项目：Markdown 写剧本/分镜，旁边放角色定妆、场景、音频；长剧再按季、集分子文件夹。平时要在资源管理器、编辑器、终端之间来回切——尤其还要另开窗口跑 opencode、dsh-tui 这类 Agent 时，上下文很容易对不上。

**AIReelStudio 不另起云端 CMS，也不替代你的文件系统。**  
它把你已有的「项目根」做成可视化工作台：目录仍是事实来源，软件负责浏览、编辑、预览，以及在应用内嵌终端对接 AI Agent。

**一句话：** 给「目录 + Markdown + 媒体 + 本地 Agent CLI」这条创作流水线，配一个专用桌面壳。

---

## 有什么用

| 你现在的痛点 | 本应用怎么帮你 |
|---|---|
| 剧本/季集目录深，翻文件夹慢 | 左侧项目树自动识别剧本 / 季 / 集，可过滤、新建、重命名、标进度 |
| 改稿要开外部编辑器，和素材脱节 | 中间栏直接写 Markdown（高亮、大纲、预览），同栏浏览图/视/音频 |
| Agent 在另一个终端里，要手打路径 | 右侧嵌入式 Shell；一键把当前文件/选区引用填进智能体 |
| 素材在 NAS / 共享盘上 | 支持本地路径与 UNC；项目根由你指定，不必绑死仓库里的打包目录 |

适合已经用「文件夹 + Markdown + 本地 Agent」做短剧/短视频的个人或小团队。不适合指望纯网页、无本地目录的云端协作场景。

---

## 界面怎么组织

首次启动选择**项目根目录**（例如 `D:\dramas` 或 `\\nas\share\scripts`）。注意：仓库内的 `scripts/` 是**打包脚本**，不是你的创作项目根。

```
┌─────────────┬──────────────────────────┬─────────────────┐
│  项目树      │  文档 Tab / 素材网格       │  嵌入式 Shell    │
│  剧本·季·集  │  Markdown 编辑 ↔ 预览     │  PTY 多 Tab      │
│  进度·右键   │  图 / 视 / 音频预览        │  快捷启动 Agent  │
└─────────────┴──────────────────────────┴─────────────────┘
```

三栏可拖拽调宽；Shell 可折叠（会话不销毁）。

---

## 功能一览（以当前代码为准）

| 能力 | 说明 |
|---|---|
| **项目树** | 识别剧本/季/集；过滤；新建剧本/子文件夹；右键打开、资源管理器、重命名、复制、删除、创作进度；视频可截首/末帧 |
| **文档编辑** | 多 Tab Markdown；语法高亮；行号；大纲轨（可钉，`Ctrl+Shift+O`）；章节跳转；编辑↔预览；`Ctrl+S` 保存 |
| **工作区记忆** | Tabs、选中项、树展开、文档光标/滚动/选区，跨启动恢复 |
| **素材浏览** | 网格导航、类型过滤、导入、分类汇总；图片/视频/音频预览；右键文件操作 |
| **全局搜索** | `Ctrl+P`：文件名 + Markdown 正文（内存扫描，非 SQLite） |
| **Shell / Agent** | 多 Tab PTY；可配置快捷启动与 cwd（项目根 / 当前选中目录）；`Ctrl+Alt+K`（可改）向智能体填入 `@路径` / `#L行` 引用 |
| **ComfyUI 生成** | 中间栏「生成」：导入 API JSON、勾选暴露输入、动态表单调用本地 Comfy；动作落在 `.aireel/comfy/` 可热加载 |
| **会话恢复（一期）** | 按项目记住 Shell Tab、cwd、启动命令、面板显隐；重启后重建并重拉 Agent（不恢复屏幕滚动缓冲） |
| **设置** | 项目根、主题、字号、快捷启动、引用快捷键 |

---

## 快速开始

```bash
flutter pub get
flutter run -d windows

# Release 绿色包（zip；可选 Inno 安装器需本机 Inno Setup 6）
powershell -ExecutionPolicy Bypass -File scripts/pack_windows.ps1
```

产物默认在 `dist/`：

- `AIReelStudio-0.1.0-windows-x64.zip` — 绿色包（解压即用）
- `AIReelStudio-0.1.0-Setup.exe` — 安装程序（若已安装 Inno Setup）

---

## 技术栈

| 用途 | 选型 |
|---|---|
| 框架 | Flutter / Dart 3.6+，Material 3 |
| 状态 | Riverpod |
| 终端 | `kyroon_pty` + `flterm`（libghostty） |
| 媒体 | `media_kit`（libmpv） |
| 配置与记忆 | SharedPreferences |
| 窗口 | `window_manager` + `screen_retriever` |
| 选路径 | `file_picker` / `file_selector` |
| Markdown 预览 | `flutter_markdown`（编辑区高亮为自研） |

平台优先级：**Windows（主）** → Linux（有工程壳，非正式分发）→ Android（后续）。仓库当前无 macOS 工程目录。

目标架构与缺口对照见 [docs/方案.md](docs/方案.md)。  
ComfyUI 动态 API 接入见 [docs/ComfyUI集成方案.md](docs/ComfyUI集成方案.md)。

---

## 仓库结构

```
ai_reel_studio/
├── docs/                 # 技术方案与实现状态
├── lib/
│   ├── core/             # 配置、解析、记忆、搜索、进度等
│   └── features/         # tree / editor / asset / media / shell / search / settings / layout
├── scripts/              # pack_windows 等，不是创作项目根
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
