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

# Any .json whose name carries tsconfig, anywhere in the segment: a split
# tsconfig.node.json / tsconfig.app.json pair makes describe/expect ambient
# exactly as the root config does, and tsc reads whatever config `-p` or
# `extends` names, so a non-canonical name can be a live one. Deliberately
# generous rather than anchored to a known set of spellings, on both ends of the
# name: enumerating separators is unbounded, and over-blocking costs one message
# carrying a remedy where under-blocking costs the ambient-types erosion this
# guard exists to stop. `[^/]*` is the one limit that holds, keeping the pattern
# inside a single path segment so a directory named tsconfig does not pull every
# .json beneath it in.
if echo "$file_path" | grep -qE 'tsconfig[^/]*\.json'; then
  # `new_string?` guards the index as well as the iteration: indexing a
  # non-object edits[] entry aborts the whole read, which would empty the
  # scanned text and allow the write.
  scanned_text=$(echo "$input" | jq -r '[.tool_input.new_string? // empty, .tool_input.content? // empty, (.tool_input.edits[]?.new_string? // empty)] | join("\n")' 2>/dev/null)
  if echo "$scanned_text" | grep -qi 'vitest/globals'; then
    echo "BLOCKED: Do not add vitest/globals to a tsconfig. Instead, add explicit imports in each test file: import {describe, expect, test} from 'vitest'" >&2
    exit 2
  fi
fi

exit 0
