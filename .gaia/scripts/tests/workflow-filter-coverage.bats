#!/usr/bin/env bats
# Regression guard for the paths-filter self-coverage invariant.
#
# A step gated on `if: steps.<id>.outputs.<name> == 'true'` runs only when one of
# that filter's globs matched the pull request's changed files. If the step reads
# a file the filter does not list, a pull request that changes only that file
# resolves the output `false`, the step skips, and the job reports GREEN HAVING
# RUN NOTHING. On a declared-required context that green is what branch
# protection reads, so the change merges having been checked by nothing.
#
# The failure is invisible by construction: the check is green, and green is also
# the correct result for a pull request that genuinely touches nothing relevant,
# so the two cases are indistinguishable from the outside. Nothing but this suite
# compares the two sets.
#
# The class recurs. Every instance so far was found by hand after the fact: a
# filter that omitted the suite guarding its own gate, two entries made no-ops by
# a catch-all above them, a comment naming a narrower surface than the suite had,
# a gate extracted into a script that left its workflow's filter behind, and the
# two the `.husky/**` and `.github/workflows/**` globs in shell-lint.yml were each
# added to close. Those two globs carry the repo's own written record that this
# recurs.
#
# ---------------------------------------------------------------------------
# What this guard asserts, and what it deliberately does not
# ---------------------------------------------------------------------------
#
# A gated step's real inputs are not statically knowable: a `run:` block is
# arbitrary shell and may read anything. So this is a FLOOR, not a complete
# accounting. It asserts the narrow invariant most recorded instances violated:
#
#   every repo-relative path a gated step names LITERALLY must be reachable by
#   the globs of the filter output that gates it,
#
# where "names literally" means a git-tracked file appearing as a whitespace-
# delimited token in the step's `run:` body, plus the `action.yml` of a local
# composite action the step `uses:`. Each gated step's own workflow file counts as
# an input of itself, which is the self-coverage half: a gate must re-run on a
# change to its own definition.
#
# Three things are deliberately out of scope, because each needs a mechanism this
# floor does not have and a decision this suite should not make on its own:
#
#   1. Transitive inputs. A step invoking `run-all.sh` gets that script checked,
#      not the files the scenarios inside it inspect. Reaching those needs either
#      a declared-inputs convention on every gated step or a runtime witness.
#   2. Paths built at runtime. A path assembled from a variable or a glob
#      expansion is invisible to a token scan, and always will be.
#   3. Composite-action bodies. A local action's own `run:` steps are not
#      descended into; only its `action.yml` is checked.
#   4. A filter propagated across jobs. The gate scan reads
#      `steps.<id>.outputs.<name>`, so a paths-filter run in a setup job and
#      exposed through that job's `outputs:` for a downstream job to gate on as
#      `needs.<job>.outputs.<name>` is invisible here -- to the coverage
#      assertions AND to the section-4 escape-hatch pin, with no exemption
#      entry required. Nothing in the tree uses that shape today. Recorded
#      rather than left implied absent, because section 4 exists precisely so
#      that coverage cannot be dropped silently, and this is a second exit.
#
# Under-reaching is the deliberate bias: a path this suite cannot see is a path it
# says nothing about, never a path it silently blesses. The extraction-intact
# tests in section 1 are what keep "says nothing about" from quietly becoming
# "says nothing at all".
#
# Hand-rolled gates (a `run:` block emitting `code=true` from its own diff scan,
# as tests.yml does) are a different shape with no glob list to read, so they are
# out of the coverage assertion. Section 4 pins the exempt set so a new workflow
# cannot evade this guard by hand-rolling its filter.
#
# Assertion style (.claude/rules/bats-assertions.md): non-final checks use POSIX
# `[ ]`, `grep -q`, or an explicit `return 1`, never a bare `[[ ]]`; an absence
# assertion is written as the positive bad case followed by `&& return 1`.
#
# The negative tests below point the extractor at synthetic fixtures written into
# $BATS_TEST_TMPDIR. bats runs each `@test` body in its own subshell and re-runs
# `setup()` before each one, so nothing written there leaks between tests. The
# checker sees only the subshell and reports the cross-test leak it implies, hence
# the file-wide suppression on the next line. Keep that line last in this block: a
# following comment opening with the checker's own name parses as a second,
# malformed directive (SC1073) and fails the lint outright.
# shellcheck disable=SC2030,SC2031

