#!/bin/bash
# Advisory reminder fired before `gh pr merge`:
# require a code-review-audit pass per wiki/concepts/PR Merge Workflow.md.
# Exit 0 always (non-blocking).

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // ""')

if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Match `gh pr merge` (including `gh   pr   merge --squash` etc.)
if ! echo "$command" | grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
  exit 0
fi

echo "PR merge audit reminder — see wiki/concepts/PR Merge Workflow.md" >&2

exit 0
