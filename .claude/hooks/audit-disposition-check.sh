#!/bin/bash
# PreToolUse Bash hook: DENY `gh pr merge` when the disposition-ledger sidecar
# for HEAD's frontend content digest claims a disposition that does not hold,
# or when a valid frontend marker exists but its sidecar has gone missing.
# This is the DETERMINISTIC backstop for the audit's forced-disposition
# guarantee: the code-audit-frontend agent's own verify-after-file re-query is
# the primary enforcer, but that is agent behavior, not code. This hook
# re-reads the disposition-ledger sidecar
# (.gaia/local/audit/<frontend-digest>.dispositions.json) and fails the merge
# by CODE when a marker's claimed dispositions do not check out, or when a
# valid marker's sidecar is absent.
#
# It sits ALONGSIDE pr-merge-audit-check.sh (the marker-existence gate) and
# worthiness-presence-check.sh: all three gate `gh pr merge` and deny
# independently. This hook never relaxes the marker-existence gate; it adds an
# orthogonal check.
#
# DENY conditions:
#   1. A `filed` sidecar entry whose dedup key has NO matching `tech-debt` issue
#      (open OR closed) on a REACHABLE backend (the marker claims a filing that
#      does not exist). A CLOSED match means the disposition was filed and later
#      fixed/closed by /gaia-debt (a fully honored disposition) -> satisfied,
#      so it is NOT an offender.
#   2. A `pending` entry with pending_reason "definitive" (a present, writable
#      backend with a genuinely-missing disposition; a marker should not exist,
#      but defend against a hand-written one).
#   3. The frontend earned marker for the current frontend digest is VALID
#      (present, writer-shaped, provenance earned) but its sidecar is ABSENT.
#      Every audit run, including one that identifies zero out-of-scope
#      findings, writes a sidecar (an empty findings list at minimum), so an
#      absent sidecar alongside a valid marker means the sidecar was lost, not
#      that nothing was ever filed. Digest keying makes this a fail-open the
#      old whole-tree key never exposed; this arm closes it.
#   4. The frontend content digest cannot be derived (a missing sha256 tool, an
#      unloadable classifier/machinery library, a failing `git ls-tree`, or an
#      absent digest library). A digest-keyed gate that cannot compute its own
#      key has no path to check, so it denies rather than fall through to a
#      permissive exit.
#
# FAIL-OPEN everywhere else (SPEC never-block invariant): no frontend marker at
# all (or one present but not writer-shaped/valid for the current digest),
# backend "absent", every `filed` entry confirmed present, all entries
# diverted/waived/pending(transient), or ANY gh/tooling failure (no gh,
# unauthenticated, timeout, rate-limit, 5xx, unresolved repo). The backstop
# blocks ONLY on a confirmed present-backend inconsistency, a
# pending(definitive) entry, a valid-marker-with-absent-sidecar mismatch, or an
# undivertable digest-derive failure.
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

# HEAD sha, used only to identify the run in a deny message (never a validity
# key any more). Absence does not exit early: an unresolvable git state falls
# through to the digest-derive-failure deny arm below, which is the
# fail-closed posture the digest redesign requires here.
sha=$(git rev-parse HEAD 2>/dev/null || true)

# The audited working root, CWD-independent for the digest walk. The hook
# runs with cwd at the repo root, so a bare toplevel query answers it (fall
# back to pwd only when git cannot, e.g. no git at all).
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Load the shared disposition logic from this hook's OWN on-disk location
# (never cwd, never $root). The offender collection lives in the lib so this
# hook and the merge gate (pr-merge-audit-check.sh) share ONE implementation
# rather than two. An absent lib is an inability to verify, so it fails open
# (exit 0), consistent with every other guard in this hook.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -z "$_lib_dir" ] || [ ! -f "$_lib_dir/audit-dispositions.sh" ]; then
  exit 0
fi
# shellcheck source=/dev/null
. "$_lib_dir/audit-dispositions.sh"

# The digest engine, loaded from the same location. Unlike the disposition lib
# above, its absence is NOT a plain lib-load fail-open: without it this hook
# cannot even name the sidecar it is supposed to check, so it falls into the
# digest-derive-failure deny arm below.
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-digest.sh"
fi

# The clearance reader, loaded the same way. It backs ONLY the new
# marker-valid-but-sidecar-absent arm below; its absence degrades gracefully
# (that arm simply never fires, same posture as every other lib-load guard in
# this hook), because the digest is still derivable and the offender check
# below does not depend on it.
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-clearance.sh"
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

# Fail-closed: the frontend digest is the sidecar's validity key. Without it
# this hook has no path to check, and the redesigned gate's posture does not
# fall through to a permissive exit on a digest-derive failure (missing
# sha256 tool, unloadable classifier/machinery lib, failing git ls-tree, or an
# absent digest library).
frontend_digest=""
if command -v audit_member_digest >/dev/null 2>&1; then
  frontend_digest=$(audit_member_digest "$root" "code-audit-frontend" 2>/dev/null || true)
fi
if [ -z "$frontend_digest" ]; then
  deny "PR merge gate: the frontend content digest could not be derived for HEAD ${sha:0:12}, so the disposition-ledger sidecar cannot be located.

This denies rather than falls through permissively: a digest-keyed gate that cannot compute its own key has no way to know which sidecar (if any) governs this merge, and treating that as 'nothing to check' would silently reopen the exact fail-open the digest redesign closes.

Likely causes: a missing sha256 tool (sha256sum / shasum), an unloadable ownership classifier or machinery library (.claude/hooks/lib/audit-scope.sh, .claude/hooks/lib/audit-machinery.sh), or a git failure (git ls-tree) in this checkout.

See wiki/concepts/Audit Disposition and Debt Fix.md for the full contract."
fi

sidecar=".gaia/local/audit/${frontend_digest}.dispositions.json"

# New fail-closed arm (C4): a valid frontend earned marker for this exact
# digest with an ABSENT sidecar. Degrades to a no-op (the arm never fires)
# when the clearance reader could not be loaded above.
if command -v clearance_member_cleared >/dev/null 2>&1 \
   && clearance_member_cleared "$root" "$frontend_digest" "code-audit-frontend" \
   && [ ! -f "$sidecar" ]; then
  deny "PR merge gate: a valid code-audit-frontend clearance exists for frontend digest ${frontend_digest:0:12}, but its disposition-ledger sidecar (${sidecar}) is absent.

A valid marker for this content means the frontend audit ran to completion; every audit run, including one that identifies zero out-of-scope findings, writes a sidecar (an empty findings list at minimum), so an absent sidecar alongside a valid marker means the sidecar was lost rather than that nothing was ever filed.

To unblock:
  1. Re-run the local code-audit-frontend agent on this HEAD so it re-writes the sidecar.
  2. Retry gh pr merge.

See wiki/concepts/Audit Disposition and Debt Fix.md for the full contract."
fi

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

deny "PR merge gate: the disposition-ledger sidecar for frontend digest ${frontend_digest:0:12} claims dispositions that do not hold.

Offending finding key(s):

${offender_list}

A marker for this content asserts every out-of-scope finding has a real disposition, but:
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
