# dsh-plugins

GitHub 待处理事项每日汇总脚本。

每天一条命令，看自己名下所有仓库有没有新 PR / 新 issue：哪些仓库在积压、哪些躺了太久没人管、有没有别人提的 PR 等你 review。

## 功能

- **只统计自己在维护的仓库**：`OWNER` 名下、**非 fork** 的仓库（含私有），上游 fork 项目的 PR/issue 不会混进来
- **列出 open 状态的 PR 和 issue**：带编号、标题、作者、**开启多久**（"3 个月前"这种，一眼看出积压时长）
- **PR 额外标注**草稿 / 已批准 / 要求修改
- **终端直接输出 Markdown**：可重定向存文件，也可直接粘进 issue、周报
- 末尾附一张「速览」表，按待处理量排序，先看主要矛盾

## 安装

需要 `gh`（已登录）、`curl`、`python3`：

```bash
git clone https://github.com/weibaohui/dsh-plugins.git
cd dsh-plugins
chmod +x github-daily.sh
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
| `GITHUB_DAILY_PROXY` | `http://127.0.0.1:7897` | 访问 GitHub 的本地代理；设为空字符串可直连 |

## 说明

- 走 GraphQL：先一次性取所有仓库的计数，**只对有内容的仓库拉明细**，再用别名批量（一次请求最多 25 个仓库），因此上百个仓库也在 10 秒内跑完
- 翻页按 cursor 手工实现（`gh api graphql --paginate` 在部分环境下会挂住），仓库数量继续增长也不会漏
- 只读操作，不会修改任何仓库内容

## 联系我

有想法或者问题，欢迎加飞书群一起聊。

![飞书群](https://weibaohui.github.io/imgs/feishu-group.png)
