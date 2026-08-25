#!/usr/bin/env bash
# PreToolUse Bash hook: records this execution session's ground-truth token
# tally on the orchestrator's per-phase git commit/push, so a resumed or
# worktree session is captured deterministically instead of depending on a
# session-scoped prose instruction. Gated on an active plan folder (a
# RUNNING sentinel whose branch matches the current branch) and keyed to
# that plan's feature. This hook only performs a side effect: it emits no
# permission decision, and every path it takes deliberately exits 0. The one
# way it can still block is a library it cannot parse, which the load comment
# below bounds.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# The verb fragment mirrors the mandated `git -C <path> commit|push` form
# (.claude/rules/shell-cwd.md): an optional `-C <path>` group between `git`
# and the subcommand, where <path> may be quoted as long as it holds no
# spaces. Shared arming decision (.claude/hooks/lib/verb-arming.sh): its data
# proof means a heredoc body carrying this text no longer arms the tally on
# its own. Its tokenizer pass widens what arms beyond the text fragment: it
# reads the first command's actual words, so a quoted `-C` path containing
# spaces, which the fragment's space-free group misses, still arms. Broader
# arming here is the safe direction; this hook only records a tally row. A
# quoted verb inside prose still arms; fail-closed, no safe narrowing.
_va_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_va_lib:-}" ] && "${BASH:-bash}" -n "$_va_lib/verb-arming.sh" 2>/dev/null && . "$_va_lib/verb-arming.sh" 2>/dev/null || true
type gaia_verb_armed >/dev/null 2>&1 || exit 0

frag='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|push)([[:space:]]|$)'
words='git commit;git push;git -C * commit;git -C * push'
if gaia_verb_armed "$frag" "$words" "$cmd"; then
  :
else
  exit 0
fi

# Source the shared resolver first, from this hook's own checkout via
# BASH_SOURCE (never the process cwd): the cheap gate below needs
# gaia_resolve_main_root before resolve_active_plan_dir (which defers its own
# copy of this same source into its body) ever runs. Then the plan-folder lib,
# off the same $_va_lib the verb-arming load above resolved.
# Sourcing is side-effect-free and near-free; the expensive work
# (token-tally.sh's transcript parse) still runs only past the gate.
#
# Three library loads, two treatments, decided by which side of the arming gate
# each one sits on. Under `set -e` a failed `.` abandons the shell ahead of the
# ERR trap at the top, and the two ways it fails do not cost the same. Bash
# cannot open the file: the shell exits 1, which a PreToolUse hook reports as an
# advisory, so the git operation proceeds and what is lost is the tally row plus
# a raw diagnostic on stderr. That is the 3.2.57 stock macOS ships as /bin/bash;
# 5.x reaches a trailing `||` arm instead. Bash opens the file but cannot parse
# it, a lib left holding conflict markers: the shell exits 2, which is the deny
# code, so the git operation is refused, including the commit that would repair
# the lib. That half dies on 3.2 even through an arm.
#
# The two loads here run only on an armed git commit/push, so they parse-check
# first. `bash -n` answers both questions in one call and subsumes an existence
# test. A lib that parses and then fails at source time lands on the trailing
# `|| true` on bash 5, which continues past the load; on 3.2 that failure
# abandons the shell ahead of the arm and the ERR trap takes it, exiting 0
# without the tally row. Non-blocking on both. What degrades in the trap's
# place for a lib that never loaded is the `type` check below for the
# plan-folder lib, and for the resolver the `|| exit 0` the cheap gate's
# gaia_resolve_main_root call already carries.
#
# The verb-arming load above runs before the gate, on every Bash tool call, so
# whatever guards it is paid on every call. It parse-checks anyway. The figure
# that once argued against that here, ~13ms of fork, did not survive
# re-measurement: on this machine `bash -n` on the real verb-arming.sh costs
# ~3.1ms on bash 3.2.57 and ~5.7ms on 5.3.15, and as a whole extra hook process
# that is +2.5ms and +5.7ms against a ~16-21ms hook. A surcharge, not the
# doubling the old number implied, and cheap enough that the `|| true` arm this
# load used to carry is not worth its two costs: it closed the bash 5 half
# only, leaving an unparseable verb-arming.sh abandoning the shell on a stock
# 3.2, and it suppressed the syntax error that would name the broken file.
#
# The three errexit sibling hooks that load verb-arming.sh the same way carry
# the same check for the same measured reason (capture-gh-artifact.sh,
# post-findings-block-on-merge.sh, token-rollup-merge.sh).
#
# What the check does not reach, and the bound therefore covers one file rather
# than two: verb-arming.sh lazily sources verb-arming-walk.sh on a raw match,
# inside _gaia_va_view, behind an `-f` test but no parse check and no arm, and
# `bash -n` does not recurse into a sourced file. So an unparseable walk lib
# still denies on 3.2. That load lives inside verb-arming.sh, so no consumer
# hook can guard it from out here; it is gaia-react/gaia#1556.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
"${BASH:-bash}" -n "$gaia_scripts/main-root-lib.sh" 2>/dev/null && . "$gaia_scripts/main-root-lib.sh" 2>/dev/null || true
# shellcheck source=/dev/null
"${BASH:-bash}" -n "${_va_lib:-}/gaia-active-plan.sh" 2>/dev/null && . "${_va_lib:-}/gaia-active-plan.sh" 2>/dev/null || true
type resolve_active_plan_dir >/dev/null 2>&1 || exit 0

