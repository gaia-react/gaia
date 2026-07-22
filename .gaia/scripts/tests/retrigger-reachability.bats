#!/usr/bin/env bats
# Regression guard for the CI-mode self-heal re-trigger reachability invariant.
#
# When the Code Review Audit runs in `ci` mode and pushes a self-heal commit,
# GitHub's GITHUB_TOKEN recursion guard fires no `pull_request` event for the
# new HEAD, so every required check would be absent and branch protection would
# block the merge forever. code-review-audit.yml compensates by re-dispatching
# the workflows named in `.gaia/audit-ci.yml`'s `retrigger_workflows` and
# stamping each dispatched run's per-JOB conclusion onto the new HEAD.
#
# That closes the loop only when three things hold for every declared-required
# context (.gaia/scripts/verify-required-checks.sh's REQUIRED_CONTEXTS):
#
#   1. its workflow declares `workflow_dispatch:`, or `gh workflow run` cannot
#      dispatch it at all;
#   2. its job's `if:` admits `workflow_dispatch`, or the job skips and the
#      stamp records `skipped`, which does not satisfy a required check;
#   3. its workflow's display name is listed in `retrigger_workflows`, or
#      nothing dispatches it in the first place.
#
# Break any one and a self-heal commit wedges the PR permanently. This is
# latent while the repo runs `default_mode: local`, so nothing else in the PR
# lane would notice the gap; the guard is the only thing that does.
#
# `GAIA-Audit` is exempt: it is a commit STATUS the audit posts about itself,
# not a workflow job, so it has no workflow to dispatch.
#
# Assertion style (.claude/rules/bats-assertions.md): non-final checks use
# POSIX `[ ]`, `grep -q`, or an explicit `return 1`, never a bare `[[ ]]`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
  VERIFY="$REPO_ROOT/.gaia/scripts/verify-required-checks.sh"
  READ_CONFIG="$REPO_ROOT/.gaia/scripts/read-audit-ci-config.sh"
  [ -d "$WORKFLOWS_DIR" ] || skip ".github/workflows not present"
  [ -f "$VERIFY" ] || skip "verify-required-checks.sh not present"
  [ -f "$READ_CONFIG" ] || skip "read-audit-ci-config.sh not present"
}

# ---------------------------------------------------------------------------
# Helpers. Each takes the workflows dir as an argument so the negative test can
# point them at a doctored sandbox copy and prove the assertions are not hollow.
# ---------------------------------------------------------------------------

# Every context `REQUIRED_CONTEXTS` declares, scraped by literal shape.
declared_contexts() {
  sed -n '/^REQUIRED_CONTEXTS=(/,/^)/p' "$VERIFY" \
    | sed -n 's/^  "\([^"]*\)".*$/\1/p'
}

# How many entries the array declares, counted without depending on the quoting
# or indentation the scrape above keys on. Continuation comment lines inside the
# array (the rationale after `Vitest (.gaia/cli)`) start with `#` and are excluded.
declared_entry_count() {
  sed -n '/^REQUIRED_CONTEXTS=(/,/^)/p' "$VERIFY" \
    | sed '1d;$d' \
    | grep -cE '^[[:space:]]*[^#[:space:]]'
}

# Guard the scrape before any assertion loops over it. A cosmetic edit to
# `REQUIRED_CONTEXTS` (single quotes, a different indent, an inline comment
# line) defeats the literal scrape, `declared_contexts` emits nothing, every
# loop below runs zero iterations, and all three tests report green having
# asserted nothing -- on the one invariant whose breakage wedges a pull request
# permanently. Comparing against a shape-independent count catches a partial
# scrape too, not only a total one.
assert_extraction_intact() {
  local got want
  got="$(declared_contexts | grep -c .)"
  want="$(declared_entry_count)"
  [ "$want" -gt 0 ] || { echo "REQUIRED_CONTEXTS declares no entries" >&2; return 1; }
  [ "$got" -eq "$want" ] || {
    echo "scraped ${got} of ${want} REQUIRED_CONTEXTS entries; the array's literal shape changed" >&2
    return 1
  }
}

# Declared-required contexts, minus GAIA-Audit (a commit status, not a job).
required_job_contexts() {
  declared_contexts | grep -vxF -- "GAIA-Audit"
}

