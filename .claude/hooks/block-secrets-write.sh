#!/usr/bin/env bash
# PreToolUse Edit/Write hook: deny writes that contain obvious secrets.
#
# Patterns:
#   - AWS access key prefix:   AKIA[0-9A-Z]{16}
#   - GitHub PATs:             ghp_, gho_, ghu_, ghs_, ghr_  (followed by token chars)
#   - Private key headers:     -----BEGIN [A-Z ]*PRIVATE KEY-----
#   - dotenv-style assignment to suspicious names, with or without a leading
#     export / declare / typeset / local / readonly and that keyword's own
#     options:
#       (_TOKEN|_SECRET|_KEY|_PASSWORD)=<non-placeholder-value>
#       Placeholders allowed: empty, "", '', x, xxx, changeme, REPLACE_ME,
#       TODO, PLACEHOLDER, ${...}, $VAR, and three whole-value shapes:
#       $(...) unnested, <...> with no inner `>`, and a your-* / fake-* /
#       dummy-* / example* placeholder whose every SEGMENT is short
#       (case-insensitive).
#     A shell declaration additionally allows the ordinary expansion forms as
#     whole values: a positional ($1, ${1}), an EMPTY operand (${VAR:-}), a
#     value that is nothing but braced references (${A}${B}), and ${VAR}
#     followed by a segment-bounded path. The value is judged whole FIRST, so a
#     separator inside it (`$(cmd || true)`) is never mistaken for a tail.
#     Only then does a trailing comment or ; && || clause come off, and it is
#     read rather than discarded. The allowlist judges it only where an
#     EXECUTABLE tail's assignment LEADS its fragment, and a `$(…)` in that
#     assignment's value is kept whole the way the primary value's is. Leading a
#     fragment is a property of the SEPARATORS, not of the surrounding syntax:
#     an assignment behind a bare `{`, `(`, or pipe does not lead one and falls
#     back to shape, while the same assignment after a separator INSIDE that
#     group does lead one and is allowlist-judged. One inside a `$(…)` body is
#     judged by neither, since the mask erases the body. A comment tail, and any
#     tail carrying no assignment, fall back to shape too, a 13+ alphanumeric
#     run mixing letters and digits. That shape bound is the honest limit, an
#     all-letter or under-13 secret parked where shape is what runs clears it.
set -euo pipefail

payload=$(cat)

