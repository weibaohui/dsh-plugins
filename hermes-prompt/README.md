# dsh-plugin-hermes-prompt

Hermes Prompt Framework for DeepSeek Harness.

## 安装

从插件合集仓库的子目录安装（`#path:` 指向子目录，引号防止 shell 展开）：

```bash
dsh plugin --profile web add 'github:weibaohui/dsh-plugins#path:hermes-prompt' -w
```

## 功能

将 Hermes 提示词框架注入每个 agent 会话的 system prompt：

1. **交付纪律** — 干完才算完，不许交半成品，不许编造输出
2. **收尾沉淀** — 何时存 skill/memory，存哪，先问用户
3. **反面清单** — 什么不许存，防止记忆库被垃圾灌满

## Prompt 顺序

- `-100`: Harness identity
- `0`: Persona
- `50`: Hermes discipline (本插件)
- `100-199`: Tool guidance

## 依赖

- `@deepseek-ai/dsh-system-prompt` (通过 `systemPrompt` 服务注入)