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
# So the guard is an ALLOWLIST over what an edit changes, not a filename match.
# Each side of the edit is read as a stream of the lines that matter: blank lines
# and comments drop out, and every line that survives is tagged either a bare
# `...<name>.<group>` preset spread or anything else. An edit passes on one
# relation between the two streams:
#
#   the before stream appears in the after stream as an ORDERED SUBSEQUENCE,
#   and every after line the match does not consume is a preset spread.
#
# Read as shapes, that is: a blank line or a comment changes freely, since
# neither reaches the stream; a preset spread may be ADDED anywhere; and nothing
# else may be added, and nothing at all removed, altered, or REORDERED, since
# order is the thing a subsequence preserves.
#
# A bare spread carries no literal, so it cannot express a rule override; a
# called preset (`...lint.betterTailwind({...})`) can, and stays denied.
# Refusing removal is what stops the obvious way around addition, deleting or
# commenting out a spread so a rule stops firing. Refusing reordering stops the
# same thing by a quieter route, because a later spread overrides an earlier one
# and moving one silences rules without touching a line (see `classify()`).
#
# One relation rather than a list of permitted shapes is the point: a shape list
# is only as good as the shapes someone thought of, and a move is the shape that
# gets missed, being neither an addition nor a deletion.
#
# Everything else is denied, including a shape this allowlist has never seen.
# Uncertainty resolves the same way: an unrecognized tool, a payload whose
# strings are missing or non-string, or a target that cannot be read all deny. A
# filename match already denied all of those, so the allowlist is never more
# permissive than the filename match was, except that it admits a comment-only
# change and an added preset spread. That direction is the guard; check any
# proposed simplification against it.
#
# Every tool shape is judged on WHOLE FILES, never on the strings the payload
# carries. An Edit's `old_string`/`new_string` are a fragment whose boundaries
# the caller chooses, and comment state is a property of the file rather than of
# the fragment, so judging fragments lets the caller pick a window that hides
# what the edit does. Two edits that each look inert then compose into one that
# is not: append a lone `/*` after one spread, append a lone `*/` after another,
# and the spreads between them stop running while both fragments read as pure
# comment lines. So Edit and MultiEdit reconstruct the before and after file the
# way the real tool will, applying each pair in order, and classify those.
# Reconstruction failure denies: an unreadable target, an `old_string` that is
# absent, or one that matches more than once without `replace_all`, which is the
# same uniqueness contract the edit tools themselves enforce.
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
  echo "BLOCKED: $1 The rule is to fix the lint error in the source file where it occurs, not to silence it in eslint.config.*. Two edits to this file are allowed: one whose changed lines are all comments, and one that only ADDS a bare '...<name>.<group>' preset spread. Removing a spread, commenting one out, MOVING one (a later preset overrides an earlier one, so order silences rules too), or touching a rules/ignores/options block is denied; make that edit by hand." >&2
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
# parser. It counts a `/*` as an opener only at line start or after whitespace,
# which is what keeps an ordinary glob out of it: `['dist/**']` and
# `['.gaia/**']` both contain `/*`, and treating those as openers puts the whole
# rest of the file inside a phantom comment, which denies the very migration
# this hook exists to allow on the config that motivated it. The test costs
# nothing in strictness, because an opener sitting on a line that is not itself
# blank or comment-prefixed makes that line residue, and adding or changing
# residue is already denied. What it does not model is a string literal holding a
# whitespace-preceded `/*`; that reads as an opener and denies.
#
# Over-reading the state demotes a line from `S` to `X`, and `X` is compared line
# for line while `S` is compared as a multiset, so an error in that direction
# tightens the guard. Under-reading runs the other way, and the opener rule can
# under-read: `];/*` opens a block in JavaScript and is not counted here, so the
# region below it reads as live when it is really commented out, and a later bare
# `*/` would then be admitted while really ending the block early. That residual
# is accepted rather than closed, on two grounds. No admitted edit can create the
# precondition, since a line carrying such a `/*` is residue and changing residue
# is already denied, so the guard cannot be walked into the state; the config has
# to arrive that way. And every candidate rule tried here trades one direction of
# error for the other: excluding word characters instead of requiring whitespace
# restores `];/*` and re-breaks `['**/*.ts']`. Chasing that is how a guard
# acquires a shape per round.
#
# The whole argument holds only because `classify()` is fed a whole file: seeding
# the tracker at the start of a caller-chosen fragment is itself a misreading,
# and that one runs the loosening way, promoting `X` back to `S`.
#
# One residual this leaves, fail-closed, costing a by-hand edit rather than
# admitting anything: a block comment whose body lines carry no `*` prefix is
# tagged `X` and compared line for line, so rewording that prose is denied. The
# `//` and ` * ` styles this repo uses are skipped and unaffected.
#
# What the tags do NOT carry is position, so the comparison in `pair_ok()` has to
# supply it. Preset order is load-bearing: ESLint applies later config objects
# over earlier ones, and the groups in `@gaia-react/lint` overlap heavily rather
# than partitioning the rule space, `base` and `prettier` alone sharing 155 rule
# ids with most set at different severities. So swapping two spreads, or hoisting
# one past a line that is not a spread, turns rules off that are on today,
# without adding, deleting, or altering a single line. Anything that compares the
# spreads as an unordered set cannot see it.
classify() {
  awk '
    function scan(line,   i, prev) {
      while (1) {
        if (inblock) {
          i = index(line, "*/")
          if (i == 0) return
          line = substr(line, i + 2)
          inblock = 0
        } else {
          i = index(line, "/*")
          if (i == 0) return
          prev = (i == 1) ? " " : substr(line, i - 1, 1)
          line = substr(line, i + 2)
          if (prev == " " || prev == "\t") inblock = 1
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
#
# One walk down the two classified streams, matching each before line against the
# next after line that equals it, tag included, so that a line moving between the
# categories counts as a change: a spread wrapped in a block comment comes back
# `X` and no longer equals the `S` line it was. The pair passes when the walk
# consumes the whole before stream and every after line it skipped is a spread.
#
# Matching greedily is safe. Which after lines end up skipped does not depend on
# where the walk chose to match, because the matched lines are exactly the before
# stream either way, so the skipped ones are always the after stream minus the
# before stream. The greedy walk therefore decides the whole relation, and it is
# the standard subsequence test.
#
# This one relation subsumes the pair of tests it replaces, rather than trading
# one for the other. If the before stream embeds in order then every non-spread
# line survives in its own order and no non-spread line was added, which is the
# line-for-line comparison; and each before spread consumes a distinct after
# spread, which is the no-spread-removed count. It refuses two things they let
# through, a reorder and a hoist past a non-spread line, and nothing they refuse
# gets through it.
pair_ok() {
  local before_cls after_cls
  before_cls=$(classify "$1")
  after_cls=$(classify "$2")

  # `classify()` never emits an empty line, so skipping them costs nothing and
  # keeps an empty stream (an empty or absent file) from arriving as one line.
  printf '%s\n===\n%s\n' "$before_cls" "$after_cls" | awk '
    /^$/ { next }
    $0 == "===" { side = 1; next }
    side == 0 { before[++nb] = $0; next }
    { after[++na] = $0 }
    END {
      j = 1
      for (i = 1; i <= na; i++) {
        if (j <= nb && after[i] == before[j]) { j++; continue }
        if (after[i] !~ /^S/) exit 1
      }
      if (j <= nb) exit 1
    }
  '
}

# Applies one literal old -> new replacement to the text on stdin, the way the
# edit tools do. Strings arrive through the environment rather than `awk -v`,
# which processes backslash escapes in its value and would corrupt any edit
# carrying a backslash. Exit 1 = `old` absent or empty, 2 = it matches more than
# once without `replace_all`; both deny.
apply_edit() {
  GAIA_OLD="$1" GAIA_NEW="$2" GAIA_ALL="$3" awk '
    { buf = buf $0 "\n" }
    END {
      old = ENVIRON["GAIA_OLD"]
      new = ENVIRON["GAIA_NEW"]
      all = ENVIRON["GAIA_ALL"]
      if (old == "") exit 1
      rest = buf
      out = ""
      n = 0
      while ((i = index(rest, old)) > 0) {
        n++
        out = out substr(rest, 1, i - 1) ((all == "true" || n == 1) ? new : old)
        rest = substr(rest, i + length(old))
      }
      if (n == 0) exit 1
      if (n > 1 && all != "true") exit 2
      printf "%s", out rest
    }
  '
}

tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || tool_name=""

case "$tool_name" in
  Write)
    if ! jq -e '.tool_input.content | type == "string"' >/dev/null 2>&1 <<<"$payload"; then
      deny "this Write carries no readable content, so what it changes cannot be established."
    fi
    after=$(jq -r '.tool_input.content' <<<"$payload")
    # An unreadable target is not an empty one. Swallowing the read failure
    # judges the Write against a baseline nothing ever read, and every line of the
    # replacement then reads as added, so content that is nothing but comments and
    # spreads passes while really replacing a whole config, spreads and rules
    # blocks included. The Edit and MultiEdit arms refuse an unreadable target and
    # this one has to as well. A target that does not exist is the one honest
    # empty baseline: there the Write creates the file rather than replacing
    # anything. No `printf x` sentinel here, unlike the arms below: nothing is
    # reconstructed from the two strings, and a trailing newline reaches the
    # classifier as a blank line, which it drops. Leaving it off is also what
    # keeps `|| deny` live, since the sentinel would supply the exit status.
    if [ -e "$file_path" ]; then
      { [ -f "$file_path" ] && [ -r "$file_path" ]; } ||
        deny "'$file_path' cannot be read, so what this Write changes cannot be established."
      before=$(cat -- "$file_path") ||
        deny "'$file_path' cannot be read, so what this Write changes cannot be established."
    else
      before=""
    fi
    pair_ok "$before" "$after" ||
      deny "this Write changes more in '$file_path' than comments and added preset spreads."
    ;;

  Edit | MultiEdit)
    if [ "$tool_name" = Edit ]; then
      pairs=$(jq -c '[{old: .tool_input.old_string, new: .tool_input.new_string,
                       all: (.tool_input.replace_all // false)}]' <<<"$payload" 2>/dev/null) || pairs=''
    else
      pairs=$(jq -c '[.tool_input.edits[]? | {old: .old_string, new: .new_string,
                       all: (.replace_all // false)}]' <<<"$payload" 2>/dev/null) || pairs=''
    fi

    if ! jq -e 'length > 0 and all(.[]; (.old | type == "string") and (.new | type == "string"))' \
      >/dev/null 2>&1 <<<"${pairs:-null}"; then
      deny "this $tool_name carries no readable before/after strings, so what it changes cannot be established."
    fi

    [ -f "$file_path" ] && [ -r "$file_path" ] ||
      deny "'$file_path' cannot be read, so what this $tool_name changes cannot be established."
    # `$(…)` strips every trailing newline, and here that is not cosmetic: when
    # `old_string` ends in a newline and `new_string` does not, the tool glues
    # `new_string`'s last line onto the line that followed, so `…base,\n` ->
    # `…base,\n  //` comments out the spread below rather than adding a `//`
    # line of its own. Stripping either string hides that. The `printf x`
    # sentinel preserves them exactly, and `jq -j` is what keeps jq from adding a
    # newline of its own on top.
    before=$(cat -- "$file_path" 2>/dev/null; printf x) ||
      deny "'$file_path' cannot be read, so what this $tool_name changes cannot be established."
    before=${before%x}

    after="$before"
    count=$(jq 'length' <<<"$pairs")
    i=0
    while [ "$i" -lt "$count" ]; do
      old=$(jq -j ".[$i].old" <<<"$pairs"; printf x); old=${old%x}
      new=$(jq -j ".[$i].new" <<<"$pairs"; printf x); new=${new%x}
      all=$(jq -r ".[$i].all" <<<"$pairs")
      rc=0
      next=$(apply_edit "$old" "$new" "$all" <<<"$after") || rc=$?
      case "$rc" in
        0) after="$next" ;;
        2) deny "this $tool_name's replaced text appears more than once in '$file_path', so which occurrence it changes cannot be established." ;;
        *) deny "this $tool_name's replaced text is not present in '$file_path', so what it changes cannot be established." ;;
      esac
      i=$((i + 1))
    done

    pair_ok "$before" "$after" ||
      deny "this $tool_name changes more in '$file_path' than comments and added preset spreads."
    ;;

  *)
    deny "'$tool_name' is not a tool this guard can read, so what it would change in '$file_path' cannot be established."
    ;;
esac

exit 0
