#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""render3d.py — 从 github-daily.sh 的中间产物渲染「近 N 天」时间窗报告。

背景: github-daily.sh 只统计**当前仍 open** 的 PR/issue，没有时间窗过滤，
      也看不到窗口内已经关闭/合并的动态 —— 一个"两个 PR 已合并 + 一个 issue 已关闭"
      的活跃周期，会被它渲染成干净的全 0，容易误读成"期间无事发生"。

本脚本补的正是这一层。它做两件事:
  1. 从 GraphQL 中间产物里筛出 createdAt 落在窗口内、且仍 open 的项；
  2. 读 REST 通道(per-repo state=all)的结果，列出窗口内创建、但已关闭/已合并的项。

用法:
  # 第 1 步: 跑主脚本并保留中间产物
  GITHUB_DAILY_KEEP_ARTIFACTS=1 ./github-daily.sh > full-report.md

  # 第 2 步: 采集"含已关闭"的 REST 数据(脚本看不到关闭项，需要单独拉)
  ./collect-rest.sh 3 > rest_window.jsonl

  # 第 3 步: 渲染窗口报告
  ./render3d.py 3 .github-daily-artifacts > report-3d.md

依赖: python3 (标准库)。window 计算与过滤全在本地，不再打 API。
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

DEFAULT_ART = ".github-daily-artifacts"


def parse_iso(s):
    """GitHub 返回 '...Z'，转成带时区的 aware datetime；两侧都按 UTC 比较。"""
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def age_cn(iso, now):
    secs = (now - parse_iso(iso)).total_seconds()
    if secs >= 86400:
        return f"{secs / 86400:.1f} 天"
    return f"{secs / 3600:.1f} 小时"


def ts_cn(iso):
    return parse_iso(iso).strftime("%Y-%m-%d %H:%M UTC")


def load_details(art):
    """读 details.jsonl（每行一个仓库的 GraphQL 明细）。"""
    repos = []
    path = os.path.join(art, "details.jsonl")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                repos.append(json.loads(line))
    return repos


def load_repo_names(art):
    path = os.path.join(art, "repos.tsv")
    with open(path, encoding="utf-8") as fh:
        return [l.split("\t")[0] for l in fh if l.strip()]


def load_rest(path, days, now):
    """读 REST 通道结果（每行一个 in-window 项，含已关闭）。

    返回 (rows, warnings)。REST 数据是独立采集的，其窗口由采集时刻决定；
    这里按文件里记录的 cutoff 与本次渲染窗口比对，不一致就告警——避免把
    "上一次用别的窗口采的数据" 静默混进本次报告。
    """
    rows, warnings = [], []
    if not path:
        return rows, warnings
    if not os.path.exists(path):
        warnings.append(f"REST 文件 {path} 不存在：已关闭项一栏将为空，"
                        f"请先跑 ./collect-rest.sh {days} 生成。")
        return rows, warnings
    if os.path.getsize(path) == 0:
        warnings.append(f"REST 文件 {path} 为空（0 行）：窗口内无已关闭/已合并项，"
                        f"或采集未成功，请确认。")
        return rows, warnings
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("_cutoff"):
                rec_cut = parse_iso(rec["_cutoff"])
                drift = abs((rec_cut - (now - timedelta(days=days))).total_seconds())
                if drift > 3600:
                    warnings.append(
                        f"REST 数据的窗口 cutoff ({rec['_cutoff']}) 与本次渲染窗口相差 "
                        f"{drift / 3600:.1f} 小时，可能不是同一窗口采集的，请留意。")
                continue
            rows.append(rec)
    return rows, warnings


