#!/bin/bash

# Block adding vitest/globals to tsconfig.json
# Exit 2 = block the tool call, stderr is shown to Claude as the reason

input=$(cat /dev/stdin)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. This matcher cannot reach the jq
# install itself, so the refusal is unconditional within it and the call below
# passes no binding literal; the contract lives in
# .claude/hooks/lib/jq-availability.sh.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-vitest-globals-tsconfig.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the vitest/globals tsconfig guard' "$input" tool_input

file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

if echo "$file_path" | grep -q 'tsconfig\.json'; then
  new_string=$(echo "$input" | jq -r '.tool_input.new_string // .tool_input.content // ""')
  if echo "$new_string" | grep -qi 'vitest/globals'; then
    echo "BLOCKED: Do not add vitest/globals to tsconfig.json. Instead, add explicit imports in each test file: import {describe, expect, test} from 'vitest'" >&2
    exit 2
  fi
fi

exit 0
