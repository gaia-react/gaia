#!/usr/bin/env bash
# PreToolUse Edit/Write hook: deny writes that contain obvious secrets.
#
# Patterns:
#   - AWS access key prefix:   AKIA[0-9A-Z]{16}
#   - GitHub PATs:             ghp_, gho_, ghu_, ghs_, ghr_  (followed by token chars)
#   - Private key headers:     -----BEGIN [A-Z ]*PRIVATE KEY-----
#   - dotenv-style assignment to suspicious names, with or without a leading
#     export / declare / local / readonly and that keyword's own options:
#       (_TOKEN|_SECRET|_KEY|_PASSWORD)=<non-placeholder-value>
#       Placeholders allowed: empty, "", '', x, xxx, changeme, REPLACE_ME,
#       TODO, PLACEHOLDER, ${...}, $VAR, and three whole-value shapes:
#       $(...) unnested, <...> with no inner `>`, and a short your-* /
#       example* placeholder (case-insensitive).
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
while IFS= read -r line; do
  # Extract the value portion after `=`, drop a trailing shell comment or
  # operator clause, then strip surrounding quotes & whitespace. A shell line
  # carries a tail a dotenv line never does, and without dropping it the whole
  # remainder of the line becomes the value: no arm can match, so an ordinary
  # secret-free `export FOO_KEY="$BAR" # note` is hard-blocked and the deny
  # tells its author to use the environment variable the line already uses.
  # The comment separator has to be preceded by whitespace so a `#` inside the
  # value itself is not read as one.
  val=$(sed -E 's/^[^=]*=//; s/[[:space:]]+#.*$//; s/[[:space:]]+([|][|]|&&|;).*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' <<<"$line")
  # Empty / placeholder values are fine.
  [[ -z "$val" ]] && continue
  case "$val" in
    x|xx|xxx|xxxx|changeme|CHANGEME|REPLACE_ME|TODO|PLACEHOLDER|placeholder)
      continue ;;
  esac
  # Allow values whose source line carries no literal secret. Every arm below is
  # a shape heuristic, not a proof, and each has to mean "the value is WHOLLY
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
  # alphanumeric run. So the placeholder arms below bound each SEGMENT rather
  # than the whole value, which keeps `your-github-personal-access-token` (long,
  # segmented) and rejects `your-aB3xK9pQ7zR2wL5t` (short, unbroken). A length
  # cap gets both of those backwards.
  #
  # None of these read meaning. `$(mint_key)` and `$(echo <a-literal-secret>)`
  # are the same shape, so the arm admits both; separating them needs reading
  # the command, and this allowlist does not claim to.
  if grep -Eqi \
    '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$|^\$[A-Za-z_][A-Za-z0-9_]*$|^\$\([^)]+\)$|^<[^>]+>$|^(your|fake|dummy)[-_][A-Za-z0-9]{1,12}([-_.][A-Za-z0-9]{1,12})*$|^example([-_.][A-Za-z0-9]{1,12})*$' \
    <<<"$val"; then
    continue
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
  if grep -Eq '^\$[0-9]$|^\$\{[0-9]+\}$|^\$\{[A-Za-z_][A-Za-z0-9_]*:?[-+?=]\}$|^(\$\{[A-Za-z_][A-Za-z0-9_]*\})+$|^\$\{[A-Za-z_][A-Za-z0-9_]*\}([/.][A-Za-z0-9_-]{1,12})+$' <<<"$val"; then
    continue
  fi
  deny "BLOCKED: write contains a non-placeholder secret assignment: '$line'. Use environment variables / .env (gitignored), not committed source."

# The declaration keyword carries its own options, so the group has to accept
# them too. `declare -r` and `local -r` are the idiomatic spellings in careful
# bash, and a group that only accepts the bare keyword takes exactly those lines
# back out of the scan, which is the failure recognizing the keywords exists to
# close.
done < <(grep -E '^[[:space:]]*((export|declare|local|readonly)[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*(_TOKEN|_SECRET|_KEY|_PASSWORD)[[:space:]]*=' <<<"$content" || true)

exit 0
