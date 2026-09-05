# AIReelStudio

AI 短视频创作工作台 —— 可视化浏览/编辑 `scripts/` 目录，内置 Shell 终端对接 opencode / dsh-tui 等 Agent。

> 状态：**可用预览 v0.1**（Windows 优先）
> 最后更新：2026-09-05

---

## 能做什么

| 能力 | 说明 |
|---|---|
| **剧本管理** | 三栏布局；树形浏览 `scripts/`；Markdown 编辑（语法高亮） |
| **物料管理** | 素材网格、图片/视频/音频预览、右键操作 |
| **长剧结构** | 自动识别季/集层级；创作进度徽章 |
| **全局搜索** | Ctrl+P：文件名 + Markdown 内容；键盘上下选择 |
| **AI 互操作** | 右侧多 Tab PTY 终端；可配置快捷启动命令 |

## 技术栈

- **框架**：Flutter (Dart) — Windows → Linux → macOS → Android
- **终端**：`kyroon_pty` + `xterm`
- **媒体**：`media_kit`（libmpv）
- **状态**：Riverpod
- **配置**：SharedPreferences（项目路径 / 主题 / 字号 / 快捷启动）

详见 [docs/方案.md](docs/方案.md)

## 快速开始

```bash
# 依赖
flutter pub get

# 开发运行（Windows）
flutter run -d windows

# Release 构建 + zip（可选安装器，需本机安装 Inno Setup 6）
powershell -ExecutionPolicy Bypass -File scripts/pack_windows.ps1
```

首次启动选择本地或 UNC 挂载的 `scripts/` 根目录即可。

产物默认输出到 `dist/`：

- `AIReelStudio-0.1.0-windows-x64.zip` — 绿色包（解压即用）
- `AIReelStudio-0.1.0-Setup.exe` — 安装程序（若已安装 Inno Setup）

## 目录结构

```
AIReelStudio/
├── docs/                 # 方案与实现状态
├── lib/                  # Flutter 源码
├── scripts/              # 打包脚本
├── installer/windows/    # Inno Setup 脚本
└── windows/              # Windows 平台壳与图标
```

## 实现进度（相对方案）

| 阶段 | 内容 | 状态 |
|---|---|---|
| Phase 0 | PTY / 目录解析 / 媒体预览 PoC | ✅ 完成 |
| Phase 1 | 三栏布局 / 项目树 / Markdown / 设置 | ✅ 完成 |
| Phase 2 | 物料网格 / 预览 / 搜索 | 🟨 部分（缺拖拽、标签、SQLite FTS） |
| Phase 3 | Shell 多 Tab / 快捷启动 | 🟨 部分（快捷启动可配置；cwd 可联动选中目录） |
| Phase 4 | 季集 / 进度 | 🟨 部分（进度在本地偏好，非 meta.json） |
| Phase 5 | Release 打包 / 安装器 | 🟨 进行中 |
| Phase 6 | Android | ⏳ 后续 |

## 已知限制

- 未接入 SQLite/drift；搜索为内存 + 按需读 Markdown
- 无角色管理、生成清单专页；无拖拽上传
- Shell 不恢复历史 Tab/屏幕内容
- Linux/macOS/Android 未作为正式分发目标

---

*详细方案与缺口见 [docs/方案.md](docs/方案.md)*
