# dsh-plugins

[weibaohui](https://github.com/weibaohui) 写的 [DeepSeek Harness](https://github.com/deepseek-harness/deepseek-harness)（dsh）插件合集。每个子目录是一个独立可安装的 dsh 插件包。

## 插件列表

| 目录 | 说明 |
|---|---|
| [`scheduled-items/`](scheduled-items/README.md) | cron 定时事项：每个事项带标题、提示词、croner 表达式，可绑定工作区；定时/立即执行时新建 agent 会话提交提示词，带全屏管理界面 |

## 安装

通过 `dsh plugin add` 从本仓库的子目录安装（`-w` 必需：`dsh plugin` 在 profile 目录内转发给 pnpm，而 profile 目录是一个 workspace root）：

```bash
dsh plugin --profile web add github:weibaohui/dsh-plugins/scheduled-items -w
```

安装后 `dsh plugin` 会把包调和（reconcile）进 profile 的 `dsh.profile.bundles` 层列表：包内 `package.json` 声明 `dsh.bundle.patch`，其 `cordis.patch.yml` 把插件行插入宿主组合，`dsh.client` 声明让 web 外壳加载管理界面。

pnpm ≥10 可能拦截 git 依赖的 `prepare` 构建脚本，报错时按提示把对应 key 加进 profile 目录的 `pnpm-workspace.yaml` 的 `allowBuilds` 再重跑即可（本合集的插件没有 `prepare` 脚本，通常不受影响）。

随后正常启动：

```bash
dsh --profile web
```

## 布局约定

- 每个子目录一个插件，目录名即安装 spec 的尾段（`github:weibaohui/dsh-plugins/<目录名>`）。
- 子目录保持独立包形态：自带 `package.json`、`cordis.patch.yml`、`src/`，可独立测试与发布 npm。
- 本仓库根目录不发布包，仅为合集载体。

## License

各插件沿用其目录内声明的许可证（均 MIT）。
