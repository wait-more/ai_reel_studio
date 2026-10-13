# OpenCode V1 / V2 双栈说明

## 原则

- **调用方不写版本 if**：`shell_panel` 等只依赖 `OpenCodeGateway`。
- **版本分支只在适配层**：`detectOpenCodeVersion()` → 工厂选出 `OpenCodeGatewayV1` / `OpenCodeGatewayV2`。
- **导航结果用枚举**：`OpenCodeNavOutcome.ok | needsRestart | failed`；UI 只认结果类型。

## V1

- 启动：`opencode --hostname 127.0.0.1 --port <allocated>`，可选 `-s`。
- 列表：`opencode db` SQL。
- 切会话 / 新建：`POST /tui/select-session`、`POST /tui/new-session`（失败则 needsRestart）。
- 改名 / 删除：打 TUI 端口或临时 `serve`。
- 结束：按端口杀监听进程。

## V2

- **不用** `--standalone`；**不主动** `service start`（CLI 自管 service）。
- 启动：`opencode` 或 `opencode -s <id>`（禁止顶层 `--hostname/--port`）。
- 列表：在目标 `cwd` 下执行 `session list -n N --format json`（CLI 已按当前项目作用域；勿用宿主 exe cwd，勿再按目录硬过滤掉同项目会话）。
- 打开会话菜单：`preferForceRefreshOnSessionMenuOpen`（V2=`true` 跳过 TTL；V1=`false` 继续吃 20s 缓存）。UI 只读该标志，不写版本 if。
- 删除：`session delete <id>`。
- 改名：`opencode api session.update --param sessionID=… -d '{"title":"…"}'`。
- 切会话 / 新建：当前实现直接 `needsRestart`（再 `prepareTuiLaunch`）；若日后有稳定 live API 可在 Gateway 内升级为 `ok`，UI 无需改。
- 结束：按会话 id / TUI 命令行杀进程；**绝不** `opencode service stop`。

## 相关文件

| 路径 | 职责 |
|------|------|
| `lib/core/opencode/opencode_gateway.dart` | 门面接口、工厂、`OpenCodeNavResult` |
| `lib/core/opencode/opencode_gateway_v1.dart` | V1 适配（转调 `opencode_sessions.dart`） |
| `lib/core/opencode/opencode_gateway_v2.dart` | V2 适配 |
| `lib/core/opencode/opencode_version.dart` | 版本解析与缓存 |
| `lib/core/opencode_sessions.dart` | 模型、路径工具、V1 实现细节 |
| `test/opencode_gateway_test.dart` | 解析 / 工厂 / 命令拼装 / JSON 映射 |