# The workflow file declaring a job whose display name is <context>. Both
# extensions, matching the directory scan in verify-required-checks.sh.
workflow_for_context() {
  local dir="$1" ctx="$2" f
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    grep -qxF -- "    name: ${ctx}" "$f" && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# The job block (job-id line through the line before the next job-id line)
# containing the `name: <context>` line.
job_block() {
  local file="$1" ctx="$2"
  # `exit` falls through to END, so the wanted block is emitted there and only
  # there: printing at the job boundary too would duplicate it.
  awk -v want="    name: ${ctx}" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      if (has_name) exit
      block = ""; has_name = 0
    }
    { block = block $0 "\n" }
    $0 == want { has_name = 1 }
    END { if (has_name) printf "%s", block }
  ' "$file"
}

# The job block's top-level `if:` expression, flattened onto one line.
# Empty when the job declares no `if:` (it then runs on every trigger).
job_if_expr() {
  awk '
    /^    if:/ { collecting = 1; expr = expr " " $0; next }
    collecting && /^      [^ ]/ { expr = expr " " $0; next }
    collecting { collecting = 0 }
    END { print expr }
  '
}

# The workflow names `.gaia/audit-ci.yml` tells the audit to re-dispatch, read
# through the repo's own parser so this guard and the workflow never disagree.
retrigger_workflow_names() {
  ( cd "$REPO_ROOT" && bash "$READ_CONFIG" 2>/dev/null ) \
    | sed -n '/^retrigger_workflows<<__GAIA_END__$/,/^__GAIA_END__$/p' \
    | sed '1d;$d'
}

# ---------------------------------------------------------------------------
# 1. Every declared-required context's workflow can be dispatched at all.
# ---------------------------------------------------------------------------

