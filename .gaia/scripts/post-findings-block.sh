#!/usr/bin/env bash
# post-findings-block.sh: merge every dispatched Code Audit Team member's
# findings sidecar for this run into ONE machine-readable findings block and
# post-or-update it on the PR, the local-producer counterpart to the block
# CI's own workflow prompt already emits (code-review-audit.yml:359-372).
#
# Purpose
#   The finding-recurrence tally reads PR comments for a parseable findings
#   block and counts distinct PRs per
#   finding_class. Only CI ever emitted that block, so a PR audited entirely
#   by the local producer contributed nothing. Each dispatched member writes
#   a deterministic sidecar (see the "Findings sidecar" section of its own
#   agent definition); this script merges every sidecar for one run into a
#   single block, matching the frozen comment-block contract, and posts or
#   updates exactly one PR comment carrying it.
#
# Usage
#   post-findings-block.sh --base <sha> [--pr <N>]
#     --base <sha>  REQUIRED. The incremental audit base; combined with this
#                   tree's own branch (gaia_audit_key, audit-key-lib.sh) into
#                   the key that globs the sidecars
#                   (.gaia/local/audit/<sha>.<branch-slug>.*.findings.json).
#                   Callers resolve <sha> the same way the audited member(s)
#                   already do (.github/audit/resolve-audit-base.sh +
#                   merge-base, or the plain merge-base a specialized member
#                   computes for its own remit filter); this script invents
#                   no base of its own.
#     --pr <N>      PR number. Default: resolved from the current branch via
#                   `gh pr view --json number`.
#     --help | -h   Usage, exit 0.
#
# Output contract
#   One stdout marker line, always. Exit 0 on EVERY path.
#     findings: posted <n> finding(s) from <m> member(s) to PR #<N>
#     findings: updated <n> finding(s) from <m> member(s) on PR #<N>
#   Decline lines (prefix "findings: declined: "), never a non-zero exit:
#     no sidecars          no sidecar matched the glob, or every matched
#                           sidecar was malformed (named individually on
#                           stderr as each is skipped)
#     gh absent
#     gh unauthenticated
#     pr unresolved
#     post failed
#   A malformed --base (missing) or an unrecognized flag is a USAGE error
#   (exit 2, stderr), the one path that is not a decline line.
#
# Caller contract (load-bearing, not this script's own concern)
#   Call this ONLY from the local orchestrator, once per local dispatch wave,
#   after every dispatched member has returned, and ONLY when
#   resolved_mode=local. This script edits ANY PR comment carrying the
#   `<!-- gaia-harden:findings:start -->` sentinel; calling it under
#   resolved_mode=ci would silently overwrite CI's own findings block with
#   one carrying only the locally-dispatched members' findings. See
#   wiki/concepts/PR Merge Workflow.md.
#
# Sidecar shape (each Code Audit Team member's own contract; written by
# .gaia/scripts/audit-write-findings.sh)
#   .gaia/local/audit/<base-sha>.<branch-slug>.<member>.findings.json, the
#   key gaia_audit_key computes (audit-key-lib.sh): base-sha alone collides
#   between two worktrees cut from the same main tip, so the acting tree's
#   own branch is the discriminator.
#   {"schema":1,"member":"<name>","findings":[
#     {"finding_class":"...","severity":"error|warning|suggestion",
#      "area_tags":["..."],"path":"...","line":N,"title":"...",
#      "failure_mode":"...","verified_by":"...","suggested_fix":"..."}
#   ]}
#   "findings":[] is a valid, meaningful sidecar (the member ran and found
#   nothing countable); an ABSENT sidecar is not the same thing, and this
#   script never fabricates one.
#
# Projection to the block (load-bearing)
#   The sidecar is the member's full report of record: it carries the file,
#   line, defect, verification, and recommended repair a fix needs. The PR
#   comment block does NOT. Each finding is projected to exactly
#   finding_class / severity / area_tags on the way out, for two reasons. The
#   block's contract is frozen at those three keys (parse-findings-block.ts
#   reads only them, and the recurrence tally counts distinct PRs per
#   finding_class), so anything else is dead weight in a comment nobody reads
#   by hand. And a PR comment is a published surface whose visibility follows
#   the repo's, while a finding's text can quote the very secret or hole it
#   reports; the local sidecar is the right home for that, and the
#   security-class disposition rules exist precisely because publishing such a
#   finding is not always safe. Extending the sidecar therefore never widens
#   what this script publishes.
#
# Rendered block shape (frozen, matches parse-findings-block.ts)
#   <!-- gaia-harden:findings:start -->
#   <!--
#   {"schema":1,"pr_number":N,"auditor":"local","findings":[ ... ]}
#   -->
#   <!-- gaia-harden:findings:end -->
#
# Merge order
#   Sidecar paths are sorted `LC_ALL=C sort` before merging, matching the
#   dispatch resolver's own sort discipline, so the merged array's order is
#   deterministic across runs given the same sidecar set.
#
# Malformed sidecars (never crash, never silently vanish)
#   A sidecar that is not valid JSON, or whose `.findings` is not a JSON
#   array, is skipped: named on stderr, excluded from the merge, and every
#   OTHER valid sidecar is still posted. If every matched sidecar is
#   malformed, the run declines `no sidecars` (there is nothing valid to
#   post), each bad file still named individually on stderr first.
#
# Filename collision with a clearance marker: PROVABLY NONE
#   A clearance marker/refusal/dispositions-sidecar is keyed to a member's
#   CONTENT DIGEST, a 64-hex sha256 (audit-digest.sh). A findings sidecar is
#   keyed to <base-sha>.<branch-slug> (gaia_audit_key), never a bare 64-hex
#   value, so a findings sidecar can never be mistaken for, or glob-matched
#   as, a marker by VALUE. Direction two: no marker reader globs the audit
#   directory for `.ok`/`.refused` files by pattern.
#   post-audit-status.sh operates only on the single marker path an agent
#   hands it as an argument; pr-merge-audit-check.sh and
#   audit-disposition-check.sh read only their own single exact digest-keyed
#   path. local-janitor.sh DOES glob the directory, but its glob list
#   (*.ok, *.refused, *.carried, *.dispositions.json, *.progress.log,
#   *.rerun.json) has no `*.findings.json` arm, so it neither reaps nor
#   misidentifies a findings sidecar; it also means a findings sidecar is
#   never swept, a named follow-up (see this task's return to the
#   orchestrator).
#
# Bash 3.2 compatible (macOS default). Never `cd`s. jq required (fails
# closed, matching every other digest/clearance script in this directory).

