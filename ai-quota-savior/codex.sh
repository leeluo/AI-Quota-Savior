#!/usr/bin/env bash
# AI Quota Savior — Burn less. Do more.
# Claude 设计与判断，Codex 调查、实现、验收执行。stdout 只返回必要信息。
# codex.sh explore|exec|audit|check <repo> <slug>
# codex.sh resume|feedback <repo> <slug> <rework文件名>
# CODEX_BIN / CODEX_EFFORT 可覆盖；CODEX_CHECKPOINT=1 仅用于已有授权的检查点提交。
set -euo pipefail
mode=${1:?mode} repo=$(cd "${2:?repo}" && pwd) slug=${3:?slug}
[[ $slug =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "ABORT slug 只能含字母、数字、点、下划线和连字符"; exit 2; }
case $mode in explore|exec|audit|check|resume|feedback) ;; *) echo "ABORT 未知模式: $mode"; exit 2 ;; esac
task="$repo/.codex-tasks/$slug" here=$(cd "$(dirname "$0")" && pwd) EFFORT=${CODEX_EFFORT:-high}
w() { cygpath -w "$1"; }
need() { local f; for f in "$@"; do [ -s "$task/$f" ] || { echo "ABORT 缺少 $task/$f"; exit 2; }; done; }

# check 仅重跑本地检查，不需要 Codex CLI。
if [ "$mode" != check ]; then
  CODEX=${CODEX_BIN:-$(ls -t "$(cygpath "$LOCALAPPDATA")"/OpenAI/Codex/bin/*/codex.exe 2>/dev/null | head -1 || true)}
  [ -x "$CODEX" ] || { echo "ABORT 找不到 codex.exe，请设置 CODEX_BIN"; exit 2; }
fi
ex=$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude) || { echo "ABORT 不是 git 仓库"; exit 2; }
git -C "$repo" rev-parse --verify HEAD >/dev/null || { echo "ABORT 仓库还没有任何提交"; exit 2; }
mkdir -p "$task"
grep -qxF '.codex-tasks/' "$ex" 2>/dev/null || { mkdir -p "$(dirname "$ex")"; echo '.codex-tasks/' >> "$ex"; }

run_codex() { # 每阶段独立日志；调用失败必须传回，不得被后续 check 掩盖。
  local phase=$1 t0=$SECONDS rc=0; shift
  "$CODEX" exec "$@" > "$task/$phase.events.jsonl" 2> "$task/$phase.codex.log" || rc=$?
  echo "== codex exit=$rc 用时 $(( (SECONDS-t0)/60 ))m"
  if [ "$rc" != 0 ]; then
    grep -E '^\{"type":"(error|turn\.failed)"' "$task/$phase.events.jsonl" | tail -2 | cut -c1-400 | grep . || tail -3 "$task/$phase.codex.log"
  fi
  return "$rc"
}

tree_state() { # 已跟踪文件当前内容（含未提交改动）的 tree，不触碰工作区
  local s; s=$(git -C "$repo" stash create 2>/dev/null) || true
  git -C "$repo" rev-parse "${s:-HEAD}^{tree}"
}

previous() { [ ! -f "$task/$1.md" ] || mv -f "$task/$1.md" "$task/$1.previous.md"; }
summary() { need "$1.md"; echo "== 完整报告: $task/$1.md"; sed -n '1,20p' "$task/$1.md"; }
invalidate() { previous audit; previous decision; }

checkpoint() {
  local d; d=$(git -C "$repo" status --porcelain)
  if [ -n "$d" ]; then
    [ "${CODEX_CHECKPOINT:-0}" = 1 ] || { echo "ABORT 工作区有未提交改动。仅在用户已授权提交这些改动时设置 CODEX_CHECKPOINT=1；否则先由用户处理基线。"; exit 2; }
    git -C "$repo" -c core.safecrlf=false add -A && git -C "$repo" commit -q -m "checkpoint: $1（$slug）" \
      || { echo "ABORT 检查点提交失败，请检查 git 输出"; exit 2; }
    echo "== 已提交$1 $(git -C "$repo" rev-parse --short HEAD)"; head -20 <<<"$d"
  fi
  git -C "$repo" rev-parse HEAD > "$task/base"
}

implementation_prompt() {
  cat "$here/exec-rules.md" "$task/plan.md"
  printf '\n## 任务资料目录（按计划引用读取）\n%s\n' "$(w "$task")"
  printf '\n## 允许修改的文件\n'; cat "$task/allowed.txt"
  printf '\n## 交付前必须全部通过的命令\n'; cat "$task/verify.txt"
}

check() {
  need base allowed.txt verify.txt
  local base f p c o ok out=0 n=0; base=$(cat "$task/base")
  git -C "$repo" rev-parse --verify "$base^{commit}" >/dev/null || return 2
  echo "== Codex 实现报告（最终验收由 Claude 判断）"
  if [ -s "$task/report.json" ]; then
    cat "$task/report.json"; echo
    # 沙箱内常因 spawn EPERM 等限制无法自测：partial 只警告，以下方沙箱外重跑结果为准；blocked 仍失败。
    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"blocked"' "$task/report.json"; then echo "FAIL 实现报告 blocked"; out=1
    elif ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"done"' "$task/report.json"; then
      echo "WARN 实现报告非 done（自报；以沙箱外重跑结果为准，最终由 Claude 判断）"; fi
  else echo "FAIL 无实现报告"; out=1; fi
  echo "== 越界检查（对比 ${base:0:8}）"
  while IFS= read -r -d '' f; do
    ok=0
    while IFS= read -r p || [ -n "$p" ]; do p=${p%$'\r'}; [ -n "$p" ] && [[ $f == $p ]] && { ok=1; break; }; done < "$task/allowed.txt"
    [ "$ok" = 1 ] || { echo "OUT-OF-SCOPE  $f"; out=1; }
  done < <({ git -C "$repo" diff --name-only -z "$base"; git -C "$repo" ls-files -z --others --exclude-standard; } | sort -zu)
  [ "$out" = 0 ] && echo "OK"
  echo "== 验证命令（在 repo 根目录重跑）"
  : > "$task/verify.log"
  while IFS= read -r c || [ -n "$c" ]; do
    c=${c%$'\r'}; [[ $c =~ ^[[:space:]]*$ ]] && continue
    n=$((n+1)); printf '\n$ %s\n' "$c" >> "$task/verify.log"
    if o=$(cd "$repo" && bash -c "$c" 2>&1 </dev/null); then
      echo "PASS  $c"; printf '%s\nexit=0\n' "$o" >> "$task/verify.log"
    else
      ok=$?; out=1; echo "FAIL  $c"; tail -30 <<<"$o" | sed 's/^/    /'
      printf '%s\nexit=%s\n' "$o" "$ok" >> "$task/verify.log"
    fi
  done < "$task/verify.txt"
  [ "$n" != 0 ] || { echo "FAIL verify.txt 没有可执行命令"; out=1; }
  echo "== 验证日志: $task/verify.log"
  echo "== diff 统计"
  git -C "$repo" diff --stat "$base" | tail -15
  git -C "$repo" ls-files --others --exclude-standard | sed 's/^/ 新增 /'
  return "$out"
}

case $mode in
explore|audit)
  if [ "$mode" = explore ]; then input=explore.md output=map sandbox=read-only; else input=audit-plan.md output=audit sandbox=workspace-write; fi
  need "$input"
  previous "$output"; previous decision
  before=$(tree_state)
  { cat "$here/$mode-rules.md" "$task/$input"; printf '\n## 任务资料目录\n%s\n' "$(w "$task")"; } \
    | run_codex "$mode" -s "$sandbox" -C "$(w "$repo")" -c model_reasoning_effort="$EFFORT" -o "$(w "$task/$output.md")" --json -
  summary "$output"
  after=$(tree_state)
  if [ "$before" != "$after" ]; then # explore/audit 只能产生未跟踪的产物，不得改已跟踪源码
    echo "FAIL $mode 期间已跟踪文件被修改："; git -C "$repo" diff --name-only "$before" "$after" | sed 's/^/    /'; exit 1
  fi ;;
exec)
  need plan.md allowed.txt verify.txt
  [ ! -f "$task/start" ] || { echo "ABORT 已存在实现任务，请用 resume 或新 slug，避免覆盖初始基线"; exit 2; }
  checkpoint 委派前检查点; cp "$task/base" "$task/start"
  invalidate; rm -f "$task/report.json" "$task/exec-thread"
  rc=0
  implementation_prompt | run_codex exec -s workspace-write -C "$(w "$repo")" -c model_reasoning_effort="$EFFORT" \
    --output-schema "$(w "$here/report-schema.json")" -o "$(w "$task/report.json")" --json - || rc=$?
  tid=$(sed -n 's/.*"thread_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$task/exec.events.jsonl" | head -1)
  [ -z "$tid" ] || printf '%s\n' "$tid" > "$task/exec-thread"
  [ "$rc" = 0 ] || exit "$rc"
  need exec-thread
  check ;;
resume|feedback)
  rework=${4:?rework文件名}
  [[ $rework != */* && $rework != *\\* && $rework != . && $rework != .. ]] || { echo "ABORT 返工文件必须位于任务目录"; exit 2; }
  need exec-thread base plan.md allowed.txt verify.txt "$rework"
  tid=$(cat "$task/exec-thread")
  [ "$mode" != feedback ] || checkpoint 用户反馈返工前检查点
  invalidate; rm -f "$task/report.json"
  { implementation_prompt; printf '\n## 本轮返工要求\n'; cat "$task/$rework"; } \
    | (cd "$repo" && run_codex resume resume -c sandbox_mode=workspace-write -c model_reasoning_effort="$EFFORT" \
        --output-schema "$(w "$here/report-schema.json")" -o "$(w "$task/report.json")" --json "$tid" -)
  check ;;
check) check ;;
esac
