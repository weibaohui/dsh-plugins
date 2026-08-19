# ntd → dsh 插件迁移方案

把 [ntd](https://github.com/weibaohui/ntd)（Now Task, Done）的任务域能力拆成 dsh 插件，收进本合集。源码位置：`~/projects/rust/nothing-todo`。

## 总映射

| ntd 概念 | ntd 实现 | dsh 机制 | 插件目录 | 阶段 |
|---|---|---|---|---|
| skills | `handlers/skills.rs` + `handlers/bundled.rs` + `expert/`，约 4600 行 Rust + 3800 行 TSX | `ctx.skills` provider 契约 + webServer 管理 API + web 管理界面 | `skills/` | P1 |
| 专家 | `expert/`（WorkBuddy plugin.json 格式，文件存储 + 内存索引 + 注入） | 执行时拼接进提交的 prompt；注册表挂宿主平面 | `experts/` | P2 |
| 事项 | `models/todo.rs` + `task_manager.rs` + `scheduler.rs` | scheduled-items 的泛化：cron 可选、六态生命周期、续连 | `todos/` | P3 |
| 工艺 | `services/process/`（YAML 文件为唯一真源，guid 寻址） | 文件扫描 + storageDomain 索引 + web 目录页 | `processes/` | P4 |
| 环路 | `services/loop_runner.rs` + gate/phase/transition/rework | 每步经 `ctx.agents` 起子会话；黑板走 storageDomain；croner 调度 | `loops/` | P5 |

## 核心判断

**dsh 本身就是执行器。** ntd 的 13 种执行器适配层、飞书集成、worktree 管理不搬；搬的是任务域模型与编排。跨执行器的功能（compare / version-update / sync）前提消失，由「市场库 → 用户库」的安装取代。

## 共同骨架（scheduled-items 已验证）

每个子目录一个独立包，零 `@deepseek-ai/*` npm 依赖，宿主半端经 `ctx.*` 运行时服务访问能力：

```
<module>/
├── package.json        # dsh-plugin-<module>，声明 dsh.bundle.patch + dsh.client
├── cordis.patch.yml    # insert 插件行进宿主组合
├── src/index.js        # 宿主半端
├── client/index.js     # 浏览器半端
├── client/bundle.js    # 构建产物
├── scripts/build-client.mjs
└── test/*.test.mjs     # 离线单测（CI matrix 直接复用）
```

安装：`dsh plugin --profile web add 'github:weibaohui/dsh-plugins#path:<module>' -w`

## 阶段验证标准（每阶段同一套）

1. 本地 `npm run check` + `npm test` 绿
2. scratch `DSH_HOME` 实测 `#path:` 安装，调和进 `dsh.profile.bundles`
3. `dsh --profile web` 启动后按模块的功能面打 API / 看 UI 验证
4. CI matrix 加项，README 表加行

## 不搬清单

执行器适配层、飞书全家族、worktree 管理、看板/仪表盘/纪念板、wiki 黑板对话、云端同步/备份/守护进程、Todo 模板/快捷按钮（dsh 侧由 preset/skill 生态覆盖）。

## 开放问题

1. **token 上限**（loops）：dsh 侧宿主插件能否读子会话用量待调研；读不到则 v1 只做步数上限。
2. **专家选择入口**（experts）：v1 用 API/创建事项时传 `expert` 字段；agent preset 生成后置。
3. **skill 调用追踪**（skills）：dsh 的 skill 调用走会话日志，追踪可从日志投影，v2 做。

各模块详案：[skills.md](skills.md)（P1，后续模块按阶段补）。
