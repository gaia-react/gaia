#!/usr/bin/env bash
# PreToolUse Edit/Write hook: deny writes that contain obvious secrets.
#
# Patterns:
#   - AWS access key prefix:   AKIA[0-9A-Z]{16}
#   - GitHub PATs:             ghp_, gho_, ghu_, ghs_, ghr_  (followed by token chars)
#   - Private key headers:     -----BEGIN [A-Z ]*PRIVATE KEY-----
#   - dotenv-style assignment to suspicious names, with or without a leading
#     export / declare / typeset / local / readonly and that keyword's own
#     options. In a write whose destination is named `.env.example`, this rule
#     alone drops its placeholder allowlist and judges the value by SHAPE only,
#     the way both sibling env guards already special-case that file; the three
#     rules above still run on it:
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
#     run mixing letters and digits. That bound is on the RUN, not the value, so
#     the honest limit where shape is what runs is that a value whose every
#     alphanumeric run is under 13 or unmixed clears, a segmented secret
#     included.
set -euo pipefail

payload=$(cat)

# The destination, read for the one path-scoped exemption in rule 4 below. Every
# tool on this matcher (Edit, Write, MultiEdit) carries it; a payload without one
# resolves to empty, matches no exemption, and is scanned in full.
file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")

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

# Strip surrounding whitespace, then surrounding quotes.
trim_value() {
  sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' <<<"$1"
}

# The run of `x` every mask body is filled from, grown on demand and reused
# across the bodies of ONE call. The sole call site is a command substitution, so
# the growth is discarded when that subshell exits and the next call rebuilds
# from scratch, which is O(n) against a walk already O(n) per substitution. That
# per-call reset is also why no call can observe another's state, and the
# unconditional initializer is what keeps an inherited environment variable of
# the same name from ever being read as a run.
mask_xrun=x

