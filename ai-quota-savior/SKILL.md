---
name: ai-quota-savior
description: 将代码调查、实现和验收执行委派给 Codex（Astra），Claude 负责规划、关键决策和最终验收，以节省 Claude 额度。用于：用户说"交给 codex / 让 Astra 做 / 委派 / 省额度"；或在 git 仓库里做中大型实现。
---

# AI Quota Savior

**Burn less. Do more.**

Claude leads. Codex grinds. Your quota survives.

**Claude 带队，Codex 肝活，额度保命。**

目标：在达到用户质量标准的前提下，减少每个验收通过任务消耗的 Claude 额度。读源码、追踪调用、运行验证、整理证据均可委派；Claude 保留调查设计、方案决策和最终验收责任。

Claude 通过交付物理解现状和判断结果，按需阅读章节。证据缺失或冲突时定向补查；关键判断仍无法确定时，亲自读取相关源码片段。完整阅读和完整验证由执行者完成，不能为了缩短摘要而省略。

本文中的 Claude 指当前负责规划和最终验收的模型，例如 Opus 或 Sonnet。沿用用户选择的模型与推理档位，本技能不自动切换。

## 入口与分流

调用：`/ai-quota-savior`，或直接说“用 AI Quota Savior，把这个任务交给 Codex”。

脚本：`bash ~/.claude/skills/ai-quota-savior/codex.sh <mode> <repo> <slug>`。
任务目录：`<repo>/.codex-tasks/<slug>/`，自动加入仓库本地 exclude。需 bash（Windows 用 Git Bash，macOS/Linux 用系统 bash）、已登录的 Codex CLI 和已有提交的 Git 仓库。Codex 查找顺序：CODEX_BIN → Windows 桌面端最新的 codex.exe → PATH 中的 codex。默认使用本机 Codex 配置的模型，推理强度 `high`；`CODEX_EFFORT=xhigh` 可覆盖，`CODEX_BIN` 可指定可执行文件。

| 任务 | 路径 |
|---|---|
| 小改动，直接处理更省额度 | Claude 直接完成 |
| 批量机械修改 | 简短方案与可核对的验收项，直接执行 |
| 代码理解、完成度调查 | 调查设计 → explore → Claude 判断资料是否足够，可独立结束 |
| 疑难 bug | Claude 设计排查问题，Codex 追踪与验证假设，Claude 判断根因后再派修复 |
| 中大型实现 | 调查 → 方案 → 实现 → 验收执行 → Claude 最终判断 |

同一仓库同时只跑一个委派，委派期间也不要有其他智能体修改该仓库（否则越界检查误报，检查点会混入他人未完成的改动）。跨仓库每个仓库一个任务，先做被依赖方，后续方案写明实际接口约定。预计超过一小时的任务按有独立交付物的流程或模块拆分，保留跨模块依赖。

## 1. 设计调查，委派代码理解

Claude 写 `explore.md`：明确需要支持的决策、要回答的问题、相关业务流程与已知入口、需要追踪的分支和依赖、排除范围，以及哪些未知会阻止制定方案。不要求预先找齐文件；Codex 从入口发现并追踪必要依赖。全量指约定流程及其必要依赖。

运行 `codex.sh explore <repo> <slug>`。Codex 接收 [explore-rules.md](explore-rules.md)，交付 `map.md`：开头最多 20 行决策摘要，正文完整记录覆盖、流程、完成度、证据与未知。脚本只打印前 20 行及文档路径。

Claude 阅读摘要及制定方案所需章节。完成标准：每个调查问题有答案或明确未知；覆盖可追溯；没有阻止当前决策的证据缺口。需补查时更新 `explore.md`，指明旧报告、需保留的结论和新增问题，再运行 explore；上一版保存在 `map.previous.md`。需写文件的复现或测试交给 audit，只读调查中标明未运行。

## 2. 制定实现与验收计划

Claude 根据调查交付物写三个文件：
- `plan.md`：目标、采用的代码事实及出处、按文件/函数描述的行为变化、接口与业务约束、已决定的取舍、验收项、人工验收项。注明 Codex 应读取 map.md 的哪些章节；资料过期时先核对受影响部分。
- `allowed.txt`：允许修改的仓库相对路径，一行一个，Bash glob，`*` 可跨目录；包含新文件。增加范围由 Claude 决定。
- `verify.txt`：必须通过的验证命令，一行一条，在仓库根目录运行。使用 Windows 原生命令，如 `npm run build`、`python -m pytest`；按改动选择能发现实际错误的检查。纯文档可用相应校验代替构建。

每个验收项使用稳定 ID（如 A1），写清触发/输入、预期结果、验证方法和所需证据。覆盖核心业务行为、相关异常分支、共享调用方与必须保持的旧行为。简单任务可只有一项，避免为凑数量增加测试。构建通过只能证明构建。

例如：`A1：重复提交同一请求只产生一条记录；运行已有幂等性测试，报告测试位置、命令与结果。`

计划写清结果、约束和关键设计，具体编码由 Codex 完成。涉及产品取舍且上下文无法确定时询问用户；大任务（≥5 个文件或跨模块）先给目标、范围、关键决策、验收方式、规模的摘要，已有授权覆盖时直接推进。

## 3. 派发实现

运行 `codex.sh exec <repo> <slug>`；长任务通过宿主支持的后台机制等待完成。Codex 接收 [exec-rules.md](exec-rules.md)，交付符合 [report-schema.json](report-schema.json) 的 report.json，逐项给出验收状态与证据。

