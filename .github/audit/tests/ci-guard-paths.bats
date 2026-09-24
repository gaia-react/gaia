#!/usr/bin/env bats
# Terminal-path guard tests for .github/workflows/code-review-audit.yml.
#
# The job's steps are guarded by `if:` expressions over step outputs. Those
# expressions are the merge gate's control flow: the steps they guard write the
# `GAIA-Audit` commit status that .claude/hooks/pr-merge-audit-check.sh gates
# merges on. A guard that fires on a path it should not fires the gate open.
#
# The expressions are not unit-testable through GitHub, so this suite evaluates
# them directly. `eval_guard` translates the GitHub Actions expression subset the
# workflow uses (`steps.<id>.outputs.<name>`, `steps.<id>.outcome`, the status
# functions and the implicit `success()` GitHub adds to a guard naming none,
# single-quoted literals, `==`, `!=`, `&&`, `||`, parentheses) into a bash
# condition list and evaluates it against a scenario's step-output state.
#
# A scenario states every step output the job would hold on one terminal path,
# with the empty string for any step GitHub would have SKIPPED (a skipped step's
# outputs are empty, which is what makes the guards' accumulating prefixes
# meaningful). Each test then asserts the EXACT set of steps that fire. Exact,
# not superset: a collapsed guard that widens fires an extra step, and one that
# narrows drops a step, and only an exact-set assertion catches both.
#
# The scenarios below are the ways the job can conclude. Most stamp a
# `GAIA-Audit` commit status and end with no named terminal step of their own;
# only an aborted audit reaches a step, `Status - audit aborted`, since that is
# the one path with no earlier status write to fall back on.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$WORKFLOW" ] || skip "in-tree workflow absent (adopter clone)"
}

# guarded_steps: names of every step in the job that carries an `if:`, in file
# order. Derived from the YAML rather than hard-coded, so a newly added guarded
# step shows up in the fired-set diff instead of silently escaping the suite.
guarded_steps() {
  awk '
    /^      - name: / {
      name = substr($0, index($0, "name: ") + 6)
      next
    }
    /^        if:/ {
      if (name != "" && name != last) { print name; last = name }
    }
  ' "$WORKFLOW"
}

# extract_guard <step-name>: the step'\''s `if:` expression, newline-joined.
# Handles both the inline form (`if: expr`) and the block form (`if: |`).
extract_guard() {
  awk -v want="$1" '
    /^      - name: / {
      cur = substr($0, index($0, "name: ") + 6)
      instep = (cur == want)
      inif = 0
      next
    }
    !instep { next }
    /^        if: \|[[:space:]]*$/ { inif = 1; next }
    /^        if: / { print substr($0, index($0, "if: ") + 4); next }
    # The block ends at the step'\''s next 8-space key. Test that BEFORE the
    # continuation rule: a wrapped operand is indented deeper than 10 to align
    # under its opening paren, so a continuation rule keyed on exactly 10 spaces
    # silently drops it and truncates the expression.
    inif && /^        [^[:space:]]/ { inif = 0; next }
    inif && /^          / {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      print line
      next
    }
  ' "$WORKFLOW"
}