# The workflows this guard reads are a precondition on CI, not a maybe: the job
# that runs this suite checks the repo out whole, so an absent path there means
# the directory was renamed and this guard silently stopped guarding. So the CI
# branch FAILS instead of skipping. A skip reports `ok ... # skip` and greens the
# job, which would retire every test in this file including the section-0 gate
# that exists to stop exactly that. Off CI the skip stands: a checkout that
# legitimately lacks these paths is not the environment the guard is making a
# claim about. Section 0 proves the CI branch fires.
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

# Gate only the tests that parse YAML. On CI the parser is a precondition rather
# than a maybe: audit-ci-tests.yml installs python3-yaml in the same job that runs
# this suite. So the CI branch FAILS instead of skipping, for the same reason
# require_repo_path does. Matches .gaia/scripts/tests/retrigger-reachability.bats,
# whose own gate this mirrors.
require_yaml_parser() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "no YAML parser (python3 + PyYAML) on a CI runner; the parser-gated tests here would skip to green. Check the apt install in .github/workflows/audit-ci-tests.yml." >&2
    return 1
  fi
  skip "no YAML parser available (python3 + PyYAML)"
}

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

  # Workflows that gate a step on a hand-rolled `run:`-emitted output rather than
  # a dorny/paths-filter glob list. Section 4 asserts this set exactly, so adding
  # a hand-rolled gate to a new workflow reds until it is named here on purpose.
  HANDROLLED_EXEMPT="tests.yml"

  require_repo_path -d "$WORKFLOWS_DIR" ".github/workflows" || return 1
}

