# 自动化制片流水线

面向「一句话下任务 → 全自动出片 → 事后自然语言返修」。

## 角色分工

- **OpenCode**：意图识别 + 写分镜/`graph.json` + 批量自检 + 轮询 Job
- **Studio JobEngine**：可恢复账本 + Comfy 批量出图/出视频
- **流水线面板**：监控进度/产物/模板绑定（主入口仍是右侧对话）

## 数据目录

账本（全局，按 Job 索引，体积小）：

```
.aireel/pipeline/
  config.json
  bridge.json
  jobs/<jobId>/
    job.json
    graph.json
    events.jsonl
    report.md
```

**产物约定**（不会在项目根新建剧名文件夹）：

```
<项目根>/
  .aireel/pipeline/jobs/<jobId>/
    clips/                     ← 成片临时（按 Job 隔离；finalize 后删除）
  001_某剧/…/14_某集/          ← chapterPath / storyboardDir
    参考图/                    ← 跨 Job 复用
    分镜素材/                  ← finalize 后最终成片（<shotId>.mp4）
```

`create_job` 若找不到已有目录会 400 报错，避免误建。

## HTTP 工具桥

应用启动后监听 `127.0.0.1:<bridgePort>`（默认 7829，冲突则自动换端口）。

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/health` | 探活 |
| GET | `/pipeline/jobs` | 列表 |
| GET | `/pipeline/jobs/:id` | 快照（job+graph） |
| GET | `/pipeline/assets/refs?q=&kind=&limit=` | 扫描可复用参考图 |
| POST | `/pipeline/resolve_refs` | 按 id/title/kind 匹配已有图 |
| POST | `/pipeline/parse_intent` | 辅助解析章节/场景 |
| POST | `/pipeline/create_job` | 建 Job |
| POST | `/pipeline/submit_graph` | authoring 完成；默认 `reuseExisting:true` 自动挂接 |
| POST | `/pipeline/run_job` | 开始/继续 |
| POST | `/pipeline/submit_review_batch` | 自检结果 |
| POST | `/pipeline/revise_scene` | 局部返修 |
| POST | `/pipeline/cancel_job` | 取消（仅未终态） |
| POST | `/pipeline/delete_job` | 删除 Job 账本与临时 clips（不删参考图/分镜素材） |
| GET/PUT | `/pipeline/config` | 读写配置 |

### 参考图复用

扫描来源：历史 Job 的 `graph.json`（ready 路径）、`assets/refs/**`、项目内常见物料夹（`角色定妆照`/`场景素材`/`道具`/`characters`/`scenes`/`props` 等）。

`submit_graph` 默认会按 id/title 自动匹配；命中则写入 `outputPath` + `status:ready`，`gen_refs` 跳过这些节点。Agent skill 仍要求先主动 `GET /pipeline/assets/refs`，避免漏匹配。

当前桥地址见 `.aireel/pipeline/bridge.json` 或面板顶栏。

## 无人值守约定

1. Agent `submit_graph` → `run_job` 后轮询 `get_job`
2. 状态 `waiting_agent` 时立刻批量看图/抽帧，调用 `submit_review_batch`
3. 不要中途问用户「参考图是否满意」（除非 `failed_needs_human`）
4. `gates.beforeFirstVideo` 默认 `false`

## 配置默认

```json
{
  "templates": {
    "ref_character": "",
    "ref_scene": "",
    "ref_prop": "",
    "shot_video": ""
  },
  "maxReviewRounds": { "ref": 3, "clip": 1 },
  "autoReviewClips": true,
  "gates": { "beforeFirstVideo": false, "onReviewExhausted": true },
  "comfyConcurrency": 0,
  "comfyServerId": "",
  "bridgePort": 7829
}
```

- `comfyServerId` 为空：使用设置里**全部已启用**且探测在线的 Comfy 实例组成池，参考图按依赖波次并行、镜头全量并行。  
- `comfyConcurrency`：`0`=自动（并行度=在线实例数）；`>0` 时上限截断到在线数。  
- 指定 `comfyServerId` 时只跑那一台。

在「流水线」面板绑定已导入的 Comfy 模板；模板需暴露 prompt 文本字段，视频模板另暴露 image 参考口。

## OpenCode Skill

内置源：[`assets/skills/aireel-produce/SKILL.md`](../assets/skills/aireel-produce/SKILL.md)。

打开或切换项目时，Studio 会自动同步到：

- `<项目根>/.opencode/skills/aireel-produce/SKILL.md`（OpenCode 自动发现）
- `<项目根>/.aireel/skills/aireel-produce/SKILL.md`（旁路副本）

应用升级后再次打开项目会覆盖同步（保持与内置 skill 一致）。在项目根启动 OpenCode 即可加载 `aireel-produce`。
