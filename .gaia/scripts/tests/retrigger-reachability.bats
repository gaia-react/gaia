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
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The negative tests below point `VERIFY` at a doctored copy and restore it on
# every exit path. bats runs each `@test` body in its own subshell and re-runs
# `setup()` before each one, so the reassignment cannot leak between tests. The
# checker sees only the subshell and reports the cross-test leak it implies,
# hence the file-wide suppression on the next line. Keep that line last in this
# block: a following comment opening with the checker's own name parses as a
# second, malformed directive (SC1073) and fails the lint outright.
# shellcheck disable=SC2030,SC2031

# require_repo_path <test-flag> <path> <label>
#
# The three paths this suite reads are preconditions on CI, not maybes: the job
# that runs it checks the repo out whole, so an absent path there means one of
# them was renamed and this guard silently stopped guarding, or the job is
# misconfigured. So the CI branch FAILS instead of skipping, for the same reason
# `require_yaml_parser` below does: a skip reports `ok ... # skip` and greens the
# job, which would retire every test in this file including the section-0 gate
# that exists to stop exactly that. Only one of the three has a backstop that
# reds loudly on its own (verify-required-checks.yml invokes
# verify-required-checks.sh by path); this arm is what covers the other two.
# Off CI the skip stands: a checkout that legitimately lacks these paths is not
# the environment the guard is making a claim about. Section 0 proves the CI
# branch fires.
require_repo_path() {
  local flag="$1" path="$2" label="$3"
  # `test` rather than `[ ]`: shellcheck parses a bracket test's operator
  # statically and rejects one held in a variable (SC1073/SC1072), while the
  # `test` builtin it does not try to parse resolves the flag at runtime, which
  # is what lets one helper serve both the -d and the -f preconditions.
  if test "$flag" "$path"; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    # No `::error::` prefix: bats prints a test's stderr prefixed with `# `, and
    # Actions parses a workflow command only at column 0, so the annotation that
    # spelling promises would never render. The `return 1` is what gates.
    echo "$label not present on a CI runner; every test here would skip to green. If it moved, update this suite's paths in setup()." >&2
    return 1
  fi
  skip "$label not present"
}

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
  VERIFY="$REPO_ROOT/.gaia/scripts/verify-required-checks.sh"
  READ_CONFIG="$REPO_ROOT/.gaia/scripts/read-audit-ci-config.sh"
  AUDIT_WORKFLOW="$WORKFLOWS_DIR/code-review-audit.yml"
  # Margin between the poller's window and the highest cap a dispatched job may
  # declare, charged **per hop** of a `needs:` chain. `timeout-minutes` bounds a
  # job's EXECUTION, while the poller measures the run's wall clock, so the
  # margin absorbs queue time plus the <=90s the poller spends resolving the
  # dispatched run's id. A chained job queues once per hop, so one flat margin
  # per run would price a two-job chain the same as a single job and leave the
  # second hop's wait uncovered.
  POLLER_MARGIN_MIN=5
  # `|| return 1` on each: only the last of the three is setup()'s final command,
  # so the first two would otherwise lean on `set -e` to propagate. The skip arm
  # exits 0 from inside the helper, so this only ever forwards the CI failure.
  require_repo_path -d "$WORKFLOWS_DIR" ".github/workflows" || return 1
  require_repo_path -f "$VERIFY" "verify-required-checks.sh" || return 1
  require_repo_path -f "$READ_CONFIG" "read-audit-ci-config.sh" || return 1
}

# Helpers. Each takes the workflows dir as an argument so the negative test can
# point them at a doctored sandbox copy and prove the assertions are not hollow.

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

# YAML extraction, python3 + PyYAML.
#
# Workflow structure is parsed rather than scraped. Every shape a line-oriented
# scrape has to be taught one at a time -- a trailing comment on `jobs:` or on a
# job id, a quoted job id, a `needs:` written as a scalar, an inline list, or a
# block sequence at either indentation, a folded `if: >-` whose value spans
# lines -- is a shape a real parser already knows. The scrape surface is
# unbounded; the parser's is not.
#
# What is deliberately NOT parsed this way: `REQUIRED_CONTEXTS` and the poller
# window are bash and shell, not YAML, and the two extraction-guard tests below
# depend on a *literal* scrape disagreeing with a shape-independent count.
#
# Four reads of YAML stay line-oriented as well, and the reason is the same one
# that makes the parser worth it everywhere else. `workflow_for_context` matches
# a job's `    name: <ctx>` at exactly four spaces; `workflow_for_name` and the
# retrigger-listing test read a workflow's top-level `name:` with sed; and the
# dispatch-trigger test greps `^  workflow_dispatch:`. A quoted or
# differently-indented spelling defeats the three `name:` reads, whose value is a
# scalar in every legal YAML shape, so no flow sequence reaches them; an inline
# `on: [push, workflow_dispatch]` is what defeats the trigger grep. All four fail
# CLOSED: the read comes back empty or unmatched, and the context is named as a
# gap by the test that owns that report. For `workflow_for_context` that is the
# dispatch-trigger test in section 1 below; its other three loops `continue` past
# an unresolved context precisely because section 1 already reports it. So a
# narrow scrape costs a false alarm here, never the false green a silent drop-out
# would cost. Parsing buys nothing these four do not already have.

# Gate only the tests that parse YAML, so the REQUIRED_CONTEXTS tests still run
# where PyYAML is absent. On CI the parser is a precondition rather than a maybe:
# audit-ci-tests.yml installs python3-yaml in the same job that runs this suite.
# So the CI branch FAILS instead of skipping. A skip reports `ok ... # skip` and
# greens the job, so a runner that lost that install would retire the 15
# parser-gated tests below in silence -- the hollow-guard failure the rest of
# this file exists to catch, turned on the file itself. Section 0 below proves
# this branch fires. Matches .gaia/tests/lib/lint-yaml.bats, whose own gate also
# accepts a `yq` fallback this one has no equivalent of.
require_yaml_parser() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    # No `::error::` prefix: bats prints a test's stderr prefixed with `# `, and
    # Actions parses a workflow command only at column 0, so the annotation that
    # spelling promises would never render. The `return 1` is what gates.
    echo "no YAML parser (python3 + PyYAML) on a CI runner; the parser-gated tests here would skip to green. Check the apt install in .github/workflows/audit-ci-tests.yml." >&2
    return 1
  fi
  skip "no YAML parser available (python3 + PyYAML)"
}

