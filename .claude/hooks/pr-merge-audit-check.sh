#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until every dispatched Code Audit
# Team member has cleared HEAD. AND-aggregator: resolves the diff's dispatched
# member set (.gaia/scripts/resolve-audit-members.sh) and requires each
# member's own clearance, one cleared member can no longer satisfy the gate
# while a co-dispatched member withholds.
#
# Zero-match (the whole diff is out of audit scope) or the resolver script
# being absent both fall through to the LEGACY single-signal gate: the marker/
# trailer/status/bypass logic below, unchanged, evaluated for
# code-audit-frontend alone. A non-empty dispatched set instead runs the
# member-aware gate further down: code-audit-frontend by the same signals,
# each SPECIALIZED member <m> by its own marker
# .gaia/local/audit/<digest>.<m>.ok (the sole clearance signal for maintainer
# members, which are local/advisory-only with no CI/trailer equivalent).
#
# Markers are keyed to each member's own CONTENT DIGEST (a sha256 over exactly
# the files that member owns plus the shared gate machinery, folding in the
# in-scope-but-ownerless paths for the default member), not the whole tree and
# not the commit. A marker attests that a member audited the CONTENT its
# digest covers: an out-of-glob change (a CHANGELOG line, a wiki edit) rotates
# no member's digest, so every existing marker keeps validating with zero
# re-dispatch; a change to a file a member owns rotates only that member's
# digest; a change to any gate-machinery file rotates every member's digest.
# code-audit-frontend's GAIA-Audit trailer stamp lands as an empty commit,
# which advances HEAD while leaving every blob byte-identical, so it rotates
# no digest either.
#
# code-audit-frontend / legacy-gate signals:
#
#   1. Local marker file at .gaia/local/audit/<frontend-digest>.ok, written by
#      the audit agent at the end of a clean local review.
#
#   2. GAIA-Audit trailer on HEAD's commit message, when the trailer's
#      version and frontend-digest fields both match a recomputed frontend
#      digest. Written by a local audit run via
#      .claude/hooks/audit-stamp-trailer.sh.
#
#   3. GAIA-Audit GitHub commit status on HEAD with state: success, description
#      "<version> <frontend-digest> <tree>", when both version and digest
#      match (the tree field is data only, never compared). CI stamps this
#      status instead of pushing an empty marker commit (pushing it would
#      re-trigger CI and leave the PR HEAD without check runs). A non-success
#      status (e.g. a local-mode stand-down's pending status on the same
#      context and SHA) is not a cleared signal even when its description
#      matches. Queried via `gh api` using GH_TOKEN or the ambient gh auth
#      session.
#
#   4. chore(deps) PR bypass: PR title matches `^chore\(deps(-dev)?\):`. The
#      /update-deps wrapper runs the full quality gate locally before
#      pushing, so the audit signal is implicit for this PR class. Mirrors
#      the same narrowing applied to code-review-audit.yml, tests.yml, and
#      chromatic.yml, all four surfaces skip together on chore(deps) PRs.
#
#   5. Out-of-scope bypass (legacy gate only, a non-empty dispatched set means
#      an in-scope file exists so this never applies there): every file the PR
#      changes lives on a surface outside audit scope, wiki, instruction files
#      (.claude / .specify), .gaia metadata, prose docs, and root-level
#      markdown. These mirror the surfaces code-review-audit.yml treats as out
#      of scope via its `has_source` check. Evaluated fail-closed: any in-scope
#      path (app/, test/, configs, .github/workflows/) makes the marker
#      mandatory again. An in-scope-but-ownerless path (a root Dockerfile,
#      public/**) is folded into the frontend member's digest input set, so a
#      stale marker computed for a prior digest never matches such a change
#      either; this bypass and that digest fold close the same band from two
#      directions.
#
#   6. Self-mod-only GAIA-update bypass: the only in-scope path the PR changes
#      is .github/workflows/code-review-audit.yml AND its committed bytes are a
#      verbatim re-render of the bundled template
#      (.gaia/cli/templates/workflows/code-review-audit.yml.tmpl), with every
#      other changed path out of scope. This is the self-mod-only case
#      /update-gaia Step 12 produces: it refreshes a stale audit workflow by
#      copying the release template verbatim, which makes CI self-mod-skip (no
#      stamp) and trips the in-scope guard of signal 5. The changed bytes are
#      GAIA's own template, not adopter code, so there is nothing to audit.
#
# Signals 1-4 and 6 prove an audit ran against this content (or that none is
# needed); signal 5 proves there is nothing in audit scope to review at all. A
# refusal artifact (.gaia/local/audit/<digest>[.<member>].refused) for a
# member's current digest is checked BEFORE any earned signal and is
# absolute: it denies regardless of a same-digest earned marker, for both
# code-audit-frontend and every specialized member.
#
# Without every dispatched member's clearance, the hook denies the gh pr merge
# call. To unblock:
#   1. Spawn the pending member's agent (code-audit-frontend for the default
#      member; the specialized member named in the deny reason otherwise) on
#      the current branch, OR for code-audit-frontend, push to the PR branch
#      and wait for CI's audit to stamp the GitHub commit status (CI ships no
#      specialized members).
#   2. Address any findings; commit and push.
#   3. Re-spawn the pending member's agent on the new HEAD; let it write its marker.
#   4. Retry gh pr merge.
#
# See wiki/concepts/PR Merge Workflow.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Note: avoid naming this `command`, it would shadow bash's `command` builtin
# and make any later `command -v ...` calls in this script silently misbehave.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match `gh pr merge` only when it appears as an actual shell invocation,
# either at the very start of the command (after optional whitespace) or
# immediately after a shell separator (&&, ;, ||, |, newline). This avoids
# false positives on heredoc body text and quoted strings (e.g. commit
# messages that reference the command in prose). Use bash =~ for whole-string
# regex semantics; grep operates line-by-line and would match heredoc body
# lines. The newline alternative covers multi-statement scripts where each
# command is on its own line.
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
else
  exit 0