# eval_guard <expr> <ctx-pair>...: evaluate a GitHub Actions guard expression.
# Each ctx-pair is `<context-ref>=<value>`, e.g.
# `steps.gate.outputs.gated=false`. Any context reference the pairs do not name
# resolves to the empty string, which is what GitHub yields for a skipped step.
# Returns 0 when the guard fires, 1 when it does not.
#
# The job's status is the pseudo-pair `job.failed=true`, which no guard spells:
# it is the state GitHub's status functions read. An expression that calls none
# of them is evaluated as `success() && (<expr>)`, because that is what GitHub
# does with it, and that implicit prefix is why one failed step skips every
# later step that does not ask for failure() or always() by name.
eval_guard() {
  local expr="$1"
  shift

  local pair key value escaped script job_failed
  script=""
  job_failed=""
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    case "$key" in
      job.failed) job_failed="$value"; continue ;;
      failed_at) continue ;;
    esac
    # Escaped for a sed pattern in-process: this runs once per pair per guard,
    # thousands of times a run, and a `sed` fork per key dominated the suite.
    escaped="${key//\\/\\\\}"
    escaped="${escaped//./\\.}"
    escaped="${escaped//\[/\\[}"
    escaped="${escaped//\*/\\*}"
    escaped="${escaped//^/\\^}"
    escaped="${escaped//\$/\\\$}"
    script="${script}s|${escaped}|'${value}'|g;"
  done
  # `job.status` reads the same state as the status functions but is not
  # translated. Refused before anything can short-circuit, so a guard spelling
  # it stops the suite on every path rather than only on the ones it evaluates.
  case "$expr" in
    *job.*)
      printf 'eval_guard: untranslated reference in: %s\n' "$expr" >&2
      return 2
      ;;
  esac
  case "$expr" in
    *'always()'*|*'failure()'*|*'success()'*|*'cancelled()'*) ;;
    *)
      # The implicit success() is false on a failed job, so the whole guard is,
      # and there is nothing left to translate.
      [ "$job_failed" = "true" ] && return 1
      expr="success() && ( ${expr} )"
      ;;
  esac
  # Unnamed references are skipped steps: empty string.
  script="${script}s|steps\\.[A-Za-z0-9_-]*\\.outputs\\.[A-Za-z0-9_]*|''|g;"
  script="${script}s|steps\\.[A-Za-z0-9_-]*\\.outcome|''|g;"
  script="${script}s|always()|'ALWAYS'|g;"
  # A cancelled run is not modelled: cancellation stops the job rather than
  # running a guard, so no scenario here can reach a step on it.
  script="${script}s|cancelled()|'CANCELLED'|g;"
  if [ "$job_failed" = "true" ]; then
    script="${script}s|success()|'NOT'|g;s|failure()|'ALWAYS'|g;"
  else
    script="${script}s|success()|'ALWAYS'|g;s|failure()|'NOT'|g;"
  fi
  # Comparisons become POSIX test commands; `&&`, `||` and parens are already
  # valid bash once the operands are.
  script="${script}s|'\\([^']*\\)'[[:space:]]*==[[:space:]]*'\\([^']*\\)'|[ \"\\1\" = \"\\2\" ]|g;"
  script="${script}s|'\\([^']*\\)'[[:space:]]*!=[[:space:]]*'\\([^']*\\)'|[ \"\\1\" != \"\\2\" ]|g;"
  script="${script}s|'ALWAYS'|[ 1 = 1 ]|g;"
  script="${script}s|'NOT'|[ 1 = 0 ]|g;s|'CANCELLED'|[ 1 = 0 ]|g;"

  local condition
  condition="$( printf '%s' "$expr" | sed "$script" | tr '\n' ' ' )"

  # Any surviving bare word means the translation missed a construct; fail loud
  # rather than evaluating a half-translated expression.
  case "$condition" in
    *steps.*|*github.*)
      printf 'eval_guard: untranslated reference in: %s\n' "$condition" >&2
      return 2
      ;;
  esac

  # A truncated or mistranslated expression is a bash syntax error, and `eval`
  # reports that as a non-zero status indistinguishable from "the guard did not
  # fire". Parse first so a broken translation is status 2 (fatal) rather than a
  # silent false negative that would green this whole suite.
  if ! bash -n -c "$condition" 2>/dev/null; then
    printf 'eval_guard: untranslatable expression: %s\n' "$condition" >&2
    return 2
  fi

  eval "$condition"
}

# all_steps: names of every step in the job, guarded or not, in file order.
all_steps() {
  awk '/^      - name: / { print substr($0, index($0, "name: ") + 6) }' "$WORKFLOW"
}

# ensure_guard_table: build, once per test, a table of every step as
# `<name><TAB><guard>` in file order, the guard joined onto one line (eval_guard
# joins it anyway) and empty for an unguarded step, and point GUARD_TABLE at it.
# The failed-run tests evaluate every step's guard once per failure point, and
# re-parsing the workflow for each of those makes the suite run for minutes.
# Called directly rather than in a command substitution, so the variable lands
# in the caller's shell.
ensure_guard_table() {
  GUARD_TABLE="$BATS_TEST_TMPDIR/guard-table"
  [ -f "$GUARD_TABLE" ] && return 0
  local step
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    printf '%s\t%s\n' "$step" "$( extract_guard "$step" | tr '\n' ' ' | sed 's/ *$//' )"
  done > "$GUARD_TABLE.tmp" <<STEPS
$( all_steps )
STEPS
  mv "$GUARD_TABLE.tmp" "$GUARD_TABLE"
}