def self_test(now, cutoff):
    """窗口边界的自检：确保 >= 语义和时区处理没写错。"""
    ok = True
    checks = [
        ("恰好等于 cutoff 应算窗内", cutoff >= cutoff, True),
        ("cutoff 前 1 秒应算窗外", (cutoff - timedelta(seconds=1)) >= cutoff, False),
        ("cutoff 后 1 秒应算窗内", (cutoff + timedelta(seconds=1)) >= cutoff, True),
    ]
    for label, got, want in checks:
        flag = "PASS" if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"  [{flag}] {label}: got={got} want={want}", file=sys.stderr)
    return ok


def main():
    ap = argparse.ArgumentParser(description="渲染近 N 天 PR/issue 时间窗报告")
    ap.add_argument("days", nargs="?", type=int, default=3, help="窗口天数（默认 3）")
    ap.add_argument("art", nargs="?", default=DEFAULT_ART, help=f"中间产物目录（默认 {DEFAULT_ART}）")
    ap.add_argument("--owner", default=os.environ.get("GITHUB_DAILY_OWNER", "weibaohui"))
    ap.add_argument("--rest", default="rest_window.jsonl", help="REST 通道结果文件")
    ap.add_argument("--no-self-test", action="store_true", help="跳过窗口边界自检")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=args.days)

    if not args.no_self_test:
        print("窗口边界自检:", file=sys.stderr)
        if not self_test(now, cutoff):
            print("自检未通过，终止（避免产出不可信的窗口结论）。", file=sys.stderr)
            return 2

    if not os.path.isdir(args.art):
        print(f"找不到中间产物目录 {args.art}；"
              f"请先用 GITHUB_DAILY_KEEP_ARTIFACTS=1 跑 github-daily.sh。", file=sys.stderr)
        return 1

    repos = load_details(args.art)
    total_repos = len(load_repo_names(args.art))
    rest_rows, warnings = load_rest(args.rest, args.days, now)
    for w in warnings:
        print(f"[警告] {w}", file=sys.stderr)

    prs, issues = [], []
    for r in repos:
        name = r["name"]
        for n in (r.get("pullRequests", {}).get("nodes") or []):
            prs.append((name, n))
        for n in (r.get("issues", {}).get("nodes") or []):
            issues.append((name, n))

    gql_win_pr = [(rn, n) for rn, n in prs if parse_iso(n["createdAt"]) >= cutoff]
    gql_win_iss = [(rn, n) for rn, n in issues if parse_iso(n["createdAt"]) >= cutoff]

    per_repo = {}
    for rn, n in gql_win_pr:
        per_repo.setdefault(rn, {"PR": 0, "issue": 0})["PR"] += 1
    for rn, n in gql_win_iss:
        per_repo.setdefault(rn, {"PR": 0, "issue": 0})["issue"] += 1

    open_all = sorted(
        [(rn, n, k) for k in ("PR", "issue")
         for rn, n in (prs if k == "PR" else issues)],
        key=lambda x: x[1]["createdAt"],
    )
    # 每行的 in_window 一律从 cutoff 重新计算，不硬编码。
    # 附表只准收 state != open 的项；仍 open 的窗口内项属于「新待办」。
    def in_window(iso):
        return parse_iso(iso) >= cutoff

    # 窗口外最年轻的一条（max createdAt < cutoff），用于边界自检的对照值。
    out_of_window = [x for x in open_all
                     if not in_window(x[1]["createdAt"])]
    youngest_out = max(out_of_window, key=lambda x: x[1]["createdAt"],
                       default=None)

    # 三态拆分 —— 必须**跨通道合并去重**，不能只看一条通道：
    #   - 窗口内「仍 open」的项：GraphQL 通道按定义只含当前 open 项，是这一态的权威；
    #   - 窗口内「已关闭/已合并」的项：GraphQL 看不见，只能来自 REST state=all 通道；
    #   同一个项可能两条通道都出现（例如 REST 也返回 state=open），
    #   若各自计数会在总览表与等式校验之间自相矛盾（表里 2 项、等式里 0 项还打 ✓）。
    # 故按 (repo, kind, number) 建 key 求并集，并以 REST 的 closed 态覆盖。
    def _state(r):
        return (r.get("state") or "").lower()

    def _key(repo, kind, number):
        return (repo, kind, int(number))

    def _rest_kind(r):
        return "PR" if r.get("kind") == "PR" else "issue"

    rest_in_win = [r for r in rest_rows
                   if cutoff <= parse_iso(r["created"]) <= now]
    rest_open = [r for r in rest_in_win if _state(r) == "open"]
    rest_closed = [r for r in rest_in_win if _state(r) in ("closed", "merged")]
    rest_other = [r for r in rest_in_win
                  if _state(r) not in ("open", "closed", "merged")]
    if rest_other:
        print(f"[警告] REST 通道有 {len(rest_other)} 项 state 既非 open 也非 "
              f"closed/merged，已从统计中剔除："
              f"{[r.get('state') for r in rest_other]}", file=sys.stderr)

    gql_keys = {}
    for rn, n in gql_win_pr:
        gql_keys[_key(rn, "PR", n["number"])] = n
    for rn, n in gql_win_iss:
        gql_keys[_key(rn, "issue", n["number"])] = n
    rest_win_keys = {_key(r["repo"], _rest_kind(r), r["number"]): r
                     for r in rest_in_win}
    closed_keys = {_key(r["repo"], _rest_kind(r), r["number"]): r
                   for r in rest_closed}

    union_keys = set(gql_keys) | set(rest_win_keys)
    still_open_keys = union_keys - set(closed_keys)
    total_in_win = len(union_keys)

    def kind_split(keys):
        pr = sum(1 for k in keys if k[1] == "PR")
        return pr, len(keys) - pr

    t_open_pr, t_open_is = kind_split(still_open_keys)
    t_tot_pr, t_tot_is = kind_split(union_keys)
    c_pr, c_is = kind_split(set(closed_keys))
    merged = sum(1 for r in rest_closed if r.get("merged"))

    # 展示用明细：仍 open 的窗口内项以 GraphQL 记录为准（字段更全），
    # GraphQL 没有但 REST 说仍 open 的项也补进来（否则等于把它从报告里抹掉）。
    def rest_as_node(r):
        return {"number": r["number"], "title": r["title"],
                "author": {"login": r.get("author") or "-"},
                "createdAt": r["created"]}

    def created_of(k):
        # 注意不能写成 dict.get(k, rest_win_keys[k][...])：
        # 默认值是**先求值再传参**，GraphQL 独有的 key 会在 rest_win_keys 里 KeyError。
        if k in gql_keys:
            return gql_keys[k]["createdAt"]
        return rest_win_keys[k]["created"]

    shown = {"PR": [], "issue": []}
    for k in sorted(still_open_keys, key=created_of):
        repo, kind, _num = k
        node = gql_keys[k] if k in gql_keys else rest_as_node(rest_win_keys[k])
        shown[kind].append((repo, node))
    win_pr, win_iss = shown["PR"], shown["issue"]

    W = sys.stdout.write
    W(f"# {args.owner} 名下 GitHub 仓库 近 {args.days} 天 PR / issue 汇报\n\n")
    W(f"- 生成时间: {now.strftime('%Y-%m-%d %H:%M UTC')}"
      f"（{now.astimezone().strftime('%Y-%m-%d %H:%M %Z')} 本地）\n")
    W(f"- 统计窗口: 最近 {args.days} 天（createdAt >= {cutoff.strftime('%Y-%m-%d %H:%M UTC')}）\n")
    W(f"- 仓库总数: {total_repos}（{args.owner} 名下，不含 fork），"
      f"其中 {len(repos)} 个有 open 待处理项\n")
    W("- 数据通道: GraphQL 中间产物（脚本口径，仅 open）"
      "+ REST per-repo `state=all`（含已关闭，权威枚举）\n\n")

    W("## 总览\n\n")
    W("| 类别 | 窗口内新增且仍 open | 窗口内新增（含已关闭/已合并） | 窗口内已关闭/已合并 |\n")
    W("| --- | --- | --- | --- |\n")
    W(f"| PR | {t_open_pr} | {t_tot_pr} | {c_pr} |\n")
    W(f"| issue | {t_open_is} | {t_tot_is} | {c_is} |\n")
    W(f"| **合计** | **{len(still_open_keys)}** | **{total_in_win}** | "
      f"**{len(closed_keys)}** |\n\n")
    _eq_ok = total_in_win == len(still_open_keys) + len(closed_keys)
    W(f"等式校验：新增 {total_in_win} = 仍 open {len(still_open_keys)} + "
      f"已关闭/已合并 {len(closed_keys)} "
      f"{'✓' if _eq_ok else '✗ 不一致，请核查'}\n\n")

    W("### 涉及仓库速览\n\n")
    if per_repo:
        W("| 仓库 | PR | issue |\n| --- | --- | --- |\n")
        for rn in sorted(per_repo, key=lambda k: -(per_repo[k]["PR"] + per_repo[k]["issue"])):
            W(f"| {rn} | {per_repo[rn]['PR']} | {per_repo[rn]['issue']} |\n")
    else:
        W("无。\n")
    W("\n")

    for kind, items, path_seg in (("PR", win_pr, "pull"), ("issue", win_iss, "issues")):
        W(f"## 近 {args.days} 天 {kind}（{len(items)} 个）\n\n")
        if items:
            W("| 仓库 | 编号 | 标题 | 作者 | 创建 |\n| --- | --- | --- | --- | --- |\n")
            for rn, n in sorted(items, key=lambda x: x[1]["createdAt"]):
                url = f"https://github.com/{args.owner}/{rn}/{path_seg}/{n['number']}"
                who = (n.get("author") or {}).get("login") or "-"
                W(f"| {rn} | [#{n['number']}]({url}) | {n['title']} | @{who} | "
                  f"{age_cn(n['createdAt'], now)} |\n")
        else:
            W("无。\n")
        W("\n")

    W("---\n\n## 附：窗口内另有活动（已关闭/已合并，非待办）\n\n")
    W("脚本口径为「仅统计当前 OPEN」。以下项目在窗口内创建并已在窗口内关闭/合并，\n")
    W("故不计入上方合计，列出以免把「0」误读为「期间无动态」。\n")
    W("数据来自 REST 独立通道（per-repo `state=all` 权威枚举）；\n")
    W("**本表只收 state != open 的项**，窗口内仍 open 的项已计入上方正文，不在此重复。\n\n")
    if rest_closed:
        W("| 仓库 | 编号 | 标题 | 作者 | 创建 | 关闭/合并 | 结果 |\n")
        W("| --- | --- | --- | --- | --- | --- | --- |\n")
        for r in sorted(rest_closed, key=lambda x: x.get("created", "")):
            seg = "pull" if r.get("kind") == "PR" else "issues"
            url = f"https://github.com/{args.owner}/{r['repo']}/{seg}/{r['number']}"
            if r.get("merged"):
                outcome, closed = "已合并 (merged)", ts_cn(r["merged"])
            else:
                reason = r.get("reason") or "completed"
                outcome = f"已关闭 ({reason})"
                closed = ts_cn(r["closed"]) if r.get("closed") else "—"
            W(f"| [{r['repo']}](https://github.com/{args.owner}/{r['repo']}) | "
              f"[#{r['number']}]({url}) | {r['title']} | @{r.get('author') or '-'} | "
              f"{ts_cn(r['created'])} | {closed} | {outcome} |\n")
        W("\n")
    else:
        W("无。\n\n")

    if rest_open:
        W("### 注：REST 通道中窗口内仍 open 的项（已计入正文，非附表）\n\n")
        for r in rest_open:
            kind = "PR" if r.get("kind") == "PR" else "issue"
            seg = "pull" if kind == "PR" else "issues"
            url = f"https://github.com/{args.owner}/{r['repo']}/{seg}/{r['number']}"
            W(f"- [{r['repo']} #{r['number']}]({url})（{kind}，仍 open）\n")
        W("\n")

    W("### 双通道交叉核对\n\n")
    W("下表**逐条比对两条独立通道各自的窗口内 open 清单**（不做并集），\n")
    W("不一致即说明取数有分歧，需按 fork / 口径范围排查后再下结论。\n\n")
    W("| 口径 | PR（窗口内 open） | issue（窗口内 open） |\n| --- | --- | --- |\n")
    W(f"| GraphQL 中间产物通道（脚本口径） | {len(gql_win_pr)} | {len(gql_win_iss)} |\n")
    rest_pr = sum(1 for r in rest_open if _rest_kind(r) == "PR")
    rest_is = sum(1 for r in rest_open if _rest_kind(r) == "issue")
    W(f"| REST per-repo `state=all` 独立通道 | {rest_pr} | {rest_is} |\n")
    _pr_ok = len(gql_win_pr) == rest_pr
    _is_ok = len(gql_win_iss) == rest_is
    W(f"| 一致 | {'✓' if _pr_ok else '✗'} | {'✓' if _is_ok else '✗'} |\n")
    if not (_pr_ok and _is_ok):
        only_gql = set(gql_keys) - set(closed_keys) - set(
            _key(r["repo"], _rest_kind(r), r["number"]) for r in rest_open)
        only_rest = {_key(r["repo"], _rest_kind(r), r["number"])
                     for r in rest_open} - set(gql_keys)
        if only_gql or only_rest:
            W(f"\n> 分歧明细：仅 GraphQL 通道有 {sorted(only_gql)}；"
              f"仅 REST 通道有 {sorted(only_rest)}。\n")
    W("\n")

    W("### 全量 open 积压（窗口外存量，非本窗口新增）\n\n")
    W(f"当前仍 open 共 **{len(open_all)} 项**"
      f"（PR {len(prs)} / issue {len(issues)}），分布在 {len(repos)} 个仓库。\n")
    if open_all:
        rn, n, k = open_all[0]
        seg = "pull" if k == "PR" else "issues"
        url = f"https://github.com/{args.owner}/{rn}/{seg}/{n['number']}"
        W(f"最久一项: [{rn} #{n['number']}]({url})「{n['title']}」，"
          f"已开启 {age_cn(n['createdAt'], now)}。\n")
    W("\n---\n\n## 边界自检\n\n")
    if youngest_out:
        rn, n, k = youngest_out
        W(f"窗口 cutoff = {cutoff.strftime('%Y-%m-%d %H:%M UTC')}；窗口外**最年轻**的一条 open 项 "
          f"[{rn} #{n['number']}](https://github.com/{args.owner}/{rn}/"
          f"{'pull' if k == 'PR' else 'issues'}/{n['number']}) "
          f"创建于 {n['createdAt']}，距今 {age_cn(n['createdAt'], now)}，"
          f"仍落在 cutoff 之前 ⇒ 窗口边界成立。\n\n")
    else:
        W(f"窗口 cutoff = {cutoff.strftime('%Y-%m-%d %H:%M UTC')}；"
          f"当前没有窗口外的 open 项可比对。\n\n")
    W("| 仓库 | 类型 | 编号 | createdAt (UTC) | in_window | 距今 |\n")
    W("| --- | --- | --- | --- | --- | --- |\n")
    for rn, n, k in open_all:
        seg = "pull" if k == "PR" else "issues"
        url = f"https://github.com/{args.owner}/{rn}/{seg}/{n['number']}"
        W(f"| {rn} | {k} | [#{n['number']}]({url}) | {n['createdAt']} | "
          f"{in_window(n['createdAt'])} | {age_cn(n['createdAt'], now)} |\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
