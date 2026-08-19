# P1：skills 模块迁移详案

ntd 源码：`backend/src/handlers/skills.rs`（1649 行）、`backend/src/handlers/bundled.rs`（2958 行）、`backend/src/expert/`（解析共用）、`frontend/src/components/skills/`（3769 行 TSX）。用户文档：`docs/user-guide/features/skills-overview.md`。

## 一、要迁移重写的前端功能列表

按 ntd 的 4 个子视图 + 市场页逐一给出去留判定：

### 保留重写

| # | ntd 前端功能 | ntd 位置 | dsh 重写形态 |
|---|---|---|---|
| F1 | **技能市场（按来源浏览 + 全部技能两种模式，搜索/来源筛选/分页）** | `SkillMarketplace.tsx`（1000 行） | 全屏管理页主视图：市场库（`~/.ntd/bundled/skills` 30+ 来源合集）网格 + 搜索 + 来源筛选 |
| F2 | **技能详情抽屉（SKILL.md 渲染 + 元信息 + 文件清单）** | `SkillDetailDrawer.tsx`（300 行） | 市场卡片点开：frontmatter 元信息 + 正文 markdown 渲染 + 附带文件树 |
| F3 | **技能内文件浏览（树 + 单文件预览，含路径逃逸防护）** | `SkillFileBrowser.tsx`/`Modal.tsx`/`Preview.tsx`（749 行） | F2 内的文件面板，同一 API（`file` 接口） |
| F4 | **安装（选目标，市场 → 用户库）** | `SkillMarketplace.tsx` 内 `useSkillInstall` | 「安装到我的技能库」：市场技能复制进 `$DSH_HOME/skills/<name>/`，装完立即可被 `skill` 工具调用 |
| F5 | **已安装技能总览（卡片/列表双模式、搜索、统计）** | `SkillsOverview.tsx`（574 行）+ `SkillCardView.tsx` | 管理页第二个 tab：扫 `$DSH_HOME/skills/`，卡片视图 + 删除 |
| F6 | **删除已安装技能** | `SkillsOverview` 删除按钮 + `DELETE /api/skills` | F5 内，只对用户库 |
| F7 | **导入/导出（zip）** | `ImportExportModal.tsx`（281 行） | v1 保留导出（单个/全部打 zip 下载）；导入 v1 砍——市场安装已覆盖主路径，砍 `POST import` |

### 不迁移（前提消失）

| ntd 前端功能 | 为什么砍 |
|---|---|
| **10 来源 tab**（9 执行器 + agents 切换） | dsh 单执行器。「来源」从执行器变为市场来源（anthropics-skills 等 30+ 个），已在 F1 覆盖 |
| **对比分析**（`compare_skills`，同名 skill 跨执行器 diff，共享/独占） | 跨执行器前提消失 |
| **同步管理**（`SkillSync`，源执行器 → 多目标执行器复制） | 同上 |
| **版本更新**（`SkillVersionUpdate.tsx` 519 行 + `version_update_list`，跨执行器版本一致性检查） | 同上；市场技能的更新 = 重新安装覆盖，F4 天然覆盖 |
| **调用追踪 tab**（`invocations` 记录/分页） | dsh 侧 skill 调用走会话日志，模型可见 ⟺ 已记录；从日志投影是更对的路，v2 做 |
| **市场源同步配置**（`bundled/config`、git pull 状态） | v1 市场库只读本地目录（`~/.ntd/bundled` 或 config 指定），不内置 git 拉取；换库 = 改 config 指向别的目录 |

## 二、后端功能 → dsh 切入点

### 2.1 宿主半端（`src/index.js`）两条腿

**腿 1：SkillRegistry provider（模型可用性的核心）**

```js
inject: ['skills', ...]
ctx.skills.registerProvider((control) => ntdSkillsProvider)
```

照 `packages/skill/skill-filesystem` 的 provider 契约实现：