# in_list <needle> <newline-list>: exact whole-line membership, in-process.
in_list() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# fired_steps <ctx-pair>...: newline-separated names of every guarded step whose
# `if:` fires under the given state, in file order.
#
# The pseudo-pair `failed_at=<step name>` states that the named step ran and
# failed the job, so every step after it in file order is evaluated with
# `job.failed=true`. Unguarded steps are walked for that purpose only: they are
# never printed, since the fired set is a claim about guards. Naming a step that
# does not exist, or a guarded step that did not fire, is a harness misuse and
# aborts, because a failure the job cannot reach would otherwise read as a
# scenario that simply fired nothing.
fired_steps() {
  local step guard rc failed_at job_failed reached pair
  failed_at=""
  job_failed=""
  reached=no
  for pair in "$@"; do
    case "$pair" in
      failed_at=*) failed_at="${pair#failed_at=}" ;;
    esac
  done
  ensure_guard_table
  if [ -n "$failed_at" ] && ! grep -q -F -- "${failed_at}"$'\t' "$GUARD_TABLE"; then
    printf 'fired_steps: failed_at names no step: %s\n' "$failed_at" >&2
    return 2
  fi
  while IFS=$'\t' read -r step guard; do
    [ -n "$step" ] || continue
    if [ -z "$guard" ]; then
      # Unguarded: it runs whenever the job has not failed yet, and there is
      # one failure per scenario, so reaching it by name is reaching it.
      if [ "$step" = "$failed_at" ]; then
        reached=yes
        job_failed=true
      fi
      continue
    fi
    rc=0
    eval_guard "$guard" "$@" "job.failed=${job_failed}" || rc=$?
    # rc 1 is an honest "did not fire"; anything higher is a harness failure and
    # must abort rather than read as a step that stayed quiet.
    if [ "$rc" -gt 1 ]; then
      printf 'fired_steps: guard evaluation failed for step: %s\n' "$step" >&2
      return 2
    fi
    [ "$rc" -eq 0 ] && printf '%s\n' "$step"
    if [ "$step" = "$failed_at" ]; then
      [ "$rc" -eq 0 ] && reached=yes
      job_failed=true
    fi
  done < "$GUARD_TABLE"
  if [ -n "$failed_at" ] && [ "$reached" != yes ]; then
    printf 'fired_steps: failed_at names a step that never ran: %s\n' "$failed_at" >&2
    return 2
  fi
  return 0
}