set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/audit-key-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: post-findings-block.sh --base <sha> [--pr <N>]
  --base <sha>  the incremental audit base; combined with this tree's own
                branch into the key that globs the sidecars.
  --pr <N>      PR number. Default: resolved from the current branch via gh.
  --help | -h   usage, exit 0.
EOF
}

emit_decline() {
  printf 'findings: declined: %s\n' "$1"
}

emit_error() {
  printf 'post-findings-block: %s\n' "$1" >&2
}

BASE=""
PR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      BASE="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --pr)
      PR="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      emit_error "unrecognized argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ -z "$BASE" ]; then
  emit_error "--base is required"
  usage
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  emit_error "jq is required"
  exit 2
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || repo_root="."
audit_dir="${repo_root}/.gaia/local/audit"

# AUDIT_TAG combines --base with THIS tree's own branch (gaia_audit_key,
# audit-key-lib.sh): a base sha alone collides between two worktrees cut
# from the same main tip, since both compute the identical merge-base. Empty
# when the branch is undeterminable (detached HEAD) -- the glob below then
# matches nothing, which declines "no sidecars" below, the same fail-open
# rule an empty --base already gets.
AUDIT_TAG=""
AUDIT_TAG="$(gaia_audit_key "$BASE" "$repo_root" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# 1. Glob sidecars for this tree's tag, sorted LC_ALL=C for a deterministic
#    merge order (matches the dispatch resolver's own sort discipline).
# -----------------------------------------------------------------------------

sidecars=()
if [ -n "$AUDIT_TAG" ]; then
  for f in "${audit_dir}"/"${AUDIT_TAG}".*.findings.json; do
    [ -e "$f" ] || continue
    sidecars+=("$f")
  done
fi

if [ "${#sidecars[@]}" -gt 0 ]; then
  sorted_list="$(printf '%s\n' ${sidecars[@]+"${sidecars[@]}"} | LC_ALL=C sort)"
  sidecars=()
  while IFS= read -r line; do
    [ -n "$line" ] && sidecars+=("$line")
  done <<< "$sorted_list"
fi

if [ "${#sidecars[@]}" -eq 0 ]; then
  emit_decline "no sidecars"
  exit 0
