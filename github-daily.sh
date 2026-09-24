#!/usr/bin/env bash
#
# github-daily.sh — 每日汇总 GitHub 上自己名下各仓库的待处理 PR / issue
#
# 用法:
#   ./github-daily.sh                 # 打印 Markdown 汇总到终端
#   ./github-daily.sh > report.md     # 存成报告文件
#   ./github-daily.sh -u someoneelse  # 统计别的账号名下的仓库
#
# 依赖: gh (已登录)、curl、python3
# 说明: 只统计 OWNER 名下、非 fork 的仓库(含私有); 只列 open 状态的 PR/issue。
#
# 想每天自动跑, 加一条 crontab (crontab -e), 例如每天 9:00 生成报告:
#   0 9 * * * /Users/weibh/projects/ts/dsh-plugins/github-daily.sh > ~/github-daily.md 2>/dev/null
# 环境变量: GITHUB_DAILY_OWNER(账号) / GITHUB_DAILY_PROXY(默认 http://127.0.0.1:7897)

set -euo pipefail

OWNER="${GITHUB_DAILY_OWNER:-weibaohui}"
API=https://api.github.com/graphql
PROXY="${GITHUB_DAILY_PROXY:-http://127.0.0.1:7897}"

while getopts "u:h" opt; do
  case "$opt" in
    u) OWNER="$OPTARG" ;;
    h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "缺少 gh，请先安装并 gh auth login" >&2; exit 1; }

TOKEN="$(gh auth token)" || { echo "未登录 gh，请先 gh auth login" >&2; exit 1; }

