#!/usr/bin/env bash
# parse-verdict.sh — extracts the classifier verdict from the
# anthropics/claude-code-action output. Emits JSON to stdout.
#
# Usage:
#   parse-verdict.sh <action-output-file>
#
# Output JSON shape:
#   {
#     "verdict": "non-issue|needs-human|auto-fixable|ambiguous",
#     "reasoning": "<everything before the GAIA-VERDICT line>",
#     "proposed_paths": ["path1", "path2"]
#   }
#
# `ambiguous` covers UAT-003 case (b):
#   - No `GAIA-VERDICT:` line.
#   - Multiple `GAIA-VERDICT:` lines.
#   - A `GAIA-VERDICT:` value outside the closed set.
#   - `auto-fixable` without a parseable `### Proposed paths` fence.
#
# The verdict line MUST be the LAST non-blank line of the response;
# anything trailing it (besides blank lines) is also ambiguous.
#
# POSIX bash + awk only. No jq, no python. Exit 0 always (consumers read
# JSON); exit 2 reserved for genuine usage errors.

set -u

usage() {
  echo "usage: parse-verdict.sh <action-output-file>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
input_file="$1"
[ -f "$input_file" ] || { echo "parse-verdict.sh: input file not found: $input_file" >&2; exit 2; }

work_dir=$(mktemp -d 2>/dev/null) || { echo "parse-verdict.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_dir"' EXIT

# ---------------------------------------------------------------------------
# Step 1: locate every `GAIA-VERDICT:` line and identify the LAST non-blank
# line of the file. A conformant response has exactly one verdict line, and
# that line is the last non-blank line.
# ---------------------------------------------------------------------------

# Count of GAIA-VERDICT lines (leading whitespace tolerated; the rest of the
# line is the value, possibly with trailing whitespace).
verdict_count=$(awk '/^[[:space:]]*GAIA-VERDICT:/ { c++ } END { print c+0 }' "$input_file")

# Line number of the last non-blank line.
last_nonblank_lineno=$(awk 'NF { last = NR } END { print last+0 }' "$input_file")

# Line number of the (single) verdict line, if present.
verdict_lineno=$(awk '/^[[:space:]]*GAIA-VERDICT:/ { print NR }' "$input_file" | tail -n 1)

# ---------------------------------------------------------------------------
# Step 2: classify the verdict.
# ---------------------------------------------------------------------------

verdict="ambiguous"

if [ "$verdict_count" -eq 0 ]; then
  verdict="ambiguous"
elif [ "$verdict_count" -gt 1 ]; then
  # Strict contract: exactly one verdict line. Multiple = non-conformant.
  verdict="ambiguous"
elif [ "$verdict_lineno" != "$last_nonblank_lineno" ]; then
  # Verdict line exists but is not the LAST non-blank line.
  verdict="ambiguous"
else
  raw=$(awk -v ln="$verdict_lineno" 'NR==ln' "$input_file")
  # Strip leading whitespace and the `GAIA-VERDICT:` prefix.
  value=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]*GAIA-VERDICT:[[:space:]]*//' | awk '{$1=$1; print}')
  case "$value" in
    non-issue|needs-human|auto-fixable) verdict="$value" ;;
    *) verdict="ambiguous" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Step 3: extract reasoning — everything before the verdict line. If no
# verdict line was located, reasoning is the entire file (with any trailing
# newline preserved as best-effort).
# ---------------------------------------------------------------------------

if [ "$verdict_count" -ge 1 ] && [ -n "${verdict_lineno:-}" ]; then
  awk -v ln="$verdict_lineno" 'NR < ln' "$input_file" > "$work_dir/reasoning.txt"
else
  cp "$input_file" "$work_dir/reasoning.txt"
fi

# Trim a single trailing blank line (markdown structure between the
# reasoning and the verdict line) without touching content lines.
awk '
  { lines[NR] = $0 }
  END {
    e = NR
    if (e >= 1 && lines[e] == "") e = e - 1
    for (i = 1; i <= e; i++) {
      if (i > 1) printf "\n"
      printf "%s", lines[i]
    }
  }