fi

# Repo-scope: this gate enforces the home repo's audit contract only. A
# `gh pr merge` aimed at a different repo (e.g. a sibling project merged via
# `cd ../other && gh pr merge` or `gh pr merge -R owner/other`) has no bearing
# on this repo's audit markers, allow it.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Load the shared clearance reader from this hook's OWN on-disk location
# (never cwd, never $repo_root). The bats suites run this hook by absolute
# path from a sandbox cwd that has no .claude/, so a cwd-relative source would
# miss the lib and flip every clearance check. Loaded lazily here, after the
# early exits above, because this hook fires on every Bash tool call.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-clearance.sh"
fi

# Load the shared ownership classifier + machinery list + digest engine from
# the same on-disk location. check_out_of_scope_pr() and
# check_self_mod_only_update_pr() below depend on the classifier to know what
# a changed path is, and every marker check below is keyed to a member's
# content digest computed by the digest engine; an absent or unreadable
# module means this gate cannot know what it is gating, so it denies rather
# than fall through to a degraded, uninformed gate. This is a new, deliberate
# fail-closed path distinct from every other guard in this hook (which fail
# OPEN on an unusable lookup).
_scope_lib="$_lib_dir/audit-scope.sh"
_machinery_lib="$_lib_dir/audit-machinery.sh"
_digest_lib="$_lib_dir/audit-digest.sh"
if [ -z "$_lib_dir" ] || [ ! -f "$_scope_lib" ] || [ ! -f "$_machinery_lib" ] || [ ! -f "$_digest_lib" ]; then
  jq -n --arg r "PR merge gate: cannot load the ownership classifier or the digest engine (.claude/hooks/lib/audit-scope.sh, .claude/hooks/lib/audit-machinery.sh, and .claude/hooks/lib/audit-digest.sh must all exist and be readable). Every marker check below is keyed to a member's content digest, and this gate's out-of-scope and self-mod-only bypasses depend on the classifier to know what a changed path is, so it denies rather than guess. Restore all three files (they ship with the framework; a missing or corrupted checkout is the usual cause) and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi
