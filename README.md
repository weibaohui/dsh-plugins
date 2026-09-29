# dsh-plugins

GitHub 待处理事项每日汇总脚本。

每天一条命令，看自己名下所有仓库有没有新 PR / 新 issue：哪些仓库在积压、哪些躺了太久没人管、有没有别人提的 PR 等你 review。

还能按时间窗看「最近 N 天」的动态（含已关闭/已合并的项），适合写周报。

## 功能

- **只统计自己在维护的仓库**：`OWNER` 名下、**非 fork** 的仓库（含私有），上游 fork 项目的 PR/issue 不会混进来
- **列出 open 状态的 PR 和 issue**：带编号、标题、作者、**开启多久**（"3 个月前"这种，一眼看出积压时长）
- **PR 额外标注**草稿 / 已批准 / 要求修改
- **终端直接输出 Markdown**：可重定向存文件，也可直接粘进 issue、周报
- 末尾附一张「速览」表，按待处理量排序，先看主要矛盾
- **时间窗报告（近 N 天）**：`render3d.py` 从中间产物渲染窗口报告，**并补上窗口内已关闭/已合并的项**

> ⚠️ 为什么需要单独的时间窗报告：主脚本只统计**当前仍 open** 的项。
> 如果这 3 天里两个 PR 合并了、一个 issue 关闭了，主脚本会渲染成干净的全 0，
> 看起来像"期间无事发生"——实际上很活跃。`render3d.py` 通过 REST 通道
> （per-repo `state=all`）把已关闭项补回来，这类"0"才不会被误读。

## 安装

需要 `gh`（已登录）、`curl`、`python3`：

```bash
git clone https://github.com/weibaohui/dsh-plugins.git
cd dsh-plugins
chmod +x github-daily.sh render3d.py collect-rest.sh
```

## 使用

```bash
./github-daily.sh                  # 终端打印 Markdown 汇总
./github-daily.sh > report.md      # 存成报告文件
./github-daily.sh -u someoneelse   # 统计别的账号名下的仓库
./github-daily.sh -h               # 看帮助
```

输出长这样：

```
# GitHub 待处理汇总 · weibaohui

生成时间: 2026-09-24 14:14 CST

**待处理 PR: 8** ｜ **待处理 issue: 36** ｜ 涉及仓库: 10 个

## 按仓库明细

### skills-management — PR 1 ｜ issue 0

| 类型 | 编号 | 标题 | 作者 | 开启 | 状态 |
| --- | --- | --- | --- | --- | --- |
| PR | #11 | fix: 技能市场面板闪退/空白+已装技能无标识+搜索卡顿 | tianyao2003 | 今天 | - |
...
```

## 时间窗报告（最近 N 天）

三步，看「最近 3 天」有哪些新增 PR/issue（含已被关闭、被合并的）：

```bash
# 1. 跑主脚本，并保留中间产物
GITHUB_DAILY_KEEP_ARTIFACTS=1 ./github-daily.sh > full-report.md

# 2. 采集"含已关闭"的 REST 数据（主脚本看不到关闭项，需单独拉）
./collect-rest.sh 3 .github-daily-artifacts/repos.tsv > rest_window.jsonl

# 3. 渲染窗口报告
./render3d.py 3 .github-daily-artifacts --rest rest_window.jsonl > report-3d.md
```

渲染结果含四段：窗口内新增且仍 open、**窗口内另有活动（已关闭/已合并）**、
双通道交叉核对、以及「全量 open 积压」——最后一节是为了把
「窗口内新增 0」和「仍积压 N 项」这两件事分开，别混成一句话。

`render3d.py` 会先做窗口边界自检（cutoff 前后 1 秒的归属），自检不过直接中止，
避免产出一份结论不可信的窗口报告。如果 REST 数据缺失、为空、或与本次渲染窗口不一致，
会在 stderr 给出**显式警告**而不是静默按 0 处理。

> 首次跑完可以先 `rm -rf .github-daily-artifacts rest_window.jsonl` 清掉中间产物。

## 每天自动跑

加一条 crontab（`crontab -e`），例如每天 9:00 生成报告：

```cron
0 9 * * * /Users/weibh/projects/ts/dsh-plugins/github-daily.sh > ~/github-daily.md 2>/dev/null
```

> macOS 上定时任务的环境变量与登录 shell 不同，若报「缺少 gh」，把脚本里的 `gh` 换成绝对路径（如 `/Users/weibh/.local/bin/gh`）即可。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GITHUB_DAILY_OWNER` | `weibaohui` | 统计哪个账号名下的仓库 |
| `GITHUB_DAILY_PROXY` | `http://127.0.0.1:7897` | 访问 GitHub 的本地代理；**设为空字符串**可直连（跳过探测） |
| `GITHUB_DAILY_KEEP_ARTIFACTS` | `0` | 设为 `1` 保留中间产物，供 `render3d.py` 做时间窗过滤 |
| `GITHUB_DAILY_ARTIFACT_DIR` | `./.github-daily-artifacts` | 中间产物保留目录 |

代理行为说明：设了代理时，脚本先探活一次。探不通会**自动回退直连**，并把实际决定
打印到 stderr（不会闷声失败）；想彻底不走代理就把它设为空字符串。

## 说明

- 走 GraphQL：先一次性取所有仓库的计数，**只对有内容的仓库拉明细**，再用别名批量（一次请求最多 25 个仓库），因此上百个仓库也在 10 秒内跑完
- 翻页按 cursor 手工实现（`gh api graphql --paginate` 在部分环境下会挂住），仓库数量继续增长也不会漏
- 只读操作，不会修改任何仓库内容

## 联系我

有想法或者问题，欢迎加飞书群一起聊。

![飞书群](https://weibaohui.github.io/imgs/feishu-group.png)
