#!/bin/bash

# Block adding vitest/globals to a tsconfig
# Exit 2 = block the tool call, stderr is shown to Claude as the reason
#
# .claude/settings.json registers this under the Edit|Write|MultiEdit PreToolUse
# matcher, and the three tools carry their text in three different places: Edit
# in new_string, Write in content, MultiEdit in edits[].new_string. All three
# are joined into one scanned string, so an edit array is covered whichever of
# its entries carries the string.

input=$(cat /dev/stdin)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# The whole tsconfig*.json family: a split tsconfig.node.json / tsconfig.app.json
# makes describe/expect ambient exactly as the root config does. `[^/]*` keeps
# the pattern from crossing a path separator, so a directory named tsconfig does
# not pull every .json beneath it into the guard.
if echo "$file_path" | grep -qE 'tsconfig(\.[^/]*)?\.json'; then
  scanned_text=$(echo "$input" | jq -r '[.tool_input.new_string? // empty, .tool_input.content? // empty, (.tool_input.edits[]?.new_string // empty)] | join("\n")')
  if echo "$scanned_text" | grep -qi 'vitest/globals'; then
    echo "BLOCKED: Do not add vitest/globals to a tsconfig. Instead, add explicit imports in each test file: import {describe, expect, test} from 'vitest'" >&2
    exit 2
  fi
fi

exit 0
