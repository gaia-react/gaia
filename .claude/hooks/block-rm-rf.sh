#!/usr/bin/env bash
# PreToolUse Bash hook: deny dangerous `rm -rf` invocations.
#
# Denied targets (case-insensitive on flags):
#   - any command using --no-preserve-root
#   - rm -rf / (root)
#   - rm -rf $HOME, ${HOME}, ~, ~/, $HOME/...
#   - rm -rf .   (cwd, incl. $PWD)
#   - rm -rf *   (unscoped glob)
#   - rm -rf .*  (dotfile glob, incl. the .[!.]* / ..?* / {.,}* spellings)
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
# and the list is NOT exhaustive, assume more exist. Each new literal shape this
# guard learns to catch reveals another it does not: treat the deny list as a
# floor, never a ceiling. Known holes are tracked as tech debt.
#
# One direction is deliberately NOT repaired, and it looks like a bug. The guard
# denies commands that merely *mention* a target in a quoted string, so
# `git commit -m "fix: rm -rf $HOME bypass"` is a false deny. Making a quoted
# `rm` not-a-command would fix that, and would also allow `bash -c "rm -rf /"`,
# `ssh host "rm -rf /"`, and `eval "rm -rf /"`. A text matcher cannot tell a
# quoted command from a quoted string; of the two failure directions the false
# deny is the safe one, so it stays. Deliver such text via `--body-file` / `-F`,
# or through a variable.
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

# Neutralize `;`, `&`, and `|` INSIDE quoted spans, rewriting each to a space.
#
# Both the short-circuit grep and the segment extraction below stop a segment at
# the first `;&|` byte, on the assumption that those bytes always terminate a
# command. Inside quotes they do not: they are ordinary characters in an operand.
# `rm -rf ";" $HOME` hands bash the argv [-rf] [;] [$HOME] and deletes home, while
# the unrepaired guard extracts only `rm -rf "`, never tokenizes `$HOME`, and
# allows it. This has to run before the short-circuit, not just before extraction:
# `rm ";" -rf $HOME` puts the quoted separator between `rm` and its flags, so the
# short-circuit misses too and the deny logic below never runs at all.
#
# A space is the right rewrite, not deletion and not a sentinel byte. The guard is
# already quote-blind at the token level (it strips quotes, then word-splits), so
# an extra token boundary inside a quoted string costs nothing, while any other
# filler would glue onto the token and break the anchored arms below: `rm -rf
# "$HOME;"` must still reach the $HOME arm, and with a space it does.
#
# Substituting rather than DELETING is load-bearing, and not only for the reason
# above. The gate below skips this walk entirely for a command whose raw text holds
# no `rm`, which is sound only because a substitution preserves every character's
# position and so can never *synthesize* an `rm` that the raw text lacked. Delete
# the separators instead and `r;m -rf /` would walk into `rm -rf /`, which the gate
# would already have skipped, turning that optimization into a live bypass. Do not
# "simplify" this to a deletion without also removing the `*rm*` test below.
#
# This only ever WIDENS what gets inspected, so it can add denials and never
# remove one.
#
# It deliberately does NOT skip an `rm` that is itself inside quotes, which looks
# like the matching fix for this guard's false denies on prose that merely mentions
# a command (`git commit -m "fix: stop rm -rf $HOME from bypassing the guard"` is
# denied today, and that is annoying). Do not "fix" it: the same change allows
# `bash -c "rm -rf /"`, `ssh host "rm -rf /"`, and `eval "rm -rf /"`, which are real
# shapes this guard catches today. A text matcher cannot tell a quoted command from
# a quoted string, and of the two failure directions the false deny is the safe one.
# Work around it by delivering the text via `--body-file` / `-F`, or via a variable.
#
# Escaped quotes inside a quoted span are not tracked. The guard is a heuristic
# matcher; mis-tracking there misplaces a space, which fails safe.
neutralize_quoted_separators() {
  local s=$1 out='' quote='' ch i len=${#1}
  for ((i = 0; i < len; i++)); do
    ch=${s:i:1}
    if [[ -n "$quote" ]]; then
      if [[ "$ch" == "$quote" ]]; then
        quote=''
      else
        case "$ch" in ';'|'&'|'|') ch=' ' ;; esac
      fi
    else
      case "$ch" in '"'|"'") quote=$ch ;; esac
    fi
    out+=$ch
  done
  printf '%s' "$out"
}

