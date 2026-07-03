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
#   - .gaia/cache/*
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
if ! grep -Eq '(^|[^[:alnum:]_-])rm[[:space:]]+(-[a-zA-Z]*[rRfF]|-[rRfF][a-zA-Z]*|--recursive|--force)' <<<"$cmd"; then
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
for tok in "${tokens[@]}"; do
  # Skip the literal `rm` word and flag tokens.
  [[ "$tok" == "rm" || "$tok" == rm ]] && continue
  [[ "$tok" == -* ]] && continue

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
    .gaia/cache/*|./.gaia/cache/*)
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