# yaml_workflow <mode> <file> [arg]
#
# Reads the file's top-level `jobs:` mapping, which a fixture declares too.
#
#   ids                    every job id, one per line
#   cap <job-id>           that job's integer `timeout-minutes`; empty when it
#                          declares none, or declares an expression this guard
#                          cannot evaluate, which the caller reports as no cap
#   path <margin>          the worst needs-chain as "<minutes> <hops>", chosen by
#                          minutes + margin x hops (see below)
#   job-if <job-name>      the job's own `if:`, normalized; empty when unset
#   filter-gate <job-name> `pull_request` when the job's dorny/paths-filter step
#                          is gated to that event, `other` for any other gate,
#                          `none` when the job runs no such step
#   filter-ifs <job-name>  the `if:` of every step gated on steps.filter.outputs.
#
# **Exits 2 when the file will not parse, declares no jobs mapping, or names no
# such job.** A caller must check the status: reading empty output as an answer
# is how an unreadable workflow drops out of a loop while the test stays green.
yaml_workflow() {
  python3 - "$@" <<'PY'
import sys

import yaml

mode, path = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ''


def die(msg):
    sys.stderr.write('%s: %s\n' % (path, msg))
    sys.exit(2)


try:
    with open(path, encoding='utf-8') as handle:
        doc = yaml.safe_load(handle)
except (yaml.YAMLError, OSError) as exc:
    die('unreadable YAML (%s)' % exc.__class__.__name__)

# Strictly the top-level `jobs:` mapping, with no fallback to the document
# itself. A workflow that declares no `jobs:` is not a workflow, and treating its
# root as the job list is the very defect a line-oriented scan had: `on:`'s
# trigger keys sit at the same depth as job ids, so `push`, `pull_request`, and
# `workflow_dispatch` get read as jobs and reported as phantom missing caps.
# (`on:` also resolves to the boolean True as a key, so a workflow's keys are
# never all strings; nothing here may assume otherwise.)
jobs = doc.get('jobs') if isinstance(doc, dict) else None
if not isinstance(jobs, dict) or not jobs:
    die('no jobs mapping')

# Ids round-trip as strings so a `cap` lookup always matches what `ids` emitted:
# a job id that is a YAML boolean or number (`no:`, `2:`) is a legal GitHub id.
jobs = {str(k): (v if isinstance(v, dict) else {}) for k, v in jobs.items()}


def normalize(expr):
    """Collapse a gate to one comparable line.

    GitHub accepts `if: <expr>` and `if: ${{ <expr> }}` as the same condition,
    and a folded scalar arrives already joined but irregularly spaced.
    """
    return ' '.join(str(expr).replace('${{', ' ').replace('}}', ' ').split())


def named(want):
    for jid, job in jobs.items():
        if str(job.get('name', '')) == want:
            return jid, job
    return None, None


def needs_of(jid):
    value = jobs[jid].get('needs')
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def cap_of(jid):
    value = jobs[jid].get('timeout-minutes')
    # bool is an int subclass, and an expression-valued cap arrives as a string.
    # Neither is a number this guard can hold a job to.
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def chain(jid, seen):
    """(minutes, hops) of the worst needs-chain ending at jid.

    Unmemoized on purpose: these graphs hold a handful of jobs, and `seen` alone
    bounds a malformed cyclic `needs:` without a memo that could hand back a
    result computed under a different cycle guard. An uncapped job contributes 0
    minutes and still counts as a hop, so the caller's separate no-cap check is
    what prices it rather than this reading it as free.

    Chains are compared by minutes + margin x hops, not by minutes alone,
    because the ceiling shrinks as hops grow: a 14-minute three-hop chain can
    breach a ceiling that a 20-minute one-hop chain clears, so picking the
    longest chain by minutes would return the safer of the two and miss it.
    """
    best = (0, 0)
    for dep in needs_of(jid):
        if dep not in jobs or dep in seen:
            continue
        candidate = chain(dep, seen | {dep})
        if weigh(candidate) > weigh(best):
            best = candidate
    return (cap_of(jid) or 0) + best[0], best[1] + 1


def weigh(pair):
    return pair[0] + margin * pair[1]


def filter_steps(job):
    return [step for step in job.get('steps') or []
            if isinstance(step, dict)
            and 'dorny/paths-filter' in str(step.get('uses', ''))]


if mode == 'ids':
    print('\n'.join(jobs))
elif mode == 'cap':
    if arg not in jobs:
        die('no job id %r' % arg)
    cap = cap_of(arg)
    if cap is not None:
        print(cap)
elif mode == 'path':
    try:
        margin = int(arg)
    except ValueError:
        die('margin %r is not a number' % arg)
    print('%d %d' % max((chain(jid, {jid}) for jid in jobs), key=weigh))
else:
    jid, job = named(arg)
    if jid is None:
        die('no job named %r' % arg)
    if mode == 'job-if':
        if 'if' in job:
            print(normalize(job['if']))
    elif mode == 'filter-gate':
        steps = filter_steps(job)
        # ANY such step gated to the event, not merely the first. A job whose
        # second paths-filter step carries the gate would otherwise read `other`
        # and the caller would skip the job outright, which is the silent
        # scope-drop this whole test exists to prevent. Failing toward
        # inspecting the job is the safe direction.
        if not steps:
            print('none')
        elif any(normalize(step.get('if', '')) == "github.event_name == 'pull_request'"
                 for step in steps):
            print('pull_request')
        else:
            print('other')
    elif mode == 'filter-ifs':
        for step in job.get('steps') or []:
            gate = str(step.get('if', '')) if isinstance(step, dict) else ''
            if 'steps.filter.outputs.' in gate:
                print(normalize(gate))
    else:
        die('unknown mode %r' % mode)
PY
}