fi

# -----------------------------------------------------------------------------
# 2. Validate each sidecar; skip and name a malformed one on stderr rather
#    than crash or silently drop the whole run.
# -----------------------------------------------------------------------------

valid_files=()
for f in ${sidecars[@]+"${sidecars[@]}"}; do
  if ! jq -e . "$f" >/dev/null 2>&1; then
    emit_error "malformed sidecar (invalid JSON), skipping: $f"
    continue
  fi
  if ! jq -e '(.findings | type) == "array"' "$f" >/dev/null 2>&1; then
    emit_error "malformed sidecar (missing or non-array findings), skipping: $f"
    continue
  fi
  valid_files+=("$f")
done

if [ "${#valid_files[@]}" -eq 0 ]; then
  emit_decline "no sidecars"
  exit 0
fi

# -----------------------------------------------------------------------------
# 3. gh must be present and authenticated before anything gh-shaped happens
#    (fail-safe asymmetry, exactly as post-audit-status.sh has it): the
#    sidecars themselves are untouched either way.
# -----------------------------------------------------------------------------

if ! command -v gh >/dev/null 2>&1; then
  emit_decline "gh absent"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  emit_decline "gh unauthenticated"
  exit 0
fi

# -----------------------------------------------------------------------------
# 4. Resolve the PR number.
# -----------------------------------------------------------------------------

if [ -z "$PR" ]; then
  PR="$(gh pr view --json number --jq .number 2>/dev/null || true)"
fi
if [ -z "$PR" ]; then
  emit_decline "pr unresolved"
  exit 0
fi

# -----------------------------------------------------------------------------
# 5. Merge every valid sidecar's findings[] into one array, then render the
#    frozen block shape. The JSON payload lives inside an INNER HTML comment
#    so it never renders (matches parse-findings-block.ts:5-20).
# -----------------------------------------------------------------------------

merged_findings="$(jq -s '[.[] | .findings[]? | {finding_class, severity, area_tags}]' ${valid_files[@]+"${valid_files[@]}"} 2>/dev/null || true)"
if [ -z "$merged_findings" ]; then
  merged_findings="[]"
fi
n="$(printf '%s' "$merged_findings" | jq 'length' 2>/dev/null || echo 0)"
m="${#valid_files[@]}"

payload="$(jq -nc \
  --argjson pr "$PR" \
  --argjson findings "$merged_findings" \
  '{schema: 1, pr_number: $pr, auditor: "local", findings: $findings}' 2>/dev/null || true)"
if [ -z "$payload" ]; then
  emit_error "could not render the findings payload"
  emit_decline "post failed"
  exit 0
fi

body_file="$(mktemp 2>/dev/null || true)"
if [ -z "$body_file" ]; then
  emit_decline "post failed"
  exit 0
fi
trap 'rm -f "$body_file"' EXIT

{
  printf '<!-- gaia-harden:findings:start -->\n'
  printf '<!--\n'
  printf '%s\n' "$payload"
  printf '%s\n' '-->'
  printf '<!-- gaia-harden:findings:end -->\n'
} > "$body_file"

# -----------------------------------------------------------------------------
# 6. Post or update EXACTLY ONE comment: locate an existing one by the start
#    sentinel and edit it; create one only when none exists.
# -----------------------------------------------------------------------------

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
if [ -z "$repo" ]; then
  emit_decline "post failed"
  exit 0
fi

existing_id="$(gh api "repos/${repo}/issues/${PR}/comments" --paginate \
  --jq '.[] | select((.body // "") | contains("<!-- gaia-harden:findings:start -->")) | .id' \
  2>/dev/null | head -n 1 || true)"

if [ -n "$existing_id" ]; then
  if gh api --method PATCH "repos/${repo}/issues/comments/${existing_id}" \
    -f body=@"$body_file" >/dev/null 2>&1; then
    printf 'findings: updated %s finding(s) from %s member(s) on PR #%s\n' "$n" "$m" "$PR"
    exit 0
  fi
  emit_decline "post failed"
  exit 0
fi

if gh api --method POST "repos/${repo}/issues/${PR}/comments" \
  -f body=@"$body_file" >/dev/null 2>&1; then
  printf 'findings: posted %s finding(s) from %s member(s) to PR #%s\n' "$n" "$m" "$PR"
  exit 0
fi

emit_decline "post failed"
exit 0