# assert_fired <expected-newline-list> <ctx-pair>...
assert_fired() {
  local expected="$1"
  shift
  local actual
  actual="$( fired_steps "$@" )" || return 1
  if [ "$actual" != "$expected" ]; then
    printf 'expected fired set:\n%s\n\nactual fired set:\n%s\n' \
      "$expected" "$actual" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Harness self-checks. A fixture harness that cannot fail proves nothing, so
# these pin that eval_guard actually discriminates.
# ---------------------------------------------------------------------------

@test "harness: eval_guard fires on a satisfied equality" {
  run eval_guard "steps.gate.outputs.gated == 'false'" \
    "steps.gate.outputs.gated=false"
  [ "$status" -eq 0 ]
}

@test "harness: eval_guard does not fire on an unsatisfied equality" {
  run eval_guard "steps.gate.outputs.gated == 'false'" \
    "steps.gate.outputs.gated=true"
  [ "$status" -eq 1 ]
}

@test "harness: eval_guard treats an unnamed reference as a skipped step" {
  # A skipped step's output is the empty string, never 'false'.
  run eval_guard "steps.workflow-self-mod.outputs.self_modified == 'false'"
  [ "$status" -eq 1 ]
}

@test "harness: eval_guard honors != and short-circuits a conjunction" {
  run eval_guard "steps.a.outputs.x != 'true' && steps.b.outputs.y == 'yes'" \
    "steps.a.outputs.x=false" "steps.b.outputs.y=no"
  [ "$status" -eq 1 ]
  run eval_guard "steps.a.outputs.x != 'true' && steps.b.outputs.y == 'yes'" \
    "steps.a.outputs.x=false" "steps.b.outputs.y=yes"
  [ "$status" -eq 0 ]
}

@test "harness: eval_guard evaluates a parenthesized disjunction" {
  run eval_guard "steps.a.outputs.x == 'true' &&
(steps.b.outputs.m == 'true' ||
 steps.b.outputs.p == 'true')" \
    "steps.a.outputs.x=true" "steps.b.outputs.m=false" "steps.b.outputs.p=true"
  [ "$status" -eq 0 ]
  run eval_guard "steps.a.outputs.x == 'true' &&
(steps.b.outputs.m == 'true' ||
 steps.b.outputs.p == 'true')" \
    "steps.a.outputs.x=true" "steps.b.outputs.m=false" "steps.b.outputs.p=false"
  [ "$status" -eq 1 ]
}

@test "harness: every guarded step yields an extractable guard" {
  local step guard count
  count=0
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    guard="$( extract_guard "$step" )"
    if [ -z "$guard" ]; then
      printf 'no guard extracted for: %s\n' "$step" >&2
      return 1
    fi
    count=$(( count + 1 ))
  done <<EOF
$( guarded_steps )
EOF
  # Sanity floor: the job carries many guarded steps; a parser that silently
  # matched nothing would otherwise pass this suite vacuously.
  [ "$count" -ge 20 ]
}

@test "harness: a guard naming no status function carries the implicit success()" {
  run eval_guard "steps.a.outputs.x == 'true'" "steps.a.outputs.x=true"
  [ "$status" -eq 0 ]
  run eval_guard "steps.a.outputs.x == 'true'" "steps.a.outputs.x=true" "job.failed=true"
  [ "$status" -eq 1 ]
}

@test "harness: failure() fires only once the job has failed" {
  run eval_guard "failure() && steps.a.outputs.x != 'true'" "steps.a.outputs.x=false"
  [ "$status" -eq 1 ]
  run eval_guard "failure() && steps.a.outputs.x != 'true'" "steps.a.outputs.x=false" "job.failed=true"
  [ "$status" -eq 0 ]
  run eval_guard "failure() && steps.a.outputs.x != 'true'" "steps.a.outputs.x=true" "job.failed=true"
  [ "$status" -eq 1 ]
}

@test "harness: always() fires on a failed job and job.status is refused" {
  run eval_guard "always()" "job.failed=true"
  [ "$status" -eq 0 ]
  run eval_guard "job.status == 'failure'" "job.failed=true"
  [ "$status" -eq 2 ]
}

@test "harness: failed_at skips every later step and refuses a step that never ran" {
  # Checkout PR head is unguarded and first, so failing there skips every
  # guarded step that carries the implicit success().
  local fired
  fired="$( fired_steps "steps.gate.outputs.gated=false" "failed_at=Checkout PR head" )" || return 1
  grep -qxF 'Check chore-deps title' <<<"$fired" && return 1
  run fired_steps "steps.gate.outputs.gated=true" "failed_at=Run code-review-audit (claude-code-action)"
  [ "$status" -eq 2 ]
  run fired_steps "failed_at=No such step"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Terminal-path scenarios.
#
# Each scenario is the complete step-output state on one way the job concludes.
# A step GitHub would have SKIPPED is named with an empty value, or left unnamed
# (eval_guard resolves an unnamed reference to the empty string either way).
# ---------------------------------------------------------------------------

# scenario_ctx <name>: the scenario'\''s context pairs, one per line.
scenario_ctx() {
  case "$1" in
    gated)
      # No gate label: nothing downstream runs at all.
      printf '%s\n' \
        "steps.gate.outputs.gated=true"
      ;;
    chore-deps)
      printf '%s\n' \
        "steps.gate.outputs.gated=false" \
        "steps.chore-deps.outputs.skip=true"
      ;;
    no-source)
      printf '%s\n' \
        "steps.gate.outputs.gated=false" \
        "steps.chore-deps.outputs.skip=false" \
        "steps.source-changes.outputs.has_source=false"
      ;;
    self-modified)
      printf '%s\n' \
        "steps.gate.outputs.gated=false" \
        "steps.chore-deps.outputs.skip=false" \
        "steps.source-changes.outputs.has_source=true" \
        "steps.workflow-self-mod.outputs.self_modified=true"
      ;;
    stand-down)
      printf '%s\n' \
        "steps.gate.outputs.gated=false" \
        "steps.chore-deps.outputs.skip=false" \
        "steps.source-changes.outputs.has_source=true" \
        "steps.workflow-self-mod.outputs.self_modified=false" \
        "steps.decision.outputs.should_run=false"
      ;;
    aborted)
      printf '%s\n' \
        "steps.gate.outputs.gated=false" \
        "steps.chore-deps.outputs.skip=false" \
        "steps.source-changes.outputs.has_source=true" \
        "steps.workflow-self-mod.outputs.self_modified=false" \
        "steps.decision.outputs.should_run=true" \
        "steps.config.outputs.push_fixes=true" \
        "steps.audit.outcome=failure" \
        "failed_at=Status - audit aborted"
      ;;
    complete-pushed)
      printf '%s\n' \
        "steps.gate.outputs.gated=false" \
        "steps.chore-deps.outputs.skip=false" \
        "steps.source-changes.outputs.has_source=true" \
        "steps.workflow-self-mod.outputs.self_modified=false" \
        "steps.decision.outputs.should_run=true" \
        "steps.config.outputs.push_fixes=true" \
        "steps.audit.outcome=success" \
        "steps.push-fixes.outputs.pushed=true" \
        "steps.push-fixes.outputs.marker_only=false"
      ;;
    complete-clean)
      printf '%s\n' \
        "steps.gate.outputs.gated=false" \
        "steps.chore-deps.outputs.skip=false" \
        "steps.source-changes.outputs.has_source=true" \
        "steps.workflow-self-mod.outputs.self_modified=false" \
        "steps.decision.outputs.should_run=true" \
        "steps.config.outputs.push_fixes=true" \
        "steps.audit.outcome=success" \
        "steps.push-fixes.outputs.pushed=false" \
        "steps.push-fixes.outputs.marker_only=false"
      ;;
    *)
      printf 'scenario_ctx: unknown scenario: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

# The failed-run backstop: the one writer that runs after a failure rather than
# on a terminal path of its own.
BACKSTOP="Write GAIA-Audit commit status (failed run)"

SCENARIOS="gated chore-deps no-source self-modified stand-down aborted complete-pushed complete-clean"

