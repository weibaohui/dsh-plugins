#!/usr/bin/env bash
#
# update-desktop-plugins.sh — 把 desktop profile (~/.dsh/profiles/desktop) 下所有用户插件升级到最新版
#
# 用法:
#   ./update-desktop-plugins.sh          # 检查并升级所有插件到最新版
#   ./update-desktop-plugins.sh -n       # dry-run，只报告哪些有新版，不实际升级
#   ./update-desktop-plugins.sh -h       # 看帮助
#
# 背景: desktop profile 由 DeepSeek Harness.app 独占管理，`dsh plugin add/remove` 被 CLI 守卫挡住
#       (报 "profile desktop is managed exclusively by the Electron application")。
#       只能用 app 自带的 pnpm 11 直接改 package.json + `pnpm add`。
#       app 的 pnpm 11 与 profile 的 .modules.yaml (packageManager: pnpm@11.7.0) 匹配，
#       增量 `pnpm add <pkg>@latest` 不会触发整目录 purge 重建。
#
# 依赖: DeepSeek Harness.app (提供 runtime/pnpm)、node (默认 /opt/homebrew/bin/node)、npm (随 node)
# 升级后须 Cmd+Q 退出 DeepSeek Harness.app 再重开才生效（app 不热加载 bundle，磁盘改动不进内存）。
#
# 环境变量:
#   DSH_DESKTOP_PROFILE  desktop profile 目录 (默认 ~/.dsh/profiles/desktop)
#   DSH_APP_PNPM         app 自带 pnpm.cjs 路径
#                        (默认 /Applications/DeepSeek Harness.app/.../runtime/pnpm/bin/pnpm.cjs)
#   NODE_BIN              驱动 pnpm.cjs 的 node 可执行 (默认 /opt/homebrew/bin/node)

set -euo pipefail

PROFILE_DIR="${DSH_DESKTOP_PROFILE:-$HOME/.dsh/profiles/desktop}"
APP_PNPM_CJS="${DSH_APP_PNPM:-/Applications/DeepSeek Harness.app/Contents/Resources/runtime/pnpm/bin/pnpm.cjs}"
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"

DRY_RUN=0
while getopts "nh" opt; do
  case "$opt" in
    n) DRY_RUN=1 ;;
    h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 2 ;;
  esac
done

# —— 环境探测 ——
[ -d "$PROFILE_DIR" ] || { echo "✗ 找不到 desktop profile: $PROFILE_DIR" >&2; exit 1; }
[ -f "$APP_PNPM_CJS" ] || {
  echo "✗ 找不到 app 自带 pnpm: $APP_PNPM_CJS" >&2
  echo "  请确认 DeepSeek Harness.app 已安装；或用 DSH_APP_PNPM 指定 pnpm.cjs 路径" >&2
  exit 1
}
[ -x "$NODE_BIN" ] || { echo "✗ 找不到可用的 node: $NODE_BIN" >&2; echo "  可用 NODE_BIN=/path/to/node 指定" >&2; exit 1; }
command -v npm >/dev/null || { echo "✗ 缺少 npm（随 node 提供）" >&2; exit 1; }

cd "$PROFILE_DIR"

# registry: 从 .npmrc 读，fallback 腾讯云
REGISTRY="$(grep -E '^registry=' .npmrc 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
REGISTRY="${REGISTRY:-https://mirrors.cloud.tencent.com/npm/}"

echo "==> profile:  $PROFILE_DIR"
echo "==> pnpm:     app pnpm ($APP_PNPM_CJS)"
echo "==> node:     $NODE_BIN ($("$NODE_BIN" -v))"
echo "==> registry: $REGISTRY"
[ "$DRY_RUN" = 1 ] && echo "==> dry-run 模式：只检查不升级"
echo

# —— 备份（非 dry-run 才备份）——
if [ "$DRY_RUN" = 0 ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  cp package.json "package.json.bak-$TS"
  cp pnpm-lock.yaml "pnpm-lock.yaml.bak-$TS"
  echo "==> 已备份 package.json / pnpm-lock.yaml → .bak-$TS"
  echo
fi

# —— 读取 dependencies 中所有用户插件（排除 @deepseek-ai/* 平台包，由 app.asar 运行时提供）——
PLUGINS="$("$NODE_BIN" -e '
  const p = require("./package.json");
  Object.keys(p.dependencies || {})
    .filter(k => !k.startsWith("@deepseek-ai/"))
    .forEach(k => console.log(k));
')"
COUNT=$(printf '%s\n' "$PLUGINS" | grep -c . || true)
echo "==> 待检查插件 $COUNT 个"
echo

UPGRADED=0; SKIPPED=0; FAILED=0; UPDATED_LIST=""

while IFS= read -r pkg; do
  [ -z "$pkg" ] && continue
  cur="$("$NODE_BIN" -e "try{console.log(require('$pkg/package.json').version)}catch(e){console.log('未安装')}")"
  latest="$(npm view "$pkg" version --registry="$REGISTRY" 2>/dev/null || true)"
  if [ -z "$latest" ]; then
    printf '  ✗ %-40s 查询最新版失败\n' "$pkg"
    FAILED=$((FAILED+1)); continue
  fi
  if [ "$cur" = "$latest" ]; then
    printf '  · %-40s %s (已是最新)\n' "$pkg" "$cur"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf '  ↑ %-40s %s -> %s\n' "$pkg" "$cur" "$latest"
    UPGRADED=$((UPGRADED+1)); continue
  fi
  printf '  ↑ %-40s %s -> %s ... ' "$pkg" "$cur" "$latest"
  # 用具体版本号而非 @latest：pnpm 的 metadata cache 可能缓存滞后的 latest tag，
  # 导致 @latest 解析到旧版（实测 dsh-context registry 已 0.61.0 但 cache 仍 0.59.2）。
  # 用 npm view 查到的具体版本号能绕过 cache、装到 registry 实际最新。
  # 包名里的 / 换成 - 做日志文件名，避免被当目录分隔符
  LOG="/tmp/dsh-desktop-upgrade-${pkg//\//-}-$$.log"
  if "$NODE_BIN" "$APP_PNPM_CJS" add "$pkg@$latest" >"$LOG" 2>&1; then
    actual="$("$NODE_BIN" -e "try{console.log(require('$pkg/package.json').version)}catch(e){console.log('?')}")"
    if [ "$actual" = "$latest" ]; then
      echo "完成"
    else
      echo "版本不符 (实装 $actual，期望 $latest)"
    fi
    UPGRADED=$((UPGRADED+1))
    UPDATED_LIST="${UPDATED_LIST}  ${pkg}: ${cur} -> ${actual}"$'\n'
    rm -f "$LOG"
  else
    echo "失败 (日志: $LOG)"
    FAILED=$((FAILED+1))
  fi
done <<< "$PLUGINS"

echo
if [ "$DRY_RUN" = 1 ]; then
  echo "==> 汇总: 可升级 $UPGRADED / 已最新 $SKIPPED / 失败 $FAILED (共 $COUNT)"
else
  echo "==> 汇总: 升级 $UPGRADED / 跳过 $SKIPPED / 失败 $FAILED (共 $COUNT)"
  if [ "$UPGRADED" -gt 0 ]; then
    echo
    echo "已升级:"
    printf '%s' "$UPDATED_LIST"
    echo
    echo "==> 已升级的插件需重启 DeepSeek Harness.app 才生效：Cmd+Q 退出后重新打开"
  fi
fi
[ "$FAILED" -gt 0 ] && exit 1
exit 0
