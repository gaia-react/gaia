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
#   post-findings-block.sh [--pr <N>]
#     --pr <N>      PR number. Default: resolved from the current branch via
#                   `gh pr view --json number`.
#     --help | -h   Usage, exit 0.
#
#   No base argument, and none resolved internally; see "Which sidecars this
#   reads" below. A caller still passing the removed `--base` gets the ordinary
#   unrecognized-argument usage error rather than a silently narrowed read.
#
# Which sidecars this reads (load-bearing)
#   Every findings sidecar this tree's branch has written, across EVERY base:
#   .gaia/local/audit/*.<branch-slug>.*.findings.json.
#
#   The sidecar key is `<base-sha>.<branch-slug>` (gaia_audit_key,
#   audit-key-lib.sh) and only the branch half is stable across a fix loop.
#   The gate stamps a `GAIA-Audit:` trailer on a `chore: code review audit
#   passed` commit at the end of every cleared round, and
#   .github/audit/resolve-audit-base.sh walks to the newest trailer-bearing
#   ancestor of HEAD, so the shared base advances by one stamp per cleared
#   round (a rebase onto main and a machinery-reset move it too). One branch
#   therefore writes its sidecars under SEVERAL bases, one per round, and that
#   partitioning is deliberate: it is the durable per-round record of what each
#   round found, so this script widens the read rather than stabilizing the key.
#
#   Keying this glob to one base is what starved the block before: the base a
#   caller could resolve at merge time is the newest one, whose round is clean
#   by construction, because a clean round is what let the pull request merge.
#   The findings worth hardening against -- the ones fixed during the loop --
#   were exactly the ones dropped. gaia-react/gaia#1573.
#
#   The branch half stays the whole discriminator. `.gaia/local/audit/` is
#   shared (symlinked to main from every worktree), so a sibling tree's
#   sidecars sit in the same directory, and git forbids one branch in two
#   worktrees at once. `gaia_key_slug` percent-encodes every byte outside
#   [A-Za-z0-9_-], the dot included, so no slug carries a dot of its own and
#   the literal `.<slug>.` anchor cannot straddle a key boundary or match a
#   branch whose name merely ends in this one.
#
#   What bounds the read in TIME is the janitor, not the key.
#   `.claude/hooks/local-janitor.sh` reaps `*.findings.json` off file mtime
#   (`GAIA_AUDIT_FINDINGS_RETENTION_HOURS`, default 72, floor 24), so a branch name reused long
#   after its first pull request merged reads only its own rounds. Inside that
#   window a reused branch name would merge the earlier run's rounds into the
#   later one's block, which is the honest cost of selecting on the branch: the
#   base half could not have bounded it either, since a superseded round's base
#   is an ancestor of HEAD exactly as this round's is.
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
#   An unrecognized flag is a USAGE error (exit 2, stderr), the one path that
#   is not a decline line.
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
#   own branch is the discriminator. The writer keys on both halves; this
#   reader selects on the branch half only, per "Which sidecars this reads".
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
#   {"schema":1,"pr_number":N,"auditor":"local","findings":[ ... ],
#    "review_bases":[{"member":"...","sha":"...","reason":"...",
#                     "anchor_tree":"..."}]}
#   -->
#   <!-- gaia-harden:findings:end -->
#
#   review_bases is ALWAYS present, possibly []. One entry per valid sidecar
#   carrying a well-formed `review_base` (audit-write-findings.sh), built from
#   that sidecar's .member, .review_base.sha, .review_base.reason, and
#   .review_base.anchor_tree (the empty string when the sidecar omits it). A
#   sidecar with no `review_base` key contributes no entry. `review_bases`
#   carries no finding text -- it is the per-member decision record (SPEC
#   lifecycle step 8), not a channel for anything the "Projection to the
#   block" note above already excludes.
#
# Merge order
#   Sidecar paths are sorted `LC_ALL=C sort` before merging, matching the
#   dispatch resolver's own sort discipline, so the merged array's order is
#   deterministic across runs given the same sidecar set. review_bases follows
#   the same sorted sidecar order.
#
# Malformed sidecars (never crash, never silently vanish)
#   A sidecar that is not valid JSON, or whose `.findings` is not a JSON
#   array, is skipped: named on stderr, excluded from the merge, and every
#   OTHER valid sidecar is still posted. If every matched sidecar is
#   malformed, the run declines `no sidecars` (there is nothing valid to
#   post), each bad file still named individually on stderr first.
#
#   A malformed `review_base` on an otherwise-valid sidecar (a string instead
#   of an object, or an object missing `sha`) is narrower: that ONE
#   review_bases entry is skipped and named on stderr, but the sidecar's
#   findings still merge normally. A jq failure while building review_bases
#   degrades the whole array to `[]` with a stderr note rather than aborting
#   the post -- the findings are the load-bearing half, review_bases a rider.
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
#   path. local-janitor.sh DOES glob the directory, and it does sweep
#   findings sidecars (its own `*.findings.json` arm, aged off plain file
#   mtime), but every arm it runs selects by an exact suffix, so no arm can
#   reap or misidentify a sidecar as a marker or a marker as a sidecar.
#
# Bash 3.2 compatible (macOS default). Never `cd`s. jq required (fails
# closed, matching every other digest/clearance script in this directory).