# phase_step_body: the "Resolve audit phase" step's `run:` block, dedented to a
# runnable script. Matches the `- name:` line exactly and stops at the next one.
phase_step_body() {
  local out="$BATS_TEST_TMPDIR/phase-step.sh"
  awk '
    !grab && $0 == "      - name: Resolve audit phase" { grab = 1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun = 1; next }
    inrun { print }
  ' "$WORKFLOW" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

# reached_audit <gated> <has_source> <self_modified>
#
# The audit-phase precondition the guards below read, obtained by EXECUTING the
# workflow step that computes it. A hand-written mirror of that block would pin
# only the shape a structural test can see -- its inputs and its two output
# literals -- and not the condition choosing between them, so dropping a clause
# from the real step would leave every scenario below green. Running the step's
# own shell removes the second copy that could drift.
#
# The step's inputs are exported the way the runner supplies them: always
# defined, empty when the upstream step was skipped, which is what lets the
# fail-closed cases below exercise the real `set -eu` body rather than a
# stand-in.
reached_audit() {
  local body out
  body="$( phase_step_body )" || return 1
  out="$BATS_TEST_TMPDIR/phase-output.txt"
  : > "$out"
  GATED="$1" HAS_SOURCE="$2" SELF_MODIFIED="$3" GITHUB_OUTPUT="$out" \
    bash "$body" || return 1
  sed -n 's/^reached_audit=//p' "$out"
}

# fired_with <pair>...: derive the audit-phase output from the upstream signals
# the pairs declare, then evaluate every guard with it appended.
fired_with() {
  local pair gated has_source self_modified
  gated=""
  has_source=""
  self_modified=""
  for pair in "$@"; do
    case "$pair" in
      steps.gate.outputs.gated=*) gated="${pair#*=}" ;;
      steps.source-changes.outputs.has_source=*) has_source="${pair#*=}" ;;
      steps.workflow-self-mod.outputs.self_modified=*) self_modified="${pair#*=}" ;;
    esac
  done
  fired_steps "$@" \
    "steps.phase.outputs.reached_audit=$( reached_audit "$gated" "$has_source" "$self_modified" )"
}

# fired_in <scenario-name>: the fired set for a named scenario.
fired_in() {
  local name="$1"
  shift
  set --
  while IFS= read -r pair; do
    [ -n "$pair" ] && set -- "$@" "$pair"
  done <<EOF
$( scenario_ctx "$name" )
EOF
  fired_with "$@"
}

# assert_scenario <scenario-name> <expected-newline-list>
assert_scenario() {
  local actual
  actual="$( fired_in "$1" )" || return 1
  if [ "$actual" != "$2" ]; then
    printf 'scenario %s\nexpected:\n%s\n\nactual:\n%s\n' "$1" "$2" "$actual" >&2
    return 1
  fi
}

@test "terminal path: gate label missing" {
  assert_scenario gated ""
}

@test "terminal path: chore-deps PR" {
  assert_scenario chore-deps "Check chore-deps title
Write GAIA-Audit commit status (chore-deps skip)"
}

@test "terminal path: no source changes" {
  assert_scenario no-source "Check chore-deps title
Resolve audit base
Check for source-code changes
Write GAIA-Audit commit status (out-of-scope skip)"
}

@test "terminal path: workflow self-modification" {
  assert_scenario self-modified "Check chore-deps title
Resolve audit base
Check for source-code changes
Check workflow self-modification"
}

@test "terminal path: local-mode stand-down" {
  assert_scenario stand-down "Check chore-deps title
Resolve audit base
Check for source-code changes
Check workflow self-modification
Resolve audit decision
Stand down (local-mode, no override)"
}

@test "terminal path: audit aborted" {
  assert_scenario aborted "Check chore-deps title
Resolve audit base
Check for source-code changes
Check workflow self-modification
Resolve audit decision
Setup pnpm
Setup Node
Install dependencies
Compute audit step timeout
Run code-review-audit (claude-code-action)
Print audit progress breadcrumbs
Status - audit aborted
${BACKSTOP}"
}

@test "terminal path: the audit-aborted comment step fails the job" {
  # The aborted scenario states failed_at on this step, and that pair is what
  # fires the backstop there. It is warranted only while the step really ends
  # the job red, so pin the body's own exit.
  local body
  body="$( awk '
    !grab && $0 == "      - name: Status - audit aborted" { grab = 1; next }
    grab && /^      - name: / { exit }
    grab { print }
  ' "$WORKFLOW" )"
  grep -qx '          exit 1' <<<"$body"
}

@test "terminal path: audit complete, self-heal pushed" {
  assert_scenario complete-pushed "Check chore-deps title
Resolve audit base
Check for source-code changes
Check workflow self-modification
Resolve audit decision
Setup pnpm
Setup Node
Install dependencies
Compute audit step timeout
Run code-review-audit (claude-code-action)
Print audit progress breadcrumbs
Commit and push self-heal
Write GAIA-Audit commit status
Re-trigger and stamp required checks on new HEAD"
}