# Pull whichever field carries the new content (Edit uses new_string, Write uses content,
# MultiEdit uses edits[].new_string). Concatenate so a single pattern scan covers all.
content=$(jq -r '
  ( .tool_input.new_string // "" ) + "\n" +
  ( .tool_input.content    // "" ) + "\n" +
  ( ( .tool_input.edits // [] ) | map(.new_string // "") | join("\n") )
' <<<"$payload")

[[ -n "$content" && "$content" != $'\n\n\n' ]] || exit 0

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# 1. AWS access keys.
if grep -Eq 'AKIA[0-9A-Z]{16}' <<<"$content"; then
  deny "BLOCKED: write contains an AWS access-key id (AKIA…). Use environment variables, never commit secrets."
fi

# 2. GitHub PATs.
if grep -Eq '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}' <<<"$content"; then
  deny "BLOCKED: write contains a GitHub personal-access-token. Use environment variables, never commit secrets."
fi

# 3. Private key headers.
if grep -Eq -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' <<<"$content"; then
  deny "BLOCKED: write contains a PEM private-key header. Never commit private keys."
fi

# 4. dotenv-style assignments to suspicious names with non-placeholder values.
#    Iterate matching lines and apply the placeholder allowlist.

# The suspicious-name grammar, named once because TWO callers read it: the loop
# feeder at the bottom, and the executable-tail rescan inside the loop, which
# has to recognize a second assignment parked after `;` / `&&` / `||` by the
# same rule that recognized the first one. A private copy in either place is a
# copy that drifts.
#
# The declaration keyword carries its own options, so the group has to accept
# them too. `declare -r` and `local -r` are the idiomatic spellings in careful
# bash, and a group that only accepts the bare keyword takes exactly those lines
# back out of the scan, which is the failure recognizing the keywords exists to
# close. `typeset` is bash's synonym for `declare` and belongs with the others.
name_re='^[[:space:]]*((export|declare|typeset|local|readonly)[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*(_TOKEN|_SECRET|_KEY|_PASSWORD)[[:space:]]*='

# Strip surrounding whitespace, then one matched pair of surrounding quotes.
trim_value() {
  sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' <<<"$1"
}

# secret_shaped <text>: 0 when the text carries a run of 13+ alphanumerics
# mixing letters and digits. A placeholder segment is bounded at 12 and prose
# does not take that shape, so this is the same structural rule the placeholder
# arms use, applied to text that is not a value. Its honest limit: an all-letter
# secret clears it, and so does anything under 13 characters.
#
# The consumer is fed by process substitution rather than sitting at the end of
# a pipe, because under `pipefail` the pipeline's status IS this function's
# return value and `grep -q` exits on its first match. On text carrying enough
# runs that the producer is still writing, the producer takes SIGPIPE, the
# pipeline reports 141, and the function reports NOT secret-shaped: a fail-OPEN
# on exactly the densest material, and the wrong direction for a guard. Short
# text never shows it, since the producer finishes before the consumer leaves.
secret_shaped() {
  grep -qE '[0-9].*[A-Za-z]|[A-Za-z].*[0-9]' < <(grep -oE '[A-Za-z0-9]{13,}' <<<"$1")
}

# value_allowed <value>: 0 when the value carries no literal secret. Every arm
# is a shape heuristic, not a proof, and each has to mean "the value is WHOLLY
# this shape" rather than "the value starts or ends like it". Two ways an arm
# loses that meaning, both of which this allowlist has shipped:
#
#   - A delimiter class that swallows its own terminator. `$(.+)` and `<.+>`
#     match `)` / `>` inside the body, so `$(a)<literal>$(b)` and
#     `<a><literal><b>` satisfy anchors that were supposed to certify a whole
#     value. Excluding the terminator from the body is the fix, at the cost of
#     a nested `$(… $(…) …)`, denied, since balanced delimiters need a parser.
#   - An unanchored tail. `^your[-_]` and `^example` matched a PREFIX, so any
#     secret rode through behind a placeholder-shaped lead-in.
#
# What separates a placeholder from a secret is STRUCTURE, not length: a
# placeholder is short words joined by -_. while a secret is one unbroken
# alphanumeric run. So the placeholder arms bound each SEGMENT rather than the
# whole value, which keeps `your-github-personal-access-token` (long, segmented)
# and rejects `your-aB3xK9pQ7zR2wL5t` (short, unbroken). A length cap gets both
# of those backwards.
#
# None of these read meaning. `$(mint_key)` and `$(echo <a-literal-secret>)`
# are the same shape, so the arm admits both; separating them needs reading
# the command, and this allowlist does not claim to.
value_allowed() {
  local v="$1"
  if [ -z "$v" ]; then
    return 0
  fi
  case "$v" in
    x|xx|xxx|xxxx|changeme|CHANGEME|REPLACE_ME|TODO|PLACEHOLDER|placeholder)
      return 0 ;;
  esac
  if grep -Eqi \
    '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$|^\$[A-Za-z_][A-Za-z0-9_]*$|^\$\([^)]+\)$|^<[^>]+>$|^(your|fake|dummy)[-_][A-Za-z0-9]{1,12}([-_.][A-Za-z0-9]{1,12})*$|^example([-_.][A-Za-z0-9]{1,12})*$' \
    <<<"$v"; then
    return 0
  fi
  # A shell declaration (`export FOO_KEY=…`) reaches this rule too, and those
  # values are variable references far more often than dotenv literals are.
  # The bare-identifier arm above admits none of the ordinary expansion forms,
  # so these whole-value shapes are allowed alongside it: a positional in
  # either spelling (`$1`, `${1}`), an expansion whose operand is EMPTY
  # (`${VAR:-}`, `${VAR:?}`), a value that is nothing but braced references
  # (`${A}${B}`), and an expansion followed by a path (`${ROOT}/dev.pem`).
  #
  # Each is anchored end to end, and the operand arm requires the operand to be
  # empty rather than merely short: a default value is exactly where a real
  # secret lands, and no shape test tells `${K:-550e8400-e29b-41d4-a716-…}`
  # from a legitimate one, because a segmented secret has the same structure a
  # placeholder does. The all-references arm needs no bound at all, since a
  # value made only of references contains no literal to hide one in.
  #
  # The path arm carries the SAME per-segment bound the placeholder arms use,
  # for the same reason they use it. Requiring the literal to open with `/` or
  # `.` bounds only where the tail starts, not how long it runs, so on its own
  # the separator would unlock the whole character set a secret is written in:
  # `${X}/sk-live-…` is one segment, not a path. Bounding each segment keeps
  # `${ROOT}/dev.pem` and drops the secret.
  #
  # These deliberately do NOT match a value containing `$(…)`. A reference
  # inside a substitution body would otherwise re-open the splice bypass the
  # `$(…)` arm above exists to close, since `$(echo ${X})<secret>` contains a
  # reference like any other.
  if grep -Eq '^\$[0-9]$|^\$\{[0-9]+\}$|^\$\{[A-Za-z_][A-Za-z0-9_]*:?[-+?=]\}$|^(\$\{[A-Za-z_][A-Za-z0-9_]*\})+$|^\$\{[A-Za-z_][A-Za-z0-9_]*\}([/.][A-Za-z0-9_-]{1,12})+$' <<<"$v"; then
    return 0
  fi
  return 1
}

while IFS= read -r line; do
  rest=$(sed -E 's/^[^=]*=//' <<<"$line")

  # Judge the value UNTRIMMED first, and only fall through to the tail handling
  # when nothing matches. A `;`, `&&`, `||`, or `#` can sit INSIDE the value
  # rather than after it, and the tail strip cannot tell the two apart: it is a
  # regex, not a parser, so it has no substitution or quoting context.
  # `$(cmd 2>/dev/null || true)` is the shape that matters, since it is how this
  # repo's own scripts guard a command substitution, and truncating it at the
  # `||` leaves a value with no closing paren that no arm can match. Ordering
  # the untrimmed judgement first is what bounds the strip: it can turn a deny
  # into an allow, never an allow into a deny.
  if value_allowed "$(trim_value "$rest")"; then
    continue
  fi

  # A shell line carries a tail a dotenv line never does: a trailing comment, or
  # a second statement after `;`, `&&`, `||`. It has to come off before the
  # allowlist reads the value, or the whole remainder of the line becomes the
  # value, no arm can match, and an ordinary secret-free
  # `export FOO_KEY="$BAR" # note` is hard-blocked by a deny that tells its
  # author to use the environment variable the line already uses.
  #
  # The tail comes off, but it is never DISCARDED unread. A comment beside a
  # placeholder, or a second assignment after `;`, is exactly where a real key
  # gets parked, so dropping it unexamined would trade the false positive above
  # for a hole. How it is read depends on which separator opened it, because the
  # two tails differ in kind and only one of them has structure worth reusing.
  tail=$(grep -oE '[[:space:]]+(#|[|][|]|&&|;).*$' <<<"$rest" | head -1 || true)
  if [ -n "$tail" ]; then
    sep=$(sed -E 's/^[[:space:]]+//; s/^(#|[|][|]|&&|;).*$/\1/' <<<"$tail")
    tail_has_assignment=0
    if [ "$sep" != "#" ]; then
      # An EXECUTABLE tail whose assignment LEADS a fragment is judged by the
      # assignment rule, not by shape: split on the separators and run the same
      # name grammar and the same allowlist over each fragment. Shape alone lets
      # a parked key through whenever it is under 13 characters or all letters,
      # and the feeder grep is line-anchored, so it never re-reads a fragment.
      #
      # The grammar is tested per FRAGMENT, never against the whole tail: it is
      # anchored at `^`, and the tail still opens with its own separator, so a
      # whole-tail test can never match and would silently downgrade every one
      # of these to the shape rule. That anchor is also what bounds the reach,
      # and the bound is about separators rather than syntax: an assignment
      # behind a BARE `{`, `(`, or pipe does not lead its fragment and falls
      # back to shape, while the same assignment placed after a separator INSIDE
      # that group does lead one and is judged right here. One sitting inside a
      # `$(…)` body is judged in neither place, because the mask erases the body
      # before the split ever sees it.
      #
      # A separator can sit INSIDE a parked value exactly as it can inside the
      # primary one, and the split is a `tr`, not a parser. So an unnested
      # `$(…)` masks to a body-free `$(@)` before the `tr` ever sees the tail.
      # That is the rescan's version of the untrimmed-first bound above: it
      # keeps `$(cmd 2>/dev/null || true)` whole instead of truncating it at the
      # `||` into a fragment with no closing paren that no arm can match.
      #
      # The mask is NOT verdict-preserving, and erasing a body erases whatever
      # it held. Rather than assert a bound this does not have, the consequences
      # that follow from it, each verified and each pinned by a test:
      #
      #   - An assignment sitting between a `$(` and its first `)` goes away
      #     with the body, so one parked inside a substitution clears where the
      #     truncated fragments used to deny.
      #   - The erased body can take an inner `>` with it, so a `<…>` wrapper
      #     that the `>` used to disqualify (`<$(cmd 2>/dev/null)>`) reads as a
      #     whole placeholder and clears. The PRIMARY value does NOT reach this
      #     one, so here the tail is the more permissive of the two.
      #   - Erasing an assignment also erases the evidence that the tail HAD
      #     one, which is why the flag is read separately below, off the
      #     unmasked tail. Without that split the mask denies where the old
      #     split allowed.
      #
      # None of this hands a writer concealment the guard does not already give,
      # and the reason is the plain `<…>` arm rather than anything about the
      # mask: `<hunter2xyz123>` is allowed in BOTH positions by `^<[^>]+>$`
      # today, so a bracket wrapper already conceals a bare 13+ run wherever it
      # appears. The mask changes which BODY reaches that arm, not whether the
      # arm admits a wrapped literal.
      #
      # The mask carries the substitution arm's own bound, `[^)]+`, so it stops
      # at the first `)` and, like the arm, declines an EMPTY body: `$()` is
      # denied in both positions rather than in the primary alone. A greedy body
      # would run to the LAST `)` on the line and swallow an assignment parked
      # between two substitutions, which is the one thing the split still has to
      # see. Masking and collapsing are independent, since the collapse touches
      # no `$`, `(`, or `)`; only running both before the `tr` matters.
      #
      # The operators collapse to `;` so the split needs only `tr`, which keeps
      # this portable to BSD `sed` (no `\n` in a replacement). The loop is fed
      # by process substitution rather than a pipe so it runs in this shell and
      # its flag survives.
      #
      # SC2016 fires on the mask's `$(@)` replacement. Not expanding is the
      # whole point: it has to reach `sed` as the literal text the masked value
      # becomes, and expanding it would run `@` as a command.
      # shellcheck disable=SC2016
      while IFS= read -r frag; do
        [ -n "$frag" ] || continue
        grep -Eq "$name_re" <<<"$frag" || continue
        tail_has_assignment=1
        if ! value_allowed "$(trim_value "$(sed -E 's/^[^=]*=//' <<<"$frag")")"; then
          deny "BLOCKED: write parks a secret assignment after a shell separator: '$line'. Use environment variables / .env (gitignored), not committed source."
        fi
      done < <(sed -E 's/\$\([^)]+\)/$(@)/g; s/[|][|]/;/g; s/&&/;/g' <<<"$tail" | tr ';' '\n')

      # The mask governs the DENY judgement only; the FLAG is read from the
      # UNMASKED tail. Erasing a body erases any assignment inside it, so a tail
      # whose only watched assignment sits in a substitution would otherwise
      # leave the flag at 0 and fall through to the shape rule, which then reads
      # the very material the mask claimed to remove and denies a line holding
      # no literal. Splitting the two inputs keeps the mask one-directional: it
      # can turn a deny into an allow, never the reverse.
      # `grep` is fed by process substitution rather than sitting at the end of
      # a pipeline, for the same reason the loop above is, and the reason bites
      # harder here. Under `pipefail` the `if` reads the WHOLE pipeline's
      # status, and `grep -q` exits on its first match: on a tail long enough
      # that `tr` is still writing, `tr` takes SIGPIPE, the pipeline reports
      # 141, the flag stays 0 on a tail that plainly carries an assignment, and
      # the shape rule denies. A short tail never shows it, because `tr` is done
      # before `grep` leaves.
      if grep -Eq "$name_re" < <(sed -E 's/[|][|]/;/g; s/&&/;/g' <<<"$tail" | tr ';' '\n'); then
        tail_has_assignment=1
      fi
    fi
    # A comment tail, or an executable tail whose assignment never leads a
    # fragment, has no structure the rescan can reuse, so it falls back to the
    # shape rule.
    if [ "$tail_has_assignment" -eq 0 ] && secret_shaped "$tail"; then
      deny "BLOCKED: write parks secret-shaped material in a trailing comment or statement: '$line'. Use environment variables / .env (gitignored), not committed source."
    fi
  fi

  # Now the value itself, with the tail off. The comment separator has to be
  # preceded by whitespace so a `#` inside the value itself is not read as one.
  val=$(trim_value "$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+([|][|]|&&|;).*$//' <<<"$rest")")
  if value_allowed "$val"; then
    continue
  fi
  deny "BLOCKED: write contains a non-placeholder secret assignment: '$line'. Use environment variables / .env (gitignored), not committed source."
done < <(grep -E "$name_re" <<<"$content" || true)

exit 0
