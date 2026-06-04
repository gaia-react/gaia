#!/usr/bin/env bash
# render-prompt.sh: SPEC-003 prompt-template renderer.
#
# Usage:
#   render-prompt.sh <template-file> <key=value>...
#
# Reads <template-file> from disk and substitutes each `{{KEY}}` placeholder
# with the supplied value. Renders to stdout.
#
# Why this script exists: the previous inline `awk -v` rendering blocks in
# `.github/workflows/forensics-triage.yml` had two critical bugs, POSIX
# awk and gawk both reject `-v var=value` assignments containing literal
# newlines (UAT-001), and `gsub(re, repl, target)` expands `&` in `repl`
# to the matched text, corrupting any user content containing `&`
# (UAT-002). This helper sidesteps both failures by walking the template
# once and replacing tokens with literal-string values, no regex, no
# `awk -v`, no replacement-string escape semantics.
#
# Single-pass guarantee (UAT-003): the template is walked exactly once.
# At each cursor position we look for the LEFTMOST placeholder token; if
# found, we emit the literal prefix and the substituted value, then
# advance the cursor PAST the inserted value (not re-scanning it). A
# placeholder token that appears inside a substituted value's text is
# therefore NEVER re-substituted on a later pass.
#
# Bash 3.2 compatible (no associative arrays, no `mapfile`). The macOS
# default bash is 3.2 and the existing forensics scripts run there for
# bats locally; GitHub Actions ubuntu-latest has bash 5+.
#
# Exit codes:
#   0: success
#   2: bad usage (missing template, malformed key=value, key not present
#       in template, duplicate key)

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "render-prompt.sh: usage: render-prompt.sh <template-file> <key=value>..." >&2
  exit 2
fi

template_file="$1"
shift

if [ ! -f "$template_file" ]; then
  echo "render-prompt.sh: template not found: $template_file" >&2
  exit 2
fi

# Parallel arrays, bash 3.2 has no associative arrays. `keys[i]`,
# `tokens[i]`, and `vals[i]` index together.
keys=()
tokens=()
vals=()
for arg in "$@"; do
  case "$arg" in
    *=*)
      key="${arg%%=*}"
      value="${arg#*=}"
      if [ -z "$key" ]; then
        echo "render-prompt.sh: malformed key=value (empty key): $arg" >&2
        exit 2
      fi
      # Duplicate-key check: scan keys[] for this key.
      for existing in ${keys[@]+"${keys[@]}"}; do
        if [ "$existing" = "$key" ]; then
          echo "render-prompt.sh: duplicate key $key" >&2
          exit 2
        fi
      done
      keys+=("$key")
      tokens+=("{{${key}}}")
      vals+=("$value")
      ;;
    *)
      echo "render-prompt.sh: malformed key=value (no '='): $arg" >&2
      exit 2
      ;;
  esac
done

# Slurp the template once.
content="$(cat "$template_file")"

# Validate: every supplied key must appear at least once in the template.
# Surfacing a typo'd key explicitly is preferable to silently emitting a
# template with `{{FOO}}` un-substituted.
i=0
for key in ${keys[@]+"${keys[@]}"}; do
  token="${tokens[$i]}"
  case "$content" in
    *"$token"*) ;;
    *)
      echo "render-prompt.sh: key $key not present in template" >&2
      exit 2
      ;;
  esac
  i=$((i + 1))
done

# Single-pass walk:
#
#   while content has any token:
#     find the LEFTMOST token across all (token, value) pairs
#     emit prefix (text before the leftmost token) verbatim
#     emit the corresponding value verbatim
#     advance past the value (do NOT re-scan it for tokens)
#
# Bash parameter-expansion idiom for "position of first occurrence of N
# in S" is "${S%%N*}" giving the prefix; its length is the position.
# `${#var}` works correctly for byte-length even when the content
# contains `&`, `\`, `/`, or newlines.
#
# Output is built up in `result` and emitted at the end with a single
# `printf '%s'` so there is no extra trailing newline beyond what the
# template (or its substituted values) already contained.

result=""

n="${#keys[@]}"
while :; do
  # Find leftmost token in current `content`.
  best_pos=-1
  best_idx=-1
  best_token_len=0
  best_value=""
  i=0
  while [ "$i" -lt "$n" ]; do
    token="${tokens[$i]}"
    case "$content" in
      *"$token"*)
        prefix="${content%%"$token"*}"
        pos="${#prefix}"
        if [ "$best_pos" -eq -1 ] || [ "$pos" -lt "$best_pos" ]; then
          best_pos="$pos"
          best_idx="$i"
          best_token_len="${#token}"
          best_value="${vals[$i]}"
        fi
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$best_idx" -eq -1 ]; then
    # No more tokens. Emit the rest of the content and stop.
    result="${result}${content}"
    break
  fi

  # Emit prefix + value, advance content past the matched token.
  prefix="${content:0:best_pos}"
  result="${result}${prefix}${best_value}"
  content="${content:best_pos + best_token_len}"
done

printf '%s\n' "$result"
