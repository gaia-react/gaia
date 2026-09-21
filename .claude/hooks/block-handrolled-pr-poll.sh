#!/usr/bin/env bash
#
# PreToolUse hook: deny a hand-rolled pull-request merge wait, a shell loop
# polling `gh pr view` / `gh pr checks` that never reads `mergeable`. Point the
# caller at `.gaia/scripts/pr-wait-merge.sh`, which is the same wait with the
# exits the hand-rolled shape drops.
#
# Exit 2 = block the tool call; stderr is shown to Claude as the reason.
#
# WHAT GOES WRONG WITHOUT IT. A wait that exits only on `MERGED` cannot end
# when the merge has become impossible. `origin/main` lands a conflicting
# change, `mergeable` turns `CONFLICTING` within minutes, the queued `--auto`
# merge never lands, and the loop has no exit condition left that can ever
# fire: it spins until a human notices. That is gaia-react/gaia#2209, observed
# on PR gaia-react/gaia#2203, where the substituted loop was
# `until [ "$(gh pr view 2203 --json state --jq .state)" != "OPEN" ]`.
#
# WHY A HOOK AND NOT PROSE, given the prose is already correct. It was already
# correct on gaia-react/gaia#2203. Issue gaia-react/gaia#2144 fixed the TEXT of every poll in the workflow,
# and the recurrence happened anyway, because the documented compound form is
# refused by the worktree-isolation guard and the caller was one keystroke from
# improvising past it. Prose cannot hold a boundary an agent has a standing
# reason to cross under pressure; this is the same lesson
# `block-fourth-audit-round.sh` and `block-spec-plan-chain.sh` were written
# for.
#
# WHY THE DENIAL NAMES A SCRIPT. `.gaia/scripts/pr-wait-merge.sh` ships in the
# same change as this hook, and the order matters: a denial with no blessed
# alternative is what produces the next improvisation. A single
# `bash .gaia/scripts/pr-wait-merge.sh --pr <N>` is also plain enough for the
# worktree-isolation guard to read, so taking the blessed path removes the
# refusal that caused the improvisation in the first place.
#
# WHAT IT CATCHES, honestly: the common spelling, not the class. This is a text
# heuristic over an unbounded surface, the same posture
# `block-selfheal-paths.sh` already takes. A poll written in Python, or inside
# a script file this hook never sees, walks past it untouched. The
# justification for a heuristic anyway is that this failure is silent and costs
# a full wait plus a spent CI round, which is the argument gaia-react/gaia#2144 already made
# and which the recurrence confirms.
#
# THE DELIBERATE ESCAPES, both cheap, because over-denying a legitimate wait is
# worse than missing an improvised one:
#   - A command that already reads `mergeable` or `CONFLICTING` is allowed
#     however it is spelled. That IS the property being asked for, and a caller
#     who wrote it by hand has satisfied the rule rather than evaded it.
#   - A command naming `pr-wait-merge.sh` is allowed. That covers the blessed
#     path, the script's own bats suite, and any command that quotes the shape
#     in a heredoc while writing about it. It is trivially forgeable by a
#     comment, and that is accepted: this guard exists to stop an improvisation
#     under pressure, not a determined bypass.
#
# FAIL-OPEN POSTURE. An unreadable payload resolves the command to the empty
# string, which matches nothing and allows the call. A missing jq is the
# opposite condition and refuses loudly, narrowed by the `gh pr` literal so the
# command that installs jq is never caught by it.

payload=$(cat)

# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literals below satisfy, live in .claude/hooks/lib/jq-availability.sh.
# The `gh pr` literal cannot reach a poll spelled through an alias or a
# variable holding the binary name; those fall outside this hook with jq
# present too, so the arm loses nothing the predicate itself has.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-handrolled-pr-poll.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the hand-rolled merge-wait guard' "$payload" tool_input 'gh pr'

tool=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

# --- escape 1: the blessed path, and anything writing about it ----------------
BLESSED_RE='pr-wait-merge\.sh'
[[ "$command" =~ $BLESSED_RE ]] && exit 0

# --- escape 2: the command already reads the property this guard asks for -----
# Unanchored and case-sensitive: `mergeable` is the gh field spelling and
# `CONFLICTING` the value spelling, and both are what a correct wait carries.
HAS_MERGEABLE_RE='mergeable|CONFLICTING'
[[ "$command" =~ $HAS_MERGEABLE_RE ]] && exit 0

# --- is this a loop at all? ---------------------------------------------------
# Two independent signals, both required, because either alone has a false
# positive this hook must not have.
#
# The keyword has to sit at a command position: the start of the command, or
# just after a separator or a NEWLINE. The newline is not decoration -- a
# multi-line Bash command is the ordinary shape for a poll, and a class built
# from `^` and the separator punctuation alone misses every one of them, which
# is the whole failure mode wearing different whitespace.
#
# `done` has to be present as its own word. Every `for`/`while`/`until` loop
# closes with one, and no prose mentioning a loop inside a `--body` or a commit
# message carries it, so this is what keeps the keyword test off text that
# merely talks about polling.
LOOP_KEYWORD_RE=$'(^|[;&|(\n])[[:space:]]*(until|while|for)[[:space:]]'
[[ "$command" =~ $LOOP_KEYWORD_RE ]] || exit 0
DONE_RE='(^|[[:space:];&])done([[:space:]]|;|$)'
[[ "$command" =~ $DONE_RE ]] || exit 0

# --- does the loop read pull-request state? -----------------------------------
# `gh pr checks` is included because the workflow's own rule covers it: "any
# wait on CI or on a GAIA-Audit status between audit rounds" can go dead the
# same way, and `wiki/concepts/PR Merge Workflow.md`'s "Conflict found
# mid-wait" says every wait in this workflow exits on CONFLICTING for that
# reason. A CI wait is a merge wait wearing a different hat.
#
# `gh pr view` is narrowed to a call that actually reads STATE, either as a
# `--json` field or through a `.state` filter expression. A loop over
# `gh pr view <N> --json title` is enumerating pull requests, not waiting on
# one, and denying it would be noise.
CHECKS_RE='gh[[:space:]]+pr[[:space:]]+checks'
VIEW_STATE_RE='gh[[:space:]]+pr[[:space:]]+view[^|;&]*(--json[^|;&]*state|\.state)'
if [[ "$command" =~ $CHECKS_RE ]] || [[ "$command" =~ $VIEW_STATE_RE ]]; then
  cat >&2 <<'EOF'
BLOCKED: this looks like a hand-rolled pull-request merge wait that never reads `mergeable`.

A loop that exits only on `MERGED` cannot end once the merge has become impossible. When `origin/main` lands a conflicting change, `mergeable` turns `CONFLICTING`, the queued `--auto` merge never lands, and the loop has no exit condition left that can fire. It spins until a human notices, and the in-flight required checks are spent either way.

Use the shipped wait, which exits on all four terminal states:

    bash .gaia/scripts/pr-wait-merge.sh --pr <N>

It prints one verdict token and exits 0 MERGED / 3 CONFLICTING / 4 CHECK_FAILED / 5 TIMEOUT. Pass `--attempts` for a longer bound (releases and full CI runs use 20) and `--interval` to change the 30-second spacing. On CONFLICTING, repair per `wiki/concepts/PR Merge Workflow.md`, "### Conflict found mid-wait", then run it again.

If you genuinely need your own loop, read `mergeable` in it and this guard stands down.
EOF
  exit 2
fi

exit 0
