#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until proof of a passing
# code-review-audit exists for the current HEAD. Three signals and one
# bypass are accepted:
#
#   1. Local marker file at .gaia/local/audit/<sha>.ok, written by the
#      audit agent at the end of a clean local review.
#
#   2. GAIA-Audit trailer on HEAD's commit message, when the trailer's
#      tree-sha matches HEAD's current tree. Written by a local audit run
#      via .claude/hooks/audit-stamp-trailer.sh.
#
#   3. GAIA-Audit GitHub commit status on HEAD, description "<version> <tree>",
#      when both version and tree-sha match. CI stamps this status instead of
#      pushing an empty marker commit (pushing it would re-trigger CI and leave
#      the PR HEAD without check runs). Queried via `gh api` using GH_TOKEN or
#      the ambient gh auth session.
#
#   4. chore(deps) PR bypass: PR title matches `^chore\(deps(-dev)?\):`. The
#      /update-deps wrapper runs the full quality gate locally before
#      pushing, so the audit signal is implicit for this PR class. Mirrors
#      the same narrowing applied to code-review-audit.yml, tests.yml, and
#      chromatic.yml, all four surfaces skip together on chore(deps) PRs.
#
#   5. Out-of-scope bypass: every file the PR changes (vs its merge base with
#      the default branch) lives on a surface outside audit scope, wiki,
#      instruction files (.claude / .specify), .gaia metadata, prose docs, and
#      root-level markdown. These mirror the surfaces code-review-audit.yml
#      treats as out of scope via its `has_source` check, so the agent has no
#      rules that apply and there is nothing to audit. Evaluated fail-closed:
#      any in-scope path (app/, test/, configs, .github/workflows/) makes the
#      marker mandatory again, so a PR that changes auditable source can never
#      reach this branch, it cannot mask an audit that withheld its marker
#      over unresolved findings. Pure local git; works even when the repo's
#      installed code-review-audit.yml predates the out-of-scope status stamp
#      (or CI is absent), which is the case on clones that enabled CI before
#      the stamp step existed.
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
#      Stricter than signal 5 and fail-closed: exactly one in-scope path, it
#      must be the audit workflow, and git-blob identity must prove its bytes
#      equal the template; any other in-scope path, an absent template, or a
#      non-matching byte falls through to deny.
#
# Signals 1-4 prove the audit ran against this content and the agent saw no
# Critical Issues and no unresolved Important Issues; signals 5-6 prove there is
# nothing in audit scope to review (5: the whole diff is out of scope; 6: the
# one in-scope path is a verbatim re-render of GAIA's audit-workflow template).
# Without one, the hook denies the gh pr merge call. To unblock:
#   1. Spawn the code-review-audit agent on the current branch, OR push to the
#      PR branch and wait for CI's audit to stamp the GitHub commit status (CI
#      skips when the PR modifies the audit workflow file itself, in that case
#      only the local audit will satisfy the gate).
#   2. Address any findings; commit and push.
#   3. Re-spawn the agent on the new HEAD; let it write the marker.
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

# Resolve HEAD SHA. If we cannot (no git, detached state we can't read),
# fall back to permissive: this hook only enforces in repos where git answers.
sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$sha" ]; then
  exit 0
fi

marker=".gaia/local/audit/${sha}.ok"
if [ -f "$marker" ]; then
  exit 0
fi

# Trailer fallback: accept a GAIA-Audit trailer on HEAD when its tree-sha
# matches HEAD's current tree. The trailer format (per audit-stamp-trailer.sh)
# is "GAIA-Audit: <version> <tree-sha>", two space-separated fields after the
# colon. Tree-sha equality is the load-bearing check: identical trees mean
# identical content, so an audit on a different commit-sha but the same tree
# is auditing the same code being merged.
trailer_line=$(git log -1 --format='%B' HEAD 2>/dev/null \
  | git interpret-trailers --parse 2>/dev/null \
  | grep -E '^GAIA-Audit:' \
  | head -1)
trailer_status="missing"
if [ -n "$trailer_line" ]; then
  trailer_tree=$(printf '%s' "$trailer_line" | awk '{print $NF}')
  head_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)
  if [ -n "$trailer_tree" ] && [ -n "$head_tree" ] && [ "$trailer_tree" = "$head_tree" ]; then
    exit 0
  fi
  trailer_status="present but tree-sha mismatch (audit was for a different tree)"