# shellcheck source=/dev/null
. "$_scope_lib"
# shellcheck source=/dev/null
. "$_machinery_lib"
# shellcheck source=/dev/null
. "$_digest_lib"

# The shared disposition-ledger logic (disposition_offenders). C4 re-verifies
# code-audit-frontend's dispositions whenever its own earned digest marker is
# valid, so a still-open receipt that seed-forward carried across a digest
# rotation without re-verifying it against the backend is still caught here.
# Loaded lazily here, after the early exits, resolved from this hook's own
# on-disk location. An absent lib is NOT fail-closed: the re-check below
# simply cannot run (every call site guards on `command -v
# disposition_offenders`), the gate still demands every dispatched member's
# own clearance regardless.
if [ -f "$_lib_dir/audit-dispositions.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-dispositions.sh"
fi

# Resolve HEAD SHA. If we cannot (no git, detached state we can't read),
# fall back to permissive: this hook only enforces in repos where git answers.
sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$sha" ]; then
  exit 0
fi

# Resolve HEAD's TREE. This is now a plain DATA field (surfaced in deny
# messages only), never a validity key: every marker check below is keyed to
# a member's own content digest, computed next.
tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)

# The audited working root. clearance_member_cleared builds its marker paths
# from this; the hook runs with cwd at the repo root, so a bare toplevel query
# answers it (fall back to pwd only when git cannot).
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Parse the roster ONCE per run (never once per path); the classifier module
# was sourced above. audit_digests_all below re-inits the same state
# internally (its own single-walk contract), so this call is redundant with
# it in effect but kept explicit: check_out_of_scope_pr() and
# check_self_mod_only_update_pr() run before any digest-dependent path in a
# future edit would still find the roster parsed.
audit_scope_init "$root"

# Compute every roster member's content digest in ONE walk (directive
# PERF-001): audit_digests_all parses the roster, walks the tree once, and
# classifies every path once, emitting "<member>\t<digest>" per member. This
# is the sole validity-key derive point for every marker check below,
# replacing the single HEAD^{tree} marker key. Fail closed: a missing sha256
# tool, an unloadable classifier, or a git failure returns non-zero here (the
# same tool-degradation fail-closed posture already applied to an unloadable
# classifier above), and this gate must never proceed with a partial or empty
# digest set.
_digest_batch="$(audit_digests_all "$root" 2>/dev/null)" || _digest_batch=""
if [ -z "$_digest_batch" ]; then
  jq -n --arg r "PR merge gate: cannot derive per-member content digests for HEAD ${sha:0:12} (audit_digests_all failed or returned nothing). This usually means a missing sha256 tool (sha256sum / shasum -a 256), a git failure, or a corrupted checkout. Every Code Audit Team marker is keyed to a member's content digest, so this gate denies rather than match against an empty or partial digest. Restore the missing tool/checkout and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

