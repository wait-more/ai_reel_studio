---
name: aireel-produce
description: >-
  用 AIReel Studio 本机流水线桥做自然语言制片：整集/单场出片、复用已有参考图、
  批量自检与场景返修。用户说「制作第N集」「只做第X场」「脸崩了重做」时使用。
metadata:
  source: aireel-studio
  managed: "true"
---

# aireel-produce

用 AIReel Studio 本机流水线桥，把自然语言制片任务跑到「各场景视频就绪并落盘分镜素材」。

本文件由 AIReel Studio 在打开项目时同步到 `.opencode/skills/aireel-produce/SKILL.md`；请勿改目录名。

## 何时使用

用户说「帮我把第14集制作一下」「只做第3场」「第5场脸崩了重做」「做到哪了」等。

## 前置

1. 读取项目 `.aireel/pipeline/bridge.json` 的 `baseUrl`（没有则让用户打开 Studio「流水线」面板）。  
   - `baseUrl` 一定是本机 `127.0.0.1`：**不会打到别的机器**；多机各自跑各自的 Studio 桥即可。  
   - 可选：先 `GET {baseUrl}/health`，确认 `ok` 且记下返回的 `hostId`。
2. 所有请求打到该 `baseUrl`（仅本机 loopback）。
3. **`chapterPath` 必须是项目里已经存在的剧本/集目录或其中的剧本文件**（绝对路径或相对项目根）。  
   - **禁止**传还不存在的剧名字符串（服务端也不会在项目根新建剧名文件夹；对不上会直接报错）  
   - 先在项目树里确认真实路径再 `create_job`

## 多机共用同一 NAS 项目（重要）

同一项目目录可被多台机器同时打开；**任务必须按机器隔离**，否则查进度会串台。

1. `GET /pipeline/jobs` **默认只返回本机创建的 Job**（`scope=mine`）。不要用 `scope=all` 除非用户明确要看全局。
2. 每个 Job 带 `hostId`；`create_job` 后只轮询**你刚创建的那个 `jobId`**，不要扫列表里别人的 `waiting_*` 去自检/续跑。
3. 对带其它 `hostId` 的 Job 调 `run_job` / `submit_review_batch` / `revise_scene` 会被拒绝（409）。不要强行 `force`，除非用户明确说要接管他机任务。
4. 参考图目录仍可跨机复用；临时成片在各自 Job 目录下，互不覆盖。

## 产物路径（硬约定）

| 阶段 | 位置 | 说明 |
|------|------|------|
| 参考图 | `{chapterPath}/参考图/` | 跨 Job 共用，可复用；文件名用角色/场景/道具 id |
| 成片临时 | `.aireel/pipeline/jobs/<jobId>/clips/` | **按 Job 隔离**，避免多任务同名互相覆盖 |
| 最终成片 | `{分镜脚本目录}/分镜素材/` | **全部生成并验收完成后**由 `finalize` 自动落盘；落盘后清理该 Job 临时 `clips/` |

- **分镜脚本目录**：`submit_graph` 的 `storyboardDir`（推荐显式传入）；未传则回退为 `chapterPath` 解析出的工作目录。
- 最终文件名：`<shot.id>.<原扩展名>`（如 `s03.mp4`）。
- 汇报成功时，列出的是 **分镜素材** 下的绝对路径，不是临时目录。

## 意图路由

先判 intent（也可用 `POST /pipeline/parse_intent`）：

| intent | 例子 | 动作 |
|--------|------|------|
| `episode_produce` | 把第14集做一下 | 整集 Job |
| `scene_produce` | 只做第14集第3场 | 单场景 |
| `scene_revise` | 第3场光太暗 | `revise_scene` |
| `ref_only` | 先出齐角色参考图 | 建 Job 后只推到 refs 通过 |
| `status` | 做到哪了 | 只读 `GET /pipeline/jobs` |
| `other` | 闲聊/改文案 | 不建制片 Job |

缺章节/场景号时先问一句澄清，不要空跑 Comfy。

## 整集 / 单场景剧本

