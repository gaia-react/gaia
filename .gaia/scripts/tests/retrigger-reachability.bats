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
#      nothing dispatches it in the first place;
#   4. every job in a dispatched workflow finishes inside the poller's window,
#      or the poller gives up, stamps nothing, and the context is ABSENT on the
#      self-heal HEAD rather than red. A job that hits its own
#      `timeout-minutes` is cancelled and its run still completes, so the
#      poller stamps a failure; a job with no cap inherits the 6-hour runner
#      default and can outlive the poller instead.
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
#
# The negative tests below point `VERIFY` at a doctored copy and restore it on
# every exit path. bats runs each `@test` body in its own subshell and re-runs
# `setup()` before each one, so the reassignment cannot leak between tests. The
# checker sees only the subshell and reports the cross-test leak it implies,
# hence the file-wide suppression on the next line. Keep that line last in this
# block: a following comment opening with the checker's own name parses as a
# second, malformed directive (SC1073) and fails the lint outright.
# shellcheck disable=SC2030,SC2031

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
  VERIFY="$REPO_ROOT/.gaia/scripts/verify-required-checks.sh"
  READ_CONFIG="$REPO_ROOT/.gaia/scripts/read-audit-ci-config.sh"
  AUDIT_WORKFLOW="$WORKFLOWS_DIR/code-review-audit.yml"
  # Margin between the poller's window and the highest cap a dispatched job may
  # declare. `timeout-minutes` bounds a job's EXECUTION, while the poller
  # measures the run's wall clock, so the margin absorbs queue time plus the
  # <=90s the poller spends resolving the dispatched run's id.
  POLLER_MARGIN_MIN=5
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
# or indentation the scrape above keys on. Trailing comments are stripped first,
# so the continuation comment lines inside the array (the rationale after
# `Vitest (.gaia/cli)`) contribute nothing.
#
# Counting TOKENS rather than lines is load-bearing. Two entries sharing one
# line (`  "A" "B"`) is one line but two entries, and the scrape above emits
# only the first of them, so a line count agrees with the partial scrape at 1
# and the guard passes while the second entry goes unguarded by every loop
# below.
#
# All three token shapes count, which is what keeps this shape-independent, the
# property the whole guard rests on. Both quote styles, so the single-quote
# reformat the negative test applies still reports entries here while the
# double-quote scrape empties, which is the disagreement that test requires.
# And bare, unquoted tokens: an unquoted element is valid bash and plausible for
# a single-word context name, and it is invisible to the scrape above, so
# counting only quoted tokens would make the two agree and pass blind on
# exactly the entry no loop below is covering.
#
# `|| true` keeps a zero count a reported failure rather than an opaque one:
# `grep -c` exits 1 on no match, and bats runs each test under `set -e`, so
# without it the caller's assignment aborts the test before it can reach the
# `declares no entries` branch that exists to explain exactly this.
declared_entry_count() {
  sed -n '/^REQUIRED_CONTEXTS=(/,/^)/p' "$VERIFY" \
    | sed '1d;$d' \
    | sed 's/#.*$//' \
    | grep -oE "\"[^\"]*\"|'[^']*'|[^\"'[:space:]]+" \
    | grep -c . || true
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

# The workflow file whose top-level `name:` is <workflow-name>. The retrigger
# knob names workflows by display name, where `workflow_for_context` above
# resolves a JOB's display name.
workflow_for_name() {
  local dir="$1" want="$2" f
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    [ "$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -n1)" = "$want" ] \
      && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# Every job id under the workflow's top-level `jobs:` key. Scoped to that block
# on purpose: `on:`'s trigger keys (`push:`, `pull_request:`, `workflow_dispatch:`)
# share the two-space bare-key shape, so an unscoped scan reads them as jobs and
# then reports three phantom missing timeouts per workflow.
#
# A trailing comment is tolerated on both the `jobs:` key and a job id, because
# YAML allows one and a scrape that silently emits nothing for a workflow is the
# worst failure available here: it drops that workflow from the checks below
# while leaving them green. The caller treats an empty result for a resolved
# file as a gap for the same reason, so a shape this does not anticipate fails
# loudly rather than quietly.
workflow_job_ids() {
  awk '
    /^jobs:[[:space:]]*(#.*)?$/ { in_jobs = 1; next }
    in_jobs && /^[A-Za-z]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      id = $0; sub(/[[:space:]]*(#.*)?$/, "", id); sub(/:$/, "", id); sub(/^  /, "", id)
      print id
    }
  ' "$1"
}

# A job's declared `timeout-minutes`, or empty when it declares none (in which
# case the job inherits the runner's 6-hour default). The job-boundary patterns
# match `workflow_job_ids` above: a scrape that emits an id this one cannot find
# again reports a false "no cap" for a job that declares one.
job_timeout_minutes() {
  awk -v want="$2" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      id = $0; sub(/[[:space:]]*(#.*)?$/, "", id); sub(/:$/, "", id); sub(/^  /, "", id)
      if (in_job) exit
      if (id == want) { in_job = 1 }
      next
    }
    in_job && /^    timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/ {
      v = $0
      sub(/^    timeout-minutes:[[:space:]]*/, "", v)
      sub(/[^0-9].*$/, "", v)
      print v
      exit
    }
  ' "$1"
}

# The longest path through the workflow's `needs:` graph, in minutes, summing
# each job's declared cap along the way.
#
# This, not any single cap, is what has to fit the poller's window: the poller
# waits on the RUN, and a run completes only once every job does, so two jobs
# chained by `needs:` contribute the sum of their caps to the run's worst case
# while two unchained jobs contribute only the larger. Comparing caps one at a
# time would read a 2 + 18 chain and a lone 18 as equally safe.
#
# Jobs with no cap contribute 0 here; the caller reports those separately, so a
# missing cap is never silently priced as free.
workflow_critical_path_minutes() {
  awk '
    /^jobs:[[:space:]]*(#.*)?$/ { in_jobs = 1; next }
    in_jobs && /^[A-Za-z]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      id = $0; sub(/[[:space:]]*(#.*)?$/, "", id); sub(/:$/, "", id); sub(/^  /, "", id)
      cur = id; jobs[++n] = id; cap[id] = 0; needs[id] = ""; collecting = 0
      next
    }
    in_jobs && cur != "" && /^    timeout-minutes:[[:space:]]*[0-9]+/ {
      v = $0; sub(/^    timeout-minutes:[[:space:]]*/, "", v); sub(/[^0-9].*$/, "", v)
      cap[cur] = v + 0
      collecting = 0
      next
    }
    # `needs: [a, b]`
    in_jobs && cur != "" && /^    needs:[[:space:]]*\[/ {
      v = $0; sub(/^    needs:[[:space:]]*\[/, "", v); sub(/\].*$/, "", v)
      gsub(/[[:space:]"'"'"']/, "", v)
      needs[cur] = v
      collecting = 0
      next
    }
    # `needs:` opening a block sequence
    in_jobs && cur != "" && /^    needs:[[:space:]]*(#.*)?$/ { collecting = 1; next }
    # `needs: a`
    in_jobs && cur != "" && /^    needs:[[:space:]]*[^[:space:]]/ {
      v = $0; sub(/^    needs:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/["'"'"']/, "", v)
      needs[cur] = v
      collecting = 0
      next
    }
    collecting && /^      -[[:space:]]*[^[:space:]]/ {
      v = $0; sub(/^      -[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/["'"'"']/, "", v)
      needs[cur] = (needs[cur] == "" ? v : needs[cur] "," v)
      next
    }
    collecting && /^    [^[:space:]]/ { collecting = 0 }
    END {
      if (n == 0) { exit }
      # Relax to a fixed point. n passes settle any acyclic graph of n nodes,
      # and the bound is what keeps a malformed cyclic `needs:` from spinning.
      for (pass = 1; pass <= n; pass++) {
        for (i = 1; i <= n; i++) {
          j = jobs[i]; best = 0
          if (needs[j] != "") {
            cnt = split(needs[j], dep, ",")
            for (k = 1; k <= cnt; k++) {
              if (cost[dep[k]] + 0 > best) best = cost[dep[k]] + 0
            }
          }
          cost[j] = cap[j] + best
        }
      }
      longest = 0
      for (i = 1; i <= n; i++) if (cost[jobs[i]] > longest) longest = cost[jobs[i]]
      print longest
    }
  ' "$1"
}

# The completion-poll window in code-review-audit.yml's `poll_and_stamp`, in
# minutes: iterations x sleep seconds. Derived from the workflow rather than
# restated here so that changing the poller re-derives the ceiling below instead
# of leaving this guard enforcing a number the poller no longer honors.
#
# The loop is identified by the warning it guards, not by position: the same
# file holds a second, shorter poll loop (run-id resolution) whose own warning
# text differs, and anchoring on the message keeps the two from being confused
# if either moves.
poller_window_minutes() {
  awk '
    /seq 1 [0-9]+/ {
      v = $0; sub(/.*seq 1 /, "", v); sub(/[^0-9].*$/, "", v)
      if (v != "") iters = v
    }
    /^[[:space:]]*sleep [0-9]+[[:space:]]*$/ {
      v = $0; sub(/^[[:space:]]*sleep /, "", v); sub(/[^0-9].*$/, "", v)
      if (v != "") slp = v
    }
    /did not complete within/ {
      if (iters != "" && slp != "") { printf "%d\n", (iters * slp) / 60 }
      exit
    }
  ' "$1"
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

# The step block (a `      - ` list item plus its continuation lines) that runs
# `dorny/paths-filter`, or nothing when the job has no such step. Same shape as
# `job_block` above: `exit` at the following item's boundary falls through to
# END, so the wanted block is emitted there and only there.
filter_step_block() {
  printf '%s' "$1" | awk '
    /^      - / {
      if (found) exit
      block = ""
    }
    { block = block $0 "\n" }
    /dorny\/paths-filter/ { found = 1 }
    END { if (found) printf "%s", block }
  '
}

# True when the job gates its `dorny/paths-filter` step to `pull_request`, so the
# outputs it produces are unset on the dispatch lane.
#
# The gate is compared after normalizing away the `${{ }}` wrapper and repeated
# whitespace, because GitHub accepts `if: <expr>` and `if: ${{ <expr> }}` as the
# same condition. Matching one spelling byte-for-byte would silently drop a job
# out of the caller's scope the moment someone rewrote its gate to the other,
# and the caller's loop would then assert nothing about that job's steps while
# still reporting green.
job_skips_filter_on_dispatch() {
  local block gate
  block="$(filter_step_block "$1")"
  [ -n "$block" ] || return 1
  gate="$(printf '%s' "$block" | sed -n 's/^        if:[[:space:]]*//p' | head -n1)"
  gate="$(printf '%s' "$gate" \
    | sed -e 's/\${{//g' -e 's/}}//g' \
          -e 's/[[:space:]][[:space:]]*/ /g' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ "$gate" = "github.event_name == 'pull_request'" ]
}

@test "no required-context job step is gated on a dispatch-skipped filter alone" {
  local ctx file block candidates=0 gaps=""
  assert_extraction_intact
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    file="$(workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
    [ -n "$file" ] || continue
    block="$(job_block "$file" "$ctx")"
    [ -n "$(filter_step_block "$block")" ] && candidates=$(( candidates + 1 ))
    job_skips_filter_on_dispatch "$block" || continue
    while IFS= read -r step_if; do
      [ -n "$step_if" ] || continue
      printf '%s' "$step_if" | grep -qF -- "workflow_dispatch" \
        || gaps="${gaps}${ctx}: step gated on the skipped filter alone ->${step_if}"$'\n'
    done < <(printf '%s' "$block" | grep -F -- "steps.filter.outputs.")
  done < <(required_job_contexts)

  # This test only says something where a required-context job actually runs
  # `dorny/paths-filter`. If the scrape ever stops finding one, the loop above
  # goes vacuous and reports green having examined nothing, which is the same
  # hollow-guard failure `assert_extraction_intact` exists to prevent one level
  # up.
  #
  # Counted through `filter_step_block`, the same helper the detector reads, so
  # a break in that helper shows up here rather than leaving the count at its
  # healthy value while nothing is actually located. Deliberately NOT a count of
  # jobs the detector MATCHED: a job whose filter is gated on something else
  # (chromatic.yml gates its on the chore-deps output) is correctly not a match,
  # so requiring one would fail on a healthy repo.
  [ "$candidates" -gt 0 ] || {
    echo "no required-context job's dorny/paths-filter step was located; this test asserted nothing" >&2
    return 1
  }
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
# 4. Every dispatched workflow finishes inside the poller's window. The poller
#    waits on the RUN, and a run completes only when all of its jobs do, so one
#    uncapped job holds the whole run past the window: the poller logs `did not
#    complete within`, stamps nothing, and every context that run would have
#    supplied is absent on the self-heal HEAD. Absent is strictly worse than red
#    -- a red check is an ordinary failure to re-run, an absent one wedges the
#    merge with no signal -- so the cap is what converts the worse outcome into
#    the ordinary one.
#
#    Two things are checked, because one cap alone does not bound a run: every
#    job must declare a cap at all, and the longest `needs:` chain must total
#    under the ceiling. Jobs chained by `needs:` run in sequence and contribute
#    the SUM of their caps to the run, so a pair capped 5 and 20 is a 25-minute
#    run even though neither job alone reaches the ceiling.
# ---------------------------------------------------------------------------

@test "every retrigger workflow's jobs cap runtime under the self-heal poller window" {
  local window ceiling names wf file id cap here path checked=0 gaps=""

  [ -f "$AUDIT_WORKFLOW" ] || skip "code-review-audit.yml not present"

  window="$(poller_window_minutes "$AUDIT_WORKFLOW")"
  [ -n "$window" ] || {
    echo "could not derive the poll window from $(basename "$AUDIT_WORKFLOW")" >&2
    return 1
  }
  ceiling=$(( window - POLLER_MARGIN_MIN ))
  [ "$ceiling" -gt 0 ] || {
    echo "poll window ${window}m leaves no room for the ${POLLER_MARGIN_MIN}m margin" >&2
    return 1
  }

  names="$(retrigger_workflow_names)"
  [ -n "$names" ] || { echo "retrigger_workflows resolved empty" >&2; return 1; }

  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    file="$(workflow_for_name "$WORKFLOWS_DIR" "$wf")"
    [ -n "$file" ] || {
      gaps="${gaps}${wf}: no workflow file declares this name"$'\n'
      continue
    }
    here=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      here=$(( here + 1 ))
      checked=$(( checked + 1 ))
      cap="$(job_timeout_minutes "$file" "$id")"
      if [ -z "$cap" ]; then
        gaps="${gaps}${wf} / ${id}: no timeout-minutes; inherits the 6-hour runner default"$'\n'
      fi
    done < <(workflow_job_ids "$file")

    # A resolved workflow that yields no jobs is the quietest way this test can
    # stop covering something: it contributes nothing to `gaps`, and the other
    # workflows keep the aggregate `checked` above zero, so the run-wide guard
    # below never notices. Report the per-workflow zero as its own gap.
    if [ "$here" -eq 0 ]; then
      gaps="${gaps}${wf}: job scrape found no jobs in $(basename "$file")"$'\n'
      continue
    fi

    path="$(workflow_critical_path_minutes "$file")"
    if [ -z "$path" ]; then
      gaps="${gaps}${wf}: could not resolve a critical path through $(basename "$file")"$'\n'
    elif [ "$path" -gt "$ceiling" ]; then
      gaps="${gaps}${wf}: longest needs-chain totals ${path}m, past the ${ceiling}m ceiling (${window}m poll window - ${POLLER_MARGIN_MIN}m margin)"$'\n'
    fi
  done < <(printf '%s\n' "$names")

  # Same hollowness concern as everywhere else in this suite: a job scrape that
  # matches nothing runs the loop zero times and reports green.
  [ "$checked" -gt 0 ] || { echo "no jobs examined; the job scrape found nothing" >&2; return 1; }
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

# ---------------------------------------------------------------------------
# Negative: two entries sharing one line. The scrape emits only the first of
# them, so every loop above silently stops covering the second. A line-based
# count agrees with that partial scrape and the guard passes; counting quoted
# tokens is what makes the two disagree.
# ---------------------------------------------------------------------------

@test "negative: two REQUIRED_CONTEXTS entries on one line are caught" {
  local original="$VERIFY" want

  # Derived, not hardcoded: adding a required context is a legitimate change and
  # must not fail this test.
  want="$(declared_entry_count)"
  [ "$want" -gt 1 ] || { echo "need 2+ entries to collapse a pair" >&2; return 1; }

  VERIFY="$BATS_TEST_TMPDIR/verify-collapsed.sh"
  awk '
    /^  "Audit CI Tests"/ { pending = 1; next }
    pending && /^  "Run Chromatic"/ { print "  \"Audit CI Tests\" \"Run Chromatic\""; pending = 0; next }
    { print }
  ' "$original" > "$VERIFY"

  # The doctored array still declares every entry, and the scrape loses one to
  # the shared line. That disagreement is the whole signal.
  [ "$(declared_entry_count)" -eq "$want" ] || {
    VERIFY="$original"
    echo "collapsing a pair changed the token count; the fixture no longer models the defect" >&2
    return 1
  }
  [ "$(declared_contexts | grep -c .)" -eq $(( want - 1 )) ] || {
    VERIFY="$original"
    echo "the scrape did not lose exactly one entry to the shared line" >&2
    return 1
  }

  run assert_extraction_intact
  VERIFY="$original"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Negative: an unquoted entry. Valid bash, and invisible to the scrape's `^  "`
# anchor, so a counter that only recognized quoted tokens would agree with the
# partial scrape and pass while that context went unchecked by every loop above.
# ---------------------------------------------------------------------------

@test "negative: an unquoted REQUIRED_CONTEXTS entry is caught" {
  local original="$VERIFY" want

  want="$(declared_entry_count)"
  [ "$want" -gt 0 ] || { echo "no entries to unquote" >&2; return 1; }

  # Same entries, one of them stripped of its quotes.
  VERIFY="$BATS_TEST_TMPDIR/verify-unquoted.sh"
  sed 's/^  "Distribution Audit"/  Distribution-Audit/' "$original" > "$VERIFY"

  # The entry still counts, and the scrape no longer sees it.
  [ "$(declared_entry_count)" -eq "$want" ] || {
    VERIFY="$original"
    echo "unquoting an entry changed the token count; it is no longer counted" >&2
    return 1
  }
  [ "$(declared_contexts | grep -c .)" -eq $(( want - 1 )) ] || {
    VERIFY="$original"
    echo "the scrape did not lose exactly the unquoted entry" >&2
    return 1
  }

  run assert_extraction_intact
  VERIFY="$original"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Negative: both shapes the timeout assertion exists to catch. A job capped past
# the poller window and a job with no cap at all both leave the poller stamping
# nothing, so prove the scrape reports each rather than reading them as capped.
# ---------------------------------------------------------------------------

@test "negative: a dispatched job with no cap, or one past the window, is caught" {
  local sb="$BATS_TEST_TMPDIR/workflows"
  local window ceiling subject cap

  [ -f "$AUDIT_WORKFLOW" ] || skip "code-review-audit.yml not present"
  mkdir -p "$sb"
  cp "$WORKFLOWS_DIR"/*.yml "$sb/"

  window="$(poller_window_minutes "$AUDIT_WORKFLOW")"
  [ -n "$window" ] || { echo "could not derive the poll window" >&2; return 1; }
  ceiling=$(( window - POLLER_MARGIN_MIN ))

  # Capped past the window.
  subject="$(workflow_for_name "$sb" "Tests")"
  [ -n "$subject" ] || { echo "sandbox lost the Tests workflow" >&2; return 1; }
  sed "s/^    timeout-minutes: [0-9][0-9]*$/    timeout-minutes: $(( ceiling + 40 ))/" \
    "$subject" > "$subject.doctored"
  mv "$subject.doctored" "$subject"
  cap="$(job_timeout_minutes "$subject" "tests")"
  [ -n "$cap" ] || { echo "doctored Tests lost its timeout-minutes" >&2; return 1; }
  [ "$cap" -gt "$ceiling" ] || {
    echo "over-cap job not caught: ${cap} is within the ${ceiling}m ceiling" >&2
    return 1
  }

  # No cap at all.
  subject="$(workflow_for_name "$sb" "Chromatic")"
  [ -n "$subject" ] || { echo "sandbox lost the Chromatic workflow" >&2; return 1; }
  grep -v '^    timeout-minutes:' "$subject" > "$subject.doctored"
  mv "$subject.doctored" "$subject"
  [ -z "$(job_timeout_minutes "$subject" "chromatic")" ]
}

# ---------------------------------------------------------------------------
# Negative: a `needs:` chain whose jobs are each individually under the ceiling
# but whose SUM is not. Comparing caps one at a time reads this as safe, which
# is the whole reason the critical path is what gets compared.
# ---------------------------------------------------------------------------

@test "negative: a needs-chain summing past the ceiling is caught" {
  local sb="$BATS_TEST_TMPDIR/chain"
  local subject path

  mkdir -p "$sb"
  subject="$sb/chained.yml"
  cat > "$subject" <<'YAML'
name: Chained
on:
  workflow_dispatch:
jobs:
  first:
    name: First
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - run: echo one
  second:
    name: Second
    needs: first
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - run: echo two
YAML

  # Neither job exceeds a 20m ceiling on its own.
  [ "$(job_timeout_minutes "$subject" "first")" -eq 12 ] || return 1
  [ "$(job_timeout_minutes "$subject" "second")" -eq 12 ] || return 1

  # The chain does.
  path="$(workflow_critical_path_minutes "$subject")"
  [ "$path" -eq 24 ] || {
    echo "expected a 24m critical path, got '${path}'" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Negative: an unparsed workflow must be loud. A trailing comment on `jobs:`
# used to empty the scrape for that one file, which contributed nothing to the
# gap list while the other workflows kept the run-wide counter above zero, so
# uncapped jobs merged under a green test.
# ---------------------------------------------------------------------------

@test "negative: a workflow whose jobs cannot be scraped is caught" {
  local sb="$BATS_TEST_TMPDIR/commented"
  local subject

  mkdir -p "$sb"
  subject="$sb/commented.yml"
  cat > "$subject" <<'YAML'
name: Commented
on:
  workflow_dispatch:
jobs: # the two jobs below
  alpha: # first
    name: Alpha
    timeout-minutes: 7
    runs-on: ubuntu-latest
    steps:
      - run: echo alpha
YAML

  # A trailing comment on either key is legal YAML and must not empty the scrape.
  [ "$(workflow_job_ids "$subject" | grep -c .)" -eq 1 ] || {
    echo "a trailing comment emptied the job scrape" >&2
    return 1
  }
  [ "$(job_timeout_minutes "$subject" "alpha")" -eq 7 ] || return 1

  # And a shape it still cannot read reports zero jobs, which the caller turns
  # into a gap rather than silence.
  printf 'name: Broken\njobs:\n  not-a-job\n' > "$sb/broken.yml"
  [ "$(workflow_job_ids "$sb/broken.yml" | grep -c .)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Negative: the filter-gate detector reads a condition, not one spelling of it.
# Both forms GitHub accepts must match, and an unrelated gate must not, or the
# normalization has widened into a match-anything that would pull jobs whose
# filter does run on a dispatch into the caller's scope.
# ---------------------------------------------------------------------------

@test "negative: both spellings of the filter gate are detected, and others are not" {
  local plain wrapped other

  plain="$(cat <<'YAML'
      - uses: dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d # v4.0.1
        if: github.event_name == 'pull_request'
        id: filter
YAML
)"
  wrapped="$(cat <<'YAML'
      - uses: dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d # v4.0.1
        if: ${{ github.event_name == 'pull_request' }}
        id: filter
YAML
)"
  other="$(cat <<'YAML'
      - uses: dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d # v4.0.1
        if: steps.chore-deps.outputs.skip == 'false'
        id: filter
YAML
)"

  job_skips_filter_on_dispatch "$plain" \
    || { echo "the plain spelling is no longer detected" >&2; return 1; }
  job_skips_filter_on_dispatch "$other" \
    && { echo "an unrelated gate was read as the pull_request gate" >&2; return 1; }
  job_skips_filter_on_dispatch "$wrapped"
}
