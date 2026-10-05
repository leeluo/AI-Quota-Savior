# AI Quota Savior

**少烧额度，多干活。** Claude 带队，Codex 肝活，额度保命。

[English](README.md)

AI Quota Savior 是一个 [Claude Code](https://claude.com/claude-code) skill，它把编码工作分给两个智能体：

- **Claude**（Opus、Sonnet 等）负责动脑：设计调查问题、制定方案、做关键决策，以及最终验收。
- **Codex** 负责干活：读代码、写实现、跑测试、收集证据。

目标是：在不降低质量标准的前提下，让每个**验收通过**的任务少消耗 Claude 额度。

---

## 为什么做这个 skill

Claude Opus 这类强模型做方案、做审查的质量很高，但额度紧张。大量额度其实花在了不需要顶级判断力的事情上：

- 一个个翻文件；
- 反复试错改代码；
- 一遍遍跑测试；
- 把长日志贴回对话里。

Codex 的额度通常宽裕得多，但放任它自己做，容易出现这些问题：

- 偏离方案；
- 做很多无用功；
- 没有证据就说"做完了"；
- 同一个 bug 反复修不好。

AI Quota Savior 把两者结合起来：Claude 决定**做什么**、判断**够不够好**；Codex 负责**怎么做**，必须在严格的边界内执行，每个结论都要拿出证据。

## 设计思路

1. **强模型只花在判断上。** Claude 写调查问题、方案和验收标准，并做最终判断。读代码、改代码、跑测试、整理证据，全部委派出去。
2. **只把精华放进 Claude 的上下文。**
   - Codex 的原始事件日志留在磁盘上。
   - 脚本只打印这几样：不超过 20 行的摘要、越界检查、验证结果和 diff 统计。
   - 只有某个决策确实依赖细节时，Claude 才去读报告的对应章节。
3. **用证据说话，不信自报。**
   - 每个验收项都有固定编号（`A1`、`A2`……），写明输入、预期结果、验证方法和需要的证据。
   - Codex 必须逐项给出 `passed`、`failed` 或 `not_run`，并附上证据。"没运行"不能算通过，"构建通过"也不能代替"业务行为正确"。
4. **信任，但要机械地核实。** 脚本会在 Codex 之外做这几件事：
   - **越界检查**：对比改动的文件和 `allowed.txt`；
   - 在沙箱外**重跑全部验证命令**；
   - 检查 **explore / audit** 阶段有没有改动已跟踪的文件。
5. **关键时刻独立验收。** 高风险改动可以开一个**全新的** Codex 会话，按验收计划逐项核对。这个会话只验证、只报告，不修复。最终判断仍然由 Claude 做。
6. **默认安全。**
   - 自动提交需要显式开启（`CODEX_CHECKPOINT=1`），而且不会自动 push。
   - 返工最多两轮。
   - 回滚前先明确范围，绝不默认整仓 `reset --hard`。

## 解决的问题

| 问题 | 怎么解决 |
|---|---|
| 强模型的额度耗在日常杂活上 | 读代码、改代码、跑测试、看日志都委派给 Codex |
| 执行者跑偏、过度设计 | 严格的执行规则：只改允许的路径，保持现有风格，遇到设计取舍就停下 |
| 没有证据就说"完成了" | 逐项提交验收证据，并在沙箱外机械重验 |
| 改了不该改的文件 | 按 `allowed.txt` 自动做越界检查 |
| 无限返工 | 最多两轮，之后由用户决定 |
| 换对话就丢上下文 | 所有状态都存在 `<repo>/.codex-tasks/<slug>/`，新对话从 `plan.md` 和报告接着做 |
| 验收者在验收时偷偷改代码 | explore / audit 前后各记录一次已跟踪文件的快照并比对 |

## 环境要求

- **Windows** 和 **Git Bash**。
- **Claude Code**（命令行、桌面端或 IDE 插件都可以）。
- **OpenAI Codex**，已安装并登录。脚本会自动找到 Codex 桌面端里最新的 `codex.exe`；想用别的版本，设置 `CODEX_BIN`。
- 工作目录是**至少有一次提交的 Git 仓库**。

## 安装

把 `ai-quota-savior/` 目录复制到 Claude Code 的 skills 目录：

```bash
git clone https://github.com/leeluo/AI-Quota-Savior.git
cp -r AI-Quota-Savior/ai-quota-savior ~/.claude/skills/
```

然后跑一遍自检，确认一切正常。自检是离线的：它用模拟的 Codex 走完整个流程，不调用任何模型。

```bash
python ~/.claude/skills/ai-quota-savior/self-check.py "C:/Program Files/Git/bin/bash.exe"
```

## 使用说明

在 Claude Code 里，可以直接调用：

```
/ai-quota-savior 给项目列表加分页，每页 20 条
```

也可以直接用自然语言说："用 AI Quota Savior，把这个任务交给 Codex：……"。Claude 会先选一条路径：

| 任务 | 做法 |
|---|---|
| 小改动 | Claude 直接改，比委派更省 |
| 批量机械修改 | 写一份简短方案和可核对的验收项，然后直接执行 |
| 代码理解、完成度调查 | 只做调查（`explore`） |
| 疑难 bug | Claude 设计排查假设，Codex 追踪和验证，Claude 判定根因后再委派修复 |
| 中大型功能 | 调查 → 方案 → 实现 →（验收执行）→ 最终判断 |

### 完整流程

1. **调查**（可选）。
   - Claude 写 `explore.md`：要支持什么决策、要回答哪些问题、从哪里入手、哪些不用管。
   - `codex.sh explore` 让 Codex 在只读沙箱里调查，产出 `map.md`：开头是不超过 20 行的摘要，正文是带 `文件:行号` 证据的完整记录。
2. **方案**。Claude 写三个文件：
   - `plan.md`：目标、依据的代码事实、按文件或函数写的行为变化、约束条件，以及验收项 `A1…An`；
   - `allowed.txt`：允许 Codex 修改的路径（Bash glob）；
   - `verify.txt`：必须通过的命令。
3. **实现**。`codex.sh exec` 让 Codex 在可写沙箱里实现，交回一份按 schema 校验过的 `report.json`。之后脚本自动做越界检查、重跑验证命令，并打印 diff 统计。
4. **验收执行**（只用于高风险改动）。
   - Claude 写 `audit-plan.md`。
   - `codex.sh audit` 开一个新会话逐项核对，产出 `audit.md`。
5. **判断**。Claude 核对证据，抽查有风险的代码，然后把"技术验收通过"和"待你手动验收"分开汇报。要不要提交由你决定。
6. **返工**（最多两轮）。
   - `codex.sh resume` 带上 `rework-N.md`，接着原来的实现会话继续做。
   - 如果是你手动验收后提出的问题，用 `codex.sh feedback`：它会先以当前状态建立新的基线。

### 脚本参数

```bash
bash ~/.claude/skills/ai-quota-savior/codex.sh <mode> <repo> <slug> [返工文件]
```

| 模式 | 作用 |
|---|---|
| `explore` | 只读调查，产出 `map.md` |
| `exec` | 按 `plan.md` 实现，产出 `report.json`，然后自动运行 `check` |
| `audit` | 开新会话做验收核对，产出 `audit.md` |
| `resume` | 带上返工单，续接原来的实现会话 |
| `feedback` | 和 `resume` 一样，但会先以当前状态建立新的基线 |
| `check` | 只重跑越界检查和验证命令（不需要 Codex） |

| 环境变量 | 作用 |
|---|---|
| `CODEX_EFFORT` | 推理强度，默认 `high` |
| `CODEX_BIN` | `codex.exe` 的路径 |
| `CODEX_CHECKPOINT=1` | 允许把未提交的改动提交成基线检查点。**只有在用户授权后才能设置。** |

任务文件都放在 `<repo>/.codex-tasks/<slug>/`。这个目录会被自动加入仓库本地的 `.git/info/exclude`，不会被提交。

## Windows 与沙箱注意事项

- **Codex 的沙箱有限制。** 它经常无法启动子进程（Node 测试会报 `spawn EPERM`），写不了某些目录，也访问不到本机的 Docker 服务和密钥。
  - 验证命令尽量选沙箱里能跑的写法，比如 Node 测试加上 `--test-isolation=none`。
  - 一律以脚本在沙箱外重跑的结果为准。报告是 `partial` 时只给警告，不判失败。
- **需要访问本机服务或密钥的运维任务**这样分工：Codex 写好脚本，并实现 dry-run（空跑）模式；Claude 在沙箱外先空跑，核对无误后再正式执行。
- **Python**：仓库路径里带空格时，用 `uv run python -X utf8 -m pytest`，不要用 `uv run pytest`。
- **同一个仓库同一时间只跑一个委派**，期间也不要让其他智能体修改这个仓库。

## 许可证

目前还没有选择开源许可证。在添加许可证之前，作者保留所有权利。
