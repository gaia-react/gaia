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
#       TODO, PLACEHOLDER, ${...}, $VAR, and three whole-value shapes: $(...)
#       (unnested), <...>, and a your-* / fake-* / dummy-* / example*
#       placeholder (case-insensitive).
#     A shell declaration additionally allows the ordinary expansion forms as
#     whole values: a positional ($1, ${1}), an EMPTY operand (${VAR:-}), a
#     value that is nothing but braced references (${A}${B}), and ${VAR}
#     followed by a segment-bounded path. A trailing comment or ; && || clause
#     comes off before the value is read, and it is read rather than
#     discarded: a tail carrying an assignment is judged by the same
#     allowlist, and any other tail by shape, a 13+ alphanumeric run mixing
#     letters and digits. That shape bound is the honest limit, an all-letter
#     or under-13 secret parked in a comment clears it.
set -euo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. This matcher cannot reach the jq
# install itself, so the refusal is unconditional within it and the call below
# passes no binding literal; the contract lives in
# .claude/hooks/lib/jq-availability.sh.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-secrets-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the secret-content write guard' "$payload" tool_input

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
# this shape" rather than "the value starts or ends like it".
#
# `$(mint_key)` and `$(echo <a-literal-secret>)` are the same shape, so the
# substitution arm admits both; separating them needs reading the command, and
# this allowlist does not claim to.
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
    '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$|^\$[A-Za-z_][A-Za-z0-9_]*$|^\$\([^)]+\)$|^<.+>$|^(your|fake|dummy)[-_]|^example' \
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
# below: a committed file whose purpose is placeholders, so the allowlist
# elsewhere would refuse its own real content. `block-env-read.sh` and
# `block-env-write.sh` exempt it by the same basename, on the same matcher.
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
# The match is this exact basename, so `.env`, `.env.local`, and
# `.env.example.local` reach the full allowlist below as before. `basename --`
# because a path may begin with a dash, matching `block-env-read.sh`.
if [ "$(basename -- "${file_path:-}")" = ".env.example" ]; then
  while IFS= read -r line; do
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
      # An EXECUTABLE tail carrying an assignment is judged by the assignment
      # rule, not by shape: split on the separators and run the same name
      # grammar and the same allowlist over each fragment. Shape alone lets a
      # parked key through whenever it is under 13 characters or all letters,
      # and the feeder grep is line-anchored, so it never re-reads a fragment.
      #
      # The grammar is tested per FRAGMENT, never against the whole tail: it is
      # anchored at `^`, and the tail still opens with its own separator, so a
      # whole-tail test can never match and would silently downgrade every one
      # of these to the shape rule.
      #
      # The operators collapse to `;` first so the split needs only `tr`, which
      # keeps this portable to BSD `sed` (no `\n` in a replacement). The loop is
      # fed by process substitution rather than a pipe so it runs in this shell
      # and its flag survives.
      while IFS= read -r frag; do
        [ -n "$frag" ] || continue
        grep -Eq "$name_re" <<<"$frag" || continue
        tail_has_assignment=1
        if ! value_allowed "$(trim_value "$(sed -E 's/^[^=]*=//' <<<"$frag")")"; then
          deny "BLOCKED: write parks a secret assignment after a shell separator: '$line'. Use environment variables / .env (gitignored), not committed source."
        fi
      done < <(sed -E 's/[|][|]/;/g; s/&&/;/g' <<<"$tail" | tr ';' '\n')
    fi
    # A comment tail, or an executable tail carrying no assignment at all, has
    # no structure to reuse, so it falls back to the shape rule.
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
