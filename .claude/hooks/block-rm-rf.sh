#!/usr/bin/env bash
# PreToolUse Bash hook: deny dangerous `rm -rf` invocations.
#
# Denied targets (case-insensitive on flags):
#   - any command using --no-preserve-root
#   - rm -rf / (root)
#   - rm -rf $HOME, ${HOME}, ~, ~/, $HOME/...
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
#
# SCOPE, read before trusting this guard. It matches the *literal text* of each
# target token. A target the shell computes rather than spells cannot be seen
# here and is out of reach by design: command substitution (`rm -rf "$(git
# rev-parse --show-toplevel)"`), an arbitrary variable holding a dangerous path,
# a relative escape (`rm -rf ../..`), and targets arriving through `xargs` all
# pass. This is heuristic defense-in-depth behind settings.json permissions, not
# a sandbox, and it is the second layer rather than the first.
set -euo pipefail

payload=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")

[[ -n "$cmd" ]] || exit 0

# Short-circuit: only act on commands containing `rm` with `-rf`/`-fr`/`-r -f`/etc.
#
# The flag is matched anywhere in the rm segment, not just immediately after
# `rm`. GNU getopt permutes argv, so `rm $HOME -rf` is exactly `rm -rf $HOME`
# and deletes home on Linux (CI, devcontainers, Linux adopters); BSD/macOS `rm`
# does not permute, which is why an operand-first invocation looks harmless when
# hand-tested on a Mac. Requiring adjacency let both that shape and a leading
# `--no-preserve-root` exit here, before the deny logic below ever ran.
#
# A looser short-circuit costs only wasted work, never a false deny: it decides
# what to *inspect*, and the case arms below decide what to block.
if ! grep -Eq '(^|[^[:alnum:]_-])rm[[:space:]]+[^;&|]*(-[a-zA-Z]*[rRfF]|--recursive|--force|--no-preserve-root)' <<<"$cmd"; then
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
# Extract the rm-segments: each runs from an `rm` to the next `;`/`&&`/`||`/`|`
# or end-of-line. EVERY segment is inspected, not just the first: a chained
# command whose leading `rm` is benign is an ordinary cleanup shape
# (`rm -rf node_modules && rm -rf dist`), so stopping at the first match let a
# dangerous target ride along behind a harmless one.
rm_segments=$(grep -oE '(^|[^[:alnum:]_-])rm[[:space:]]+[^;&|]*' <<<"$cmd" || true)
[[ -n "$rm_segments" ]] || exit 0

# A here-string keeps the loop in the current shell, so deny()'s exit is the
# hook's exit rather than a subshell's.
while IFS= read -r rm_segment; do
  [[ -n "$rm_segment" ]] || continue

  # Tokenize and inspect non-flag args.
  read -r -a tokens <<<"$rm_segment"
  # tokens is provably non-empty here (rm_segment is guarded non-empty above and
  # always carries the `rm` token), but guard the expansion anyway so the
  # array-guard lint stays a zero-exception gate: on bash 3.2 a bare "${tokens[@]}"
  # over an empty array aborts under `set -u`.
  for tok in ${tokens[@]+"${tokens[@]}"}; do
    # Skip the literal `rm` word and flag tokens.
    [[ "$tok" == "rm" ]] && continue
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
      # The brace form is matched alongside the bare one. `${HOME}` is if anything
      # the more careful spelling of the expansion, and leaving it out reproduced
      # the exact bug the quote-strip above fixes: the guard catching only the
      # casual spelling of the target and missing the deliberate one. Neighbours
      # like ${HOMEBREW_PREFIX} do not match, the arms are anchored, not prefixes.
      '~'|'~/'|'~/'*|'$HOME'|'$HOME/'*|'\$HOME'|'\$HOME/'*|'${HOME}'|'${HOME}/'*|'\${HOME}'|'\${HOME}/'*)
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
done <<<"$rm_segments"

exit 0
