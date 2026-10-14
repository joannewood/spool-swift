#!/usr/bin/env bash
# PreToolUse hook: this repo is only changed on Jo's Mac mini.
# Away from the mini, blocks file edits inside the repo and git commit/push.
# Chatting, reading, and working outside the repo stay allowed everywhere.
# The mini is recognised by ~/.claude/mini-host; override with CLAUDE_HOST=mini.
#
# Also: every `git push` (including from the mini) gets scanned for secrets with
# gitleaks first, over the commits actually about to be pushed, and is blocked if
# anything is found. This runs regardless of host, since all real pushes happen here.

command -v python3 >/dev/null 2>&1 || exit 0  # can't parse input; don't get in the way

python3 -c '
import json, os, re, shutil, subprocess, sys

data = json.load(sys.stdin)
tool = data.get("tool_name", "")
args = data.get("tool_input") or {}
repo = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ".")
is_mini = os.path.exists(os.path.expanduser("~/.claude/mini-host")) or os.environ.get("CLAUDE_HOST") == "mini"

def inside_repo(path):
    if not path:
        return False
    path = os.path.realpath(os.path.join(repo, os.path.expanduser(path)))
    return path == repo or path.startswith(repo + os.sep)

def block(reason):
    print("⛔ " + reason, file=sys.stderr)
    sys.exit(2)

if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
    if not is_mini:
        path = args.get("file_path") or args.get("notebook_path")
        if inside_repo(path):
            block("This project is only changed on the Mac mini, so editing files in this repo is blocked here. "
                  "Open it on the mini via Remote Control in the Claude app (or set CLAUDE_HOST=mini to override).")
    sys.exit(0)

if tool != "Bash":
    sys.exit(0)

command = args.get("command", "")
is_commit_or_push = re.search(r"\bgit\b[^;&|\n]*\b(commit|push)\b", command)
is_push = re.search(r"\bgit\b[^;&|\n]*\bpush\b", command)

if is_commit_or_push and not is_mini:
    block("This project is only changed on the Mac mini, so git commit/push is blocked here. "
          "Open it on the mini via Remote Control in the Claude app (or set CLAUDE_HOST=mini to override).")

if not is_push:
    sys.exit(0)

gitleaks = shutil.which("gitleaks")
if not gitleaks:
    print("⚠️  gitleaks not found — skipping the pre-push secret scan (install via `brew install gitleaks`).",
          file=sys.stderr)
    sys.exit(0)

def run(*cmd):
    return subprocess.run(cmd, cwd=repo, capture_output=True, text=True)

def ref_exists(ref):
    return run("git", "rev-parse", "--verify", "--quiet", ref).returncode == 0

base = None
r = run("git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
if r.returncode == 0:
    base = r.stdout.strip()
else:
    r = run("git", "symbolic-ref", "refs/remotes/origin/HEAD")
    if r.returncode == 0:
        base = r.stdout.strip().replace("refs/remotes/", "", 1)
    elif ref_exists("origin/main"):
        base = "origin/main"

log_opts = (base + "..HEAD") if base and ref_exists(base) else None

cmd = [gitleaks, "detect", "--source", repo, "--no-banner", "--no-color", "--redact",
       "--verbose", "--exit-code", "1"]
if log_opts:
    cmd += ["--log-opts", log_opts]
result = run(*cmd)

if result.returncode == 1:
    block("gitleaks found what looks like a secret in the commit(s) about to be pushed "
          "(values redacted below):\n\n" + result.stdout + result.stderr +
          "\nFix it (remove/rotate the secret, amend the commit) before pushing. If this is a "
          "false positive, add a .gitleaksignore entry or an inline # gitleaks:allow comment.")
elif result.returncode not in (0, 1):
    print("⚠️  gitleaks exited unexpectedly (" + str(result.returncode) + ") — not blocking, but "
          "worth checking manually:\n" + result.stderr, file=sys.stderr)
'
