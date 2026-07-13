#!/usr/bin/env bash
# PreToolUse Bash hook: deny dangerous `rm -rf` invocations.
#
# Denied targets (case-insensitive on flags):
#   - any command using --no-preserve-root
#   - rm -rf / (root)
#   - rm -rf $HOME, ~, ~/, $HOME/...
#   - rm -rf .   (cwd)
#   - rm -rf *   (unscoped glob)
#   - rm -rf .git
#   - rm -rf node_modules (anywhere, must use pnpm clean / explicit path)
#
# Allowed (whitelist of safe scratch paths):
#   - .gaia/local/plans/*
#   - .gaia/local/specs/*
#   - .gaia/local/audit/*
#   - .gaia/local/handoff/*
#   - .gaia/local/cache/*
#   - dist/*
#   - build/*
#
# Anything that does not match a denied pattern AND is not on the whitelist
# falls through (exit 0), this hook intentionally only blocks the well-known
# footguns; broader policy lives in settings.json permissions.
set -euo pipefail

payload=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")

[[ -n "$cmd" ]] || exit 0

# Short-circuit: only act on commands containing `rm` with `-rf`/`-fr`/`-r -f`/etc.
# `--no-preserve-root` is in the alternation because it can be written *before*
# the recursive flag (`rm --no-preserve-root -rf /`). Without it the short-circuit
# exits here and the unconditional --no-preserve-root deny below is never reached.
if ! grep -Eq '(^|[^[:alnum:]_-])rm[[:space:]]+(-[a-zA-Z]*[rRfF]|-[rRfF][a-zA-Z]*|--recursive|--force|--no-preserve-root)' <<<"$cmd"; then
  exit 0
fi

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

# 1. --no-preserve-root is always denied.
if grep -Eq -- '--no-preserve-root' <<<"$cmd"; then
  deny "BLOCKED: rm with --no-preserve-root is forbidden."
fi

# 2. Catastrophic targets.
#    Match an rm token followed (after flags) by one of: /, ~, ~/, \$HOME, ., *, .git, node_modules
#    We scan every whitespace-separated token after `rm`.
# Extract the rm-segment: from `rm` to next `;`/`&&`/`||`/`|`/end-of-line.
rm_segment=$(grep -oE '(^|[^[:alnum:]_-])rm[[:space:]]+[^;&|]*' <<<"$cmd" | head -n 1 || true)
[[ -n "$rm_segment" ]] || exit 0

# Tokenize and inspect non-flag args.
read -r -a tokens <<<"$rm_segment"
# tokens is provably non-empty here (rm_segment is guarded non-empty above and
# always carries the `rm` token), but guard the expansion anyway so the
# array-guard lint stays a zero-exception gate: on bash 3.2 a bare "${tokens[@]}"
# over an empty array aborts under `set -u`.
for tok in ${tokens[@]+"${tokens[@]}"}; do
  # Skip the literal `rm` word and flag tokens.
  [[ "$tok" == "rm" || "$tok" == rm ]] && continue
  [[ "$tok" == -* ]] && continue

  # Drop every quote character before matching. `read -r -a` word-splits but
  # does not remove quotes, so the token for `rm -rf "$HOME"` is the literal
  # 7-character "$HOME" (quotes included) and matches none of the patterns
  # below. Quoting the expansion is the *careful* way to write the command, so
  # a quote-blind guard misses precisely the well-written form and catches only
  # the sloppy one. Removing all quotes rather than just a surrounding pair also
  # covers `rm -rf "$HOME"/projects`, where the quotes sit mid-token. A path
  # whose real name contains a quote character is not a case worth protecting
  # here: the cost is a false deny, which fails safe.
  tok=${tok//\"/}
  tok=${tok//\'/}
  [[ -n "$tok" ]] || continue

  # SC2088 (tilde does not expand in quotes) is disabled for this whole case: the
  # `~` / `$HOME` patterns below are literal match targets, not paths to expand.
  # They are tested against the raw command string, where the user's unexpanded
  # token is exactly what must be caught; expanding here would break the guard.
  # The directive has to sit in front of the `case` itself, not the branch (SC1124).
  # shellcheck disable=SC2088
  case "$tok" in
    /|/*)
      # Allow specific safe absolute prefixes, currently none whitelisted absolutely.
      deny "BLOCKED: rm -rf of absolute path '$tok' is forbidden."
      ;;
    '~'|'~/'|'~/'*|'$HOME'|'$HOME/'*|'\$HOME'|'\$HOME/'*)
      deny "BLOCKED: rm -rf of \$HOME / ~ is forbidden."
      ;;
    '.'|'./')
      deny "BLOCKED: rm -rf of cwd ('.') is forbidden."
      ;;
    '*'|'./*')
      deny "BLOCKED: rm -rf of unscoped glob ('*') is forbidden."
      ;;
    .git|./.git|.git/*|./.git/*)
      deny "BLOCKED: rm -rf of .git is forbidden."
      ;;
    node_modules|./node_modules|*/node_modules|node_modules/*)
      deny "BLOCKED: rm -rf of node_modules is forbidden, use 'pnpm store prune' or remove deliberately."
      ;;
    .gaia/local/plans/*|./.gaia/local/plans/*)
      : # whitelisted
      ;;
    .gaia/local/specs/*|./.gaia/local/specs/*)
      : # whitelisted (colocated plan scratch under specs/<SPEC-ID>/plan)
      ;;
    .gaia/local/audit/*|./.gaia/local/audit/*)
      : # whitelisted
      ;;
    .gaia/local/handoff/*|./.gaia/local/handoff/*)
      : # whitelisted
      ;;
    .gaia/local/cache/*|./.gaia/local/cache/*)
      : # whitelisted
      ;;
    dist|dist/*|./dist|./dist/*)
      : # whitelisted
      ;;
    build|build/*|./build|./build/*)
      : # whitelisted
      ;;
    *)
      : # unknown relative path, let it through; permissions / other hooks may still gate it.
      ;;
  esac
done

exit 0
