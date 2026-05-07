#!/bin/bash
# PreToolUse advisory: before `gh pr merge`, remind Claude (and the user)
# that PR Merge Workflow requires a clean code-review-audit pass with all
# findings addressed. Non-blocking — exit 0 always.
#
# Emits both:
#   - structured `additionalContext` JSON via hookSpecificOutput, so Claude
#     reliably surfaces the reminder even on terminals where stderr is hidden
#   - a stderr line as a fallback for environments that ignore the JSON
#
# See wiki/concepts/PR Merge Workflow.md for the full contract.

set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

command=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match `gh pr merge` (any spacing, any flags)
if ! echo "$command" | grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
  exit 0
fi

reminder="PR Merge gate: before merging, ensure code-review-audit ran clean on the latest commit and any findings were addressed and pushed. See wiki/concepts/PR Merge Workflow.md."

jq -n --arg ctx "$reminder" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $ctx
  }
}'

echo "$reminder" >&2

exit 0