' "$work_dir/reasoning.txt" > "$work_dir/reasoning-trim.txt"

# ---------------------------------------------------------------------------
# Step 4: extract proposed_paths from a `### Proposed paths` fenced block.
#
# Shape (the outer wrapper in the prompt example uses ```` to embed the
# inner fence; we read the INNER triple-backtick block):
#
#   ### Proposed paths
#
#   ```
#   path/one
#   path/two
#   ```
#
# Algorithm:
#   1. Find the first `### Proposed paths` header line (case-sensitive).
#   2. Skip blank lines and an optional opening triple-backtick fence
#      (with optional language tag).
#   3. Read non-blank, non-fence lines until the next fence or the next
#      `^### ` header or EOF.
#   4. Each accumulated line is a path (after trimming whitespace).
# ---------------------------------------------------------------------------

awk '
  BEGIN {
    in_block = 0
    seen_open_fence = 0
  }
  # Header detection.
  /^[[:space:]]*###[[:space:]]+Proposed paths[[:space:]]*$/ {
    if (in_block == 0) {
      in_block = 1
      seen_open_fence = 0
      next
    }
  }
  # Once we are in the block, watch for the opening triple-backtick fence
  # (possibly with a language tag).
  in_block == 1 && seen_open_fence == 0 {
    if ($0 ~ /^[[:space:]]*```/) {
      seen_open_fence = 1
      next
    }
    # A new `### ` header before we see the fence ends the block — the
    # author wrote the header but never opened a fence.
    if ($0 ~ /^[[:space:]]*###[[:space:]]+/) {
      in_block = 0
      next
    }
    # Blank lines between header and fence are fine; non-blank non-fence
    # lines mean the author skipped the fence (laxer parsing not allowed).
    if ($0 !~ /^[[:space:]]*$/) {
      # Treat as malformed — abandon block.
      in_block = 0
    }
    next
  }
  # Inside the fenced block.
  in_block == 1 && seen_open_fence == 1 {
    # Closing fence ends the block.
    if ($0 ~ /^[[:space:]]*```/) {
      in_block = 0
      next
    }
    # Blank line: skip silently.
    if ($0 ~ /^[[:space:]]*$/) { next }
    # Trim leading and trailing whitespace.
    line = $0
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:]]+$/, "", line)
    if (line != "") {
      print line
    }
  }
' "$input_file" > "$work_dir/paths-raw.txt"

# Build the JSON array of proposed paths and remember whether any were found.
paths_json=""
paths_count=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  paths_count=$((paths_count + 1))
  esc=$(printf '%s' "$p" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  if [ -z "$paths_json" ]; then
    paths_json="\"$esc\""
  else
    paths_json="$paths_json,\"$esc\""
  fi
done < "$work_dir/paths-raw.txt"

# ---------------------------------------------------------------------------
# Step 5: downgrade `auto-fixable` to `ambiguous` when no proposed paths
# were parsed (proposing a fix without paths is malformed).
# ---------------------------------------------------------------------------

if [ "$verdict" = "auto-fixable" ] && [ "$paths_count" -eq 0 ]; then
  verdict="ambiguous"
fi

# ---------------------------------------------------------------------------
# Step 6: emit JSON. Escape multi-line reasoning for embedding inside a
# JSON string literal.
# ---------------------------------------------------------------------------

json_escape_file() {
  awk '
    BEGIN { first = 1 }
    {
      if (first == 1) { first = 0 } else { printf "\\n" }
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") {
          printf "\\\\"
        } else if (c == "\"") {
          printf "\\\""
        } else if (c == "\t") {
          printf "\\t"
        } else if (c == "\r") {
          printf "\\r"
        } else {
          printf "%s", c
        }
      }
    }
  ' "$1"
}

reasoning_esc=$(json_escape_file "$work_dir/reasoning-trim.txt")

printf '{"verdict":"%s","reasoning":"%s","proposed_paths":[%s]}\n' \
  "$verdict" "$reasoning_esc" "$paths_json"
