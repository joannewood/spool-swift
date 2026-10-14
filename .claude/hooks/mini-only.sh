#!/usr/bin/env bash
# PreToolUse hook: this repo is only changed on Jo's Mac mini.
# Away from the mini, blocks file edits inside the repo and git commit/push.
# Chatting, reading, and working outside the repo stay allowed everywhere.
# The mini is recognised by ~/.claude/mini-host; override with CLAUDE_HOST=mini.

[ -f "$HOME/.claude/mini-host" ] || [ "$CLAUDE_HOST" = mini ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0  # can't parse input; don't get in the way

python3 -c '
import json, os, re, sys

data = json.load(sys.stdin)
tool = data.get("tool_name", "")
args = data.get("tool_input") or {}
repo = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ".")

def inside_repo(path):
    if not path:
        return False
    path = os.path.realpath(os.path.join(repo, os.path.expanduser(path)))
    return path == repo or path.startswith(repo + os.sep)

blocked = None
if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
    path = args.get("file_path") or args.get("notebook_path")
    if inside_repo(path):
        blocked = "editing files in this repo"
elif tool == "Bash":
    if re.search(r"\bgit\b[^;&|\n]*\b(commit|push)\b", args.get("command", "")):
        blocked = "git commit/push"

if blocked:
    print("⛔ This project is only changed on the Mac mini, so " + blocked + " is blocked here. "
          "Open it on the mini via Remote Control in the Claude app "
          "(or set CLAUDE_HOST=mini to override).", file=sys.stderr)
    sys.exit(2)
'
