#!/usr/bin/env bash
# PostToolUse Bash hook: autonomously evaluate whether the just-landed commit
# warrants a wiki update, and apply the update if so.
#
# Behavior:
#   1. Match successful `git commit:*` invocations (skip merge / amend noise).
#   2. Capture the new HEAD sha + commit metadata + diffstat.
#   3. Spawn a backgrounded `claude -p` sub-agent (Sonnet) with a focused prompt
#      and the working dir scoped to the repo. The sub-agent reads the diff,
#      consults wiki/index.md, and either:
#        (a) edits the relevant wiki pages + appends to wiki/log.md, OR
#        (b) emits "NO_UPDATE_NEEDED" and exits silently.
#      The sub-agent does its own commits if needed (NOT atomic with the user's
#      commit — those will be picked up by the wiki-squash-autocommits Stop
#      hook and flow through the standard wiki-branch PR path on main).
#   4. Hook exits 0 immediately. The sub-agent runs in the background; its
#      stdout/stderr is logged to .claude/audit/wiki-evaluator-{sha}.log
#      (gitignored) for post-hoc inspection.
#
# Mechanism choice: shell out to `claude -p` (non-interactive). Reasons:
#   - The repo already depends on the `claude` CLI (statusline, init flows).
#   - No queue-watcher harness exists in the repo to consume queue files.
#   - Backgrounding means the user's `git commit` returns immediately; the
#     evaluator runs detached and is fully tolerant of failure (exit 0 always).
#
# Failure mode:
#   Every step is best-effort. Any failure (no claude on PATH, no network,
#   sub-agent error) logs to the audit file and exits 0. Never blocks commits.
set -euo pipefail

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[[ "$tool_name" == "Bash" ]] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")
# Match `git commit` (not commit-tree / commit-graph). Skip --amend (re-eval
# of the same change is wasteful) and merge commits (handled by the merge tool).
if ! grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+commit([[:space:]]|$)' <<<"$cmd"; then
  exit 0
fi
if grep -qE -- '--amend([[:space:]]|=|$)' <<<"$cmd"; then
  exit 0
fi

# Must have a HEAD (the commit landed). If anything fails reading git state,
# bail silently — never block on a PostToolUse failure.
head_sha=$(git rev-parse --short HEAD 2>/dev/null || true)
[[ -n "$head_sha" ]] || exit 0

# Skip evaluator when the commit itself is a wiki auto-commit (we'd just loop).
subject=$(git log -1 --format='%s' "$head_sha" 2>/dev/null || true)
case "$subject" in
  "wiki: auto-commit"*|"wiki: "*) exit 0 ;;
esac

# Skip when no claude CLI on PATH.
command -v claude >/dev/null 2>&1 || exit 0

# Prepare audit log path. Directory is gitignored.
audit_dir=".claude/audit"
mkdir -p "$audit_dir" 2>/dev/null || exit 0
log_file="$audit_dir/wiki-evaluator-$head_sha.log"

# Build the sub-agent prompt. Keep it tight — Sonnet handles this well.
prompt=$(cat <<PROMPT
You are an autonomous wiki-evaluator sub-agent for the GAIA project.

A new commit just landed at HEAD ($head_sha): "$subject".

Your job:
  1. Run \`git show --stat HEAD\` and \`git show HEAD\` to inspect the diff.
  2. Read wiki/index.md to learn what wiki pages exist.
  3. Decide whether this commit warrants a wiki update. File one if it introduces:
     - a new service / component family / hook / pattern
     - an added / updated / removed dependency
     - an ADR-worthy decision
     - a non-obvious invariant, gotcha, or workaround
     - a breaking change to a documented interface
     Skip for: bug fixes in existing patterns, mental-model-preserving refactors,
     typos / formatting, test additions, or duplicates of existing wiki content.
  4. If an update is warranted: edit the relevant wiki page(s), prepend a
     one-line entry to wiki/log.md (newest on top, format: "YYYY-MM-DD - $head_sha - <one-line summary>"),
     and stage + commit the wiki changes with message "wiki: evaluator update for $head_sha".
     The wiki-squash-autocommits Stop hook will fold subsequent wiki commits.
  5. If no update is warranted: print exactly "NO_UPDATE_NEEDED" and exit.

Constraints:
  - Do NOT touch source files outside wiki/.
  - Do NOT push, open PRs, or merge — let the standard wiki flow handle that.
  - Do NOT amend the user's commit — your commit is independent.
  - Be concise. The diff is the source of truth, not your training data.
PROMPT
)

# Fire and forget. Use nohup + & so the sub-agent survives the parent process
# and the user's commit returns immediately. Detach stdin from the hook's
# stdin (which is already consumed but be explicit).
{
  printf '%s\n' "=== wiki-evaluator started $(date -u +%FT%TZ) for $head_sha ===" > "$log_file"
  nohup claude -p \
    --model sonnet \
    --permission-mode bypassPermissions \
    --add-dir "$(pwd)" \
    "$prompt" >> "$log_file" 2>&1 &
  disown 2>/dev/null || true
} 2>/dev/null || true

exit 0