1. `POST /pipeline/create_job`  
   `{ "intent":"episode_produce", "chapterPath":"<相对或绝对章节路径>", "sceneId": null, "userBrief":"<原话>" }`
2. **authoring（你来做）——必须先找已有参考图**  
   - 在项目里写分镜/镜头提示词  
   - **先查可复用参考图**（禁止不查就全量重出）：  
     - `GET /pipeline/assets/refs?q=<角色或场景名>&kind=character|scene|prop`  
     - 或对拟定的 refs 调 `POST /pipeline/resolve_refs`  
       `{ "refs":[{"id","kind","title","prompt"?}], "minScore":40 }`  
   - 组装 `graph`：`refs[{id,kind,title,prompt,dependsOn,outputPath?,status?}]`、`shots[{id,title,prompt,refIds}]`  
   - **命中已有图时**：把绝对路径写入 `refs[].outputPath`，并设 `status:"ready"`（可附 `reviewNote` 说明来源）  
   - **未命中的**才留 `status:"pending"`、不写 `outputPath`，交给 Comfy 生成  
   - `POST /pipeline/submit_graph`  
     `{ "jobId","graph","storyboardDir":"<分镜脚本目录>","reuseExisting": true }`  
     （`storyboardDir` 应指向分镜脚本所在目录；最终成片会进其下 `分镜素材/`。`reuseExisting` 默认 true。）
3. `submit_graph` 成功后服务端会自动 `run`；也可再调 `POST /pipeline/run_job` `{ "jobId" }` 保险。
4. **循环直到终态（状态只认桥返回值，聊天里说「做完了」不算）**  
   - `GET /pipeline/jobs/<jobId>`  
   - `waiting_comfy` / `running` / `queued`：等待再轮询  
   - `waiting_agent` + `currentStepId=review_refs`：看完参考图后**必须**回写，任选其一：  
     - `POST /pipeline/submit_review_batch`  
       `{ "jobId","phase":"refs","items":[{"id","pass", "note","newPrompt"?}] }`  
       （`items` 可省略/空数组 = 全部 pass）  
     - 或 `POST /pipeline/ack_agent_step` `{ "jobId" }`（等价于当前阶段全 pass）  
     - 只有崩坏/错主体才显式 `pass:false` 并给 `newPrompt`  
   - `waiting_agent` + `review_clips`：同样必须 `submit_review_batch`（`phase:"clips"`）或 `ack_agent_step`  
   - **禁止**在仍是 `waiting_agent` 时对用户说「已完成」  
   - `succeeded`：用中文汇报 **`materialsDir`（分镜素材）** 下的 clips 路径清单，并说明哪些参考图是复用的；不要把临时 `clipsTempDir` 当成最终交付  
   - `failed_needs_human` / `waiting_human`：说明原因，请用户处理，禁止假装完成

## 返修

`POST /pipeline/revise_scene`  
`{ "jobId","sceneId","feedback","newPrompt?" }`  
然后同样轮询到 `succeeded`。返修默认不重出全部参考图，只动该场景视频（除非你在 graph 里把相关 ref 标成 failed/pending）。返修完成后同样经 `finalize` 写回「分镜素材」并清理临时成片。

## 硬性禁止

- 中途问「请确认参考图是否满意再继续」（除非 `failed_needs_human`）
- 每张图单独开一轮人工会话
- **不查 `/pipeline/assets/refs`（或等价目录）就对已有角色/场景全部重出**
- 不调桥、只在聊天里口头说「已生成 / 已完成」（`GET` 未到 `succeeded` 就不能结案）
- `waiting_agent` 看完图却不调 `submit_review_batch` / `ack_agent_step` 就结束
- 把 `.aireel/pipeline/jobs/.../clips` 临时路径当作最终交付路径汇报给用户

## 配置提示

若 Job 报「未配置模板」，让用户在 Studio「流水线」面板绑定 `ref_*` / `shot_video` 模板。

多 Comfy 实例：Studio 会自动用全部已启用且在线的实例并行生成；你无需也不应只盯一台。步骤详情里会出现 `并行×N · server...`。