# 走本地代理访问 GitHub(直连不通时)；失败则退回直连再试一次
gql() {
  local payload_file="$1"
  curl -sS --fail-with-body --max-time 60 \
    -x "$PROXY" -X POST "$API" \
    -H "Authorization: bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d @"$payload_file"
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------- 第 1 步
# 拉取仓库列表 + 每个仓库的 open PR/issue 数量。
# GraphQL 单页上限 100 条，用 cursor 翻页直到 hasNextPage=false。
echo "正在查询 $OWNER 名下的仓库…" >&2

cursor=""
page=0
: > "$WORKDIR/repos.tsv"
while :; do
  page=$((page + 1))
  after_clause=""
  [ -n "$cursor" ] && after_clause=", after: \"$cursor\""

  python3 - "$WORKDIR/page_req.json" "$OWNER" "$after_clause" <<'PY'
import json, sys
path, owner, after = sys.argv[1], sys.argv[2], sys.argv[3]
query = f'''query {{
  user(login: "{owner}") {{
    repositories(first: 100, ownerAffiliations: OWNER, isFork: false,
                 orderBy: {{field: PUSHED_AT, direction: DESC}}{after}) {{
      pageInfo {{ hasNextPage endCursor }}
      nodes {{
        name
        isPrivate
        pullRequests(states: OPEN, first: 1) {{ totalCount }}
        issues(states: OPEN, first: 1) {{ totalCount }}
      }}
    }}
  }}
}}'''
json.dump({"query": query}, open(path, "w"))
PY

  gql "$WORKDIR/page_req.json" > "$WORKDIR/page_resp.json" || {
    echo "查询仓库列表失败(第 ${page} 页)。若代理不可用，可试 GITHUB_DAILY_PROXY= $0" >&2
    exit 1
  }

  # 逐行输出: name \t isPrivate \t prCount \t issueCount \t hasNext \t endCursor
  python3 - "$WORKDIR/page_resp.json" <<'PY' >> "$WORKDIR/repos.tsv"
import json, sys
d = json.load(open(sys.argv[1]))
if "errors" in d:
    sys.stderr.write("GitHub 返回错误: %s\n" % d["errors"][0].get("message"))
    sys.exit(1)
repos = d["data"]["user"]["repositories"]
pi = repos["pageInfo"]
for n in repos["nodes"]:
    print("%s\t%s\t%s\t%s\t%s\t%s" % (
        n["name"], n["isPrivate"],
        n["pullRequests"]["totalCount"], n["issues"]["totalCount"],
        pi["hasNextPage"], pi["endCursor"] or ""))
PY

  has_next="$(tail -1 "$WORKDIR/repos.tsv" | cut -f5)"
  cursor="$(tail -1 "$WORKDIR/repos.tsv" | cut -f6)"
  [ "$has_next" = "True" ] && [ -n "$cursor" ] || break
  [ "$page" -ge 10 ] && break   # 安全上限，防意外死循环
done

# 只保留有 open PR/issue 的仓库
awk -F'\t' '$3+0 > 0 || $4+0 > 0' "$WORKDIR/repos.tsv" > "$WORKDIR/active.tsv"
TOTAL_REPOS=$(wc -l < "$WORKDIR/repos.tsv" | tr -d ' ')
ACTIVE_REPOS=$(wc -l < "$WORKDIR/active.tsv" | tr -d ' ')

echo "共 $TOTAL_REPOS 个仓库，其中 $ACTIVE_REPOS 个有待处理项。" >&2

# ---------------------------------------------------------------- 第 2 步
# 只对有内容的仓库拉明细，每次最多 25 个仓库(别名批量)，减少往返。
: > "$WORKDIR/details.jsonl"

if [ "$ACTIVE_REPOS" -gt 0 ]; then
  echo "正在拉取 PR/issue 明细…" >&2
  split -l 25 "$WORKDIR/active.tsv" "$WORKDIR/chunk_"

  for chunk in "$WORKDIR"/chunk_*; do
    python3 - "$chunk" "$WORKDIR/detail_req.json" "$OWNER" <<'PY'
import json, sys
chunk, out, owner = sys.argv[1], sys.argv[2], sys.argv[3]
names = [l.split("\t")[0] for l in open(chunk) if l.strip()]
parts = []
for i, name in enumerate(names):
    parts.append(f'''  r{i}: repository(owner: "{owner}", name: "{name}") {{
    name
    isPrivate
    pullRequests(states: OPEN, first: 50, orderBy: {{field: CREATED_AT, direction: DESC}}) {{
      nodes {{ number title author {{ login }} createdAt isDraft reviewDecision }}
    }}
    issues(states: OPEN, first: 50, orderBy: {{field: CREATED_AT, direction: DESC}}) {{
      nodes {{ number title author {{ login }} createdAt }}
    }}
  }}''')
json.dump({"query": "query {\n" + "\n".join(parts) + "\n}"}, open(out, "w"))
PY

    gql "$WORKDIR/detail_req.json" > "$WORKDIR/detail_resp.json" || {
      echo "拉取明细失败，请稍后重试。" >&2
      exit 1
    }
    python3 - "$WORKDIR/detail_resp.json" <<'PY' >> "$WORKDIR/details.jsonl"
import json, sys
d = json.load(open(sys.argv[1]))
if "errors" in d:
    sys.stderr.write("明细查询出错: %s\n" % d["errors"][0].get("message"))
data = d.get("data") or {}
for repo in data.values():
    if not repo:
        continue
    print(json.dumps(repo, ensure_ascii=False))
PY
  done
fi

# ---------------------------------------------------------------- 第 3 步
# 渲染 Markdown 汇总。排序: 仓库内先 PR 后 issue；仓库间按待处理总数降序。
echo "正在生成汇总…" >&2
python3 - "$WORKDIR/details.jsonl" "$WORKDIR/repos.tsv" "$OWNER" <<'PY'
import json, sys
from datetime import datetime, timezone

details_path, repos_path, owner = sys.argv[1], sys.argv[2], sys.argv[3]

repos = []
for line in open(details_path, encoding="utf-8"):
    if line.strip():
        repos.append(json.loads(line))

# 明细里没出现的仓库(理论上不会有)用计数兜底，保证总数不丢
seen = {r["name"] for r in repos}
for line in open(repos_path, encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 4 and f[0] not in seen and (int(f[2]) or int(f[3])):
        repos.append({"name": f[0], "isPrivate": f[1] == "True",
                      "pullRequests": {"nodes": []}, "issues": {"nodes": []}})

for r in repos:
    r["_prs"] = r.get("pullRequests", {}).get("nodes") or []
    r["_iss"] = r.get("issues", {}).get("nodes") or []
    r["_total"] = len(r["_prs"]) + len(r["_iss"])
repos = [r for r in repos if r["_total"] > 0]
repos.sort(key=lambda r: (-r["_total"], r["name"].lower()))

total_pr = sum(len(r["_prs"]) for r in repos)
total_iss = sum(len(r["_iss"]) for r in repos)
now = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M %Z")

print(f"# GitHub 待处理汇总 · {owner}")
print()
print(f"生成时间: {now}")
print()
print(f"**待处理 PR: {total_pr}** ｜ **待处理 issue: {total_iss}** ｜ "
      f"涉及仓库: {len(repos)} 个")
print()

if not repos:
    print("所有仓库当前都没有 open 的 PR 或 issue。")
    sys.exit(0)


def age(iso):
    """把 ISO 时间转成 'x 天前'，用于判断积压时长。"""
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        d = (datetime.now(timezone.utc) - t).days
        if d == 0:
            return "今天"
        if d == 1:
            return "1 天前"
        if d < 30:
            return f"{d} 天前"
        if d < 365:
            return f"{d // 30} 个月前"
        return f"{d // 365} 年前"
    except Exception:
        return ""


print("## 按仓库明细")
print()
for r in repos:
    vis = " (私有)" if r.get("isPrivate") else ""
    print(f"### {r['name']}{vis} — PR {len(r['_prs'])} ｜ issue {len(r['_iss'])}")
    print()
    if r["_prs"]:
        print("| 类型 | 编号 | 标题 | 作者 | 开启 | 状态 |")
        print("| --- | --- | --- | --- | --- | --- |")
        for p in r["_prs"]:
            title = (p.get("title") or "").replace("|", "\\|")
            who = (p.get("author") or {}).get("login") or "-"
            flags = []
            if p.get("isDraft"):
                flags.append("草稿")
            rd = p.get("reviewDecision")
            if rd:
                flags.append({"APPROVED": "已批准",
                              "CHANGES_REQUESTED": "要求修改",
                              "REVIEW_REQUIRED": "待评审"}.get(rd, rd))
            print(f"| PR | #{p['number']} | {title} | {who} | "
                  f"{age(p.get('createdAt', ''))} | {'、'.join(flags) or '-'} |")
    if r["_iss"]:
        if not r["_prs"]:
            print("| 类型 | 编号 | 标题 | 作者 | 开启 |")
            print("| --- | --- | --- | --- | --- |")
        for i in r["_iss"]:
            title = (i.get("title") or "").replace("|", "\\|")
            who = (i.get("author") or {}).get("login") or "-"
            print(f"| issue | #{i['number']} | {title} | {who} | "
                  f"{age(i.get('createdAt', ''))} |")
    print()

print("## 速览")
print()
print("| 仓库 | PR | issue | 合计 |")
print("| --- | --- | --- | --- |")
for r in repos:
    print(f"| {r['name']} | {len(r['_prs'])} | {len(r['_iss'])} | {r['_total']} |")
print(f"| **合计** | **{total_pr}** | **{total_iss}** | **{total_pr + total_iss}** |")
PY