执行前需有可比较的 Git 基线。有未提交改动时脚本默认停止；只有用户已授权提交这些改动，才设置 `CODEX_CHECKPOINT=1` 运行，脚本会 `git add -A` 提交检查点。该设置不能替代用户授权；用户已给出长期授权（如记忆中记录"委派前有未提交改动直接提交检查点"）时，直接设置，不再逐次询问。汇报检查点 hash，不自动 push。feedback 遵守同一规则。

脚本打印实现报告、修改范围、命令结果和 diff 统计。报告中的 done 表示实现者自报完成，最终通过由 Claude 决定。Codex 沙箱内常因环境限制无法自测，报告为 partial 时脚本只给 WARN，以沙箱外重跑的验证结果为准；blocked、越界、验证失败仍判失败。脚本失败或后台中断时先确认执行进程是否结束，保留现场并核验已完成的工作。

## 4. 委派验收执行，Claude 判断结果

Claude 对照验收项检查已有证据。audit 会增加 Claude 写计划、读报告的固定开销，只用于高风险或复杂改动；中小任务的证据充分时直接判断。已有可复核证据充分时直接判断；核心行为、复杂调用链或风险点仍需核查时，写 audit-plan.md 后运行 `codex.sh audit <repo> <slug>`。也可独立诊断或验收现有代码，无需先执行实现。

audit-plan.md 写清验收项、待核查假设、需检查的实际路径、允许执行的命令/操作、通过标准及证据要求。选择已有证据未覆盖的部分；没有代码变化、失败或新疑点时不重复整套验证。

audit 新建会话，按 [audit-rules.md](audit-rules.md) 核对当前源码和实际结果。它可读取 plan.md、map.md、report.json 作为待核对材料，只验证和报告，不修复。测试可能生成文件，因此使用 workspace-write；脚本在 explore/audit 前后比对已跟踪文件内容，被修改即判失败（未跟踪的测试产物不受限）。

交付 audit.md：最多 20 行摘要，正文按验收项记录方法、实际/预期结果、证据、失败和未验证项。Claude 读摘要与影响判断的章节。需补查时更新 audit-plan.md 后重跑，上一版保存在 audit.previous.md。

最终判断须满足：
- 覆盖足以支持结论，关键未知已解决或明确留给用户决策。
- 计划内工作已完成，每个机器验收项有证据；未运行不能记为通过。
- 命令检查通过，核心业务行为与关键约束符合计划。
- 越界文件、偏差和生成物逐项解释，并经 Claude 判断可接受。

Claude 定向复核高风险点、矛盾或证据薄弱的源码，不默认重读全部代码、全部 diff 或重复全部命令。新的 Codex 会话仍可能漏检；它提供新的核查证据，质量判断仍归 Claude。

中大型任务或需要跨对话恢复时，把结论、证据章节、接受的偏差和待用户验收项写入简短的 decision.md（小任务直接在对话中汇报即可），区分“技术验收通过”和“用户体验/业务验收待完成”。向用户汇报结论、改动规模、证据与人工验收清单路径。最终提交由用户决定。

## 5. 返工与恢复

验收不通过时，把验收 ID、位置、实际/预期差异和需补的证据写进 rework-N.md。必要时更新 allowed.txt / verify.txt，再运行 `codex.sh resume <repo> <slug> rework-N.md`。脚本续接实现会话，传入最新完整计划、范围、命令和报告结构。

用户手动验收后反馈，使用 `codex.sh feedback <repo> <slug> rework-N.md`，以当前状态建立新基线；未提交改动的检查点须已有授权。实现改变后旧验收和决策会标记为 .previous.md，需重验受影响项及必要回归。

自动返工最多两轮；仍未通过则列出剩余问题，由用户决定继续、让 Claude 接手或停止。用户后续新增反馈单独处理。

换对话时从 plan.md（纯调查则 explore.md）、报告摘要和 decision.md 恢复，按需读正文。源码变化后核对受影响结论。原始事件和命令日志留在任务目录，仅失败诊断时读取。

放弃委派需用户明确同意。先检查 start 之后的改动、用户新增文件及检查点，再说明精确回退范围；不默认执行整个仓库的 reset --hard / clean -fd。

## 平台与沙箱注意事项

- Codex 沙箱内常无法启动子进程（node 测试报 `spawn EPERM`）、写 `.local/` 等目录或访问本机 Docker / 密钥。验证命令尽量选沙箱可运行的写法（如 node 测试加 `--test-isolation=none`），最终以脚本在沙箱外的重跑为准。
- 需要访问本机服务、密钥或数据库的运维操作：Codex 只写脚本（放在沙箱可写的路径并加入仓库本地 exclude，先实现 dry-run），由 Claude 在沙箱外运行 dry-run、核对清单后再执行。
- Windows 上的 Python：仓库路径含空格时 `uv run pytest` 会失败，用 `uv run python -X utf8 -m pytest`；不加 UTF-8 模式会遇到 GBK 解码错误。
- 后台命令被中断时 Codex 进程可能仍在运行：确认结束后再用 `check` 验收。

维护脚本后运行 `python self-check.py [bash 路径]`（Windows 传 Git Bash 路径，如 `"C:/Program Files/Git/bin/bash.exe"`；macOS/Linux 可省略）。它在临时仓库使用模拟 Codex 检查流程，不调用模型；实际节省额度与交付质量仍需真实任务验证。