# Cheap negative gate: no live plan RUNNING sentinel at all, skip before paying
# for token-tally.sh's transcript parse. Anchored to the MAIN checkout: a plan
# executed in a linked worktree keeps its RUNNING sentinel (and all of
# .gaia/local/specs | plans) only in the main checkout -- the state registry
# declares those main-only, not shared -- so a cwd-relative glob from the
# worktree would find nothing and silently lose the execute row.
main_root="$(gaia_resolve_main_root 2>/dev/null)" || exit 0
has_plan=0
for rf in "$main_root"/.gaia/local/plans/*/RUNNING "$main_root"/.gaia/local/specs/*/plan/RUNNING "$main_root"/.gaia/local/specs/*/plan-*/RUNNING; do
  [ -f "$rf" ] || continue
  has_plan=1
  break
done
[ "$has_plan" -eq 1 ] || exit 0

plan_dir="$(resolve_active_plan_dir)"
[ -n "$plan_dir" ] || exit 0

feature_key="$(resolve_feature_key "$plan_dir")"
slug="$(basename "$plan_dir")"
sid=$(jq -r '.session_id // ""' <<<"$payload")

# Route the feature key to the flag matching its shape. An unclassifiable key
# (neither SPEC- nor PLAN-, e.g. a bare `plan`/`plan-2` basename from a failed
# `## Source SPEC` parse) gets no id flag at all, so token-tally marks the row
# partial instead of binding a mistyped value into plan_id.
case "$feature_key" in
  SPEC-*) id_flag=(--spec-id "$feature_key") ;;
  PLAN-*) id_flag=(--plan-id "$feature_key") ;;
  *)      id_flag=() ;;
esac

# GAIA_TALLY_PROJECTS_ROOT is a documented test seam: unset in production
# (token-tally.sh falls back to its $HOME/.claude/projects default), set by
# bats to point at a fixture so no test run ever touches a real session's
# transcript search path.
#
# id_flag is empty for an unclassifiable key (the case `*)` branch above). The
# offset-guard `${id_flag[@]+"${id_flag[@]}"}` keeps that empty expansion from
# firing bare: on stock macOS /bin/bash 3.2 a bare "${id_flag[@]}" over an empty
# array aborts with `unbound variable` under `set -u` (before the trailing
# `|| true`, so the tally is silently dropped); bash 4.4+ tolerates it.
bash "$gaia_scripts/token-tally.sh" \
  --action execute ${id_flag[@]+"${id_flag[@]}"} --plan-slug "$slug" \
  --out-dir "$plan_dir" --session-id "$sid" \
  ${GAIA_TALLY_PROJECTS_ROOT:+--projects-root "$GAIA_TALLY_PROJECTS_ROOT"} >/dev/null 2>&1 || true

exit 0