@test "terminal path: audit complete, clean with no push" {
  assert_scenario complete-clean "Check chore-deps title
Resolve audit base
Check for source-code changes
Check workflow self-modification
Resolve audit decision
Setup pnpm
Setup Node
Install dependencies
Compute audit step timeout
Run code-review-audit (claude-code-action)
Print audit progress breadcrumbs
Commit and push self-heal
Write GAIA-Audit commit status (clean, no push)"
}

# ---------------------------------------------------------------------------
# Cross-path invariants. These hold independently of how the guards are spelled,
# so they survive a refactor of the `if:` expressions.
# ---------------------------------------------------------------------------

@test "invariant: the terminal 'Status - ' step fires only on the aborted path" {
  local scenario count fired
  for scenario in $SCENARIOS; do
    # Capture first so a harness abort fails the test rather than being read as
    # a scenario that fired no status step.
    fired="$( fired_in "$scenario" )" || return 1
    count="$( printf '%s\n' "$fired" | grep -c '^Status - ' || true )"
    case "$scenario" in
      aborted) [ "$count" -eq 1 ] || return 1 ;;
      *)       [ "$count" -eq 0 ] || return 1 ;;
    esac
  done
}

@test "invariant: at most one GAIA-Audit status writer fires on every path" {
  local scenario count fired
  for scenario in $SCENARIOS; do
    # Capture first, count second. Piping `fired_in` straight into grep discards
    # its exit status, and the `|| true` the zero-count case needs would then
    # also swallow a harness abort (status 2, no output), leaving count=0 and
    # this assertion vacuously green on a suite that evaluated nothing.
    fired="$( fired_in "$scenario" )" || return 1
    # `|| true` stays on the grep alone: a zero count is a legitimate result
    # here (the gated path posts no GAIA-Audit status at all), and grep exits 1
    # on no match, which would otherwise abort under bats' `set -e`.
    count="$( printf '%s\n' "$fired" \
      | grep -c -e '^Write GAIA-Audit commit status' -e '^Stand down (local-mode' || true )"
    if [ "$count" -gt 1 ]; then
      printf 'scenario %s fired %s GAIA-Audit writers, expected at most 1\n' \
        "$scenario" "$count" >&2
      return 1
    fi
  done
}

@test "invariant: the audit runs on exactly the two complete paths and the abort path" {
  local scenario ran fired
  for scenario in $SCENARIOS; do
    # Capture first: piped, a harness abort yields no output and reads as
    # ran=no, which passes vacuously on every scenario that expects ran=no.
    fired="$( fired_in "$scenario" )" || return 1
    ran=no
    printf '%s\n' "$fired" \
      | grep -qxF 'Run code-review-audit (claude-code-action)' && ran=yes
    case "$scenario" in
      aborted|complete-pushed|complete-clean) [ "$ran" = yes ] || return 1 ;;
      *)                                      [ "$ran" = no ]  || return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Adversarial fixtures for the precondition chain.
#
# The defect these guard against: the audit-phase preconditions are shared by
# many steps, and a site that fails to carry one of them fires on a path it was
# meant to exclude. Because the guarded steps write the `GAIA-Audit` status the
# merge gate reads, that is a gate that fails OPEN.
#
# Each fixture takes the fully-green complete path and breaks exactly ONE
# precondition, then asserts the expensive and status-writing steps all stand
# down. A guard that drops that clause turns the fixture red, which is the point:
# these fail if the chain stops being load-bearing.
#
# `fired_in` appends the override AFTER the scenario'\''s own pair. eval_guard
# builds one sed script in argument order and the first substitution consumes
# the reference, so the scenario'\''s value would win. The overrides below
# therefore break a clause the complete path leaves at its passing value by
# naming a DIFFERENT state each fixture reaches through a distinct reference.
# ---------------------------------------------------------------------------

# assert_stood_down <fired-set>: no expensive step and no status writer fired.
assert_stood_down() {
  local fired="$1" step
  for step in \
    'Run code-review-audit (claude-code-action)' \
    'Commit and push self-heal' \
    'Write GAIA-Audit commit status' \
    'Write GAIA-Audit commit status (clean, no push)' \
    'Re-trigger and stamp required checks on new HEAD'
  do
    if printf '%s\n' "$fired" | grep -qxF "$step"; then
      printf 'step fired on a path it must stand down on: %s\n' "$step" >&2
      return 1
    fi
  done
}

@test "adversarial: gate label missing stands every audit-phase step down" {
  local fired
  fired="$( fired_with \
    "steps.gate.outputs.gated=true" \
    "steps.chore-deps.outputs.skip=false" \
    "steps.source-changes.outputs.has_source=true" \
    "steps.workflow-self-mod.outputs.self_modified=false" \
    "steps.decision.outputs.should_run=true" \
    "steps.config.outputs.push_fixes=true" \
    "steps.audit.outcome=success" \
    "steps.push-fixes.outputs.pushed=true" \
    "steps.push-fixes.outputs.marker_only=false" )" || return 1
  assert_stood_down "$fired"
}