# ---------------------------------------------------------------------------
# Extraction, python3 + PyYAML.
#
# Workflow structure is parsed rather than scraped, for the reason the sibling
# suite spells out: every shape a line-oriented scrape has to be taught one at a
# time -- a quoted job id, a folded `if: >-` spanning lines, an inline list, a
# trailing comment -- is a shape a real parser already knows. The scrape surface
# is unbounded; the parser's is not.
#
# filter_coverage <mode> <tracked-list-file> <workflow-file>...
#
#   pairs       one `<ok|unreached>\t<workflow>\t<job>\t<step>\t<gate>\t<input>`
#               line per (gated step, literal input) pair
#   gated       one `<workflow>\t<job>\t<step>` line per gated step whose gate
#               resolves to a paths-filter output
#   handrolled  one `<workflow>` line per workflow gating a step on an output
#               whose producing step is not a paths-filter
#   glob        `match` or `no-match` for `<pattern>` against `<path>`, passed as
#               the two arguments after the mode (no tracked list, no files)
#
# <tracked-list-file> holds the repo-relative paths that count as real files, one
# per line. Passing it in rather than shelling out to git is what lets the
# negative tests run hermetically against a synthetic tree with no repository.
#
# **Exits 2 when a file will not parse or declares no jobs mapping.** A caller
# must check the status: reading empty output as an answer is how an unreadable
# workflow drops out of a loop while the test stays green.
# ---------------------------------------------------------------------------
filter_coverage() {
  python3 - "$@" <<'PY'
import os
import re
import sys

import yaml

mode = sys.argv[1]

# Gate reference: `steps.<id>.outputs.<name>` anywhere in a step's `if:`.
GATE = re.compile(r'steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)')
# A shell token that could be a repo-relative path. Deliberately permissive: the
# tracked-file membership test below is what decides, not this.
TOKEN = re.compile(r'[A-Za-z0-9_./+-]+')


def die(msg):
    sys.stderr.write('%s\n' % msg)
    sys.exit(2)


# Picomatch syntax this translator does not implement. A negation (`!foo/**`)
# SUBTRACTS from a filter's reach, and brace expansion, extglobs, and character
# classes each stand for a set the loop below would flatten to literals. Escaped
# through `re.escape`, every one of them yields a pattern that matches nothing
# real, and `reaches()` would then decide coverage from the surviving positive
# entries alone -- reporting a path the filter does not actually reach as `ok`.
#
# That is the one failure direction this guard must not have. Under-reaching is
# its deliberate bias everywhere else: a path it cannot see is a path it says
# nothing about. A mistranslated negation is the opposite, a path it actively
# blesses, which is the false green it exists to catch, one level up. So this
# fails closed and names the glob: a red is the correct answer from a comparator
# that cannot decide.
UNSUPPORTED_GLOB = re.compile(r'[{}()\[\]]')


def glob_to_re(pattern):
    """Translate one picomatch-style glob into a regex.

    dorny/paths-filter matches changed paths with picomatch, so `**` crosses
    directory separators and `*` does not. Getting that distinction wrong in
    either direction is a silent verdict flip: a `*` that crossed `/` would call
    an uncovered nested path covered, and a `**/` that could not match zero
    segments would call `**/*.sh` blind to a root-level `x.sh`.
    """
    if pattern.startswith('!') or UNSUPPORTED_GLOB.search(pattern):
        die('unsupported glob syntax, this guard cannot decide coverage: %r' % pattern)
    out = ['^']
    i = 0
    while i < len(pattern):
        if pattern.startswith('**/', i):
            # Zero or more leading segments, so `**/*.sh` reaches `x.sh` too.
            out.append('(?:[^/]+/)*')
            i += 3
        elif pattern.startswith('**', i):
            out.append('.*')
            i += 2
        elif pattern[i] == '*':
            out.append('[^/]*')
            i += 1
        elif pattern[i] == '?':
            out.append('[^/]')
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    out.append('$')
    return re.compile(''.join(out))


def reaches(globs, path):
    for glob in globs:
        # A filter entry may be a mapping (`- added|modified: 'x'`) rather than a
        # bare string; the glob is the value in that shape.
        if isinstance(glob, dict):
            values = list(glob.values())
            glob = values[0] if values else ''
        if glob_to_re(str(glob)).match(path):
            return True
    return False


if mode == 'glob':
    print('match' if reaches([sys.argv[2]], sys.argv[3]) else 'no-match')
    sys.exit(0)

with open(sys.argv[2], encoding='utf-8') as handle:
    tracked = {line.strip() for line in handle if line.strip()}


def normalize(expr):
    """Collapse a gate to one comparable line.

    GitHub accepts `if: <expr>` and `if: ${{ <expr> }}` as the same condition,
    and a folded scalar arrives already joined but irregularly spaced.
    """
    return ' '.join(str(expr).replace('${{', ' ').replace('}}', ' ').split())


def filters_in(steps):
    """Every paths-filter step in one job, as {step id: {name: [glob, ...]}}."""
    found = {}
    for step in steps:
        if not isinstance(step, dict):
            continue
        if 'dorny/paths-filter' not in str(step.get('uses', '')):
            continue
        raw = (step.get('with') or {}).get('filters')
        # `filters:` is a YAML document embedded in a YAML string.
        parsed = yaml.safe_load(raw) if isinstance(raw, str) else raw
        if isinstance(parsed, dict):
            found[str(step.get('id', ''))] = parsed
    return found


def literal_inputs(step, workflow_rel):
    """Repo-relative paths this step names literally.

    A `run:` body's comment lines are stripped first: a comment naming a path is
    documentation about the step, not an input to it, and counting it would make
    the guard red on prose.
    """
    body = str(step.get('run', ''))
    body = '\n'.join(
        line for line in body.splitlines() if not line.lstrip().startswith('#')
    )
    inputs = set()
    for token in TOKEN.findall(body):
        if token.startswith('./'):
            token = token[2:]
        # A bare token with no separator (`bats`, `pnpm`, a bare `package.json`)
        # is far more often a command or a word in a message than a path, so the
        # floor requires a separator. Under-reaching by construction.
        if '/' in token and token in tracked:
            inputs.add(token)
    uses = str(step.get('uses', ''))
    if uses.startswith('./'):
        for name in ('action.yml', 'action.yaml'):
            candidate = os.path.join(uses[2:], name)
            if candidate in tracked:
                inputs.add(candidate)
    # Self-coverage: a gate must re-run on a change to its own definition.
    inputs.add(workflow_rel)
    return inputs


def rel_of(path):
    """A workflow's repo-relative path, derived from the path itself.

    Not `os.path.relpath(path, os.getcwd())`: that would make every emitted
    row depend on where bats happened to be invoked from, and the negative tests
    below run against fixtures outside the repository entirely.
    """
    posix = path.replace(os.sep, '/')
    marker = '/.github/workflows/'
    index = posix.find(marker)
    return posix[index + 1:] if index >= 0 else os.path.basename(posix)


rows = []
for path in sys.argv[3:]:
    workflow_rel = rel_of(path)
    try:
        with open(path, encoding='utf-8') as handle:
            doc = yaml.safe_load(handle)
    except (yaml.YAMLError, OSError) as exc:
        die('%s: unreadable YAML (%s)' % (workflow_rel, exc.__class__.__name__))

    # Strictly the top-level `jobs:` mapping, with no fallback to the document
    # itself: `on:`'s trigger keys sit at the same depth as job ids, so treating
    # the root as the job list reads `push` and `pull_request` as phantom jobs.
    jobs = doc.get('jobs') if isinstance(doc, dict) else None
    if not isinstance(jobs, dict) or not jobs:
        die('%s: no jobs mapping' % workflow_rel)

    for job_id, job in jobs.items():
        job_id = str(job_id)
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        if not isinstance(steps, list):
            continue
        filters = filters_in(steps)
        for step in steps:
            if not isinstance(step, dict):
                continue
            gates = GATE.findall(normalize(step.get('if', '')))
            name = str(step.get('name', '')) or str(step.get('uses', ''))
            if mode == 'handrolled':
                # A step gated on `steps.filter.outputs.*` in a job that runs no
                # dorny/paths-filter step with `id: filter`. Keyed on the id
                # rather than on "any output this guard cannot read": every
                # workflow here gates steps on step outputs for reasons that have
                # nothing to do with changed paths (a title check, a config read,
                # a poller verdict), and reporting those would drown the signal.
                # `id: filter` is the repo's convention for the changed-paths
                # gate specifically, which makes it the precise thing to pin.
                # Reported per workflow, deduped below.
                for step_id, _ in gates:
                    if step_id == 'filter' and step_id not in filters:
                        rows.append(workflow_rel)
                continue
            gates = [(s, n) for s, n in gates if s in filters]
            if not gates:
                continue
            if mode == 'gated':
                rows.append('\t'.join([workflow_rel, job_id, name]))
                continue
            inputs = literal_inputs(step, workflow_rel)
            for step_id, output in gates:
                globs = filters[step_id].get(output)
                gate = '%s.%s' % (step_id, output)
                if globs is None:
                    # The step is gated on a filter output the filter never
                    # declares, so it is dead-off: the output is always empty and
                    # the step never runs. Reported against every input rather
                    # than skipped, since "never runs" is a strictly worse
                    # version of the failure this guard exists to catch.
                    for item in sorted(inputs):
                        rows.append(
                            '\t'.join(
                                ['unreached', workflow_rel, job_id, name, gate, item]
                            )
                        )
                    continue
                for item in sorted(inputs):
                    status = 'ok' if reaches(globs, item) else 'unreached'
                    rows.append(
                        '\t'.join([status, workflow_rel, job_id, name, gate, item])
                    )

for row in sorted(set(rows)) if mode == 'handrolled' else rows:
    print(row)
PY
}

