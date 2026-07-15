#!/bin/bash
# PreToolUse Bash hook: DENY `gh pr merge` when the disposition-ledger sidecar
# for the current HEAD claims a disposition that does not hold. This is the
# DETERMINISTIC backstop for the audit's forced-disposition guarantee: the
# code-audit-frontend agent's own verify-after-file re-query is the primary
# enforcer, but that is agent behavior, not code. This hook re-reads the
# disposition-ledger sidecar (.gaia/local/audit/<sha>.dispositions.json) and
# fails the merge by
# CODE when a marker's claimed dispositions do not check out.
#
# It sits ALONGSIDE pr-merge-audit-check.sh (the marker-existence gate) and
# worthiness-presence-check.sh: all three gate `gh pr merge` and deny
# independently. This hook never relaxes the marker-existence gate; it adds an
# orthogonal check.
#
# DENY conditions (the only two):
#   1. A `filed` sidecar entry whose dedup key has NO matching `tech-debt` issue
#      (open OR closed) on a REACHABLE backend (the marker claims a filing that
#      does not exist). A CLOSED match means the disposition was filed and later
#      fixed/closed by /gaia-debt (a fully honored disposition) -> satisfied,
#      so it is NOT an offender.
#   2. A `pending` entry with pending_reason "definitive" (a present, writable
#      backend with a genuinely-missing disposition; a marker should not exist,
#      but defend against a hand-written one).
#
# FAIL-OPEN everywhere else (SPEC never-block invariant): no sidecar, backend
# "absent", every `filed` entry confirmed present, all entries
# diverted/waived/pending(transient), or ANY gh/tooling failure (no gh,
# unauthenticated, timeout, rate-limit, 5xx, unresolved repo). The backstop
# blocks ONLY on a confirmed present-backend inconsistency or a
# pending(definitive) entry.
#
# Key relationship: the sidecar `key` is the dedup-key INNER content
# `v1 class=… path=… line=…` WITHOUT the `<!-- gaia-debt-key: … -->` wrapper;
# the filed issue body carries the wrapped form. A match reconstructs the
# WRAPPED form `<!-- gaia-debt-key: ${key} -->` and tests the issue body for it
# as a SUBSTRING, never whole-line equality. The wrapped form is collision-safe:
# the bare inner key ends in `line=<int>` with no boundary, so a `line=4` key
# would substring-match a sibling `line=42 -->` issue; the trailing ` -->`
# prevents that digit-prefix false match.
#
# See wiki/concepts/Audit Disposition and Debt Fix.md and
# wiki/concepts/PR Merge Workflow.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's `command` builtin and break
# later `command -v ...` guards.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match `gh pr merge` only when it appears as an actual shell invocation, either
# at the very start of the command or immediately after a shell separator. This
# avoids false positives on heredoc body text and quoted strings. Mirrors
# pr-merge-audit-check.sh exactly.
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
else
  exit 0
fi

# Repo-scope: a `gh pr merge` aimed at a different repo has no bearing on this
# repo's disposition ledger, so allow it. Mirrors the sibling merge gates.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Resolve HEAD SHA. If we cannot (no git, unreadable state), fall back to
# permissive: this hook only enforces in repos where git answers.
sha=$(git rev-parse HEAD 2>/dev/null || true)
[ -n "$sha" ] || exit 0

sidecar=".gaia/local/audit/${sha}.dispositions.json"

# Load the shared disposition logic from this hook's OWN on-disk location
# (never cwd, never $repo_root). The offender collection lives in the lib so
# this hook and the minting authority (pr-merge-audit-check.sh) share ONE
# implementation rather than two. An absent lib is an inability to verify, so
# it fails open (exit 0), consistent with every other guard in this hook.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -z "$_lib_dir" ] || [ ! -f "$_lib_dir/audit-dispositions.sh" ]; then
  exit 0
fi
# shellcheck source=/dev/null
. "$_lib_dir/audit-dispositions.sh"

# Collect offenders: (a) pending(definitive) entries (a genuinely-missing
# disposition, denied regardless of backend reachability); (b) filed entries
# whose key resolves to no tech-debt issue, open OR closed, on a REACHABLE
# backend. diverted / waived / pending(transient) are skipped. Empty = clean.
# Fail-open on no sidecar / unparseable / backend "absent" / any gh failure all
# live inside the lib. A CLOSED matching issue is a SATISFIED disposition, not
# an offender.
offenders="$(disposition_offenders "$sidecar" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Decision: allow when no offenders; otherwise deny.
# ---------------------------------------------------------------------------
[ -n "$offenders" ] || exit 0

offender_list=$(printf '%s' "$offenders" | sed 's/^/  - /')

reason="PR merge gate: the disposition-ledger sidecar for HEAD ${sha:0:12} claims dispositions that do not hold.

Offending finding key(s):

${offender_list}

A marker for this HEAD asserts every out-of-scope finding has a real disposition, but:
  - filed-but-missing: the sidecar marks the finding 'filed' yet no OPEN or CLOSED tech-debt issue carries its key on the reachable backend.
  - pending(definitive): the finding has no disposition (a definitive filing failure on a present, writable backend).

To unblock:
  1. Re-run the local code-audit-frontend agent on this HEAD so it re-files the
     missing disposition (filing is idempotent; an already-filed key is not
     duplicated).
  2. Let it rewrite the disposition-ledger sidecar and the marker.
  3. Retry gh pr merge.

This is a deterministic backstop for the audit's forced-disposition guarantee;
it never blocks on a backend-absent or transient condition.

See wiki/concepts/Audit Disposition and Debt Fix.md for the full contract."

# --arg safely escapes $reason; never interpolate dynamic values directly into
# the JSON template string.
jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'

exit 0
