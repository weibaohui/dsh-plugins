#!/usr/bin/env bash
#
# collect-rest.sh — 采集「窗口内创建、含已关闭/已合并」的 PR/issue（REST 通道）
#
# 为什么需要它: github-daily.sh 走 GraphQL 且只请求 OPEN 状态，所以窗口内已经
# 关闭/合并的项它看不见 —— 那部分往往才是一个周期的真实动态。本脚本按仓库逐个
# 拉 state=all，把窗口内的项(无论 open/closed)全部列出来，供 render3d.py 渲染。
#
# 用法:
#   GITHUB_DAILY_KEEP_ARTIFACTS=1 ./github-daily.sh > full-report.md
#   ./collect-rest.sh 3 .github-daily-artifacts/repos.tsv > rest_window.jsonl
#   ./render3d.py 3 .github-daily-artifacts --rest rest_window.jsonl > report-3d.md
#
# 依赖: gh (已登录)、python3。

set -euo pipefail

case "${1:-}" in
  -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

DAYS="${1:-3}"
REPOS_TSV="${2:-.github-daily-artifacts/repos.tsv}"

command -v gh >/dev/null || { echo "缺少 gh，请先安装并 gh auth login" >&2; exit 1; }
[ -f "$REPOS_TSV" ] || {
  echo "找不到仓库列表 ${REPOS_TSV}；请先用 GITHUB_DAILY_KEEP_ARTIFACTS=1 跑 github-daily.sh。" >&2
  exit 1
}

CUTOFF="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(days=$DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
echo "窗口 cutoff = ${CUTOFF}；逐仓库拉取 state=all…" >&2

# 首行写入本次采集的 cutoff，供 render3d.py 校验"这份 REST 数据是不是同一窗口采的"。
python3 -c "
import json
print(json.dumps({'_cutoff': '${CUTOFF}'}))
"

while read -r repo; do
  [ -z "$repo" ] && continue
  for endpoint in issues pulls; do
    # /issues 端点会连 PR 一起返回（GitHub REST 的已知行为），下游按 pull_request
    # 字段区分并与 /pulls 的结果去重。
    # 注意: gh api 的 --jq 只接受单个参数，写 `--jq -c '.'` 会报
    # "accepts 1 arg(s), received 2"；用 `.[] | @json` 让它一个对象一行输出。
    gh api "repos/${OWNER:-weibaohui}/${repo}/${endpoint}?state=all&sort=created&direction=desc&per_page=100" \
      --jq '.[] | @json' 2>/dev/null || continue
  done
done < <(cut -f1 "${REPOS_TSV}") | python3 -c "
import json, sys

cutoff = '${CUTOFF}'
seen = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        it = json.loads(line)
    except Exception:
        continue
    if not isinstance(it, dict):
        continue
    if it.get('created_at', '') < cutoff:
        continue
    repo = (it.get('repository_url') or '').rsplit('/', 1)[-1]
    if not repo:
        continue
    pr = it.get('pull_request') or {}
    is_pr = bool(pr)
    key = (repo, it['number'])
    rec = {
        'repo': repo,
        'kind': 'PR' if is_pr else 'issue',
        'number': it['number'],
        'title': it['title'],
        'created': it['created_at'],
        'closed': it.get('closed_at'),
        'merged': pr.get('merged_at') if is_pr else None,
        'state': it['state'],
        'reason': it.get('state_reason'),
        'author': (it.get('user') or {}).get('login'),
    }
    # 去重: 同一 PR 会同时出现在 issues 和 pulls 两个端点，优先保留带 merged 信息的
    if key not in seen or (rec['merged'] and not seen[key]['merged']):
        seen[key] = rec

for rec in sorted(seen.values(), key=lambda r: r['created']):
    print(json.dumps(rec, ensure_ascii=False))
"