fi

# GitHub commit status fallback: CI stamps a GAIA-Audit commit status instead
# of pushing an empty marker commit (pushing it would re-trigger CI and leave
# the PR HEAD without check runs). Query the API for a matching status on HEAD.
# Description shape: "<version> <40-hex-tree>". Both must match .gaia/VERSION
# and HEAD's tree. Falls through silently on any error (no gh, no token, no
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
  cur_version=""
  if [ -f ".gaia/VERSION" ]; then
    cur_version=$(tr -d '\r' < ".gaia/VERSION" | awk 'NF{print; exit}')
    cur_version="${cur_version#"${cur_version%%[![:space:]]*}"}"
    cur_version="${cur_version%"${cur_version##*[![:space:]]}"}"
  fi
  [ -n "$cur_version" ] || return 1

  cur_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)
  [ -n "$cur_tree" ] || return 1

  status_desc=$(gh api \
    "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | first | .description' \
    2>/dev/null || true)

  [ -n "$status_desc" ] && [ "$status_desc" != "null" ] || return 1

  status_version=$(printf '%s' "$status_desc" | awk '{print $1}')
  status_tree=$(printf '%s' "$status_desc" | awk '{print $2}')

  [ -n "$status_version" ] && [ -n "$status_tree" ] || return 1
  [ "$status_version" = "$cur_version" ] || return 1
  [ "$status_tree" = "$cur_tree" ] || return 1

  return 0
}

if check_github_status; then
  exit 0
fi

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

if check_chore_deps_pr; then
  exit 0
fi

# Out-of-scope bypass: accept the merge when every file this PR changes lives
# on a surface outside audit scope. The agent has no rules that apply to wiki,
# instruction files, .gaia metadata, or prose, so there is nothing to audit and
# no marker is required, the same determination code-review-audit.yml's
# `has_source` check makes when it skips. Keep the out-of-scope set below in
# sync with that check's complement (.github/workflows/code-review-audit.yml).
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

  # First in-scope (or unrecognized) path makes the marker mandatory. `case`
  # globs match across slashes, so `wiki/*` covers `wiki/concepts/foo.md`. The
  # `*/*` arm catches every other nested path (app/, test/, configs in
  # subdirs); the final `*)` catches root-level files that are not markdown
  # (package.json, tsconfig.json, *.config.ts, …).
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      wiki/*|.claude/*|.specify/*|.gaia/*|docs/*) continue ;;
      */*) return 1 ;;
      *.md) continue ;;
      *) return 1 ;;
    esac
  done <<< "$changed"

  return 0
}

if check_out_of_scope_pr; then
  exit 0
fi

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
# not adopter code.
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

  # Classify every changed path. Out-of-scope surfaces are always fine; the ONE
  # permitted in-scope path is the audit workflow itself. Any other in-scope
  # path (app/, test/, configs, a different workflow) denies immediately. The
  # quoted "$audit_wf" arm is a literal match (no globbing) and precedes the
  # catch-all `*/*` arm, so the workflow path is recognized before `*/*` claims
  # it; every other nested path still falls to `*/*` and denies.
  seen_audit_wf=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      wiki/*|.claude/*|.specify/*|.gaia/*|docs/*) continue ;;
      "$audit_wf") seen_audit_wf=1 ;;
      */*) return 1 ;;
      *.md) continue ;;
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

if check_self_mod_only_update_pr; then
  exit 0
fi

reason="PR merge gate: no code-review-audit signal for HEAD ${sha:0:12}.

None of the accepted signals is present:
  - Local marker:    ${marker} (missing)
  - Commit trailer:  ${trailer_status}
  - GitHub CI status: absent or version/tree mismatch
  - chore(deps) PR:  PR title does not match \`chore(deps):\` or \`chore(deps-dev):\`
  - Out-of-scope:    PR changes at least one in-scope path (app/, test/, configs,
                     .github/workflows/), not a wiki/docs/.gaia-only diff
  - Self-mod-only:   in-scope change is not a verbatim re-render of the bundled
                     code-review-audit.yml template (adopter edit, extra in-scope
                     path, or missing template)

To unblock:
  1. Spawn the code-review-audit agent locally, OR push to the PR branch
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
