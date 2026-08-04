#!/usr/bin/env bash
# PreToolUse Edit|Write|MultiEdit hook: guard eslint.config.{js,cjs,mjs,ts} at
# any path. Single-app projects have it at the repo root; monorepos nest it
# under each app (apps/web/eslint.config.mjs), so the path gate matches on the
# filename and works in both layouts.
#
# The rule is "fix the lint error in the source file where it occurs, never
# silence it here". Matching the filename alone enforces something broader than
# that: it denies every edit to the file, including the `...lint.reactRouter`
# migration GAIA's own CHANGELOG tells adopters to perform, and including a
# repair to a stale comment inside the config. That mismatch between the stated
# rule and the enforced one is tech-debt #1153.
#
# So the guard is an ALLOWLIST over the lines an edit changes, not a filename
# match. An edit passes only when both hold:
#
#   1. every changed line is blank, a comment, or a bare `...<name>.<group>`
#      preset spread, and
#   2. no preset spread is removed.
#
# A bare spread carries no literal, so it cannot express a rule override; a
# called preset (`...lint.betterTailwind({...})`) can, and stays denied. Term 2
# is what stops the obvious way around term 1, deleting or commenting out a
# spread to make a rule stop firing.
#
# Everything else is denied, including a shape this allowlist has never seen.
# Uncertainty resolves the same way: an unrecognized tool, a payload whose
# strings are missing or non-string, or a Write whose target cannot be read all
# deny. A filename match already denied all of those, so the allowlist is never
# more permissive than the filename match was, except on the two shapes above.
# That direction is the guard; check any proposed simplification against it.
#
# An unreadable payload is the one exception, and it predates this allowlist:
# without a file_path there is no way to tell whether the call even targets a
# config, so the path gate exits 0 exactly as it always has.
set -euo pipefail

payload=$(cat)

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || file_path=""

printf '%s' "$file_path" | grep -Eq '(^|/)eslint\.config\.(js|cjs|mjs|ts)$' || exit 0

# Exit 2 = block the tool call, stderr is shown to Claude as the reason.
deny() {
  echo "BLOCKED: $1 The rule is to fix the lint error in the source file where it occurs, not to silence it in eslint.config.*. Two edits to this file are allowed: one whose changed lines are all comments, and one that only ADDS a bare '...<name>.<group>' preset spread. Removing a spread, commenting one out, or touching a rules/ignores/options block is denied; make that edit by hand." >&2
  exit 2
}

# Splits input into the two categories the allowlist turns on: `S<TAB><spread>`
# for a bare preset spread, normalized so a trailing comma gained or lost when a
# neighbour is inserted is not a change, and `R<TAB><line>` for everything else,
# which must match line for line. Blank and comment lines are emitted as
# neither, which is what lets them change freely.
#
# A comment PREFIX does not make a line a comment. `/* x */ rules: {…}` closes
# the block and continues with executable code, and so does `// */ rules: {…}`
# on the line after an unclosed `/*`, since inside a block comment a `//` line
# closes it like any other. Either one would otherwise be freely changeable and
# would carry exactly the rule override this guard exists to refuse. So the test
# is not the prefix: a comment-prefixed line counts as a comment only when it
# does not close the block and continue with something. One condition covers all
# three prefixes; carving `//` out as unconditionally safe reopens the second
# vector.
#
# The residual, stated rather than implied: a `*`-prefixed line with no `*/` is
# taken as a comment. Reaching code that way needs a generator-method shape
# (`*gen() {}`), which cannot express a rule override.
#
# A line's own shape is still not enough, because a spread can be neutralized by
# wrapping it rather than by touching it:
#
#     /*
#     ...lint.guardrails,
#     */
#
# Every line there is either a delimiter or unchanged text, so nothing about any
# single line changed, while the preset stops taking effect. Recognizing the
# delimiters by shape does not close it either: an opener may carry text
# (`/* note`), and a closer may already exist further down, so adding only an
# opener swallows everything between. That makes block state the property being
# tested, not the line.
#
# So `scan()` tracks whether a block comment is open, and a line that starts
# inside one is tagged `X` rather than `R` or `S`. A wrapped spread stops being a
# spread, and a wrapped line of code stops matching its own effective self, so
# either way the comparison sees the change.
#
# `scan()` is deliberately a conservative tracker rather than a JavaScript
# parser: it ignores string literals and `//`, so `// see /* note` reads as an
# opener. That direction is the safe one and it is why a real parser is not
# needed here. Misreading the state can only demote a line from `S` to `X`, and
# `X` is compared line for line while `S` is compared as a multiset, so every
# error tightens the guard. There is no misreading that turns a checked line into
# a skipped one, because a comment-prefixed line is skipped on its own shape
# regardless of block state.
classify() {
  awk '
    function scan(line,   i) {
      while (1) {
        if (inblock) {
          i = index(line, "*/")
          if (i == 0) return
          line = substr(line, i + 2)
          inblock = 0
        } else {
          i = index(line, "/*")
          if (i == 0) return
          line = substr(line, i + 2)
          inblock = 1
        }
      }
    }
    BEGIN { inblock = 0 }
    {
      opened_inside = inblock
      scan($0)
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*(\/\/|\/\*|\*)/ && $0 !~ /\*\/[[:space:]]*[^[:space:]]/ { next }
    !opened_inside && /^[[:space:]]*\.\.\.[A-Za-z_$][A-Za-z0-9_$]*\.[A-Za-z_$][A-Za-z0-9_$]*,?[[:space:]]*$/ {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]*,?[[:space:]]*$/, "", s)
      print "S\t" s
      next
    }
    { print (opened_inside ? "X\t" : "R\t") $0 }
  ' <<<"$1"
}

