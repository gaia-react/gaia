#!/bin/bash

# Block bare `pnpm test` / `npm test` (and `run test` variants) without `--run`,
# they start vitest in watch mode and never exit in CI / agent contexts.
# Exit 2 = block the tool call, stderr is shown to Claude as the reason.

command=$(jq -r '.tool_input.command // ""' < /dev/stdin)

if echo "$command" | grep -Eq '(^|[^[:alnum:]_-])(pnpm|npm)[[:space:]]+(run[[:space:]]+)?test([[:space:]]|$)'; then
  if ! echo "$command" | grep -Eq -- '--run([[:space:]]|$)'; then
    echo "BLOCKED: bare \`pnpm test\` / \`npm test\` starts vitest watch mode. Use \`pnpm test --run\` for one-shot runs." >&2
    exit 2
  fi
fi

exit 0
