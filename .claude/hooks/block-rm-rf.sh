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
# SCOPE, read before trusting this guard. It text-matches target tokens, so it
# is porous by construction. Do not read the deny list above as a guarantee.
#
# A target the shell *computes* rather than spells is out of reach by design:
# command substitution (`rm -rf "$(git rev-parse --show-toplevel)"`), an
# arbitrary variable holding a dangerous path, a relative escape
# (`rm -rf ../..`), and targets arriving via `xargs` all pass.
#
# Some *literally spelled* targets also pass. These are known holes, not design,
# and the list is NOT exhaustive, assume more exist:
#   - `rm -rf .*` removes .git and .claude; the glob arm matches `*`, not `.*`.
#   - a quoted `;`, `&`, or `|` in an operand truncates segment extraction, so
#     every operand after it is never tokenized (`rm -rf ";" $HOME`).
#   - `$PWD/.git`, `~root`, `{.,}*` and friends match no arm.
# Each new literal shape this guard learns to catch reveals another it does not.
# Treat the deny list as a floor, never a ceiling. Known holes are tracked as
# tech debt.
#
# `jq` is a hard dependency: without it the hook exits non-zero, which Claude
# Code treats as a non-blocking error, so the command proceeds unguarded
# (loudly, on stderr, never bricking the session).
#
# This is heuristic defense-in-depth behind settings.json permissions, not a
# sandbox. It is the second layer, never the first.
set -euo pipefail

payload=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")

[[ -n "$cmd" ]] || exit 0

# Splice backslash-newline continuations before anything else looks at $cmd.
# Both greps below are line-oriented, so a target on a continuation line carries
# no `rm` token of its own, no segment is ever extracted for it, and it becomes
# invisible to the guard, while the byte-identical one-line command is denied.
# A multi-line `rm -rf \` is idiomatic, not contrived, and the target is a plain
# literal token, exactly what this guard claims to match.
#
# Join with NOTHING, not a space: bash removes the backslash-newline entirely,
# so a continuation splitting a token mid-word (`$HOM\` + newline + `E`)
# reassembles into that one token. A space-join would instead cut it into two
# fragments that match no pattern, which is the bypass rather than the fix. The
# space that already precedes a normal continuation's backslash is what keeps
# the token boundary in the idiomatic case, so nothing is lost here.
cmd=${cmd//\\$'\n'/}

# Short-circuit: only act on commands containing `rm` with `-rf`/`-fr`/`-r -f`/etc.
#
# The flag is matched anywhere in the rm segment, not just immediately after
# `rm`. GNU getopt permutes argv, so `rm $HOME -rf` is exactly `rm -rf $HOME`
# and deletes home on Linux (CI, devcontainers, Linux adopters); BSD/macOS `rm`
# does not permute, which is why an operand-first invocation looks harmless when
# hand-tested on a Mac. Requiring adjacency let both that shape and a leading
# `--no-preserve-root` exit here, before the deny logic below ever ran.
#
# A looser short-circuit is fail-safe, not free. It can only ADD denials, never
# turn a previously-denied command into an allow, because it decides what to
# *inspect* and the case arms below decide what to block. It does widen the
# false-deny surface: `git rm --cached -r .` now denies (the canonical
# `git rm -r --cached .` already did), which is annoying but safe. Widen this
# regex only with that asymmetry in mind.
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
    # Backslash goes for the same reason, and it is the same defect: bash strips
    # a backslash before an ordinary character, so `\/` reassembles into `/` and
    # hands root to rm while matching no pattern here. Stripping quotes but not
    # escapes would be half a fix.
    tok=${tok//\\/}
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
      # The backslash-escaped arms (\$HOME, \${HOME}) are unreachable now that the
      # strip above removes backslashes before matching. They stay as belt-and-braces.
      # Do not read them as proof the strip is redundant and delete the strip: the
      # strip is what catches \/ and \.git, which have no arms of their own.
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
