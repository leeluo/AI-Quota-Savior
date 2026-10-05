"""Offline integration check: python self-check.py [path-to-Git-Bash]. No model calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
BASH = sys.argv[1] if len(sys.argv) > 1 else shutil.which("bash")
assert BASH, "Pass the path to bash (on Windows: Git Bash, not WSL bash)"


def run(args, *, env=None, expected=0, cwd=None):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout


run([BASH, "-n", str(HERE / "codex.sh")])
schema = json.loads((HERE / "report-schema.json").read_text(encoding="utf-8"))
assert set(schema["required"]) == set(schema["properties"])

with tempfile.TemporaryDirectory(prefix="ai-quota-savior-check-", dir=Path.cwd()) as temporary:
    root = Path(temporary).resolve()
    assert root.parent == Path.cwd().resolve()
    repo = root / "repo with spaces"
    repo.mkdir()
    capture = root / "capture"
    capture.mkdir()
    mock = root / "mock-codex.sh"
    mock.write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$MOCK_CAPTURE/args"
cat > "$MOCK_CAPTURE/prompt"
out=; prev=; resumed=0
for arg in "$@"; do
  [ "$prev" != -o ] || out=$arg
  [ "$arg" != resume ] || resumed=1
  prev=$arg
done
! command -v cygpath >/dev/null 2>&1 || out=$(cygpath -u "$out")
case "$out" in
  */map.md) tid=explore-session ;;
  */audit.md) tid=audit-session ;;
  *) tid=implementation-session ;;
esac
printf '{"type":"thread.started","thread_id":"%s"}\\n' "$tid"
if [ "${MOCK_FAIL:-0}" = 1 ]; then
  echo '{"type":"error","message":"mock failure"}'
  exit 9
fi
[ "${MOCK_EMPTY:-0}" != 1 ] || exit 0
[ -z "${MOCK_TOUCH:-}" ] || echo touched >> "$MOCK_TOUCH"
case "$out" in
  */report.json) cat "$MOCK_CAPTURE/report" > "$out" ;;
  *) for ((n=1;n<=100;n++)); do printf 'DOC line %d\\n' "$n"; done > "$out" ;;
esac
''', encoding="utf-8", newline="\n")
    mock.chmod(0o755)
    report = {"status": "done", "changed_files": [], "verify": [], "acceptance": [
        {"id": "A1", "status": "passed", "evidence": "Offline fixture"}
    ], "deviations": [], "not_done": [], "issues": []}
    (capture / "report").write_text(json.dumps(report), encoding="utf-8")
    env = os.environ.copy()
    env.update(CODEX_BIN=mock.as_posix(), MOCK_CAPTURE=capture.as_posix(), CODEX_CHECKPOINT="0")
    for key in ("MOCK_FAIL", "MOCK_EMPTY"):
        env.pop(key, None)
    git = lambda *args: run(["git", "-C", str(repo), *args])
    git("init", "-q")
    git("config", "user.name", "Offline Check")
    git("config", "user.email", "offline@example.invalid")
    git("config", "commit.gpgsign", "false")
    (repo / "source.txt").write_text("baseline\n", encoding="utf-8")
    git("add", "source.txt")
    git("commit", "-qm", "fixture")
    initial = git("rev-parse", "HEAD").strip()
    task = repo / ".codex-tasks" / "flow"
    task.mkdir(parents=True)

    def write(name, text):
        (task / name).write_text(text, encoding="utf-8", newline="\n")

    def call(mode, *args, expected=0, extra=None):
        return run([BASH, str(HERE / "codex.sh"), mode, repo.as_posix(), "flow", *args],
                   env={**env, **(extra or {})}, expected=expected)

    write("explore.md", "Trace the requested flow")
    output = call("explore")
    assert "DOC line 20\n" in output and "DOC line 21\n" not in output
    assert len((task / "map.md").read_text().splitlines()) == 100
    assert "read-only" in (capture / "args").read_text()
    call("explore", expected=9, extra={"MOCK_FAIL": "1"})
    assert not (task / "map.md").exists() and (task / "map.previous.md").exists()
    call("explore", expected=2, extra={"MOCK_EMPTY": "1"})
    call("explore")
    print("PASS complete MD retained, stdout bounded, failed/empty reports rejected")

    write("plan.md", "A1: requested behavior")
    write("allowed.txt", "source.txt")  # Deliberately no final newline.
    write("verify.txt", "printf verification-ok")
    (repo / "source.txt").write_text("user change\n", encoding="utf-8")
    call("exec", expected=2)
    assert git("rev-parse", "HEAD").strip() == initial
    assert not (task / "start").exists()
    call("exec", extra={"CODEX_CHECKPOINT": "1"})
    assert git("rev-parse", "HEAD").strip() != initial
    assert (task / "exec-thread").read_text().strip() == "implementation-session"
    start = (task / "start").read_text()
    call("exec", expected=2)
    assert (task / "start").read_text() == start
    print("PASS checkpoint opt-in, first baseline preserved, implementation session isolated")

    write("audit-plan.md", "A1: inspect evidence")
    write("decision.md", "old decision")
    call("audit")
    args = (capture / "args").read_text().splitlines()
    assert "workspace-write" in args and "resume" not in args
    assert (task / "decision.previous.md").exists() and not (task / "decision.md").exists()
    assert len((task / "audit.md").read_text().splitlines()) == 100
    source = repo / "source.txt"
    original = source.read_bytes()
    assert "FAIL audit" in call("audit", expected=1, extra={"MOCK_TOUCH": source.as_posix()})
    source.write_bytes(original)
    write("rework-1.md", "A1: fix this behavior")
    write("plan.md", "UPDATED-PLAN A1")
    write("allowed.txt", "source.txt\nnew file.txt")
    (repo / "new file.txt").write_text("new behavior\n", encoding="utf-8")
    call("resume", "rework-1.md")
    args = (capture / "args").read_text().splitlines()
    prompt = (capture / "prompt").read_text(encoding="utf-8")
    assert "resume" in args and "implementation-session" in args
    assert "explore-session" not in args and "audit-session" not in args
    assert "--output-schema" in args and "UPDATED-PLAN" in prompt and "new file.txt" in prompt
    assert not (task / "audit.md").exists() and (task / "audit.previous.md").exists()
    assert "verification-ok" in (task / "verify.log").read_text()
    print("PASS fresh audit, audit cannot modify tracked files, correct resume, latest contract, stale evidence invalidated")

    call("resume", "rework-1.md", expected=9, extra={"MOCK_FAIL": "1"})
    assert not (task / "report.json").exists()
    call("check", expected=1)
    call("resume", "rework-1.md")
    write("verify.txt", "printf failure-evidence; exit 7")
    output = call("check", expected=1, extra={"CODEX_BIN": "/missing"})
    assert "FAIL" in output and "exit=7" in (task / "verify.log").read_text()
    write("verify.txt", "   \n")
    call("check", expected=1)
    write("verify.txt", "true")
    (repo / "out of scope.txt").write_text("unexpected\n", encoding="utf-8")
    assert "OUT-OF-SCOPE  out of scope.txt" in call("check", expected=1)
    (repo / "out of scope.txt").unlink()
    call("check")
    report["status"] = "partial"
    write("report.json", json.dumps(report))
    assert "WARN" in call("check")
    report["status"] = "blocked"
    write("report.json", json.dumps(report))
    call("check", expected=1)
    report["status"] = "done"
    write("report.json", json.dumps(report))
    print("PASS failed commands/scope/blocked/missing reports fail, partial warns, check needs no CLI")

    base = (task / "base").read_text()
    call("feedback", "rework-1.md", expected=2)
    assert (task / "base").read_text() == base
    call("feedback", "rework-1.md", extra={"CODEX_CHECKPOINT": "1"})
    assert (task / "base").read_text() != base and (task / "start").read_text() == start
    assert git("status", "--porcelain") == ""
    print("PASS feedback updates round baseline, retains initial baseline, leaves clean fixture")

print("All offline checks passed; no live Codex calls were made.")