# 0 = this before/after pair is inside the allowlist, 1 = deny.
pair_ok() {
  local before_cls after_cls before_res after_res
  before_cls=$(classify "$1")
  after_cls=$(classify "$2")

  # Everything the classifier emitted except the spreads: effective lines (`R`)
  # and commented-out ones (`X`), which must match line for line, tag included.
  # The tag is what makes a line moving between the two a change.
  before_res=$(grep -v '^S' <<<"$before_cls" || true)
  after_res=$(grep -v '^S' <<<"$after_cls" || true)
  [ "$before_res" = "$after_res" ] || return 1

  printf '%s\n===\n%s\n' "$before_cls" "$after_cls" | awk '
    $0 == "===" { side = 1; next }
    $0 !~ /^S/ { next }
    side == 0 { before[$0]++; next }
    { after[$0]++ }
    END { for (k in before) if (before[k] > after[k]) exit 1 }
  '
}

tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || tool_name=""

case "$tool_name" in
  Write)
    if ! jq -e '.tool_input.content | type == "string"' >/dev/null 2>&1 <<<"$payload"; then
      deny "this Write carries no readable content, so what it changes cannot be established."
    fi
    after=$(jq -r '.tool_input.content' <<<"$payload")
    before=$(cat -- "$file_path" 2>/dev/null || true)
    pair_ok "$before" "$after" ||
      deny "this Write changes more in '$file_path' than comments and added preset spreads."
    ;;

  Edit | MultiEdit)
    if [ "$tool_name" = Edit ]; then
      pairs=$(jq -c '[{old: .tool_input.old_string, new: .tool_input.new_string}]' <<<"$payload" 2>/dev/null) || pairs=''
    else
      pairs=$(jq -c '[.tool_input.edits[]? | {old: .old_string, new: .new_string}]' <<<"$payload" 2>/dev/null) || pairs=''
    fi

    if ! jq -e 'length > 0 and all(.[]; (.old | type == "string") and (.new | type == "string"))' \
      >/dev/null 2>&1 <<<"${pairs:-null}"; then
      deny "this $tool_name carries no readable before/after strings, so what it changes cannot be established."
    fi

    count=$(jq 'length' <<<"$pairs")
    i=0
    while [ "$i" -lt "$count" ]; do
      old=$(jq -r ".[$i].old" <<<"$pairs")
      new=$(jq -r ".[$i].new" <<<"$pairs")
      pair_ok "$old" "$new" ||
        deny "this $tool_name changes more in '$file_path' than comments and added preset spreads."
      i=$((i + 1))
    done
    ;;

  *)
    deny "'$tool_name' is not a tool this guard can read, so what it would change in '$file_path' cannot be established."
    ;;
esac

exit 0