@test "adversarial: no source changes stands every audit-phase step down" {
  local fired
  fired="$( fired_with \
    "steps.gate.outputs.gated=false" \
    "steps.chore-deps.outputs.skip=false" \
    "steps.source-changes.outputs.has_source=false" \
    "steps.workflow-self-mod.outputs.self_modified=false" \
    "steps.decision.outputs.should_run=true" \
    "steps.config.outputs.push_fixes=true" \
    "steps.audit.outcome=success" \
    "steps.push-fixes.outputs.pushed=true" \
    "steps.push-fixes.outputs.marker_only=false" )" || return 1
  assert_stood_down "$fired"
}

@test "adversarial: workflow self-modification stands every audit-phase step down" {
  local fired
  fired="$( fired_with \
    "steps.gate.outputs.gated=false" \
    "steps.chore-deps.outputs.skip=false" \
    "steps.source-changes.outputs.has_source=true" \
    "steps.workflow-self-mod.outputs.self_modified=true" \
    "steps.decision.outputs.should_run=true" \
    "steps.config.outputs.push_fixes=true" \
    "steps.audit.outcome=success" \
    "steps.push-fixes.outputs.pushed=true" \
    "steps.push-fixes.outputs.marker_only=false" )" || return 1
  assert_stood_down "$fired"
}

@test "adversarial: a skipped self-mod check is not read as 'false'" {
  # The self-mod step itself only runs in scope. If it was skipped, its output is
  # the empty string, which must NOT satisfy a `== 'false'` precondition; reading
  # an absent value as a passing one is the fail-open direction.
  local fired
  fired="$( fired_with \
    "steps.gate.outputs.gated=false" \
    "steps.chore-deps.outputs.skip=false" \
    "steps.source-changes.outputs.has_source=true" \
    "steps.workflow-self-mod.outputs.self_modified=" \
    "steps.decision.outputs.should_run=true" \
    "steps.config.outputs.push_fixes=true" \
    "steps.audit.outcome=success" \
    "steps.push-fixes.outputs.pushed=true" \
    "steps.push-fixes.outputs.marker_only=false" )" || return 1
  assert_stood_down "$fired"
}

# ---------------------------------------------------------------------------
# The "Resolve audit phase" step itself.
#
# The guards above now read one derived output, so that derivation is the single
# point where the shared precondition can go wrong. These pin it directly rather
# than only through the fired sets.
# ---------------------------------------------------------------------------

@test "audit phase: reached only when all three preconditions pass" {
  [ "$( reached_audit false true false )" = 'true' ]
}

@test "audit phase: any single failing precondition stands the phase down" {
  [ "$( reached_audit true  true  false )" = 'false' ]
  [ "$( reached_audit false false false )" = 'false' ]
  [ "$( reached_audit false true  true  )" = 'false' ]
}

@test "audit phase: a skipped upstream step never reads as a pass" {
  # Every input empty is what the job holds when the upstream checks were
  # skipped. Fail-closed: an absent value must not satisfy the precondition.
  [ "$( reached_audit '' '' '' )" = 'false' ]
  [ "$( reached_audit false true '' )" = 'false' ]
  [ "$( reached_audit false '' false )" = 'false' ]
  [ "$( reached_audit '' true false )" = 'false' ]
}

@test "audit phase: the workflow step derives from exactly the supplied inputs" {
  # reached_audit() above runs the step's own shell, so the step's LOGIC needs no
  # drift guard. Its INTERFACE still does: the harness supplies three named
  # inputs, and a fourth the harness left unset would abort the step's `set -u`
  # body or, worse, read as a value nothing here varies. Pin the interface so a
  # new input arrives as a failure rather than as untested behavior.
  local block
  block="$( awk '
    /^      - name: Resolve audit phase$/ { inblock = 1 }
    inblock && /^      - name: Resolve audit decision$/ { exit }
    inblock { print }
  ' "$WORKFLOW" )"

  grep -qF 'id: phase' <<<"$block" || return 1
  grep -qF 'GATED: ${{ steps.gate.outputs.gated }}' <<<"$block" || return 1
  grep -qF 'HAS_SOURCE: ${{ steps.source-changes.outputs.has_source }}' <<<"$block" || return 1
  grep -qF 'SELF_MODIFIED: ${{ steps.workflow-self-mod.outputs.self_modified }}' <<<"$block" || return 1
  grep -qF 'reached_audit=true' <<<"$block" || return 1
  grep -qF 'reached_audit=false' <<<"$block" || return 1

  # Exactly three inputs: a fourth would make the mirror above incomplete.
  local env_count
  env_count="$( grep -c '^          [A-Z_]*: \${{' <<<"$block" )"
  [ "$env_count" -eq 3 ]
}