- **`list(options)`**：扫用户库 `$DSH_HOME/skills/`（installed 层，rank 高）+ 市场库（market 层，只读 rank 低）。每目录读 `SKILL.md` frontmatter（name/description/keywords），产出候选摘要
- **`get(name)`**：读 SKILL.md 全文返回 definition。目录/平铺 `.md` 两种形态都支持（ntd 市场两种都有）
- **frontmatter 解析**：照搬 `expert/parser.rs` 的 `parse_skill_metadata` 语义，用 `yaml` 包解析（dsh skill-filesystem 同款）；解析失败 warn + skip，不让一个坏文件炸整个目录扫描
- **失效**：装/删技能后调 `control.invalidate()`；v1 不做文件 watch（市场库是 git 目录，手动同步后重启或调刷新 API）
- **来源标记**：候选带 `provider` 与来源目录，`snapshot()` 里两层去重时用户库优先

这是插件的最大价值：**装上后 ntd 技能直接进 dsh 的 `skill` 工具目录**，模型按 name 调用，加载即注入——ntd 的「Todo 附加 Skills 拼 prompt」在 dsh 里由工具系统原生完成，不用重写。

**腿 2：webServer prefix route（管理界面的后端）**

`/skills-management/api` 下（照 scheduled-items 的 `/scheduled-items/api` 模式）：

| API | 对应 ntd | 说明 |
|---|---|---|
| `GET /` | `list_skills` + `list_bundled_skills` | `{ market: { sources, skills }, installed: [{ name, … }] }`；市场带来源/文件数/大小，装态合并展示 |
| `GET /detail?name=` | `get_skill_content` | SKILL.md 全文 + 文件清单（`collect_skill_files` 语义） |
| `GET /file?name=&path=` | `get_skill_file` | 单文件内容；**保留 ntd 的 canonicalize 前缀校验防路径逃逸** |
| `POST /install` | `install_bundled_skill` | 市场 → `$DSH_HOME/skills/<name>/` 复制（含 scripts/assets）；同名覆盖 = 更新 |
| `DELETE /?name=` | `delete_skill` | 删用户库技能；市场库只读不可删（ntd 对 `agents` 只读源的语义平移到市场库） |
| `GET /export` | `export_skill` | zip 下载（v1 只做用户库导出） |

安装/删除后：`invalidate()` + `domain/changed` 式广播让前端刷新。

### 2.2 浏览器半端（`client/index.js`）

一个全屏管理页（scheduled-items 同款挂法）：两个 tab——市场（F1/F2/F3/F4）+ 已安装（F5/F6/F7 导出）。复用 dsh web 外壳的主题 token 与组件风格，不依赖 antd（scheduled-items 的 client 是零依赖手写 DOM，沿用）。

### 2.3 config（cordis.yml 可改）

| key | 默认 | 说明 |
|---|---|---|
| `marketDirs` | `['~/.ntd/bundled/skills']` | 市场库目录列表（可指向任意 git 合集，如 dsh-plugins 自己的 skills 目录） |
| `installedDir` | `$DSH_HOME/skills` | 用户库目录 |
| `providerName` | `'ntd-skills'` | `ctx.skills` 注册名 |

## 三、验收清单（P1 完成定义）

- [ ] 单测：frontmatter 解析（含坏文件跳过）、目录/平铺双形态、路径逃逸拒绝
- [ ] scratch home 安装后 `dsh --profile web` 启动，市场 API 列出 `~/.ntd/bundled/skills` 的 30+ 来源
- [ ] 安装一个 anthropics 技能到用户库 → **在会话里模型能通过 `skill` 工具调到它**（端到端核心验证）
- [ ] 删除后 `skill` 工具目录同步消失
- [ ] 管理页双 tab 可用：搜索、详情、文件浏览、安装、删除、导出
- [ ] CI matrix 加 `skills` 项

## 四、明确不做（v1）

zip 导入、跨源 compare/sync/version-update、调用追踪投影、市场 git 自动同步、执行器目录扫描（`~/.claude/skills` 等由 dsh skill-filesystem 原生覆盖，本插件不重复）。