@test "every declared-required context's workflow declares workflow_dispatch" {
  local ctx file gaps=""
  assert_extraction_intact
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    file="$(workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
    if [ -z "$file" ]; then
      gaps="${gaps}${ctx}: no workflow declares this job name"$'\n'
      continue
    fi
    grep -qE '^  workflow_dispatch:' "$file" \
      || gaps="${gaps}${ctx}: $(basename "$file") has no workflow_dispatch: trigger"$'\n'
  done < <(required_job_contexts)

  [ -z "$gaps" ] || { printf '%s' "$gaps" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# 2. The job actually RUNS on a dispatch. A job gated to `pull_request` reports
#    `skipped`, and the stamp mirrors that conclusion onto the self-heal HEAD,
#    where it satisfies nothing.
# ---------------------------------------------------------------------------

@test "every declared-required context's job admits workflow_dispatch in its if:" {
  local ctx file expr gaps=""
  assert_extraction_intact
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    file="$(workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
    [ -n "$file" ] || continue
    expr="$(job_block "$file" "$ctx" | job_if_expr)"
    # No `if:` at all is fine: the job runs on every trigger the workflow declares.
    printf '%s' "$expr" | grep -q '[^[:space:]]' || continue
    # Require the event, and reject a negated mention: a bare token match reads
    # `!= 'workflow_dispatch'` as satisfying the very condition it excludes.
    if printf '%s' "$expr" | grep -qF -- "!= 'workflow_dispatch'"; then
      gaps="${gaps}${ctx}: job if: negates workflow_dispatch ->${expr}"$'\n'
    elif ! printf '%s' "$expr" | grep -qF -- "workflow_dispatch"; then
      gaps="${gaps}${ctx}: job if: excludes workflow_dispatch ->${expr}"$'\n'
    fi
  done < <(required_job_contexts)

  [ -z "$gaps" ] || { printf '%s' "$gaps" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# 2b. The job's own steps have to run too, or the job concludes `success`
#     having done nothing and the audit stamps a vacuously green required check
#     onto the self-heal HEAD.
#
#     This bites only where the job resolves its scope from a step that the
#     dispatch lane skips: `dorny/paths-filter` reads changed files from the
#     pull-request context, so a job that gates it to `pull_request` leaves
#     `steps.filter.outputs.*` empty on a dispatch, and any step gated on that
#     output alone silently skips. A job whose filter is a `run:` step that
#     computes its own base (tests.yml, chromatic.yml) still populates the
#     output on a dispatch and is correctly not subject to this rule.
# ---------------------------------------------------------------------------

# True when the job gates a `dorny/paths-filter` step to `pull_request`, so the
# outputs it produces are unset on the dispatch lane.
job_skips_filter_on_dispatch() {
  local block="$1"
  printf '%s' "$block" | grep -qF -- "dorny/paths-filter" || return 1
  printf '%s' "$block" | grep -qxF -- "        if: github.event_name == 'pull_request'"
}

@test "no required-context job step is gated on a dispatch-skipped filter alone" {
  local ctx file block gaps=""
  assert_extraction_intact
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    file="$(workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
    [ -n "$file" ] || continue
    block="$(job_block "$file" "$ctx")"
    job_skips_filter_on_dispatch "$block" || continue
    while IFS= read -r step_if; do
      [ -n "$step_if" ] || continue
      printf '%s' "$step_if" | grep -qF -- "workflow_dispatch" \
        || gaps="${gaps}${ctx}: step gated on the skipped filter alone ->${step_if}"$'\n'
    done < <(printf '%s' "$block" | grep -F -- "steps.filter.outputs.")
  done < <(required_job_contexts)

  [ -z "$gaps" ] || { printf '%s' "$gaps" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# 3. Something actually dispatches it: the workflow's display name is listed in
#    retrigger_workflows.
# ---------------------------------------------------------------------------

@test "every declared-required context's workflow is listed in retrigger_workflows" {
  local ctx file wf_name names gaps=""
  assert_extraction_intact
  names="$(retrigger_workflow_names)"
  [ -n "$names" ] || { echo "retrigger_workflows resolved empty" >&2; return 1; }

  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    file="$(workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
    [ -n "$file" ] || continue
    wf_name="$(sed -n 's/^name:[[:space:]]*//p' "$file" | head -n1)"
    printf '%s\n' "$names" | grep -qxF -- "$wf_name" \
      || gaps="${gaps}${ctx}: workflow '${wf_name}' absent from retrigger_workflows"$'\n'
  done < <(required_job_contexts)

  [ -z "$gaps" ] || { printf '%s' "$gaps" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Negative: prove the assertions above are not hollow. Strip the
# `workflow_dispatch:` trigger and re-gate the job to `pull_request` in a
# sandbox copy, then re-run both checks against it and require them to catch it.
# cli-tests.yml is the subject because `Vitest (.gaia/cli)` is a declared-
# required context whose absence on a self-heal HEAD blocks the merge.
# ---------------------------------------------------------------------------

@test "negative: a required context's workflow that cannot be dispatched is caught" {
  local sb="$BATS_TEST_TMPDIR/workflows"
  local ctx="Vitest (.gaia/cli)"
  mkdir -p "$sb"
  cp "$WORKFLOWS_DIR"/*.yml "$sb/"

  local subject
  subject="$(workflow_for_context "$sb" "$ctx")"
  [ -n "$subject" ] || { echo "sandbox lost the ${ctx} job" >&2; return 1; }

  grep -v '^  workflow_dispatch:' "$subject" \
    | sed "s/^    if: github.event_name == 'pull_request'.*$/    if: github.event_name == 'pull_request'/" \
    > "$subject.doctored"
  mv "$subject.doctored" "$subject"

  # Trigger gone.
  grep -qE '^  workflow_dispatch:' "$subject" && return 1

  # Job `if:` no longer admits a dispatch.
  local expr
  expr="$(job_block "$subject" "$ctx" | job_if_expr)"
  printf '%s' "$expr" | grep -q '[^[:space:]]' || return 1
  printf '%s' "$expr" | grep -qF -- "workflow_dispatch" && return 1

  return 0
}

# ---------------------------------------------------------------------------
# Negative: a cosmetic reformat of REQUIRED_CONTEXTS defeats the literal scrape.
# Without the extraction guard this empties every loop above and the whole suite
# reports green having asserted nothing, so prove the guard catches it.
# ---------------------------------------------------------------------------

@test "negative: a REQUIRED_CONTEXTS reformat that defeats the scrape is caught" {
  local original="$VERIFY"

  # Same entries, single-quoted: the scrape's `^  "` anchor no longer matches.
  VERIFY="$BATS_TEST_TMPDIR/verify-reformatted.sh"
  sed "s/^  \"\([^\"]*\)\"/  '\1'/" "$original" > "$VERIFY"

  # The scrape goes empty while the shape-independent count still sees entries.
  [ "$(declared_contexts | grep -c .)" -eq 0 ] || { VERIFY="$original"; return 1; }
  [ "$(declared_entry_count)" -gt 0 ] || { VERIFY="$original"; return 1; }

  run assert_extraction_intact
  VERIFY="$original"
  [ "$status" -ne 0 ]
}