# Only pay for the character walk when it could change an outcome. This hook runs
# on EVERY Bash call, and the walk is O(n) bash over the command string, so a long
# inline `git commit -m "…" && git push` would otherwise pay for nothing.
#
# All three ingredients are required, and gating on `rm` is equivalence-preserving
# rather than a heuristic: the walk only ever rewrites `;`, `&`, and `|` to spaces,
# so it can neither synthesize the letters of `rm` nor remove them. A command with
# no `rm` substring therefore cannot pass the short-circuit grep below whether or
# not it was walked, which makes skipping the walk for such a command a no-op by
# construction, not a judgment call.
if [[ "$cmd" == *rm* && "$cmd" == *[\"\']* && "$cmd" == *[\;\&\|]* ]]; then
  cmd=$(neutralize_quoted_separators "$cmd")
fi

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

    # `$PWD` spells the cwd, so `$PWD/.git` IS `.git` and a bare `$PWD` IS `.`.
    # Rewrite the prefix and let the arms below judge whatever is left, rather
    # than growing a parallel set of $PWD arms that would drift from them. This
    # is why `$PWD/dist` stays on the dist whitelist while `$PWD/.git` reaches
    # the .git arm: denying every $PWD path would be the easy over-fix.
    case "$tok" in
      # `$PWD/` with nothing after it is still the cwd. It has to be caught here,
      # ahead of the prefix strips below, or the strip yields an empty token that
      # falls through to the catch-all and allows it.
      '$PWD'|'${PWD}'|'$PWD/'|'${PWD}/') tok='.' ;;
      '$PWD/'*) tok=${tok#'$PWD/'} ;;
      '${PWD}/'*) tok=${tok#'${PWD}/'} ;;
    esac
    [[ -n "$tok" ]] || continue

    # Normalize the way bash reads the path, so every arm below sees one spelling
    # of a target rather than an unbounded family of them. Bash collapses `//` to
    # `/`, and a `./` prefix is cosmetic and repeatable, so `.*`, `./.*`,
    # `././.*`, and `.//.*` are all the same cwd dotfile glob, and `.//.git` is
    # `.git`. Stripping a single `./` would close only the spelling people reach
    # for by accident and leave every evasion spelling of it open, which is the
    # half-fix the arms below exist to avoid.
    #
    # `./` alone is left intact (the strip requires something after the slash),
    # so the cwd arm still owns it rather than reducing it to an empty token.
    while [[ "$tok" == *//* ]]; do
      tok=${tok//\/\//\/}
    done
    while [[ "$tok" == ./?* ]]; do
      tok=${tok#./}
    done

    # Unscoped expansions in the FIRST path segment. These expand in the cwd, so
    # they sweep up `.git` and `.claude`.
    #
    # `rm -rf .*` is the one hole here that is plausibly an ACCIDENT rather than
    # evasion. It sits precisely between `rm -rf .` and `rm -rf *`, both denied,
    # and anyone reaching for `.*` is trying to clear dotfiles, which is exactly
    # when `.git` is the thing they least want to lose. `rm` refuses `.` and
    # `..`, so everything else goes: the repo history and the whole `.claude`
    # config. The `.[!.]*` and `..?*` idioms people reach for to skip `.` and
    # `..` still match `.git`, so they are the same hole, not a safer spelling.
    #
    # Only the first segment counts. A glob deeper in the path expands inside a
    # named directory, which is what makes the whitelisted `.gaia/local/plans/*`
    # an ordinary cleanup rather than this. The normalization above already
    # removed any `./` prefix, so the first segment is whatever precedes the
    # first slash.
    first_seg=${tok%%/*}
    if [[ "$first_seg" == .* && "$first_seg" == *[*?\[]* ]]; then
      deny "BLOCKED: rm -rf of a dotfile glob ('$tok') is forbidden, it removes .git and .claude."
    fi

    # `{.,}*` expands to `.* *`, the dotfile glob and the unscoped glob at once,
    # spelled so that neither arm below sees either one. A comma is what makes a
    # brace group an expansion list: `${HOME}` has none, so the parameter-
    # expansion arms below still own it. The `*` requirement keeps a scoped
    # `dist/{a,b}` allowed, and anchoring on the first segment keeps the brace
    # group that reaches the cwd distinct from one nested under a named dir.
    if [[ "$first_seg" == *'{'*','*'}'* && "$tok" == *'*'* ]]; then
      deny "BLOCKED: rm -rf of an unscoped brace glob ('$tok') is forbidden, it removes .git and .claude."
    fi

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
      #
      # The tilde arm is a prefix match, not the three literals `~`, `~/`, `~/…`,
      # because `~user` is a home directory too: `~root` names root's home and
      # matched none of the literal arms. A `~foo` that is not a real user stays
      # literal in bash and removes a directory named `~foo`, so denying it is a
      # false deny, which fails safe.
      '~'*|'$HOME'|'$HOME/'*|'\$HOME'|'\$HOME/'*|'${HOME}'|'${HOME}/'*|'\${HOME}'|'\${HOME}/'*)
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