# Every tracked file, as the list the extractor reads. Written once per test into
# that test's own tmpdir.
tracked_list() {
  local out="$1"
  git -C "$REPO_ROOT" ls-files > "$out"
}

# Every workflow file, both extensions, matching the directory scan in
# .gaia/scripts/verify-required-checks.sh.
workflow_files() {
  local dir="$1" file
  for file in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$file" ] || continue
    printf '%s\n' "$file"
  done
}

# ---------------------------------------------------------------------------
# 0. This suite's own two gates. Each is a single point where a whole population
#    of tests below can be turned off at once, and on a CI runner each has to
#    FAIL rather than skip. Nothing else in this file would notice if either
#    stopped: weakening one back to a bare `skip` would red nothing, and the
#    affected tests would report `ok ... # skip` and green the job. These two
#    tests are what make that weakening red. Neither is parser-gated itself.
# ---------------------------------------------------------------------------

@test "the parser gate fails on a CI runner and still skips off CI" {
  local shim="$BATS_TEST_TMPDIR/no-parser" rc
  mkdir -p "$shim"
  # python3 present, but its `import yaml` fails: the shape a runner takes when
  # python3-yaml is dropped from the apt line, not one where python3 is missing
  # outright. The shebang is absolute so the stripped PATH below cannot affect it.
  printf '#!/bin/sh\nexit 1\n' > "$shim/python3"
  chmod +x "$shim/python3"

  # Calling the gate in a subshell is what keeps its `skip` arm from marking this
  # test skipped -- bats' `skip` exits 0, so the subshell's status is exactly the
  # discriminator wanted here: non-zero is the CI failure, 0 is the off-CI skip.
  rc=0
  ( PATH="$shim" GITHUB_ACTIONS=true; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner with no YAML parser; every parsing test would report green" >&2
    return 1
  }

  rc=0
  ( PATH="$shim"; unset GITHUB_ACTIONS; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where a missing parser must still skip" >&2
    return 1
  }
}

