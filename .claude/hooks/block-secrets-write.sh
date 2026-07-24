#!/usr/bin/env bash
# PreToolUse Edit/Write hook: deny writes that contain obvious secrets.
#
# Patterns:
#   - AWS access key prefix:   AKIA[0-9A-Z]{16}
#   - GitHub PATs:             ghp_, gho_, ghu_, ghs_, ghr_  (followed by token chars)
#   - Private key headers:     -----BEGIN [A-Z ]*PRIVATE KEY-----
#   - dotenv-style assignment to suspicious names, with or without a leading
#     export / declare / local / readonly:
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
  # Extract the value portion after `=`, strip surrounding quotes & whitespace.
  val=$(sed -E 's/^[^=]*=//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' <<<"$line")
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
  # so these four whole-value shapes are allowed alongside it: a positional
  # (`${1}`), an expansion whose operand is EMPTY (`${VAR:-}`, `${VAR:?}`), and
  # an expansion followed by a path (`${ROOT}/dev.pem`).
  #
  # Each is anchored end to end, and the operand arm requires the operand to be
  # empty rather than merely short: a default value is exactly where a real
  # secret lands, and no shape test tells `${K:-550e8400-e29b-41d4-a716-…}`
  # from a legitimate one, because a segmented secret has the same structure a
  # placeholder does. The path arm requires the literal to open with `/` or `.`
  # for the same reason: it admits a path suffix without admitting arbitrary
  # trailing text, which is how a secret would ride along.
  #
  # These deliberately do NOT match a value containing `$(…)`. A reference
  # inside a substitution body would otherwise re-open the splice bypass the
  # `$(…)` arm above exists to close, since `$(echo ${X})<secret>` contains a
  # reference like any other.
  if grep -Eq '^\$\{[0-9]+\}$|^\$\{[A-Za-z_][A-Za-z0-9_]*:?[-+?=]\}$|^\$\{[A-Za-z_][A-Za-z0-9_]*\}[/.][A-Za-z0-9._/-]*$' <<<"$val"; then
    continue
  fi
  deny "BLOCKED: write contains a non-placeholder secret assignment: '$line'. Use environment variables / .env (gitignored), not committed source."
done < <(grep -E '^[[:space:]]*((export|declare|local|readonly)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(_TOKEN|_SECRET|_KEY|_PASSWORD)[[:space:]]*=' <<<"$content" || true)

exit 0