# The job's top-level `if:`, normalized onto one line. Empty when the job
# declares none (it then runs on every trigger the workflow declares). Non-zero
# when the workflow will not parse or names no such job.
job_if_expr() {
  yaml_workflow job-if "$1" "$2"
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

# Every job id under the workflow's top-level `jobs:` key. Scoped to that mapping
# rather than to a line shape, so `on:`'s trigger keys (`push:`,
# `pull_request:`, `workflow_dispatch:`) can never be read as jobs.
#
# Non-zero when the workflow will not parse or declares no jobs mapping. The
# caller turns that into a reported gap: a workflow that silently contributes no
# jobs is the worst failure available here, because it drops out of every check
# below while leaving them green.
workflow_job_ids() {
  yaml_workflow ids "$1"
}

# A job's declared `timeout-minutes`, or empty when it declares none (in which
# case the job inherits the runner's 6-hour default). An expression-valued cap
# reads as empty too: this guard cannot evaluate one, so it reports the job as
# uncapped rather than trusting a number it never saw.
job_timeout_minutes() {
  yaml_workflow cap "$1" "$2"
}

# The ceiling a chain of <hops> hops faces under a <window>-minute poll window.
#
# One definition, called by the assertion AND by the negatives that prove it
# bites. A test that recomputes this arithmetic in its own body asserts only that
# it can do the arithmetic: the production term can be dropped and that test stays
# green, which is exactly what a mutation of the per-hop term found.
chain_ceiling() {
  local window="$1" hops="$2"
  printf '%s' "$(( window - POLLER_MARGIN_MIN * hops ))"
}

# The worst path through the workflow's `needs:` graph, as "<minutes> <hops>".
#
# This, not any single cap, is what has to fit the poller's window: the poller
# waits on the RUN, and a run completes only once every job does, so two jobs
# chained by `needs:` contribute the sum of their caps to the run's worst case
# while two unchained jobs contribute only the larger. Comparing caps one at a
# time would read a 2 + 12 chain and a lone 12 as equally safe.
#
# The hop count comes back with the minutes because the ceiling depends on it:
# `timeout-minutes` bounds a job's EXECUTION, while each hop of a chain also
# waits in the queue, so the margin is charged per hop rather than once per run.
workflow_critical_path() {
  yaml_workflow path "$1" "$POLLER_MARGIN_MIN"
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
#
# The sleep is bound to its own loop: each `seq` clears the pending cadence and
# the FIRST bare `sleep` after it supplies the new one. Reading whichever sleep
# happened to come last before the warning lets an unrelated sleep placed after
# the loop set the cadence, and that is the one mis-derivation that is silent --
# it inflates the window, so every ceiling loosens and the guard reports nothing.
# Every other mis-derivation leaves the cadence unset and this returns empty,
# which the caller reports as a failure to derive the window at all.
poller_window_minutes() {
  awk '
    /seq 1 [0-9]+/ {
      v = $0; sub(/.*seq 1 /, "", v); sub(/[^0-9].*$/, "", v)
      if (v != "") { iters = v; slp = "" }
    }
    /^[[:space:]]*sleep [0-9]+[[:space:]]*$/ {
      v = $0; sub(/^[[:space:]]*sleep /, "", v); sub(/[^0-9].*$/, "", v)
      if (v != "" && slp == "") slp = v
    }
    /did not complete within/ {
      if (iters != "" && slp != "") { printf "%d\n", (iters * slp) / 60 }
      exit
    }
  ' "$1"
}

# 0. This suite's own two gates. Each is a single point where a whole population
#    of tests below can be turned off at once, and on a CI runner each has to
#    FAIL rather than skip. Nothing else in this file would notice if either
#    stopped: weakening one back to a bare `skip` would red nothing, and the
#    affected tests would report `ok ... # skip` and green the job. These two
#    tests are what make that weakening red. Neither is parser-gated itself.
#
#    `require_yaml_parser` gates the 15 parsing tests. `require_repo_path` gates
#    setup(), so every test in the file, and the five tests that additionally read
#    code-review-audit.yml call it again for that path. It covers a gate its own
#    test cannot escape, since setup() runs first here as it does everywhere: what
#    the test catches is the weakening, not the condition.
#
#    Between them these two are the only place this file stands a test down. A
#    bare `skip` anywhere else would be a third gate reporting `ok ... # skip`
#    with nothing watching it.

@test "the parser gate fails on a CI runner and still skips off CI" {
  local shim="$BATS_TEST_TMPDIR/retrigger-no-parser" rc
  mkdir -p "$shim"
  # python3 present, but its `import yaml` fails: the shape a runner takes when
  # python3-yaml is dropped from the apt line, not one where python3 is missing
  # outright. The shebang is absolute so the stripped PATH below cannot affect it.
  printf '#!/bin/sh\nexit 1\n' > "$shim/python3"
  chmod +x "$shim/python3"

  # The shim ALONE is a sufficient PATH: the gate runs no command other than
  # `command -v python3` and that python3. Calling the gate in a subshell is what
  # keeps its `skip` arm from marking this test skipped -- bats' `skip` exits 0,
  # so the subshell's status is exactly the discriminator wanted here: non-zero
  # is the CI failure, 0 is the off-CI skip.
  rc=0
  ( PATH="$shim" GITHUB_ACTIONS=true; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner with no YAML parser; 15 tests would report green" >&2
    return 1
  }

  rc=0
  ( PATH="$shim"; unset GITHUB_ACTIONS; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where a missing parser must still skip" >&2
    return 1
  }
}

# Both arms of the gate for one (flag, path) that must not satisfy it. Calling the
# gate in a subshell is what keeps its `skip` arm from marking the caller skipped --
# bats' `skip` exits 0, so the subshell's status is exactly the discriminator wanted
# here: non-zero is the CI failure, 0 is the off-CI skip.
assert_repo_path_gate() {
  local flag="$1" path="$2" rc

  rc=0
  ( GITHUB_ACTIONS=true; require_repo_path "$flag" "$path" "a renamed path" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner for '$flag $path'; every test here would report green" >&2
    return 1
  }

  rc=0
  ( unset GITHUB_ACTIONS; require_repo_path "$flag" "$path" "a renamed path" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI for '$flag $path', where an unsatisfied precondition must still skip" >&2
    return 1
  }
}

@test "the path precondition gate fails on a CI runner and still skips off CI" {
  mkdir -p "$BATS_TEST_TMPDIR/a-dir"
  : > "$BATS_TEST_TMPDIR/a-file"

  # Absent by construction: $BATS_TEST_TMPDIR is created empty for this test and
  # nothing puts `renamed-away` in it. Both flags, because setup() gates a
  # directory with -d and two scripts with -f.
  assert_repo_path_gate -d "$BATS_TEST_TMPDIR/renamed-away" || return 1
  assert_repo_path_gate -f "$BATS_TEST_TMPDIR/renamed-away" || return 1

  # Present but the wrong type. This pair is what pins the runtime flag: a gate
  # that ignored it and asked only whether the path exists would pass both of
  # these and prove nothing about the -d/-f distinction setup() relies on.
  assert_repo_path_gate -f "$BATS_TEST_TMPDIR/a-dir" || return 1
  assert_repo_path_gate -d "$BATS_TEST_TMPDIR/a-file"
}

# 1. Every declared-required context's workflow can be dispatched at all.

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

# 2. The job actually RUNS on a dispatch. A job gated to `pull_request` reports
#    `skipped`, and the stamp mirrors that conclusion onto the self-heal HEAD,
#    where it satisfies nothing.

@test "every declared-required context's job admits workflow_dispatch in its if:" {
  local ctx file expr gaps=""
  require_yaml_parser
  assert_extraction_intact
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    file="$(workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
    [ -n "$file" ] || continue
    # An unreadable workflow is a gap, never a job that quietly leaves this
    # loop's scope while the test still reports green.
    if ! expr="$(job_if_expr "$file" "$ctx")"; then
      gaps="${gaps}${ctx}: could not read the job's if: from $(basename "$file")"$'\n'
      continue
    fi
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

# How the job gates its `dorny/paths-filter` step: `pull_request` (so the outputs
# it produces are unset on the dispatch lane), `other` for any other gate, or
# `none` when the job runs no such step. Non-zero when the workflow will not
# parse, which the caller must report rather than read as `none`.
#
# The gate is compared after normalizing away the `${{ }}` wrapper and repeated
# whitespace, because GitHub accepts `if: <expr>` and `if: ${{ <expr> }}` as the
# same condition. Matching one spelling byte-for-byte would silently drop a job
# out of the caller's scope the moment someone rewrote its gate to the other,
# and the caller's loop would then assert nothing about that job's steps while
# still reporting green. Parsing rather than scraping extends that to a gate
# written as a folded `if: >-`, whose value a line-oriented read truncates to the
# literal `>-` and can then match against nothing.
job_filter_gate() {
  yaml_workflow filter-gate "$1" "$2"
}

# The `if:` of every step in the job whose own gate reads `steps.filter.outputs.`.
# Keyed on the gate rather than on any mention of the output, so a step that
# merely passes it as an input or an env value is not read as gated on it.
job_filter_dependent_step_ifs() {
  yaml_workflow filter-ifs "$1" "$2"
}

@test "no required-context job step is gated on a dispatch-skipped filter alone" {
  local ctx file gate step_if candidates=0 gaps=""
  require_yaml_parser
  assert_extraction_intact
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    file="$(workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
    [ -n "$file" ] || continue
    # An unreadable gate is reported, never treated as absent. A job that drops
    # out of this loop's scope silently is the failure this whole test is built
    # to avoid, and it looks identical to a job that has no filter step at all.
    if ! gate="$(job_filter_gate "$file" "$ctx")"; then
      gaps="${gaps}${ctx}: could not read the paths-filter gate in $(basename "$file")"$'\n'
      continue
    fi
    [ "$gate" = "none" ] || candidates=$(( candidates + 1 ))
    [ "$gate" = "pull_request" ] || continue
    while IFS= read -r step_if; do
      [ -n "$step_if" ] || continue
      printf '%s' "$step_if" | grep -qF -- "workflow_dispatch" \
        || gaps="${gaps}${ctx}: step gated on the skipped filter alone ->${step_if}"$'\n'
    done < <(job_filter_dependent_step_ifs "$file" "$ctx")
  done < <(required_job_contexts)

  # This test only says something where a required-context job actually runs
  # `dorny/paths-filter`. If the extraction ever stops finding one, the loop above
  # goes vacuous and reports green having examined nothing, which is the same
  # hollow-guard failure `assert_extraction_intact` exists to prevent one level
  # up.
  #
  # Counted through `job_filter_gate`, the same helper the detector reads, so a
  # break in that helper shows up here rather than leaving the count at its
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

# 3. Something actually dispatches it: the workflow's display name is listed in
#    retrigger_workflows.

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
#    job must declare a cap at all, and the worst `needs:` chain must total under
#    the ceiling. Jobs chained by `needs:` run in sequence and contribute the SUM
#    of their caps to the run, so a pair capped 5 and 20 is a 25-minute run even
#    though neither job alone reaches the ceiling.
#
#    The ceiling is charged per hop, because the cap bounds a job's EXECUTION
#    while each hop of a chain also waits in the queue. A workflow's own hop
#    count therefore sets its ceiling: one job clears at 20m under a 25m window,
#    while a two-job chain has to fit 15m.

# Every timeout gap the workflow named <workflow-name> presents under a
# <window>-minute poll window, one line per gap, empty when it has none.
#
# The decisions live here rather than inline in the test body because bats cannot
# call one test's body from another. A predicate written inline is executed only
# against the healthy repo, where every branch it can take is the passing one, so
# neutering any of them leaves the suite green; from a helper a negative can
# drive each gap shape against a sandbox that actually has it.
workflow_timeout_gaps() {
  local dir="$1" wf="$2" window="$3"
  local file id cap path minutes hops ceiling here=0 gaps=""

  file="$(workflow_for_name "$dir" "$wf")"
  if [ -z "$file" ]; then
    printf '%s: no workflow file declares this name\n' "$wf"
    return 0
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    here=$(( here + 1 ))
    cap="$(job_timeout_minutes "$file" "$id")"
    [ -n "$cap" ] \
      || gaps="${gaps}${wf} / ${id}: no timeout-minutes; inherits the 6-hour runner default"$'\n'
  done < <(workflow_job_ids "$file")

  # A resolved workflow that yields no jobs is the quietest way this check stops
  # covering something: it contributes nothing to the gap list while every other
  # workflow keeps the run looking healthy. Report the per-workflow zero itself.
  #
  # The critical-path arm below cannot fire today, and is kept rather than
  # dropped: reaching it requires `here` above zero, which means `ids` already
  # parsed this file, and `path` re-reads it behind the same parse and
  # jobs-mapping guards. It is the arm that starts reporting if those two modes
  # ever stop agreeing, and its absence would leave `path` unset in that case.
  # Being unreachable is also why no negative drives it.
  if [ "$here" -eq 0 ]; then
    gaps="${gaps}${wf}: found no jobs in $(basename "$file")"$'\n'
  elif ! path="$(workflow_critical_path "$file")"; then
    gaps="${gaps}${wf}: could not resolve a critical path through $(basename "$file")"$'\n'
  else
    minutes="${path% *}"
    hops="${path#* }"
    ceiling="$(chain_ceiling "$window" "$hops")"
    [ "$minutes" -le "$ceiling" ] \
      || gaps="${gaps}${wf}: worst needs-chain totals ${minutes}m over ${hops} hop(s), past the ${ceiling}m ceiling (${window}m poll window - ${POLLER_MARGIN_MIN}m margin x ${hops})"$'\n'
  fi

  printf '%s' "$gaps"
}

@test "every retrigger workflow's jobs cap runtime under the self-heal poller window" {
  local window names wf gaps

  require_yaml_parser
  require_repo_path -f "$AUDIT_WORKFLOW" "code-review-audit.yml" || return 1

  window="$(poller_window_minutes "$AUDIT_WORKFLOW")"
  [ -n "$window" ] || {
    echo "could not derive the poll window from $(basename "$AUDIT_WORKFLOW")" >&2
    return 1
  }
  [ "$(( window - POLLER_MARGIN_MIN ))" -gt 0 ] || {
    echo "poll window ${window}m leaves no room for the ${POLLER_MARGIN_MIN}m margin" >&2
    return 1
  }

  names="$(retrigger_workflow_names)"
  [ -n "$names" ] || { echo "retrigger_workflows resolved empty" >&2; return 1; }

  gaps="$(
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      workflow_timeout_gaps "$WORKFLOWS_DIR" "$wf" "$window"
    done < <(printf '%s\n' "$names")
  )"

  # No separate "did anything get examined" counter is needed here. A declared
  # name that resolves to no file, and a file that yields no jobs, are each a gap
  # of their own, so an empty result already means every name resolved and every
  # job was priced. A hollow run cannot look like a clean one.
  [ -z "$gaps" ] || { printf '%s\n' "$gaps" >&2; return 1; }
}

# Negative: prove the assertions above are not hollow. Strip the
# `workflow_dispatch:` trigger and re-gate the job to `pull_request` in a
# sandbox copy, then re-run both checks against it and require them to catch it.
# cli-tests.yml is the subject because `Vitest (.gaia/cli)` is a declared-
# required context whose absence on a self-heal HEAD blocks the merge.

@test "negative: a required context's workflow that cannot be dispatched is caught" {
  local sb="$BATS_TEST_TMPDIR/workflows"
  local ctx="Vitest (.gaia/cli)"
  require_yaml_parser
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
  expr="$(job_if_expr "$subject" "$ctx")"
  printf '%s' "$expr" | grep -q '[^[:space:]]' || return 1
  printf '%s' "$expr" | grep -qF -- "workflow_dispatch" && return 1

  return 0
}

# Negative: a job whose `if:` is a folded scalar. A line-oriented read of the
# gate returns the literal `>-`, which matches no condition and no event, so the
# job silently leaves the scope of the two tests that read its gate while both
# keep reporting green. Parsing is what makes the folded and inline spellings the
# same condition, so prove they read identically.

@test "negative: a folded if: is read as its value, not as the fold marker" {
  local sb="$BATS_TEST_TMPDIR/folded"
  local subject inline folded
  require_yaml_parser
  mkdir -p "$sb"

  cat > "$sb/inline.yml" <<'YAML'
jobs:
  probe:
    name: Probe
    if: github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'
YAML
  cat > "$sb/folded.yml" <<'YAML'
jobs:
  probe:
    name: Probe
    if: >-
      github.event_name == 'pull_request' ||
      github.event_name == 'workflow_dispatch'
YAML

  inline="$(job_if_expr "$sb/inline.yml" "Probe")"
  folded="$(job_if_expr "$sb/folded.yml" "Probe")"

  # The fold marker must not survive into the value, and both spellings must
  # yield the same condition, admitting the dispatch the test above requires.
  printf '%s' "$folded" | grep -qF -- '>-' && return 1
  [ "$folded" = "$inline" ] || {
    echo "folded gate read as '${folded}', inline as '${inline}'" >&2
    return 1
  }
  printf '%s' "$folded" | grep -qF -- "workflow_dispatch"
}

# Negative: an unreadable workflow must be loud at every helper that reads one.
# Returning empty output with a zero status is what lets a malformed workflow
# drop out of a loop while the test reports green, so every mode has to fail
# instead. `subject` is valid YAML that is not a workflow, plus a file that does
# not parse at all.

@test "negative: an unparseable or job-less workflow fails every extractor" {
  local sb="$BATS_TEST_TMPDIR/unreadable"
  local file
  require_yaml_parser
  mkdir -p "$sb"

  # Inconsistent indentation: a parse error, not a shape this guard can read.
  printf 'jobs:\n  alpha: 1\n bravo: 2\n' > "$sb/malformed.yml"
  # Parses, but `jobs:` is a scalar rather than a mapping of job ids.
  printf 'name: Broken\njobs:\n  not-a-job\n' > "$sb/scalar.yml"
  # Parses, and declares no jobs at all.
  printf 'name: Empty\non:\n  workflow_dispatch:\n' > "$sb/empty.yml"

  # Every mode, each given an argument it would accept on a healthy workflow, so
  # a non-zero status can only mean the file itself was unreadable.
  for file in "$sb/malformed.yml" "$sb/scalar.yml" "$sb/empty.yml"; do
    run yaml_workflow ids "$file"
    [ "$status" -ne 0 ] || { echo "ids read $(basename "$file")" >&2; return 1; }
    run yaml_workflow path "$file" "$POLLER_MARGIN_MIN"
    [ "$status" -ne 0 ] || { echo "path read $(basename "$file")" >&2; return 1; }
    run yaml_workflow cap "$file" alpha
    [ "$status" -ne 0 ] || { echo "cap read $(basename "$file")" >&2; return 1; }
    run yaml_workflow job-if "$file" Probe
    [ "$status" -ne 0 ] || { echo "job-if read $(basename "$file")" >&2; return 1; }
    run yaml_workflow filter-gate "$file" Probe
    [ "$status" -ne 0 ] || { echo "filter-gate read $(basename "$file")" >&2; return 1; }
    run yaml_workflow filter-ifs "$file" Probe
    [ "$status" -ne 0 ] || { echo "filter-ifs read $(basename "$file")" >&2; return 1; }
  done

  # A workflow that parses fine still fails on a job it does not declare, rather
  # than reporting the empty output that reads as "declares no cap".
  printf 'jobs:\n  alpha:\n    timeout-minutes: 3\n' > "$sb/ok.yml"
  run yaml_workflow cap "$sb/ok.yml" bravo
  [ "$status" -ne 0 ]
}

# Negative: a cosmetic reformat of REQUIRED_CONTEXTS defeats the literal scrape.
# Without the extraction guard this empties every loop above and the whole suite
# reports green having asserted nothing, so prove the guard catches it.

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

# Negative: two entries sharing one line. The scrape emits only the first of
# them, so every loop above silently stops covering the second. A line-based
# count agrees with that partial scrape and the guard passes; counting quoted
# tokens is what makes the two disagree.

@test "negative: two REQUIRED_CONTEXTS entries on one line are caught" {
  local original="$VERIFY" want ctx

  # Derived, not hardcoded: adding a required context is a legitimate change and
  # must not fail this test.
  want="$(declared_entry_count)"
  [ "$want" -gt 1 ] || { echo "need 2+ entries to collapse a pair" >&2; return 1; }

  # The pair the collapse targets has to still be there. Deriving these two by
  # position instead would couple the fixture to array order, which is no better
  # than coupling it to names; what the names cost is a bad diagnostic, so pay
  # for that directly. Without this, renaming either entry makes the collapse a
  # no-op and the failure below blames `declared_contexts` for a regression it
  # does not have.
  for ctx in "Audit CI Tests" "Run Chromatic"; do
    declared_contexts | grep -qxF -- "$ctx" || {
      echo "fixture target '${ctx}' is no longer a declared context; pick another entry" >&2
      return 1
    }
  done

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

# Negative: an unquoted entry. Valid bash, and invisible to the scrape's `^  "`
# anchor, so a counter that only recognized quoted tokens would agree with the
# partial scrape and pass while that context went unchecked by every loop above.

@test "negative: an unquoted REQUIRED_CONTEXTS entry is caught" {
  local original="$VERIFY" want

  want="$(declared_entry_count)"
  [ "$want" -gt 0 ] || { echo "no entries to unquote" >&2; return 1; }

  # Same reason as the collapse test above: without this, renaming the entry
  # makes the sed a no-op and the failure blames the scrape instead of naming the
  # fixture target that moved.
  declared_contexts | grep -qxF -- "Distribution Audit" || {
    echo "fixture target 'Distribution Audit' is no longer a declared context; pick another entry" >&2
    return 1
  }

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

# Negative: both shapes the timeout assertion exists to catch. A job capped past
# the poller window and a job with no cap at all both leave the poller stamping
# nothing, so prove the scrape reports each rather than reading them as capped.

@test "negative: a dispatched job with no cap, or one past the window, is caught" {
  local sb="$BATS_TEST_TMPDIR/workflows"
  local window ceiling subject cap

  require_yaml_parser
  require_repo_path -f "$AUDIT_WORKFLOW" "code-review-audit.yml" || return 1
  mkdir -p "$sb"
  cp "$WORKFLOWS_DIR"/*.yml "$sb/"

  window="$(poller_window_minutes "$AUDIT_WORKFLOW")"
  [ -n "$window" ] || { echo "could not derive the poll window" >&2; return 1; }
  # One hop: the ceiling a lone job faces, which is the loosest one available.
  ceiling="$(chain_ceiling "$window" 1)"

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
  # Status first, emptiness second. `cap` mode exits non-zero with EMPTY stdout
  # when the file names no such job, so reading the substitution alone cannot
  # tell "this job declares no cap" (the shape being asserted) from "there is no
  # such job" (a state that must be rejected). Renaming chromatic.yml's job id
  # would otherwise leave this, the only negative covering the no-cap shape,
  # green while asserting nothing.
  cap="$(job_timeout_minutes "$subject" "chromatic")" || {
    echo "sandbox Chromatic declares no 'chromatic' job id; the fixture no longer models the defect" >&2
    return 1
  }
  [ -z "$cap" ]
}

# Negative: `workflow_timeout_gaps`'s own decisions. Its only other caller reads
# the real repo, where every branch it takes is the healthy one, so each decision
# there can be neutered with the whole suite still green. Drive every gap shape
# here instead, and require a clean workflow to report none, or a reporter that
# returns a constant would satisfy the other four. Four of the five arms, not
# all five: the critical-path arm cannot be reached while `ids` and `path` read
# the same file behind the same guards, which the helper's own comment states.

@test "negative: every timeout gap shape is reported, and a clean workflow reports none" {
  local sb="$BATS_TEST_TMPDIR/gapshapes"
  local window=25 gaps

  require_yaml_parser
  mkdir -p "$sb"

  # A fixed window rather than the derived one: these fixtures assert exact
  # ceiling arithmetic, and deriving the window would make them move with the
  # poller. The derivation has its own negative below.
  cat > "$sb/uncapped.yml" <<'YAML'
name: Uncapped
jobs:
  capped:
    timeout-minutes: 4
  naked:
    runs-on: ubuntu-latest
YAML
  cat > "$sb/chained.yml" <<'YAML'
name: Chained
jobs:
  first:
    timeout-minutes: 12
  second:
    needs: first
    timeout-minutes: 12
YAML
  cat > "$sb/jobless.yml" <<'YAML'
name: Jobless
on:
  workflow_dispatch:
YAML
  cat > "$sb/clean.yml" <<'YAML'
name: Clean
jobs:
  only:
    timeout-minutes: 8
YAML

  # The uncapped job is named; the capped one beside it is not, or the branch is
  # reporting every job rather than the ones that inherit the 6-hour default.
  gaps="$(workflow_timeout_gaps "$sb" "Uncapped" "$window")"
  printf '%s' "$gaps" | grep -qF -- "Uncapped / naked: no timeout-minutes" || {
    echo "the uncapped job went unreported: '${gaps}'" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF -- "Uncapped / capped" && {
    echo "a capped job was reported as a gap: '${gaps}'" >&2
    return 1
  }

  # 12 + 12 over two hops, against the 15m that two hops leave of a 25m window.
  # Neither job breaches the 20m a lone job would face, which is why the chain,
  # not any single cap, is what gets compared.
  gaps="$(workflow_timeout_gaps "$sb" "Chained" "$window")"
  printf '%s' "$gaps" \
    | grep -qF -- "Chained: worst needs-chain totals 24m over 2 hop(s), past the 15m ceiling" || {
    echo "the over-ceiling chain went unreported: '${gaps}'" >&2
    return 1
  }

  # A workflow that declares no jobs drops out of every loop while contributing
  # nothing to the gap list, so it has to report itself.
  gaps="$(workflow_timeout_gaps "$sb" "Jobless" "$window")"
  printf '%s' "$gaps" | grep -qF -- "Jobless: found no jobs in jobless.yml" || {
    echo "a job-less workflow went unreported: '${gaps}'" >&2
    return 1
  }

  # Same for a declared name no file carries: dispatched by name, so an
  # unresolvable one means the retrigger cannot reach it at all.
  gaps="$(workflow_timeout_gaps "$sb" "Absent" "$window")"
  printf '%s' "$gaps" | grep -qF -- "Absent: no workflow file declares this name" || {
    echo "an unresolvable workflow name went unreported: '${gaps}'" >&2
    return 1
  }

  gaps="$(workflow_timeout_gaps "$sb" "Clean" "$window")"
  [ -z "$gaps" ]
}

# Negative: the poll window is derived from the poller, not restated. Nothing
# else executes that derivation against a known input, so replacing it with the
# number it happens to produce today would pass every other test in the suite
# while the ceiling stopped tracking the poller it is meant to follow.

# A stub in the shape `poller_window_minutes` reads: a short run-id loop, then
# the completion loop whose cadence is the answer, then the warning the
# derivation anchors on. 120 x 10s is 20 minutes, deliberately NOT the real
# workflow's 25, so a derivation replaced by a literal fails here.
write_poller_fixture() {
  local variant="$1"
  printf 'poll_and_stamp() {\n  run_id=""\n'
  printf "  for _ in \$(seq 1 18); do\n"
  printf '    if [ -n "$run_id" ]; then break; fi\n    sleep 5\n  done\n'
  printf "  for _ in \$(seq 1 120); do\n"
  printf '    if [ "$status" = completed ]; then break; fi\n'
  if [ "$variant" = "commented-sleep" ]; then
    printf '    sleep 10 # be patient\n'
  else
    printf '    sleep 10\n'
  fi
  printf '  done\n'
  [ "$variant" != "trailing-sleep" ] || printf '  sleep 60\n'
  if [ "$variant" = "reworded-warning" ]; then
    printf '  echo "WARN: run timed out; not stamping" >&2\n'
  else
    printf '  echo "WARN: run did not complete within 20 min; not stamping" >&2\n'
  fi
  printf '}\n'
}

@test "negative: the poll window is derived from the completion loop, not restated" {
  local sb="$BATS_TEST_TMPDIR/poller"
  local got

  mkdir -p "$sb"

  # The run-id loop comes first and is the wrong one to read: its cadence would
  # answer 10 and its iteration count 1, neither of which is 20.
  write_poller_fixture plain > "$sb/plain.sh"
  got="$(poller_window_minutes "$sb/plain.sh")"
  [ "$got" = "20" ] || { echo "derived '${got}' from the stub poller, want 20" >&2; return 1; }

  # A sleep AFTER the completion loop is not that loop's cadence. Reading
  # whichever sleep came last before the warning derives 150 here: a ceiling six
  # times too loose, which reports nothing and is the one silent direction.
  write_poller_fixture trailing-sleep > "$sb/trailing.sh"
  got="$(poller_window_minutes "$sb/trailing.sh")"
  [ "$got" = "20" ] || {
    echo "a sleep after the loop moved the window to '${got}'; want 20" >&2
    return 1
  }

  # The remaining mis-derivations fail closed. An unrecognized sleep line leaves
  # the cadence unset, and a reworded anchor never reaches the arithmetic; both
  # return empty and the caller reports that it could not derive the window,
  # rather than enforcing a wrong one.
  write_poller_fixture commented-sleep > "$sb/commented.sh"
  got="$(poller_window_minutes "$sb/commented.sh")"
  [ -z "$got" ] || { echo "a commented sleep still derived '${got}'" >&2; return 1; }

  write_poller_fixture reworded-warning > "$sb/reworded.sh"
  [ -z "$(poller_window_minutes "$sb/reworded.sh")" ]
}

# Negative: a `needs:` chain whose jobs are each individually under the ceiling
# but whose SUM is not. Comparing caps one at a time reads this as safe, which
# is the whole reason the critical path is what gets compared.
#
# Run over every spelling of `needs:`, because YAML accepts a scalar, an inline
# list, and a block sequence at either the parent key's own indentation or nested
# under it, and all of them parse to the same list. Anchoring on one spelling is
# what let a chain read as the larger single cap instead of the sum.

# A two-job chain, `second` needing `first`, with `needs:` written the named way
# and each job capped at $2 minutes.
write_chain_fixture() {
  local spelling="$1" cap="$2"
  printf 'name: Chained\non:\n  workflow_dispatch:\njobs:\n'
  printf '  first:\n    name: First\n    timeout-minutes: %s\n' "$cap"
  printf '    runs-on: ubuntu-latest\n    steps:\n      - run: echo one\n'
  printf '  second:\n    name: Second\n'
  case "$spelling" in
    scalar)       printf '    needs: first\n' ;;
    inline)       printf '    needs: [first]\n' ;;
    inline-quote) printf '    needs: ["first"]\n' ;;
    block-nested) printf '    needs:\n      - first\n' ;;
    block-flush)  printf '    needs:\n    - first\n' ;;
    block-note)   printf '    needs:\n      - first # the gate\n' ;;
    *) return 1 ;;
  esac
  printf '    timeout-minutes: %s\n    runs-on: ubuntu-latest\n' "$cap"
  printf '    steps:\n      - run: echo two\n'
}

@test "negative: a needs-chain past the ceiling is caught in every needs: spelling" {
  local sb="$BATS_TEST_TMPDIR/chain"
  local spelling subject path minutes hops window ceiling

  require_yaml_parser
  require_repo_path -f "$AUDIT_WORKFLOW" "code-review-audit.yml" || return 1
  mkdir -p "$sb"

  window="$(poller_window_minutes "$AUDIT_WORKFLOW")"
  [ -n "$window" ] || { echo "could not derive the poll window" >&2; return 1; }

  for spelling in scalar inline inline-quote block-nested block-flush block-note; do
    subject="$sb/${spelling}.yml"
    write_chain_fixture "$spelling" 12 > "$subject"

    # Neither job exceeds even the loosest one-hop ceiling on its own.
    [ "$(job_timeout_minutes "$subject" "first")" -eq 12 ] || return 1
    [ "$(job_timeout_minutes "$subject" "second")" -eq 12 ] || return 1

    path="$(workflow_critical_path "$subject")" || {
      echo "${spelling}: could not resolve a critical path" >&2
      return 1
    }
    minutes="${path% *}"
    hops="${path#* }"
    [ "$minutes" -eq 24 ] || {
      echo "${spelling}: expected a 24m chain, got '${minutes}' (from '${path}')" >&2
      return 1
    }
    [ "$hops" -eq 2 ] || {
      echo "${spelling}: expected 2 hops, got '${hops}' (from '${path}')" >&2
      return 1
    }

    ceiling="$(chain_ceiling "$window" "$hops")"
    [ "$minutes" -gt "$ceiling" ] || {
      echo "${spelling}: ${minutes}m over ${hops} hops cleared the ${ceiling}m ceiling" >&2
      return 1
    }
  done
}

# Negative: the per-hop margin is load-bearing, not decorative. A chain can clear
# the flat one-margin-per-run ceiling and still overrun the poller, because every
# hop waits in the queue on its own. Three jobs capped 6 total 18m, inside a flat
# 20m ceiling, and past the 10m that three hops actually leave.

@test "negative: a chain inside the flat ceiling but past its per-hop ceiling is caught" {
  local sb="$BATS_TEST_TMPDIR/perhop"
  local subject path minutes hops window flat ceiling

  require_yaml_parser
  require_repo_path -f "$AUDIT_WORKFLOW" "code-review-audit.yml" || return 1
  mkdir -p "$sb"

  window="$(poller_window_minutes "$AUDIT_WORKFLOW")"
  [ -n "$window" ] || { echo "could not derive the poll window" >&2; return 1; }

  subject="$sb/three-hop.yml"
  cat > "$subject" <<'YAML'
name: ThreeHop
on:
  workflow_dispatch:
jobs:
  first:
    name: First
    timeout-minutes: 6
    runs-on: ubuntu-latest
    steps:
      - run: echo one
  second:
    name: Second
    needs: first
    timeout-minutes: 6
    runs-on: ubuntu-latest
    steps:
      - run: echo two
  third:
    name: Third
    needs: [second]
    timeout-minutes: 6
    runs-on: ubuntu-latest
    steps:
      - run: echo three
YAML

  path="$(workflow_critical_path "$subject")" || {
    echo "could not resolve a critical path" >&2
    return 1
  }
  minutes="${path% *}"
  hops="${path#* }"
  [ "$minutes" -eq 18 ] || { echo "expected an 18m chain, got '${minutes}'" >&2; return 1; }
  [ "$hops" -eq 3 ] || { echo "expected 3 hops, got '${hops}'" >&2; return 1; }

  # A flat margin reads this as safe. That is the defect the per-hop term closes,
  # so if this stops being true the fixture no longer models it.
  flat=$(( window - POLLER_MARGIN_MIN ))
  [ "$minutes" -le "$flat" ] || {
    echo "fixture no longer models the defect: ${minutes}m already breaches the flat ${flat}m ceiling" >&2
    return 1
  }

  ceiling="$(chain_ceiling "$window" "$hops")"
  [ "$minutes" -gt "$ceiling" ] || {
    echo "${minutes}m over ${hops} hops cleared the ${ceiling}m per-hop ceiling" >&2
    return 1
  }
}

# Negative: the worst chain is selected by minutes + margin x hops, not by
# minutes alone. This is the ONLY fixture in the suite where those two rules
# disagree, and without it the selection rule is unguarded: every other fixture
# is a straight line, or a diamond whose longest-in-minutes branch is also its
# longest-in-hops, so both rules return the identical pair on all of them and on
# all five real retrigger workflows. Dropping the margin term from the metric
# then leaves the suite green while a real poller breach goes unreported.
#
# A fan-out is what separates them: a fat 14m single job beside a 3 x 4m chain.
# Selecting by minutes returns `14 1`, which clears a one-hop 20m ceiling and
# reports nothing. Selecting by minutes + margin x hops returns `12 3`, which
# breaches the 10m a three-hop chain actually leaves.

@test "negative: the worst chain is chosen by per-hop weight, not by minutes alone" {
  local sb="$BATS_TEST_TMPDIR/fanout"
  local subject path minutes hops window ceiling

  require_yaml_parser
  require_repo_path -f "$AUDIT_WORKFLOW" "code-review-audit.yml" || return 1
  mkdir -p "$sb"

  window="$(poller_window_minutes "$AUDIT_WORKFLOW")"
  [ -n "$window" ] || { echo "could not derive the poll window" >&2; return 1; }

  subject="$sb/fanout.yml"
  cat > "$subject" <<'YAML'
name: FanOut
on:
  workflow_dispatch:
jobs:
  fat:
    name: Fat
    timeout-minutes: 14
    runs-on: ubuntu-latest
    steps:
      - run: echo fat
  a:
    name: A
    timeout-minutes: 4
    runs-on: ubuntu-latest
    steps:
      - run: echo a
  b:
    name: B
    needs: a
    timeout-minutes: 4
    runs-on: ubuntu-latest
    steps:
      - run: echo b
  c:
    name: C
    needs: b
    timeout-minutes: 4
    runs-on: ubuntu-latest
    steps:
      - run: echo c
YAML

  path="$(workflow_critical_path "$subject")" || {
    echo "could not resolve a critical path" >&2
    return 1
  }
  minutes="${path% *}"
  hops="${path#* }"

  # `14 1` is the minutes-only answer. Asserting the pair, not just the breach,
  # is what makes a metric regression fail here rather than pass quietly.
  [ "$path" = "12 3" ] || {
    echo "worst chain priced '${path}', want '12 3' (minutes-only would say '14 1')" >&2
    return 1
  }

  # The chain the weight selected breaches its ceiling; the fat job would not
  # have. That asymmetry is the whole reason the weight carries the margin term.
  ceiling="$(chain_ceiling "$window" "$hops")"
  [ "$minutes" -gt "$ceiling" ] || {
    echo "${minutes}m over ${hops} hops cleared the ${ceiling}m ceiling" >&2
    return 1
  }
  [ 14 -le "$(chain_ceiling "$window" 1)" ] || {
    echo "fixture no longer models the defect: the fat job breaches its own one-hop ceiling" >&2
    return 1
  }
}

# Negative: the chain walk has to survive a `needs:` graph that is not a simple
# line. A diamond must price the longer branch, a `needs:` naming a job the
# workflow does not declare must not crash or count, and a cyclic `needs:` must
# terminate rather than spin.

@test "negative: diamond, dangling, and cyclic needs graphs are priced sanely" {
  local sb="$BATS_TEST_TMPDIR/graphs"
  local path

  require_yaml_parser
  mkdir -p "$sb"

  # Diamond: fan out to a 3m and a 9m branch, join. The join must price the
  # longer branch (2 + 9 + 4 = 15m over 3 hops), never the shorter or the sum.
  cat > "$sb/diamond.yml" <<'YAML'
jobs:
  root:
    timeout-minutes: 2
  quick:
    needs: root
    timeout-minutes: 3
  slow:
    needs: root
    timeout-minutes: 9
  join:
    needs: [quick, slow]
    timeout-minutes: 4
YAML
  path="$(workflow_critical_path "$sb/diamond.yml")" || return 1
  [ "$path" = "15 3" ] || { echo "diamond priced '${path}', want '15 3'" >&2; return 1; }

  # A `needs:` naming an undeclared job contributes nothing rather than crashing.
  cat > "$sb/dangling.yml" <<'YAML'
jobs:
  only:
    needs: ghost
    timeout-minutes: 7
YAML
  path="$(workflow_critical_path "$sb/dangling.yml")" || return 1
  [ "$path" = "7 1" ] || { echo "dangling priced '${path}', want '7 1'" >&2; return 1; }

  # A cycle is malformed YAML-as-workflow, not YAML: it parses, so the walk has
  # to terminate on it. Any answer is acceptable; hanging is not.
  cat > "$sb/cyclic.yml" <<'YAML'
jobs:
  alpha:
    needs: bravo
    timeout-minutes: 5
  bravo:
    needs: alpha
    timeout-minutes: 5
YAML
  path="$(workflow_critical_path "$sb/cyclic.yml")" || return 1
  printf '%s' "$path" | grep -qE '^[0-9]+ [0-9]+$' || {
    echo "cyclic needs did not resolve to a numeric pair: '${path}'" >&2
    return 1
  }
}

# Negative: an unparsed workflow must be loud. A trailing comment on `jobs:`
# used to empty the scrape for that one file, which contributed nothing to the
# gap list while the other workflows kept the run-wide counter above zero, so
# uncapped jobs merged under a green test.

@test "negative: comments and quoting around job ids do not empty the job list" {
  local sb="$BATS_TEST_TMPDIR/commented"
  local subject ids
  require_yaml_parser

  mkdir -p "$sb"
  subject="$sb/commented.yml"
  cat > "$subject" <<'YAML'
name: Commented
on:
  workflow_dispatch:
jobs: # the three jobs below
  alpha: # first
    name: Alpha
    timeout-minutes: 7
    runs-on: ubuntu-latest
    steps:
      - run: echo alpha
  "bravo":
    name: Bravo
    timeout-minutes: 8 # generous
    runs-on: ubuntu-latest
    steps:
      - run: echo bravo
  charlie:
    name: Charlie
    timeout-minutes: ${{ steps.pick.outputs.minutes }}
    runs-on: ubuntu-latest
    steps:
      - run: echo charlie
YAML

  # A trailing comment on any of these keys, and a quoted job id, are all legal
  # YAML and must not cost the job list an entry.
  ids="$(workflow_job_ids "$subject")"
  [ "$(printf '%s\n' "$ids" | grep -c .)" -eq 3 ] || {
    echo "comments or quoting emptied the job list: ${ids}" >&2
    return 1
  }
  [ "$(job_timeout_minutes "$subject" "alpha")" -eq 7 ] || return 1
  [ "$(job_timeout_minutes "$subject" "bravo")" -eq 8 ] || return 1

  # An expression-valued cap reads as no cap, because this guard cannot evaluate
  # one: reporting the job as uncapped is the loud direction, and trusting a
  # number never seen is the quiet one.
  [ -z "$(job_timeout_minutes "$subject" "charlie")" ]
}

# Negative: the filter-gate detector reads a condition, not one spelling of it.
# Both forms GitHub accepts must match, and an unrelated gate must not, or the
# normalization has widened into a match-anything that would pull jobs whose
# filter does run on a dispatch into the caller's scope.

# A one-job fixture whose dorny/paths-filter step carries the given `if:` lines,
# already indented for a step mapping. `-` means the step declares no gate.
write_filter_fixture() {
  printf 'jobs:\n  probe:\n    name: Probe\n    runs-on: ubuntu-latest\n    steps:\n'
  printf '      - uses: dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d # v4.0.1\n'
  [ "$1" = "-" ] || printf '%s\n' "$1"
  printf '        id: filter\n'
}

@test "negative: every spelling of the filter gate is detected, and others are not" {
  local sb="$BATS_TEST_TMPDIR/gates"
  local case_name gate
  require_yaml_parser
  mkdir -p "$sb"

  # The same condition, in each spelling GitHub accepts. `folded` is the one a
  # line-oriented read truncated to the literal `>-`, which matched nothing and
  # silently dropped the job out of the caller's scope.
  write_filter_fixture "        if: github.event_name == 'pull_request'" > "$sb/plain.yml"
  write_filter_fixture "        if: \${{ github.event_name == 'pull_request' }}" > "$sb/wrapped.yml"
  write_filter_fixture "        if: >-
          github.event_name ==
          'pull_request'" > "$sb/folded.yml"
  write_filter_fixture "        if: \"github.event_name == 'pull_request'\"" > "$sb/quoted.yml"

  for case_name in plain wrapped folded quoted; do
    gate="$(job_filter_gate "$sb/${case_name}.yml" "Probe")" || {
      echo "${case_name}: the gate could not be read at all" >&2
      return 1
    }
    [ "$gate" = "pull_request" ] || {
      echo "${case_name}: read as '${gate}', want 'pull_request'" >&2
      return 1
    }
  done

  # The gate counts wherever it sits, not only on the job's first paths-filter
  # step. Reading `steps[0]` alone answers `other` for this shape, the caller
  # skips the job outright, and the job leaves the test's scope with nothing to
  # report it -- the silent scope-drop this whole test exists to prevent. No
  # workflow in the repo runs two paths-filter steps in one job today, so this
  # fixture is the only thing holding the reader to every step.
  cat > "$sb/two-step.yml" <<'YAML'
jobs:
  probe:
    name: Probe
    runs-on: ubuntu-latest
    steps:
      - uses: dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d # v4.0.1
        id: prefilter
      - uses: dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d # v4.0.1
        if: github.event_name == 'pull_request'
        id: filter
YAML
  gate="$(job_filter_gate "$sb/two-step.yml" "Probe")" || {
    echo "two-step: the gate could not be read at all" >&2
    return 1
  }
  [ "$gate" = "pull_request" ] || {
    echo "two-step: a gate on the second paths-filter step read as '${gate}'" >&2
    return 1
  }

  # An unrelated gate must NOT match, or the normalization has widened into a
  # match-anything that pulls jobs whose filter does run on a dispatch into the
  # caller's scope. A step with no gate at all is likewise not this condition.
  write_filter_fixture "        if: steps.chore-deps.outputs.skip == 'false'" > "$sb/other.yml"
  write_filter_fixture "-" > "$sb/ungated.yml"
  for case_name in other ungated; do
    gate="$(job_filter_gate "$sb/${case_name}.yml" "Probe")" || return 1
    [ "$gate" = "other" ] || {
      echo "${case_name}: read as '${gate}', want 'other'" >&2
      return 1
    }
  done

  # A job that runs no such step is `none`, which the caller must not count as a
  # candidate and must not confuse with an unreadable gate.
  printf 'jobs:\n  probe:\n    name: Probe\n    steps:\n      - run: echo hi\n' > "$sb/nofilter.yml"
  gate="$(job_filter_gate "$sb/nofilter.yml" "Probe")" || return 1
  [ "$gate" = "none" ]
}

# Negative: a step is "gated on the filter" by its own `if:`, not by mentioning
# the output anywhere. A step that passes `steps.filter.outputs.*` as an input or
# an env value runs on a dispatch regardless, so reading it as gated would report
# a gap that is not one.

@test "negative: only a step's own if: counts as gated on the filter output" {
  local sb="$BATS_TEST_TMPDIR/gated-steps"
  local ifs_out
  require_yaml_parser
  mkdir -p "$sb"

  cat > "$sb/steps.yml" <<'YAML'
jobs:
  probe:
    name: Probe
    steps:
      - name: gated
        if: steps.filter.outputs.code == 'true'
        run: echo gated
      - name: gated on both
        if: steps.filter.outputs.code == 'true' || github.event_name == 'workflow_dispatch'
        run: echo both
      - name: merely reads the output
        env:
          CODE: ${{ steps.filter.outputs.code }}
        run: echo env
      - name: ungated
        run: echo plain
YAML

  ifs_out="$(job_filter_dependent_step_ifs "$sb/steps.yml" "Probe")"
  [ "$(printf '%s\n' "$ifs_out" | grep -c .)" -eq 2 ] || {
    echo "expected exactly the two if:-gated steps, got: ${ifs_out}" >&2
    return 1
  }
  # The one gated on the filter alone is the reportable shape; the one that also
  # admits a dispatch is not.
  printf '%s\n' "$ifs_out" | grep -qF -- "workflow_dispatch" || {
    echo "lost the step whose gate also admits a dispatch" >&2
    return 1
  }
  printf '%s\n' "$ifs_out" | grep -qF -- "CODE" && {
    echo "an env reference was read as a gate" >&2
    return 1
  }
  return 0
}