@test "the path precondition gate fails on a CI runner and still skips off CI" {
  local rc
  mkdir -p "$BATS_TEST_TMPDIR/a-dir"

  # Absent by construction: $BATS_TEST_TMPDIR is created empty for this test and
  # nothing puts `renamed-away` in it.
  rc=0
  ( GITHUB_ACTIONS=true; require_repo_path -d "$BATS_TEST_TMPDIR/renamed-away" "a renamed path" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner for an absent path; every test here would report green" >&2
    return 1
  }

  rc=0
  ( unset GITHUB_ACTIONS; require_repo_path -d "$BATS_TEST_TMPDIR/renamed-away" "a renamed path" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where an unsatisfied precondition must still skip" >&2
    return 1
  }

  # Present but the wrong type. This pins the runtime flag: a gate that ignored
  # it and asked only whether the path exists would pass this and prove nothing
  # about the -d/-f distinction setup() relies on.
  rc=0
  ( GITHUB_ACTIONS=true; require_repo_path -f "$BATS_TEST_TMPDIR/a-dir" "a renamed path" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 1. Extraction-intact. Every assertion below loops over what the extractor
#    emits, so an extraction that silently goes empty turns the whole suite green
#    having asserted nothing -- the hollow-guard failure this file exists to
#    catch, turned on the file itself. Pin both ends: the live tree does gate
#    steps on paths-filter outputs, and those steps do resolve literal inputs.
# ---------------------------------------------------------------------------

@test "the live tree still has paths-filter-gated steps to check" {
  require_yaml_parser
  local tracked="$BATS_TEST_TMPDIR/tracked" count
  tracked_list "$tracked"

  local files
  files="$(workflow_files "$WORKFLOWS_DIR")"
  [ -n "$files" ] || { echo ".github/workflows holds no workflow files" >&2; return 1; }

  # shellcheck disable=SC2086
  run filter_coverage gated "$tracked" $files
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  count="$(printf '%s\n' "$output" | grep -c . || true)"
  [ "$count" -gt 0 ] || {
    echo "no paths-filter-gated steps found; every coverage assertion here would loop zero times" >&2
    return 1
  }
}

@test "gated steps still resolve literal inputs beyond their own workflow file" {
  require_yaml_parser
  local tracked="$BATS_TEST_TMPDIR/tracked" count
  tracked_list "$tracked"

  local files
  files="$(workflow_files "$WORKFLOWS_DIR")"

  # shellcheck disable=SC2086
  run filter_coverage pairs "$tracked" $files
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  # Every gated step contributes its own workflow file, so a self-coverage-only
  # result is exactly what a broken token scan looks like: still non-empty, still
  # green, and blind to every script a step invokes.
  count="$(printf '%s\n' "$output" | awk -F'\t' '$6 !~ /^\.github\/workflows\//' | grep -c . || true)"
  [ "$count" -gt 0 ] || {
    echo "no gated step resolved a literal input outside .github/workflows/; the token scan reads nothing" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# 2. The invariant itself, over the live tree.
# ---------------------------------------------------------------------------

@test "every gated step's literal inputs are reachable by the filter gating it" {
  require_yaml_parser
  local tracked="$BATS_TEST_TMPDIR/tracked"
  tracked_list "$tracked"

  local files
  files="$(workflow_files "$WORKFLOWS_DIR")"

  # shellcheck disable=SC2086
  run filter_coverage pairs "$tracked" $files
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  local unreached
  unreached="$(printf '%s\n' "$output" | grep '^unreached' || true)"
  if printf '%s' "$unreached" | grep -q .; then
    {
      echo "A gated step reads a path its own filter does not list. A pull request"
      echo "changing only that path resolves the gate false, skips the step, and"
      echo "reports the check green having run nothing. Add the path to the filter,"
      echo "or narrow the gate."
      echo
      printf '%s\n' "$unreached" | awk -F'\t' '{printf "  %s [%s] step %s\n    gate %s does not reach %s\n", $2, $3, $4, $5, $6}'
    } >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 3. Self-coverage, called out separately from section 2 because it is the half
#    with a distinct failure story: a gate that cannot re-run on a change to its
#    own definition lets a weakening of the gate merge unchecked by the gate. It
#    is the property shell-lint.yml and audit-ci-tests.yml both record by hand
#    today, in comments, with nothing enforcing it.
# ---------------------------------------------------------------------------

@test "every gated step's filter reaches its own workflow file" {
  require_yaml_parser
  local tracked="$BATS_TEST_TMPDIR/tracked"
  tracked_list "$tracked"

  local files
  files="$(workflow_files "$WORKFLOWS_DIR")"

  # shellcheck disable=SC2086
  run filter_coverage pairs "$tracked" $files
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  local blind
  blind="$(printf '%s\n' "$output" | awk -F'\t' '$1 == "unreached" && $6 == $2' || true)"
  if printf '%s' "$blind" | grep -q .; then
    {
      echo "A gate does not re-run on a change to its own workflow file, so a"
      echo "weakening of the gate merges unchecked by the gate."
      echo
      printf '%s\n' "$blind" | awk -F'\t' '{printf "  %s [%s] gate %s does not reach %s\n", $2, $3, $5, $6}'
    } >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 4. No silent escape hatch. A workflow that gates a step on its own `run:`-
#    emitted `filter` output has no glob list for section 2 to read, so it is
#    invisible to every assertion above. That shape is legitimate (tests.yml
#    scans an incremental delta a glob list cannot express), but it must not be
#    reachable by accident: pinning the exempt set makes adding one a deliberate
#    edit here.
#
#    Scoped to the `id: filter` convention. Every workflow in this repo gates
#    steps on step outputs for reasons unrelated to changed paths -- a
#    `chore(deps)` title check, a config read, a poller verdict -- so a rule
#    reading "any output this guard cannot parse" would report those too and
#    bury the one shape that matters.
# ---------------------------------------------------------------------------

@test "only the exempt workflows gate a step on a hand-rolled filter output" {
  require_yaml_parser
  local tracked="$BATS_TEST_TMPDIR/tracked"
  tracked_list "$tracked"

  local files
  files="$(workflow_files "$WORKFLOWS_DIR")"

  # shellcheck disable=SC2086
  run filter_coverage handrolled "$tracked" $files
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  local found unexpected
  found="$(printf '%s\n' "$output" | sed 's|^.github/workflows/||' | grep . || true)"
  unexpected="$(printf '%s\n' "$found" | grep -vxF "$HANDROLLED_EXEMPT" || true)"
  if printf '%s' "$unexpected" | grep -q .; then
    {
      echo "A workflow gates a step on an output no paths-filter produces, so this"
      echo "guard cannot read its coverage. Either use dorny/paths-filter, or add"
      echo "the file to HANDROLLED_EXEMPT in setup() with the reason."
      echo
      printf '%s\n' "$unexpected" | sed 's/^/  /'
    } >&2
    return 1
  fi

  # The exempt entry must still be a real hand-rolled gate. Once tests.yml moves
  # to a paths-filter, a stale exemption is a hole the guard would not report.
  printf '%s\n' "$found" | grep -qxF "$HANDROLLED_EXEMPT" || {
    echo "HANDROLLED_EXEMPT names ${HANDROLLED_EXEMPT}, which no longer gates on a hand-rolled output; drop the exemption" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# 5. Negatives. A guard for this class that cannot show red is the same false
#    green it exists to catch, one level up. Each fixture below is the smallest
#    workflow that exhibits one failure shape.
# ---------------------------------------------------------------------------

# Write a fixture workflow and its tracked-file list into the current test's
# tmpdir. <globs> is the filter's glob list, one per line.
write_fixture() {
  local dir="$1" globs="$2" body="$3"
  mkdir -p "$dir/.github/workflows"
  {
    echo "name: Fixture"
    echo "on:"
    echo "  pull_request:"
    echo "jobs:"
    echo "  fixture:"
    echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - uses: dorny/paths-filter@v4"
    echo "        id: filter"
    echo "        with:"
    echo "          filters: |"
    echo "            code:"
    printf '%s\n' "$globs" | sed 's|^|              - |'
    echo "      - if: steps.filter.outputs.code == 'true'"
    echo "        name: Gated step"
    echo "        run: $body"
  } > "$dir/.github/workflows/fixture.yml"
}

@test "negative: a gated step reading a path its filter omits is caught" {
  require_yaml_parser
  local dir="$BATS_TEST_TMPDIR/sb"
  write_fixture "$dir" "'.github/workflows/fixture.yml'" "bash scripts/guard.sh"
  printf '%s\n' ".github/workflows/fixture.yml" "scripts/guard.sh" > "$dir/tracked"

  run filter_coverage pairs "$dir/tracked" "$dir/.github/workflows/fixture.yml"
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  # The omitted script reds...
  printf '%s\n' "$output" | grep -q "^unreached.*scripts/guard.sh" || {
    echo "the guard did not report the omitted script; it cannot show red" >&2
    return 1
  }
  # ...and the listed workflow file does not, so the verdict discriminates.
  printf '%s\n' "$output" | grep -q "^ok.*fixture.yml" || {
    echo "the guard reported a listed path as unreached; it reds on everything" >&2
    return 1
  }
}

@test "negative: a filter blind to its own workflow file is caught" {
  require_yaml_parser
  local dir="$BATS_TEST_TMPDIR/sb"
  write_fixture "$dir" "'scripts/guard.sh'" "bash scripts/guard.sh"
  printf '%s\n' ".github/workflows/fixture.yml" "scripts/guard.sh" > "$dir/tracked"

  run filter_coverage pairs "$dir/tracked" "$dir/.github/workflows/fixture.yml"
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  printf '%s\n' "$output" | grep -q "^unreached.*fixture.yml" || {
    echo "the guard did not report the self-coverage gap" >&2
    return 1
  }
}

@test "negative: a step gated on a filter name the filter never declares is caught" {
  require_yaml_parser
  local dir="$BATS_TEST_TMPDIR/sb"
  mkdir -p "$dir/.github/workflows"
  # `code:` is declared; the step gates on `shell:`, which is always empty, so the
  # step never runs at all.
  cat > "$dir/.github/workflows/fixture.yml" <<'YAML'
name: Fixture
on:
  pull_request:
jobs:
  fixture:
    runs-on: ubuntu-latest
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            code:
              - '**'
      - if: steps.filter.outputs.shell == 'true'
        name: Gated step
        run: bash scripts/guard.sh
YAML
  printf '%s\n' ".github/workflows/fixture.yml" "scripts/guard.sh" > "$dir/tracked"

  run filter_coverage pairs "$dir/tracked" "$dir/.github/workflows/fixture.yml"
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  printf '%s\n' "$output" | grep -q "^unreached" || {
    echo "a step gated on an undeclared filter name reported clean" >&2
    return 1
  }
}

@test "negative: a run-body comment naming a path does not count as an input" {
  require_yaml_parser
  local dir="$BATS_TEST_TMPDIR/sb"
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/fixture.yml" <<'YAML'
name: Fixture
on:
  pull_request:
jobs:
  fixture:
    runs-on: ubuntu-latest
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            code:
              - '.github/workflows/fixture.yml'
      - if: steps.filter.outputs.code == 'true'
        name: Gated step
        run: |
          # scripts/guard.sh explains why this step exists
          echo ok
YAML
  printf '%s\n' ".github/workflows/fixture.yml" "scripts/guard.sh" > "$dir/tracked"

  run filter_coverage pairs "$dir/tracked" "$dir/.github/workflows/fixture.yml"
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  printf '%s\n' "$output" | grep -q "scripts/guard.sh" && {
    echo "a path named only in a comment was counted as an input; the guard reds on prose" >&2
    return 1
  }
  # An explicit `true` rather than `return 0`: shellcheck reads the `return` as
  # ending the file's reachable flow and reports every following `@test` body as
  # unreachable (SC2317). This is also the spelling .claude/rules/bats-assertions.md
  # prescribes for closing a test whose last assertion is the `<bad-case> && return 1`
  # form.
  true
}

@test "negative: a hand-rolled id: filter gate is reported, a descriptive id is not" {
  require_yaml_parser
  local dir="$BATS_TEST_TMPDIR/sb"
  mkdir -p "$dir/.github/workflows"
  : > "$dir/tracked"
  # `filter` emits its output from a `run:` block, so there is no glob list to
  # read; `chore-deps` is the shape every workflow here uses for a gate that was
  # never about changed paths, and must stay out of the report.
  cat > "$dir/.github/workflows/fixture.yml" <<'YAML'
name: Fixture
on:
  pull_request:
jobs:
  fixture:
    runs-on: ubuntu-latest
    steps:
      - id: chore-deps
        run: echo "skip=false" >> "$GITHUB_OUTPUT"
      - id: filter
        run: echo "code=true" >> "$GITHUB_OUTPUT"
      - if: steps.chore-deps.outputs.skip == 'false' && steps.filter.outputs.code == 'true'
        name: Gated step
        run: bash scripts/guard.sh
YAML

  run filter_coverage handrolled "$dir/tracked" "$dir/.github/workflows/fixture.yml"
  [ "$status" -eq 0 ] || { echo "extractor failed: $output" >&2; return 1; }

  [ "$output" = ".github/workflows/fixture.yml" ] || {
    echo "expected exactly the fixture reported once, got: ${output}" >&2
    return 1
  }
}

@test "negative: an unparseable or job-less workflow fails the extractor" {
  require_yaml_parser
  local dir="$BATS_TEST_TMPDIR/sb"
  mkdir -p "$dir"
  : > "$dir/tracked"

  printf 'name: Broken\njobs:\n  - this: is not a mapping\n   bad indent\n' > "$dir/unparseable.yml"
  run filter_coverage pairs "$dir/tracked" "$dir/unparseable.yml"
  [ "$status" -eq 2 ] || {
    echo "an unparseable workflow exited ${status}; empty output would read as clean" >&2
    return 1
  }

  printf 'name: No jobs\non:\n  pull_request:\n' > "$dir/jobless.yml"
  run filter_coverage pairs "$dir/tracked" "$dir/jobless.yml"
  [ "$status" -eq 2 ]
}

@test "negative: the glob translator honors picomatch separator semantics" {
  require_yaml_parser

  # `**/` matches zero segments, so a root-level file is reached.
  run filter_coverage glob '**/*.sh' 'x.sh'
  [ "$output" = "match" ] || { echo "'**/*.sh' missed a root-level x.sh" >&2; return 1; }

  run filter_coverage glob '**/*.sh' 'a/b/x.sh'
  [ "$output" = "match" ] || { echo "'**/*.sh' missed a nested x.sh" >&2; return 1; }

  # `*` does not cross a separator, so a prefix glob cannot bless a nested path.
  run filter_coverage glob 'tsconfig*.json' 'a/tsconfig.json'
  [ "$output" = "no-match" ] || { echo "'*' crossed a directory separator" >&2; return 1; }

  run filter_coverage glob 'tsconfig*.json' 'tsconfig.node.json'
  [ "$output" = "match" ] || { echo "'tsconfig*.json' missed tsconfig.node.json" >&2; return 1; }

  # A `dir/**` glob covers what is inside the directory, not the directory entry
  # itself. Getting this wrong is what would let a bare `.gaia/cli` token read as
  # covered, which is why the token scan counts files rather than directories.
  run filter_coverage glob '.gaia/cli/**' '.gaia/cli/src/index.ts'
  [ "$output" = "match" ] || { echo "'.gaia/cli/**' missed a nested file" >&2; return 1; }

  run filter_coverage glob '.gaia/cli/**' '.gaia/clip/x.ts'
  [ "$output" = "no-match" ] || { echo "'.gaia/cli/**' matched a sibling directory prefix" >&2; return 1; }

  # A literal entry is exactly itself.
  run filter_coverage glob 'package.json' '.gaia/cli/package.json'
  [ "$output" = "no-match" ]
}

@test "negative: glob syntax the translator cannot decide fails closed, not open" {
  require_yaml_parser

  # A negation SUBTRACTS from a filter's reach. Flattened to literals it would
  # match nothing, the positive entries would carry the verdict alone, and a path
  # the filter does not reach would report `ok` -- the one direction this guard
  # must never fail in.
  run filter_coverage glob '!vendor/**' 'vendor/x.sh'
  [ "$status" -eq 2 ] || {
    echo "a negation glob exited ${status}; it must fail closed, not silently match nothing" >&2
    return 1
  }

  # Brace expansion, an extglob, and a character class each stand for a set the
  # translator would flatten the same way.
  run filter_coverage glob 'src/{a,b}/**' 'src/a/x.ts'
  [ "$status" -eq 2 ] || { echo "brace expansion did not fail closed" >&2; return 1; }

  run filter_coverage glob 'src/@(a|b).ts' 'src/a.ts'
  [ "$status" -eq 2 ] || { echo "an extglob did not fail closed" >&2; return 1; }

  run filter_coverage glob 'src/[ab].ts' 'src/a.ts'
  [ "$status" -eq 2 ] || { echo "a character class did not fail closed" >&2; return 1; }

  # The refusal must be narrow: every shape the live filters actually use still
  # decides. A guard that failed closed on ordinary globs would red the tree.
  run filter_coverage glob '.github/actions/**' '.github/actions/gaia-setup-node/action.yml'
  [ "$status" -eq 0 ] || { echo "a supported glob was refused; the check is too broad" >&2; return 1; }
  [ "$output" = "match" ]
}