set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/audit-key-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: post-findings-block.sh [--pr <N>]
  --pr <N>      PR number. Default: resolved from the current branch via gh.
  --help | -h   usage, exit 0.

Reads every findings sidecar this tree's branch has written, across every
audit base: .gaia/local/audit/*.<branch-slug>.*.findings.json.
EOF
}

emit_decline() {
  printf 'findings: declined: %s\n' "$1"
}

emit_error() {
  printf 'post-findings-block: %s\n' "$1" >&2
}

PR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
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

command -v jq >/dev/null 2>&1 || {
  emit_error "jq is required"
  exit 2
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || repo_root="."
audit_dir="${repo_root}/.gaia/local/audit"

# The branch half of the sidecar key (gaia_branch_slug, audit-key-lib.sh),
# which is the whole selector here: see "Which sidecars this reads" in the
# header for why the base half is deliberately not one. Empty when the branch
# is undeterminable (detached HEAD, not a git repository) -- the glob below
# then matches nothing, which declines "no sidecars", the same fail-open rule
# every other undeterminable half of this key already gets.
BRANCH_SLUG="$(gaia_branch_slug "$repo_root" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# 1. Glob every sidecar this tree's BRANCH has written, across every base,
#    sorted LC_ALL=C for a deterministic merge order (matches the dispatch
#    resolver's own sort discipline). Rounds interleave in that order rather
#    than staying grouped, which costs nothing: the block is a set of findings
#    and review_bases carries the per-sidecar record.
# -----------------------------------------------------------------------------

sidecars=()
if [ -n "$BRANCH_SLUG" ]; then
  for f in "${audit_dir}"/*."${BRANCH_SLUG}".*.findings.json; do
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
# 2b. Build review_bases: one entry per valid sidecar carrying a well-formed
#     review_base, in the same sorted order valid_files already holds. A
#     sidecar with no review_base contributes nothing; a malformed one (not an
#     object, or missing sha) is skipped and named on stderr without touching
#     that sidecar's findings, already accounted for above.
# -----------------------------------------------------------------------------

review_base_entries=()
for f in ${valid_files[@]+"${valid_files[@]}"}; do
  jq -e 'has("review_base")' "$f" >/dev/null 2>&1 || continue
  if ! jq -e '(.review_base | type) == "object" and ((.review_base.sha // "") != "")' "$f" >/dev/null 2>&1; then
    emit_error "malformed review_base, skipping entry: $f"
    continue
  fi
  entry="$(jq -c '{member: (.member // ""), sha: .review_base.sha,
                   reason: (.review_base.reason // ""),
                   anchor_tree: (.review_base.anchor_tree // "")}' "$f" 2>/dev/null || true)"
  [ -n "$entry" ] && review_base_entries+=("$entry")
done

review_bases="[]"
if [ "${#review_base_entries[@]}" -gt 0 ]; then
  if built="$(printf '%s\n' ${review_base_entries[@]+"${review_base_entries[@]}"} | jq -sc . 2>&1)" \
    && printf '%s' "$built" | jq -e 'type == "array"' >/dev/null 2>&1; then
    review_bases="$built"
  else
    emit_error "cannot render review_bases, degrading to []: $built"
  fi
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

#    jq's STATUS is checked, not its emptiness. Every file left in valid_files
#    already parsed with an array `.findings`, so this pass cannot come back
#    empty on data grounds: an empty result means the merge itself failed.
#    Defaulting that to `[]` would publish "the audit found nothing" on a PR
#    when what happened is "the merge broke", which is the one wrong answer
#    here, so a merge failure declines exactly as the render failure below
#    does. Its stderr is captured rather than discarded for the same reason.
if ! merged_findings="$(jq -s '[.[] | .findings[]? | {finding_class, severity, area_tags}]' ${valid_files[@]+"${valid_files[@]}"} 2>&1)"; then
  emit_error "cannot merge the findings sidecars: $merged_findings"
  emit_decline "post failed"
  exit 0
fi
n="$(printf '%s' "$merged_findings" | jq 'length' 2>/dev/null || echo 0)"
m="${#valid_files[@]}"

payload="$(jq -nc \
  --argjson pr "$PR" \
  --argjson findings "$merged_findings" \
  --argjson review_bases "$review_bases" \
  '{schema: 1, pr_number: $pr, auditor: "local", findings: $findings,
    review_bases: $review_bases}' 2>/dev/null || true)"
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
#
#    The body goes over as `-F body=@<file>`: per `gh api --help`, only
#    `-F/--field` reads the value from the file behind `@<path>`, while
#    `-f/--raw-field` would send that path as a literal string. The API returns
#    200 for either, so the wrong flag posts a path where the block belongs and
#    reports success, and the sentinel lookup above then never matches its own
#    comment.
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
    -F body=@"$body_file" >/dev/null 2>&1; then
    printf 'findings: updated %s finding(s) from %s member(s) on PR #%s\n' "$n" "$m" "$PR"
    exit 0
  fi
  emit_decline "post failed"
  exit 0
fi

if gh api --method POST "repos/${repo}/issues/${PR}/comments" \
  -F body=@"$body_file" >/dev/null 2>&1; then
  printf 'findings: posted %s finding(s) from %s member(s) to PR #%s\n' "$n" "$m" "$PR"
  exit 0
fi

emit_decline "post failed"
exit 0