@test "audit phase: the step carries no if:, so its output is always defined" {
  # A guarded phase step would yield an empty output whenever it was skipped,
  # which reads as "did not reach the audit phase". That is the safe direction,
  # but it would also make the step's own guard a second copy of the chain it
  # exists to remove.
  local guard
  guard="$( extract_guard 'Resolve audit phase' )"
  [ -z "$guard" ]
}

# ---------------------------------------------------------------------------
# Failed runs.
#
# Every guard above carries GitHub's implicit success(), so one failed step
# skips every later writer and the job ends with no GAIA-Audit status at all.
# GAIA-Audit is a required context, so that strands the pull request on a check
# that never arrives. The backstop is the one step that runs after a failure.
# ---------------------------------------------------------------------------

# scenario_pairs_without_failure <scenario>: the scenario's pairs minus its own
# failed_at, one per line, so a caller can model a different failure point.
scenario_pairs_without_failure() {
  scenario_ctx "$1" | grep -v '^failed_at=' || true
}

# fired_after_failure <scenario> <step>: the fired set when <step> fails on
# <scenario>'s path.
fired_after_failure() {
  local name="$1" step="$2" pair
  set --
  while IFS= read -r pair; do
    [ -n "$pair" ] && set -- "$@" "$pair"
  done <<PAIRS
$( scenario_pairs_without_failure "$name" )
PAIRS
  fired_with "$@" "failed_at=${step}"
}

# steps_run_on <scenario>: every step that runs on the scenario's path with no
# failure anywhere: each unguarded step, plus each guarded step that fires.
steps_run_on() {
  local name="$1" fired pair step guard
  set --
  while IFS= read -r pair; do
    [ -n "$pair" ] && set -- "$@" "$pair"
  done <<PAIRS
$( scenario_pairs_without_failure "$name" )
PAIRS
  fired="$( fired_with "$@" )" || return 1
  ensure_guard_table
  while IFS=$'\t' read -r step guard; do
    [ -n "$step" ] || continue
    if [ -z "$guard" ] || in_list "$step" "$fired"; then
      printf '%s\n' "$step"
    fi
  done < "$GUARD_TABLE"
}

@test "failed run: the backstop is the only step after a failure at any step that runs" {
  # Derived per element: every non-gated scenario, every step that runs on it.
  # A step's failure must leave the steps before it as they were and fire
  # exactly the backstop after it. The gated path is excluded here because it
  # fires no guarded step at all, so it has no step whose failure this test
  # could drive.
  local scenario step fired ran expected s guard pos_seen count
  # bats traces every simple command through an inherited DEBUG trap, which
  # costs more than the evaluation itself across this many failure points: with
  # it this one test runs for well over a minute, without it for seconds.
  # Assertions here fail by explicit return, so the trap's line tracking is all
  # that is given up.
  trap - DEBUG
  set +T
  count=0
  for scenario in $SCENARIOS; do
    [ "$scenario" = gated ] && continue
    ensure_guard_table
    ran="$( steps_run_on "$scenario" )" || return 1
    [ -n "$ran" ] || { printf 'no steps run on %s\n' "$scenario" >&2; return 1; }
    while IFS= read -r step; do
      [ -n "$step" ] || continue
      [ "$step" = "$BACKSTOP" ] && continue
      fired="$( fired_after_failure "$scenario" "$step" )" || return 1
      # The guarded steps that ran up to and including the failed one, in file
      # order, then the backstop.
      expected=""
      pos_seen=no
      while IFS=$'\t' read -r s guard; do
        [ -n "$s" ] || continue
        [ "$pos_seen" = yes ] && break
        if [ -n "$guard" ] && in_list "$s" "$ran"; then
          expected="${expected}${s}"$'\n'
        fi
        [ "$s" = "$step" ] && pos_seen=yes
      done < "$GUARD_TABLE"
      expected="${expected}${BACKSTOP}"
      if [ "$fired" != "$expected" ]; then
        printf 'scenario %s, failed at %s\nexpected:\n%s\n\nactual:\n%s\n' \
          "$scenario" "$step" "$expected" "$fired" >&2
        return 1
      fi
      count=$(( count + 1 ))
    done <<RAN
$ran
RAN
  done
  # Non-vacuity floor: the non-gated paths share a long unguarded prefix, so a
  # derivation that silently shrank would fall far below this.
  [ "$count" -ge 40 ]
}

@test "failed run: the backstop never fires on a scenario that does not fail" {
  local scenario fired checked
  checked=0
  for scenario in $SCENARIOS; do
    scenario_ctx "$scenario" | grep -q '^failed_at=' && continue
    fired="$( fired_in "$scenario" )" || return 1
    grep -qxF -- "$BACKSTOP" <<<"$fired" && return 1
    checked=$(( checked + 1 ))
  done
  [ "$checked" -gt 0 ]
}