# mask_subs <text>: a SAME-LENGTH copy of <text> whose every unnested `$(…)`
# body is overwritten with `x`. Equal length is the whole point of it. The
# caller locates a cut OFFSET on the copy and applies that offset to the
# original, so the value the allowlist reads is the true one and no arm is ever
# satisfied by masked material.
#
# That is what separates this from the executable tail's own mask below. That
# one feeds the fragments the allowlist judges, so it collapses a body to `$(@)`
# and accepts, in the consequences listed there, that erasing a body erases
# whatever the body held. This one feeds nothing but a position, so it erases
# nothing from any judgement.
#
# It carries the `$(…)` arm's own bound, `[^)]+`: it stops at the first `)` and
# leaves an EMPTY body alone, so `$()` and a nested `$(… $(…) …)` are masked the
# way that arm reads them rather than some other way. An unclosed `$(` ends the
# walk with the remainder passed through untouched, which leaves the caller's
# cut exactly where it already was. That bound is written in three places, here,
# in `value_allowed`'s substitution arm, and in the tail rescan's own mask; they
# have to agree, since each reads the same `$(…)` the others do.
#
# The x-run is taken from a doubling cache rather than from `${body//?/x}`.
# Bash's pattern substitution rescans the whole body per replacement, which is
# quadratic: on bash 3.2.57 an 8000-character body costs 26 seconds where the
# cache costs 53 milliseconds. This registration carries no `timeout`, and a
# hook killed before it reaches its `deny` lets the write through, so that cost
# is a fail-OPEN and the wrong direction for a guard.
#
# `sed 's/./x/g'` also preserves character length, multibyte included, and would
# fix that axis. The cache is used instead because it spawns nothing: the walk's
# own cost is quadratic in the NUMBER of substitutions rather than in body
# length, so a line carrying hundreds of them would pay a process per body on
# top of a cost the x-run never had.
#
# That second axis is bounded by the length cap instead, since no pure-bash walk
# avoids it. Above the cap the mask is the IDENTITY, so the cut is located on the
# raw value and this rule behaves exactly as it does without the mask at all.
#
# For every arm but one that is a false deny on a pathological line, the
# fail-CLOSED direction the rule already errs in everywhere else. The exception
# is `^<[^>]+>$`, and it follows from the same asymmetry the call site describes:
# reverting to the earlier cut also reverts that arm's allow-to-deny movement, so
# a truncated prefix satisfies it above the cap where the whole value fails it
# below. That admits nothing the rule does not already admit with no mask at all,
# but the cap is not fail-closed in one uniform direction, and lowering it on
# cost grounds means widening that one arm's reach.
#
# SC2016 fires on the `'$('` operands. Not expanding is the whole point, the
# same way it is for the tail mask below: `$(` is the literal two-character
# opener being searched for, and letting it expand would run a substitution
# instead of matching one.
# shellcheck disable=SC2016
mask_subs() {
  local s="$1" out="" body n
  [ ${#s} -le 4096 ] || { printf '%s' "$s"; return 0; }
  while [[ "$s" == *'$('* ]]; do
    out+="${s%%'$('*}"'$('
    s="${s#*'$('}"
    case "$s" in
      *')'*) ;;
      *) break ;;
    esac
    body="${s%%')'*}"
    s="${s#*')'}"
    n=${#body}
    if [ "$n" -gt 0 ]; then
      while [ ${#mask_xrun} -lt "$n" ]; do mask_xrun="$mask_xrun$mask_xrun"; done
      out+="${mask_xrun:0:n})"
    else
      out+=')'
    fi
  done
  printf '%s' "$out$s"
}

# secret_shaped <text>: 0 when the text carries a run of 13+ alphanumerics
# mixing letters and digits. A placeholder segment is bounded at 12 and prose
# does not take that shape, so this is the same structural rule the placeholder
# arms use, applied to text that is not a value. The bound is on the RUN, not on
# the whole text, and that is its honest limit: text clears whenever every
# alphanumeric run in it is under 13 or unmixed, however long the text itself
# runs. A separator is what breaks a run, so a segmented secret clears however
# much material it carries: a UUID-format key, whose longest run is 12 and all
# digits, and a base64 secret broken by `/` or `+`, are both read as not
# secret-shaped.
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

# `.env.example` is judged by SHAPE alone, skipping the placeholder allowlist
# below. It is a committed file whose entire purpose is to carry placeholder
# assignments, and both sibling guards already treat it that way:
# `block-env-read.sh` exempts it while denying the rest of the dotenv family,
# and `block-env-write.sh` exempts it by this same basename on this same
# matcher. This rule was the holdout, so the one file that exists to hold
# placeholders was the one file whose assignments could not be edited, and the
# deny told its author to use a gitignored `.env` instead, which is backwards
# for exactly this file. Its own `SESSION_SECRET` line is the worked example:
# five letters, so it clears no placeholder arm at all.
#
# Dropping the allowlist is not the same as dropping the rule, and the
# difference is what keeps a committed file from becoming the soft spot. The
# allowlist asks "is this value a recognized placeholder", which every honest
# `.env.example` value fails: `local`, `development`, `3001`, a localhost URL.
# Shape asks "is this an unbroken 13+ alphanumeric run mixing letters and
# digits", which every one of those passes and a pasted `sk-live-…`, JWT, or
# bare API key does not. So the file's real content writes freely while the
# paste that actually matters is still refused, alongside the three
# high-confidence pattern rules above, which run here as everywhere.
#
# Its honest limit is the shape rule's own, stated where that rule is defined:
# the bound is on the RUN, so a value whose every alphanumeric run is under 13
# or unmixed clears. The segmented case is what that admits furthest past the
# allowlist it replaces, and it is the one worth naming here: a UUID-format key,
# or a base64 secret broken by `/` or `+`, writes into this tracked file while
# the same value stays denied at every other path. The cost runs the other way
# too, and is accepted rather than hidden: an ordinary value carrying a 13+
# mixed run, say a hostname like `myapp123456789.example.com`, is refused here.
#
# Dropping the allowlist drops the executable-tail rescan with it, since that
# rescan exists to allowlist-judge a SECOND assignment parked after `;`, `&&`,
# or `||`. Here the whole post-`=` remainder is shape-tested as one string, so a
# tail assignment carrying a weak value clears where the general path denies it,
# and one carrying a secret-shaped value is refused the same as the first. That
# follows from the shape-only rule rather than qualifying it, but it inverts
# what the general path's own tests pin, so the suite pins it here too.
#
# The match is this exact basename, so `.env`, `.env.local`, and
# `.env.example.local` reach the full allowlist below as before. `basename --`
# because a path may begin with a dash, matching `block-env-read.sh`.
if [ "$(basename -- "${file_path:-}")" = ".env.example" ]; then
  while IFS= read -r line; do
    # No `trim_value` here, unlike the general path below, and the asymmetry is
    # deliberate rather than an oversight. Shape reads `[A-Za-z0-9]{13,}` runs,
    # while trimming removes only surrounding whitespace and surrounding quotes:
    # all non-alphanumeric, and all at the ends. So it can neither lengthen a run
    # nor merge two, and it cannot change this verdict. What carries that is the
    # removals being non-alphanumeric and at the ends, not how many come off. The
    # general path needs it because the allowlist's arms anchor on the whole
    # value.
    if secret_shaped "$(sed -E 's/^[^=]*=//' <<<"$line")"; then
      deny "BLOCKED: write assigns secret-shaped material in .env.example: '$line'. That file carries placeholders; keep the real value in a gitignored .env."
    fi
  done < <(grep -E "$name_re" <<<"$content" || true)
  exit 0
fi

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
  #
  # The cut point is located on a length-preserving mask of the value and then
  # applied to the UNMASKED value by offset, so a separator sitting inside a
  # `$(…)` body cannot open a tail. Locating it on the raw value instead cuts
  # `$(cmd 2>/dev/null || true) # note` at the body's own `||` and leaves
  # `$(cmd`, a fragment with no closing paren that no arm can match, so the deny
  # tells its author to use an environment variable on a line that already runs
  # a command to fetch one. Masking only the LOCATOR is what keeps that honest:
  # `value_allowed` still reads the true value, and the untrimmed judgement
  # above still runs first, so the two orderings agree.
  #
  # The mask writes `x`, so it can only REMOVE a separator, never add one, and a
  # cut can therefore only move later. Every value it newly ADMITS is one the
  # untrimmed judgement above already admits when the same line carries no tail,
  # so nothing reaches an arm here that could not already reach it there.
  #
  # A later cut leaves MORE material in the value, so it can also turn an allow
  # into a deny, and one arm does: `^<[^>]+>$` can be satisfied by a truncated
  # prefix that the whole value fails on an inner `>`, as in `<$(a> ; b)>`. Both
  # of those movements run fail-CLOSED, and for that shape the whole-value read
  # is the correct one, since it also denies `<$(<a-literal>> ; c)>` where the
  # truncated prefix cleared it.
  #
  # Its limit is the separator grammar's, not the mask's, and the grammar is
  # unchanged: an executable separator still has to be preceded by whitespace to
  # open a tail. So `FOO_KEY=$(cmd || true); export FOO_KEY` is read as one
  # value through to the `; export FOO_KEY` and denied. Widening the grammar to
  # bare separators is what a dotenv value cannot survive, since `a;b` is an
  # ordinary value in the file this rule exists for.
  kept=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+([|][|]|&&|;).*$//' <<<"$(mask_subs "$rest")")
  val=$(trim_value "${rest:0:${#kept}}")
  if value_allowed "$val"; then
    continue
  fi
  deny "BLOCKED: write contains a non-placeholder secret assignment: '$line'. Use environment variables / .env (gitignored), not committed source."
done < <(grep -E "$name_re" <<<"$content" || true)

exit 0
