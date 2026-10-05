# AI Quota Savior

**Burn less. Do more.** Claude leads. Codex grinds. Your quota survives.

[简体中文](README.zh-CN.md)

AI Quota Savior is a [Claude Code](https://claude.com/claude-code) skill. It splits coding work between two agents:

- **Claude** (Opus, Sonnet, …) does the thinking. It designs the investigation, makes the plan and the key decisions, and gives the final acceptance.
- **Codex** does the legwork. It reads code, implements the change, runs tests, and collects evidence.

The goal is fewer Claude tokens spent per *accepted* task, without lowering the quality bar.

---

## Why this exists

Strong models like Claude Opus produce excellent plans and reviews. Their usage quota, however, is tight. A lot of that quota goes to work that doesn't need top-tier judgment:

- reading dozens of files,
- trial-and-error editing,
- rerunning tests over and over,
- pasting long logs back into the conversation.

Codex usually comes with a much larger quota. Left on its own, though, it tends to:

- drift from the plan,
- do unnecessary work,
- report "done" without proof,
- get stuck on the same bug.

AI Quota Savior combines the two. Claude decides **what** to do and **whether it is good enough**. Codex does the **how**, inside strict boundaries, and must back every claim with evidence.

## Design

1. **Spend the strong model only on judgment.** Claude writes the investigation questions, the plan, and the acceptance criteria, and it makes the final call. Reading, editing, testing and evidence collection are delegated.
2. **Keep only the essence in Claude's context.**
   - Codex's raw event logs stay on disk.
   - The script prints only a summary of up to 20 lines, a scope check, the verification results and a diff stat.
   - Claude reads a full report section only when a decision depends on it.
3. **Evidence over self-reporting.**
   - Every acceptance item has a stable ID (`A1`, `A2`, …) with an input, an expected result, a verification method and the evidence required.
   - Codex must report each item as `passed`, `failed` or `not_run`, with evidence. "Not run" never counts as passed, and "the build passes" never stands in for business behavior.
4. **Trust, but verify mechanically.** The script runs these checks outside Codex:
   - a **scope check**: changed files vs. `allowed.txt`;
   - a rerun of **every verification command** outside the Codex sandbox;
   - a check that **explore/audit** sessions did not modify tracked files.
5. **Independent audit when it matters.** For high-risk changes, a *fresh* Codex session checks the implementation against the acceptance plan. It verifies and reports only; it never fixes anything. Claude still makes the final call.
6. **Safe by default.**
   - Commits are opt-in (`CODEX_CHECKPOINT=1`). There is no automatic push.
   - Rework is capped at two rounds.
   - Rollback is scoped explicitly. There is never a blanket `reset --hard`.

## Problems it solves

| Problem | How AI Quota Savior handles it |
|---|---|
| The premium model's quota runs out on routine work | Code reading, edits, tests and log reading are delegated to Codex |
| The executor drifts or over-engineers | Strict execution rules: change only allowed paths, keep the existing style, and stop on design trade-offs |
| "Done" without proof | Per-item acceptance evidence plus mechanical re-verification outside the sandbox |
| Out-of-scope edits | An automatic scope check against `allowed.txt` |
| Endless fix loops | At most two rework rounds; then the user decides |
| Losing context between chats | All state lives in `<repo>/.codex-tasks/<slug>/`, so a new chat can resume from `plan.md` and the reports |
| The reviewer changing code during review | Tracked-file snapshots before and after explore/audit |

## Requirements

- **Windows** with **Git Bash**.
- **Claude Code** (CLI, desktop app or IDE extension).
- **OpenAI Codex**, installed and signed in. The script picks up the newest `codex.exe` from the Codex desktop install. Set `CODEX_BIN` to use a different one.
- A **Git repository with at least one commit** to work in.

## Installation

Copy the `ai-quota-savior/` folder into your Claude Code skills directory:

```bash
git clone https://github.com/leeluo/AI-Quota-Savior.git
cp -r AI-Quota-Savior/ai-quota-savior ~/.claude/skills/
```

Then check that everything works. The self-check is offline: it runs the whole flow against a mock Codex and makes no model calls.

```bash
python ~/.claude/skills/ai-quota-savior/self-check.py "C:/Program Files/Git/bin/bash.exe"
```

## Usage

In Claude Code, either invoke the skill directly:

```
/ai-quota-savior Add pagination to the project list, 20 items per page
```

or just ask in plain language: *"Use AI Quota Savior and hand this to Codex: …"*. Claude then picks a path:

| Task | Path |
|---|---|
| Small change | Claude just does it (cheaper than delegating) |
| Batch / mechanical edits | Short plan plus checkable acceptance items, then execute |
| Code understanding / completeness survey | Investigation only (`explore`) |
| Hard bug | Claude designs the hypotheses, Codex traces and tests them, Claude decides the root cause, then the fix is delegated |
| Medium / large feature | Investigate → plan → implement → (audit) → final decision |

### The workflow

1. **Investigate** (optional).
   - Claude writes `explore.md`: the decision to support, the questions to answer, the entry points and the exclusions.
   - `codex.sh explore` runs Codex in a read-only sandbox and produces `map.md`: a summary of up to 20 lines, then a full body with `file:line` evidence.
2. **Plan.** Claude writes three files:
   - `plan.md`: the goal, the code facts it relies on, the behavior changes for each file or function, the constraints, and the acceptance items `A1…An`;
   - `allowed.txt`: the paths Codex may change (Bash globs);
   - `verify.txt`: the commands that must pass.
3. **Implement.** `codex.sh exec` runs Codex in a workspace-write sandbox. It returns a schema-validated `report.json`, then the script runs the scope check, reruns the verification commands, and prints a diff stat.
4. **Audit** (high-risk work only).
   - Claude writes `audit-plan.md`.
   - `codex.sh audit` starts a fresh Codex session that verifies and writes `audit.md`.
5. **Decide.** Claude reviews the evidence, spot-checks the risky code, and reports "technically accepted" separately from "pending your manual check". Committing is up to you.
6. **Rework** (at most two rounds).
   - `codex.sh resume` continues the implementation session with `rework-N.md`.
   - Use `codex.sh feedback` after your own manual testing: it first sets a new baseline from the current state.

### Script reference

```bash
bash ~/.claude/skills/ai-quota-savior/codex.sh <mode> <repo> <slug> [rework-file]
```

| Mode | What it does |
|---|---|
| `explore` | Read-only investigation → `map.md` |
| `exec` | Implement `plan.md` → `report.json`, then run `check` |
| `audit` | Fresh verification session → `audit.md` |
| `resume` | Continue the implementation session with a rework file |
| `feedback` | Like `resume`, but first sets a new baseline from the current state |
| `check` | Rerun the scope check and the verification commands only (needs no Codex) |

| Environment variable | Purpose |
|---|---|
| `CODEX_EFFORT` | Reasoning effort, default `high` |
| `CODEX_BIN` | Path to `codex.exe` |
| `CODEX_CHECKPOINT=1` | Allow committing uncommitted changes as a baseline checkpoint. **Set this only when the user has authorized it.** |

Task files live in `<repo>/.codex-tasks/<slug>/`. The folder is added to the repo's local `.git/info/exclude`, so it never gets committed.

## Windows & sandbox notes

- **Codex's sandbox has limits.** It often cannot spawn subprocesses (Node tests fail with `spawn EPERM`), write to some directories, or reach local Docker services and secrets.
  - Prefer sandbox-friendly verification commands (for example, `--test-isolation=none` for Node tests).
  - The script's own rerun outside the sandbox is authoritative. A `partial` report only triggers a warning.
- **Ops tasks** that need local services or secrets work like this: Codex writes the script with a dry-run mode; Claude runs the dry-run outside the sandbox, reviews it, and only then applies.
- **Python:** if the repo path contains spaces, use `uv run python -X utf8 -m pytest` instead of `uv run pytest`.
- **One delegation per repo at a time.** Don't let other agents edit the same repo meanwhile.

## License

[MIT](LICENSE) © 2026 Leeluo