# Parse the batch into parallel arrays (bash 3.2 has no associative arrays,
# mirroring the digest engine's own convention).
_DIGEST_MEMBER=()
_DIGEST_VALUE=()
while IFS= read -r _digest_line; do
  [ -n "$_digest_line" ] || continue
  _DIGEST_MEMBER[${#_DIGEST_MEMBER[@]}]="${_digest_line%%$'\t'*}"
  _DIGEST_VALUE[${#_DIGEST_VALUE[@]}]="${_digest_line#*$'\t'}"
done <<EOF
$_digest_batch
EOF

# member_digest <member> -> that member's content digest on stdout, exit 0;
# exit 1 (empty stdout) when the member is absent from the batch above.
member_digest() {
  local want="$1" i=0
  while [ "$i" -lt "${#_DIGEST_MEMBER[@]}" ]; do
    if [ "${_DIGEST_MEMBER[$i]}" = "$want" ]; then
      printf '%s\n' "${_DIGEST_VALUE[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

frontend_digest="$(member_digest code-audit-frontend)" || frontend_digest=""

marker=".gaia/local/audit/${frontend_digest}.ok"

# A refusal for the frontend's CURRENT digest is checked before any earned
# signal and is absolute (C6): denies regardless of a same-digest earned
# marker. Computed once so both the legacy and member-aware deny paths (and
# frontend_cleared() below) see the same value without re-querying per call.
frontend_refused=0
if [ -n "$frontend_digest" ] && clearance_member_refused "$root" "$frontend_digest" code-audit-frontend; then
  frontend_refused=1
fi
refusal_note=""
if [ "$frontend_refused" -eq 1 ]; then
  refusal_note="
A live refusal exists for this exact content: $(clearance_refused_path "$root" "$frontend_digest" code-audit-frontend). A refusal always takes precedence over any earned marker for the same content; re-spawn the code-audit-frontend agent to address the finding.
"
fi

# Human-readable state of a local marker file for a deny message. The gate now
# accepts only a writer-produced clearance, so a file that exists but is not
# writer-shaped is neither "cleared" nor "missing": name that third state so an
# operator staring at a present marker while the gate says "missing" is not
# left guessing.
marker_state() {
  if [ -f "$1" ]; then
    printf '(present but not a valid clearance; re-run the member'\''s agent)'
  else
    printf '(missing)'
  fi
}

# --- code-audit-frontend clearance signals -----------------------------------
#
# Each check is a self-contained function so frontend_cleared() below can
# reuse it from both the legacy gate and the member-aware gate.

# The C3 shared trailer regex (POSIX ERE): version, 64-hex frontend digest,
# 40-hex tree, in that order after the colon. $1=version, $2=digest, $3=tree.
GAIA_AUDIT_TRAILER_RE='^GAIA-Audit:[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9a-f]{64})[[:space:]]+([0-9a-f]{40})[[:space:]]*$'

# _gate_current_version -> the trimmed .gaia/VERSION literal on stdout, or
# empty. Shared by check_trailer and check_github_status: both compare a
# stamped version field against the same literal.
_gate_current_version() {
  local v=""
  if [ -f ".gaia/VERSION" ]; then
    v=$(tr -d '\r' < ".gaia/VERSION" | awk 'NF{print; exit}')
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
  fi
  printf '%s' "$v"
}

# Trailer fallback: accept a GAIA-Audit trailer on HEAD when its version and
# frontend-digest fields both match. The trailer format (per
# audit-stamp-trailer.sh) is "GAIA-Audit: <version> <frontend-digest> <tree>",
# parsed via the C3 shared regex above; the tree field is data only and is
# never compared. Sets $trailer_status for the deny reason regardless of
# outcome.
check_trailer() {
  trailer_line=$(git log -1 --format='%B' HEAD 2>/dev/null \
    | git interpret-trailers --parse 2>/dev/null \
    | grep -E '^GAIA-Audit:' \
    | head -1)
  trailer_status="missing"
  if [ -n "$trailer_line" ]; then
    if [[ "$trailer_line" =~ $GAIA_AUDIT_TRAILER_RE ]]; then
      trailer_version="${BASH_REMATCH[1]}"
      trailer_digest="${BASH_REMATCH[2]}"
      cur_version="$(_gate_current_version)"
      if [ -n "$cur_version" ] && [ "$trailer_version" = "$cur_version" ] \
         && [ -n "$frontend_digest" ] && [ "$trailer_digest" = "$frontend_digest" ]; then
        return 0
      fi
      trailer_status="present but version/digest mismatch (audit was for different content)"
    else
      trailer_status="present but does not match the GAIA-Audit trailer format (version, 64-hex frontend digest, 40-hex tree)"
    fi
  fi
  return 1
}

# GitHub commit status fallback: CI stamps a GAIA-Audit commit status instead
# of pushing an empty marker commit (pushing it would re-trigger CI and leave
# the PR HEAD without check runs). Query the API for a matching status on HEAD.
# The status must be state: success; its description shape is
# "<version> <frontend-digest> <tree>" (C3), and version + digest must both
# match (the tree field is data only, never compared). A non-success status
# (e.g. a local-mode stand-down's pending status) is filtered out at the
# source, so a pending status carrying HEAD's version+digest is not treated as
# cleared. Falls through silently on any error (no gh, no token, no
# GITHUB_REPOSITORY, API failure), the deny path below fires as normal.
check_github_status() {
  command -v gh >/dev/null 2>&1 || return 1

  # Derive repo slug. GITHUB_REPOSITORY is set inside Actions; derive from
  # the current directory's git remote for local runs via `gh repo view`
  # (avoids BSD-vs-GNU sed portability issues with lazy quantifiers).
  repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$repo" ] || return 1
    case "$repo" in
      */*) ;;  # must contain exactly one slash (owner/name)
      *) return 1 ;;
    esac
  fi

  # Read .gaia/VERSION (same "no stamp without VERSION" invariant as CI).
  cur_version="$(_gate_current_version)"
  [ -n "$cur_version" ] || return 1

  [ -n "$frontend_digest" ] || return 1

  status_desc=$(gh api \
    "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | first | select(.state == "success") | .description' \
    2>/dev/null || true)

  [ -n "$status_desc" ] && [ "$status_desc" != "null" ] || return 1

  status_version=$(printf '%s' "$status_desc" | awk '{print $1}')
  status_digest=$(printf '%s' "$status_desc" | awk '{print $2}')

  [ -n "$status_version" ] && [ -n "$status_digest" ] || return 1
  [ "$status_version" = "$cur_version" ] || return 1
  [ "$status_digest" = "$frontend_digest" ] || return 1

  return 0
}

# chore(deps) bypass: PRs whose title matches `^chore\(deps(-dev)?\):` are
# pre-verified by the /update-deps wrapper's local quality gate (typecheck +
# lint + vitest + playwright + build), so the audit-marker requirement is
# waived for this PR class. Same skip narrowing as the CI workflows
# (code-review-audit.yml, tests.yml, chromatic.yml).
#
# Title is queried via `gh pr view`. On any failure (no gh, no auth, no PR
# for the current branch, network error) the bypass does not fire and the
# normal deny path runs, the bypass is opt-in proof, not a fallback.
check_chore_deps_pr() {
  command -v gh >/dev/null 2>&1 || return 1
  pr_title=$(gh pr view --json title --jq .title 2>/dev/null || true)
  [ -n "$pr_title" ] || return 1
  case "$pr_title" in
    'chore(deps):'*|'chore(deps-dev):'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Out-of-scope bypass: accept the merge when every file this PR changes lives
# on a surface outside audit scope. The agent has no rules that apply to wiki,
# instruction files, .gaia metadata, or prose, so there is nothing to audit and
# no marker is required, the same determination code-review-audit.yml's
# `has_source` check makes when it skips. The allowlist itself lives in the
# shared classifier (audit_out_of_scope_allowlisted), the ONE place this
# literal set is defined.
# Legacy-gate only: FC-4's auditable-base mirrors this check's complement, so
# any in-scope path here also dispatches a member, a non-empty dispatched set
# never reaches this function.
#
# Strict allowlist, evaluated fail-closed: the diff base must resolve, the diff
# must be non-empty, and EVERY path must be out of scope. Any unresolved base,
# diff error, or in-scope path (app/, test/, configs, .github/workflows/) falls
# through to the normal deny. A PR that touches auditable source therefore can
# never reach this bypass, it cannot mask an audit that withheld its marker
# over unresolved findings, since that PR's diff carries in-scope paths by
# definition. Pure local git: no gh, no network, no dependence on a CI stamp.
check_out_of_scope_pr() {
  # Resolve the PR base, the default branch this work forks from. Prefer the
  # remote's advertised default; fall back to main. The merge base scopes the
  # diff to THIS PR's changes, not unrelated drift already on the base branch.
  default_branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/origin/@@')
  [ -n "$default_branch" ] || default_branch="main"

  base=$(git merge-base HEAD "origin/${default_branch}" 2>/dev/null \
    || git merge-base HEAD "${default_branch}" 2>/dev/null \
    || true)
  [ -n "$base" ] || return 1

  changed=$(git diff --name-only "${base}...HEAD" 2>/dev/null) || return 1
  [ -n "$changed" ] || return 1

  # First path the shared classifier does not allowlist makes the marker
  # mandatory.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    audit_out_of_scope_allowlisted "$path" || return 1
  done <<< "$changed"

  return 0
}

# Self-mod-only GAIA-update bypass: accept the merge when the ONLY in-scope path
# the PR changes is .github/workflows/code-review-audit.yml AND its committed
# bytes are a verbatim re-render of the bundled template
# (.gaia/cli/templates/workflows/code-review-audit.yml.tmpl), with every other
# changed path out of audit scope. This is the self-mod-only case /update-gaia
# Step 12 produces: it refreshes a stale installed audit workflow by copying the
# release template verbatim, which makes the update PR self-modifying.
# claude-code-action's workflow-validation guardrail then refuses to run CI's
# audit (no GAIA-Audit stamp can land), and the out-of-scope bypass above denies
# because .github/workflows/ is in scope, so without this signal the operator is
# forced into a ceremonial local re-audit of bytes that are GAIA's own template,
# not adopter code. The one in-scope path also sits in the auditable-base set,
# so this signal is reachable from the member-aware gate too (dispatched set
# {code-audit-frontend} alone).
#
# Stricter than check_out_of_scope_pr: exactly ONE in-scope path, it must be the
# audit workflow, and git-blob identity must prove its bytes equal the template.
# Fail-closed: any other in-scope path (app/, test/, a config, a second
# workflow), an absent template, or a single non-matching byte returns 1 and
# falls through to the normal deny. A malicious PR cannot smuggle code here, an
# app/test/config path is in scope and unrecognized, so the loop returns 1 on
# first sight. Pure local git: no gh, no network, no CI stamp.
check_self_mod_only_update_pr() {
  audit_wf=".github/workflows/code-review-audit.yml"
  audit_tmpl=".gaia/cli/templates/workflows/code-review-audit.yml.tmpl"

  default_branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/origin/@@')
  [ -n "$default_branch" ] || default_branch="main"

  base=$(git merge-base HEAD "origin/${default_branch}" 2>/dev/null \
    || git merge-base HEAD "${default_branch}" 2>/dev/null \
    || true)
  [ -n "$base" ] || return 1

  changed=$(git diff --name-only "${base}...HEAD" 2>/dev/null) || return 1
  [ -n "$changed" ] || return 1

  # Classify every changed path via the shared ORDERED THREE-WAY classifier
  # (audit_self_mod_classify): out-of-scope surfaces are always fine; the ONE
  # permitted in-scope path is the audit workflow itself; any other in-scope
  # path (app/, test/, configs, a different workflow) denies immediately.
  seen_audit_wf=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    class="$(audit_self_mod_classify "$path")"
    case "$class" in
      out-of-scope) continue ;;
      audit-workflow) seen_audit_wf=1 ;;
      *) return 1 ;;
    esac
  done <<< "$changed"

  # The audit workflow must actually be the in-scope change (otherwise this is a
  # pure out-of-scope PR the earlier bypass already cleared) AND its committed
  # bytes must be a verbatim copy of the bundled template. Git stores blobs by
  # content hash, so equal blob SHAs mean byte-identical files. Comparing HEAD's
  # blobs (not the working tree) keeps the check fail-closed against local dirt;
  # a missing file makes rev-parse fail and the merge denies.
  [ "$seen_audit_wf" -eq 1 ] || return 1
  wf_blob=$(git rev-parse "HEAD:${audit_wf}" 2>/dev/null) || return 1
  tmpl_blob=$(git rev-parse "HEAD:${audit_tmpl}" 2>/dev/null) || return 1
  [ "$wf_blob" = "$tmpl_blob" ] || return 1

  return 0
}

# code-audit-frontend clearance: a live refusal for the current digest is
# checked first and is absolute (C6); otherwise any one of the five member
# signals above (marker, trailer, CI status, chore(deps), self-mod-only).
# Reused by both the legacy gate and the member-aware gate below.
frontend_cleared() {
  [ "$frontend_refused" -eq 1 ] && return 1
  clearance_member_cleared "$root" "$frontend_digest" code-audit-frontend && return 0
  check_trailer && return 0
  check_github_status && return 0
  check_chore_deps_pr && return 0
  check_self_mod_only_update_pr && return 0
  return 1
}

# _gate_frontend_disposition_denial: when code-audit-frontend's OWN earned
# digest marker is valid (regardless of whether a trailer/status/bypass signal
# is what ultimately clears the merge), re-verify its disposition sidecar.
# Seed-forward unions a still-open receipt across a digest rotation without
# re-verifying it against the backend, so this hook is the deterministic
# backstop: a filed key whose issue no longer exists, a pending(definitive)
# entry, or a machinery_waived entry recorded against a non-machinery path,
# denies. Fail closed when the marker is valid but its sidecar is
# absent (a valid marker proves nothing about dispositions with no sidecar to
# read). Prints the deny JSON and returns 1 on denial; returns 0 (silent) when
# there is nothing to deny.
_gate_frontend_disposition_denial() {
  clearance_member_cleared "$root" "$frontend_digest" code-audit-frontend || return 0

  local sidecar reason offenders offender_list
  sidecar="$root/.gaia/local/audit/${frontend_digest}.dispositions.json"

  if [ ! -f "$sidecar" ]; then
    reason="PR merge gate: code-audit-frontend's clearance marker is valid for HEAD ${sha:0:12}, but its disposition sidecar (${sidecar}) is absent.

A valid earned marker with no matching sidecar cannot prove its out-of-scope
findings were dispositioned, so this denies rather than assume none exist.
Re-spawn the code-audit-frontend agent on this HEAD so it re-files its
disposition sidecar, then retry gh pr merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."
    jq -n --arg r "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
    return 1
  fi

  command -v disposition_offenders >/dev/null 2>&1 || return 0
  offenders="$(disposition_offenders "$sidecar" 2>/dev/null || true)"
  [ -n "$offenders" ] || return 0

  offender_list=$(printf '%s' "$offenders" | sed 's/^/  - /')
  reason="PR merge gate: code-audit-frontend's disposition sidecar names a finding that does not hold for HEAD ${sha:0:12}.

Offending finding key(s):

${offender_list}

A filed tech-debt issue named in the sidecar no longer exists, a
pending(definitive) entry remains, or a machinery_waived entry names a path that
is not gate machinery. Re-spawn the code-audit-frontend agent on this HEAD so it
re-files the missing disposition, then retry gh pr merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  return 1
}

# --- Dispatch: resolve the Code Audit Team member set for this diff ---------
members=""
if [ -x .gaia/scripts/resolve-audit-members.sh ]; then
  members="$(bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null || true)"
fi

if [ -z "$members" ]; then
  # Zero-match (entire diff out of scope) OR the resolver script is
  # absent/unusable: fall through to the legacy single-signal gate verbatim.
  # NOT an unconditional allow, FC-4's auditable-base is strictly narrower
  # than check_out_of_scope_pr's denylist, so an ownerless-but-in-scope file
  # (root Dockerfile, public/**, ...) still denies here without a marker.
  if frontend_cleared; then
    _gate_frontend_disposition_denial
    exit 0
  fi

  if check_out_of_scope_pr; then
    exit 0
  fi

  reason="PR merge gate: no code-audit-frontend signal for HEAD ${sha:0:12}.
${refusal_note}
None of the accepted signals is present:
  - Local marker:    ${marker} $(marker_state "$marker")
  - Commit trailer:  ${trailer_status:-missing}
  - GitHub CI status: absent or version/digest mismatch
  - chore(deps) PR:  PR title does not match \`chore(deps):\` or \`chore(deps-dev):\`
  - Out-of-scope:    PR changes at least one in-scope path (app/, test/, configs,
                     .github/workflows/), not a wiki/docs/.gaia-config-only diff
  - Self-mod-only:   in-scope change is not a verbatim re-render of the bundled
                     code-review-audit.yml template (adopter edit, extra in-scope
                     path, or missing template)

To unblock:
  1. Spawn the code-audit-frontend agent locally, OR push to the PR branch
     and wait for CI's audit to stamp the GitHub commit status (CI skips
     when the PR modifies the audit workflow file itself, in that case
     only the local audit will satisfy the gate).
  2. Address any Critical/Important findings; commit and push.
  3. Re-spawn the agent on the new HEAD; let it write the marker.
  4. Retry gh pr merge.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: gh pr view <N> --json state, do NOT retry
the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

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
fi

# --- AND-aggregator: require every dispatched member's clearance ------------
#
# A non-empty dispatched set means at least one changed file is owned by a
# Code Audit Team member (FC-2). Every dispatched member must clear:
# code-audit-frontend via frontend_cleared() above, each specialized member
# <m> via its own marker .gaia/local/audit/<digest>.<m>.ok, keyed to that
# member's OWN content digest. A live refusal for a member's current digest is
# checked before its earned marker and is absolute (C6).

all_cleared=1
report=""

# The self-mod-only bypass proves a property of the PR, not of one member: the
# only in-scope changed path is the audit workflow, and its committed bytes are
# a verbatim copy of the bundled template. Any member dispatched under that
# condition is therefore dispatched for that one pinned artifact alone, and a
# reviewer reading it decides nothing a script has not already decided. Resolve
# it once here rather than per member: the predicate is a repo-wide read, and
# every member's answer to it is the same.
self_mod_only=0
check_self_mod_only_update_pr && self_mod_only=1

while IFS= read -r m; do
  [ -n "$m" ] || continue

  member_cleared=0
  if [ "$m" = "code-audit-frontend" ]; then
    m_digest="$frontend_digest"
    m_refused="$frontend_refused"
    frontend_cleared && member_cleared=1
  else
    m_digest="$(member_digest "$m")" || m_digest=""
    m_refused=0
    if [ -n "$m_digest" ] && clearance_member_refused "$root" "$m_digest" "$m"; then
      m_refused=1
    fi
    if [ "$m_refused" -eq 0 ] && [ -n "$m_digest" ]; then
      clearance_member_cleared "$root" "$m_digest" "$m" && member_cleared=1
    fi
    # A live refusal stays absolute (C6): a member that refused this digest is
    # never cleared by the bypass.
    if [ "$m_refused" -eq 0 ] && [ "$member_cleared" -eq 0 ] && [ "$self_mod_only" -eq 1 ]; then
      member_cleared=1
    fi
  fi

  if [ "$member_cleared" -eq 1 ]; then
    report="${report}  - ${m}: CLEARED
"
  else
    all_cleared=0
    if [ "$m_refused" -eq 1 ]; then
      refused_path="$(clearance_refused_path "$root" "$m_digest" "$m")"
      report="${report}  - ${m}: REFUSED (a live refusal exists for this exact content at ${refused_path}; re-spawn the member's agent to address the finding)
"
    elif [ "$m" = "code-audit-frontend" ]; then
      report="${report}  - code-audit-frontend: PENDING
      Local marker:    ${marker} $(marker_state "$marker")
      Commit trailer:  ${trailer_status:-missing}
      GitHub CI status: absent or version/digest mismatch
      chore(deps) PR:  PR title does not match \`chore(deps):\` or \`chore(deps-dev):\`
"
    else
      member_marker=".gaia/local/audit/${m_digest:-<unavailable>}.${m}.ok"
      report="${report}  - ${m}: PENDING (marker ${member_marker} $(marker_state "$member_marker"))
"
    fi
  fi
done <<< "$members"

if [ "$all_cleared" -eq 1 ]; then
  _gate_frontend_disposition_denial
  exit 0
fi

reason="PR merge gate: not every dispatched Code Audit Team member has cleared HEAD ${sha:0:12} (tree ${tree:0:12}).

${report}
To unblock: spawn each PENDING member's agent on HEAD so it writes its marker
(code-audit-frontend writes .gaia/local/audit/${frontend_digest}.ok; each
specialized member writes .gaia/local/audit/<its-own-digest>.<member>.ok, NOT
the frontend digest), then retry gh pr merge. Markers are keyed to each
member's own content digest (the files it owns plus the shared gate
machinery), so an out-of-glob change never invalidates one, and a GAIA-Audit
trailer stamp (an empty commit) never invalidates any either.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: gh pr view <N> --json state, do NOT retry
the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'

exit 0
