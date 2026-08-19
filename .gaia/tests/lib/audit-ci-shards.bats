#!/usr/bin/env bats

# Structural guard for .github/workflows/audit-ci-tests.yml's fan-out shape:
# a matrix job (`shards`) plus a thin aggregator (`audit-ci-tests`) that
# carries the declared-required check name. This is C3 in
# .gaia/local/plans/PLAN-014/README.md; the checks below (W1-W10) each guard
# one of the constraints that page's task doc lays out for this workflow,
# since breaking any one of them wedges every pull request. W10 is the one
# addition that page does not name: it guards the per-leg apt list, which
# postdates it.
#
# Every test drives its check through a helper that takes the workflow's path
# as an argument, never a predicate written inline against the live file, so
# the adversarial fixture for each test exercises the SAME code against a
# doctored copy. That is the reasoning .gaia/scripts/tests/retrigger-
# reachability.bats gives for its own workflow_timeout_gaps: a predicate that
# only ever runs against the healthy file has every branch it takes be the
# passing one, so a broken predicate still reports green.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], no `!`-negated non-final assertion, POSIX [ ] / grep -q /
# explicit `return 1`.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

# The workflows this guard reads are a precondition on CI, not a maybe: the
# job that runs this suite checks the repo out whole, so an absent path means
# the file was renamed and this guard silently stopped guarding. So the CI
# branch FAILS instead of skipping, matching the sibling suites' own gate.
require_repo_path() {
  local flag="$1" path="$2" label="$3"
  if test "$flag" "$path"; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "$label not present on a CI runner; every test here would skip to green. If it moved, update this suite's paths in setup()." >&2
    return 1
  fi
  skip "$label not present"
}

# The chmod-000 fixtures below cannot arm as root, where a mode-000 file stays
# readable. Same shape as the two gates around it, and for the same reason: on
# CI the condition is not an environment difference to tolerate but a job that
# stopped running as it was configured to, and a skip there is a green test
# that asserted nothing.
require_non_root() {
  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "running as root on a CI runner, where a chmod 000 file stays readable, so this fixture would skip to green. This job is expected to run unprivileged." >&2
    return 1
  fi
  skip "running as root; a chmod 000 file stays readable"
}

# Same shape as retrigger-reachability.bats' and workflow-filter-coverage.bats'
# own gate: audit-ci-tests.yml installs python3-yaml in the same job that runs
# this suite, so the CI branch FAILS rather than skips.
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
  WORKFLOW="$REPO_ROOT/.github/workflows/audit-ci-tests.yml"
  POLLER_WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  CLI_WORKFLOW="$REPO_ROOT/.github/workflows/cli-tests.yml"
  BATS_SHARDS="$REPO_ROOT/.gaia/tests/bats-shards.sh"
  # Matches retrigger-reachability.bats' own constant: the self-heal poller
  # margin charged per hop of the needs: chain.
  POLLER_MARGIN_MIN=5
  # The four patterns W10 detects a zsh or PyYAML dependency by, written once
  # because three scans have to agree on them: two disagreeing copies would
  # each report a defensible set and W10 would compare them against each other.
  # The reasoning behind the four, and behind excluding bare `python3`, is in
  # the W10 header below.
  PKG_PATTERN='command -v zsh|zsh -c|require_yaml_parser|import yaml'
  # The two workflow lines the adversarial cases doctor, addressed by shape
  # rather than by text so a repack that rewrites either list stays a one-site
  # edit in the workflow. Each matches exactly one line today, which
  # sole_line_matching re-checks on every use; the reasoning for deriving them
  # is above that helper.
  APT_GATE_PATTERN='^ *- if: contains\(fromJSON\('
  MATRIX_SHARD_PATTERN='^ *shard: \['

  require_repo_path -f "$WORKFLOW" "audit-ci-tests.yml" || return 1
  require_repo_path -f "$POLLER_WORKFLOW" "code-review-audit.yml" || return 1
  require_repo_path -f "$CLI_WORKFLOW" "cli-tests.yml" || return 1
  require_repo_path -f "$BATS_SHARDS" "bats-shards.sh" || return 1
}

# read_wf <mode> <workflow-file> [arg]
#
# Reads the file's top-level `jobs:` mapping, structurally rather than by
# line-oriented scrape, for the same reason the sibling suites give: every
# shape a scrape has to be taught one at a time (a quoted job id, a folded
# `if: >-`, an inline list) is a shape a real parser already knows.
#
#   jobs                 every job id, one per line
#   name <job-id>         that job's raw `name:` value, unnormalized; empty if unset
#   if <job-id>           that job's `if:`, normalized; empty if unset
#   needs <job-id>        that job's `needs:` entries, one per line
#   capkind <job-id>      'int' | 'missing' | 'other', mirroring cap_of's
#                         bool/non-int rejection: an expression-valued cap
#                         reads as uncapped downstream, so this distinguishes
#                         "no cap declared" from "a cap that will not compare".
#   matrix <job-id>       that job's strategy.matrix.shard list, one per line
#   stepshards <job-id> <step-name>
#                         the shard ids named by that step's
#                         `contains(fromJSON('[...]'), matrix.shard)` gate, one
#                         per line, sorted. Exits 2 when no step carries the
#                         name, or when the one that does has no parseable,
#                         non-empty list -- each of which would otherwise read
#                         downstream as "this step gates on no shards".
#   codefilter <job-id>    that job's dorny/paths-filter step's `code:` list,
#                         one path per line, parsed as the nested YAML
#                         document the `filters:` field's block string holds
#                         rather than scraped line-by-line, for the same
#                         reason every other mode here parses structurally.
#                         Exits 2 when the job has no such step or the step
#                         has no `code:` list.
#   filtercount            total dorny/paths-filter steps in the whole file
#   filterifs              one `<job-id>\t<normalized-if>` line per step, across
#                         EVERY job, whose `if:` mentions steps.filter.outputs.
#   runinterp               one `<job-id>\t<step-name>` line per step whose RAW
#                         (unnormalized) `run:` body contains a literal `${{`
#   aggok <job-id>         'yes' if some single step in that job both
#                         references needs.shards.result (in its `run:` body
#                         or through an `env:` mapping) AND exits non-zero on
#                         a bad value, else 'no'
#   chain <margin>          the worst needs-chain over every job in the file,
#                         as "<minutes> <hops>", weighed by minutes + margin x
#                         hops -- same algorithm retrigger-reachability.bats
#                         uses for its own chain/weigh
#
# Exits 2 when the file will not parse, declares no jobs mapping, or names no
# such job. A caller must check the status.
read_wf() {
  python3 - "$@" <<'PY'
import json
import re
import sys

import yaml

mode = sys.argv[1]
path = sys.argv[2]
rest = sys.argv[3:]


def die(msg):
    sys.stderr.write('%s: %s\n' % (path, msg))
    sys.exit(2)


try:
    with open(path, encoding='utf-8') as handle:
        doc = yaml.safe_load(handle)
except (yaml.YAMLError, OSError) as exc:
    die('unreadable YAML (%s)' % exc.__class__.__name__)

jobs = doc.get('jobs') if isinstance(doc, dict) else None
if not isinstance(jobs, dict) or not jobs:
    die('no jobs mapping')
jobs = {str(k): (v if isinstance(v, dict) else {}) for k, v in jobs.items()}


def require_job(jid):
    if jid not in jobs:
        die('no job id %r' % jid)


def normalize(expr):
    """Collapse a gate to one comparable line, the same GitHub-equivalence
    fold every sibling suite applies: `if: <x>` and `if: ${{ <x> }}` are the
    same condition, and a folded scalar arrives already joined but irregularly
    spaced."""
    return ' '.join(str(expr).replace('${{', ' ').replace('}}', ' ').split())


def needs_of(jid):
    value = jobs[jid].get('needs')
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def cap_kind(jid):
    if 'timeout-minutes' not in jobs[jid]:
        return 'missing'
    value = jobs[jid]['timeout-minutes']
    if isinstance(value, bool) or not isinstance(value, int):
        return 'other'
    return 'int'


def cap_of(jid):
    return jobs[jid]['timeout-minutes'] if cap_kind(jid) == 'int' else None


def weigh(pair, margin):
    return pair[0] + margin * pair[1]


def chain(jid, seen, margin):
    best = (0, 0)
    for dep in needs_of(jid):
        if dep not in jobs or dep in seen:
            continue
        candidate = chain(dep, seen | {dep}, margin)
        if weigh(candidate, margin) > weigh(best, margin):
            best = candidate
    return (cap_of(jid) or 0) + best[0], best[1] + 1


if mode == 'jobs':
    print('\n'.join(jobs))
elif mode == 'name':
    require_job(rest[0])
    if 'name' in jobs[rest[0]]:
        print(str(jobs[rest[0]]['name']))
elif mode == 'if':
    require_job(rest[0])
    if 'if' in jobs[rest[0]]:
        print(normalize(jobs[rest[0]]['if']))
elif mode == 'needs':
    require_job(rest[0])
    for item in needs_of(rest[0]):
        print(item)
elif mode == 'capkind':
    require_job(rest[0])
    print(cap_kind(rest[0]))
elif mode == 'matrix':
    require_job(rest[0])
    shard = ((jobs[rest[0]].get('strategy') or {}).get('matrix') or {}).get('shard')
    if isinstance(shard, list):
        for item in shard:
            print(str(item))
elif mode == 'codefilter':
    require_job(rest[0])
    filter_step = None
    for step in jobs[rest[0]].get('steps') or []:
        if isinstance(step, dict) and 'dorny/paths-filter' in str(step.get('uses', '')):
            filter_step = step
            break
    if filter_step is None:
        die('job %r has no dorny/paths-filter step' % rest[0])
    filters_raw = (filter_step.get('with') or {}).get('filters')
    if not isinstance(filters_raw, str):
        die('job %r paths-filter step has no filters: string' % rest[0])
    try:
        filters_doc = yaml.safe_load(filters_raw)
    except yaml.YAMLError as exc:
        die('job %r filters: block is not valid YAML (%s)' % (rest[0], exc.__class__.__name__))
    code_list = (filters_doc or {}).get('code')
    if not isinstance(code_list, list):
        die('job %r filters: block has no code: list' % rest[0])
    for item in code_list:
        print(str(item))
elif mode == 'filtercount':
    count = 0
    for job in jobs.values():
        for step in job.get('steps') or []:
            if isinstance(step, dict) and 'dorny/paths-filter' in str(step.get('uses', '')):
                count += 1
    print(count)
elif mode == 'filterifs':
    for jid, job in jobs.items():
        for step in job.get('steps') or []:
            if not isinstance(step, dict):
                continue
            gate = normalize(step.get('if', ''))
            if 'steps.filter.outputs.' in gate:
                print('%s\t%s' % (jid, gate))
elif mode == 'runinterp':
    for jid, job in jobs.items():
        for step in job.get('steps') or []:
            if not isinstance(step, dict):
                continue
            body = str(step.get('run', ''))
            if '${{' in body:
                name = str(step.get('name', '')) or str(step.get('uses', ''))
                print('%s\t%s' % (jid, name))
elif mode == 'aggok':
    require_job(rest[0])
    exit_re = re.compile(r'\bexit\s+[1-9][0-9]*\b')
    found = False
    for step in jobs[rest[0]].get('steps') or []:
        if not isinstance(step, dict):
            continue
        body = str(step.get('run', ''))
        env = step.get('env') if isinstance(step.get('env'), dict) else {}
        env_hit = any('needs.shards.result' in str(v) for v in env.values())
        ref_hit = 'needs.shards.result' in body or env_hit
        if ref_hit and exit_re.search(body):
            found = True
            break
    print('yes' if found else 'no')
elif mode == 'stepshards':
    require_job(rest[0])
    wanted = rest[1]
    seen = False
    for step in jobs[rest[0]].get('steps') or []:
        if not isinstance(step, dict) or str(step.get('name', '')) != wanted:
            continue
        seen = True
        gate = normalize(step.get('if', ''))
        # The gate names its legs as a JSON array inside fromJSON(...). Read
        # that array with a JSON parser rather than splitting on commas: the
        # point of this mode is to report the list the workflow will actually
        # evaluate, and a hand-rolled split would disagree with GitHub the
        # first time the array is spaced or quoted differently.
        #
        # Anchored at the start of the gate, and required to be the positive
        # `contains(...)` form, because this mode reports a MEMBERSHIP list and
        # every caller reads it as "the legs this step runs on". A gate written
        # `!contains(fromJSON('[...]'), matrix.shard)` yields a byte-identical
        # list while meaning the exact complement, so an unanchored search
        # would report the step running on the legs it is the only one to skip.
        # Refusing the shape is the safe direction: a gate this cannot read is
        # a gate whose polarity nothing downstream has established.
        found = re.match(
            r"contains\(\s*fromJSON\(\s*'(\[[^']*\])'\s*\)\s*,\s*matrix\.shard\s*\)",
            gate,
        )
        if found is None:
            die(
                'step %r does not open with a positive '
                "contains(fromJSON('[...]'), matrix.shard) gate: %r" % (wanted, gate)
            )
        try:
            names = json.loads(found.group(1))
        except ValueError:
            die('step %r has an unparseable fromJSON shard list' % wanted)
        if not isinstance(names, list) or not names:
            die('step %r names an empty shard list' % wanted)
        # Deduped, because the other side of W10's comparison is `sort -u`. A
        # repeated id in the gate is harmless to GitHub, whose `contains` is a
        # membership test, but an undeduped read here would red W10 while
        # printing two lists that read as identical.
        for item in sorted({str(entry) for entry in names}):
            print(item)
    if not seen:
        die('no step named %r in job %r' % (wanted, rest[0]))
elif mode == 'chain':
    try:
        margin = int(rest[0])
    except ValueError:
        die('margin %r is not a number' % rest[0])
    print('%d %d' % max((chain(jid, {jid}, margin) for jid in jobs), key=lambda p: weigh(p, margin)))
else:
    die('unknown mode %r' % mode)
PY
}

# The completion-poll window in code-review-audit.yml's poll_and_stamp, in
# minutes: iterations x sleep seconds. Derived from the workflow rather than
# restated as a literal, so a change to the poller re-derives the ceiling
# below instead of leaving this guard enforcing a number the poller no longer
# honors. Byte-identical to retrigger-reachability.bats' own copy: both guards
# need the same derivation and there is no shared helpers file to put it in.
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

chain_ceiling() {
  local window="$1" hops="$2"
  printf '%s' "$(( window - POLLER_MARGIN_MIN * hops ))"
}

# Writes a copy of $1 to $4 with every line that equals $2 byte-for-byte
# replaced by $3. Python string equality, not sed/awk regex, because a
# workflow line routinely contains `${{ }}`, `[ ]`, and other regex
# metacharacters that would need escaping to match literally; equality
# sidesteps that entirely. Values travel through the environment so neither
# argument has to survive bash's own quoting.
replace_line() {
  local src="$1" old="$2" new="$3" out="$4"
  OLD_LINE="$old" NEW_LINE="$new" python3 - "$src" "$out" <<'PY'
import os
import sys

src, out = sys.argv[1], sys.argv[2]
old = os.environ['OLD_LINE']
new = os.environ['NEW_LINE']
with open(src, encoding='utf-8') as handle:
    lines = handle.read().split('\n')
lines = [new if line == old else line for line in lines]
with open(out, 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(lines))
PY
}

# The adversarial cases that doctor a list-bearing workflow line read the line
# out of the workflow with the two helpers below rather than restating it. Both
# of those lists are packing decisions, not settled constants: the hooks legs
# are a weighted split, so adding tests to any suite can move it onto a
# different leg, and the apt gate's leg list moves with it. A restated search
# line makes every such repack a five-site edit, four of them here.
#
# Deriving it costs an independence worth naming, because that is the reason to
# think twice. A restated line cannot silently agree with a wrong workflow, and
# a drifted copy makes replace_line no-op, which reds the case rather than
# greening it. Both helpers hold that direction: sole_line_matching fails when
# its pattern stops matching or starts matching twice, and assert_doctored
# fails when the transform leaves the line untouched. The diagnostic is what
# differs -- each helper names the drift, where a silent no-op reports a failed
# invariant and leaves the reader to work out that the fixture, not the
# workflow, is stale.
#
# What derivation does NOT reach is the guards' own independence. W6 and W10
# each compare the workflow's list against a set derived from the sharder or
# the suites, and those comparisons stay untouched. An adversarial case only
# has to prove its check reds on a doctored input, which never requires it to
# know what the healthy list says. The transform stays written out at each
# case, because which mutation is being made is the part each case is about.

# Prints the single line of $1 matching the extended regex $2, so a case can
# doctor the workflow's current text. Fails on zero matches or more than one:
# either means the workflow changed shape, which this suite has to see rather
# than doctor a line it did not mean to.
sole_line_matching() {
  local src="$1" pattern="$2" hits count
  hits="$(grep -nE -- "$pattern" "$src")" || {
    echo "sole_line_matching: no line in $src matches /$pattern/" >&2
    return 1
  }
  count="$(printf '%s\n' "$hits" | grep -c '')"
  [ "$count" -eq 1 ] || {
    echo "sole_line_matching: /$pattern/ matches $count lines in $src, expected exactly 1" >&2
    printf '%s\n' "$hits" >&2
    return 1
  }
  printf '%s' "${hits#*:}"
}

# Fails when the transform in $2 left $1 unchanged, naming it as $3. replace_line
# no-ops silently on an absent search line, so an inert transform writes a copy
# of the healthy workflow; every case here then reds on an undoctored file with
# a message about the invariant rather than about the transform.
assert_doctored() {
  local original="$1" doctored="$2" what="$3"
  [ "$doctored" != "$original" ] || {
    echo "$what: left the line unchanged, so the case would assert against an undoctored workflow" >&2
    echo "line: $original" >&2
    return 1
  }
}

# Writes a copy of $1 to $3 with every line equal to $2 removed outright.
delete_line() {
  local src="$1" old="$2" out="$3"
  OLD_LINE="$old" python3 - "$src" "$out" <<'PY'
import os
import sys

src, out = sys.argv[1], sys.argv[2]
old = os.environ['OLD_LINE']
with open(src, encoding='utf-8') as handle:
    lines = handle.read().split('\n')
lines = [line for line in lines if line != old]
with open(out, 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(lines))
PY
}

# Writes a copy of $1 to $3 with every line from the FIRST line equal to $2
# through end-of-file replaced by $3's replacement text.
replace_from() {
  local src="$1" start="$2" replacement="$3" out="$4"
  START_LINE="$start" REPLACEMENT="$replacement" python3 - "$src" "$out" <<'PY'
import os
import sys

src, out = sys.argv[1], sys.argv[2]
start = os.environ['START_LINE']
replacement = os.environ['REPLACEMENT']
with open(src, encoding='utf-8') as handle:
    lines = handle.read().split('\n')
try:
    i = lines.index(start)
except ValueError:
    sys.stderr.write('replace_from: boundary line not found: %r\n' % start)
    sys.exit(2)
lines[i:] = replacement.split('\n') if replacement else []
with open(out, 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(lines))
PY
}

# Writes a copy of $1 to $4 with $3's lines inserted immediately after the
# first line equal to $2.
insert_after() {
  local src="$1" anchor="$2" insertion="$3" out="$4"
  ANCHOR_LINE="$anchor" INSERTION="$insertion" python3 - "$src" "$out" <<'PY'
import os
import sys

src, out = sys.argv[1], sys.argv[2]
anchor = os.environ['ANCHOR_LINE']
insertion = os.environ['INSERTION']
with open(src, encoding='utf-8') as handle:
    lines = handle.read().split('\n')
try:
    i = lines.index(anchor)
except ValueError:
    sys.stderr.write('insert_after: anchor line not found: %r\n' % anchor)
    sys.exit(2)
lines[i + 1:i + 1] = insertion.split('\n')
with open(out, 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(lines))
PY
}

# The parser gate above is the single point where every parser-gated test in
# this file, W10 among them, can be turned off at once, and nothing else here
# would notice if it started skipping on CI: a lib leg that lost python3-yaml
# would report `ok ... # skip` for each of them and green the job with the
# shard-list invariant retired. This test is what makes that weakening red.
# Same shape as the sibling gates' own proving tests in lint-yaml.bats,
# workflow-filter-coverage.bats, retrigger-reachability.bats, and
# block-invalid-yaml-write.bats. Not itself gated.

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
    echo "the gate skipped on a CI runner with no YAML parser; every parser-gated test here would report green" >&2
    return 1
  }

  rc=0
  ( PATH="$shim"; unset GITHUB_ACTIONS; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where a missing parser must still skip" >&2
    return 1
  }
}

# W1. Exactly one job carries the required context name, byte-exact at four
# spaces -- the literal shape retrigger-reachability.bats' workflow_for_context
# resolves the context by.

@test "W1: exactly one job carries the required context name" {
  require_yaml_parser

  [ "$(read_wf name "$WORKFLOW" audit-ci-tests)" = "Audit CI Tests" ] || {
    echo "job id audit-ci-tests does not carry name: Audit CI Tests" >&2
    return 1
  }

  local other extra=""
  for other in $(read_wf jobs "$WORKFLOW"); do
    [ "$other" = "audit-ci-tests" ] && continue
    [ "$(read_wf name "$WORKFLOW" "$other")" = "Audit CI Tests" ] && extra="$extra $other"
  done
  [ -z "$extra" ] || { echo "job(s) other than audit-ci-tests also carry name: Audit CI Tests:${extra}" >&2; return 1; }

  read_wf needs "$WORKFLOW" audit-ci-tests | grep -qxF "shards" || {
    echo "audit-ci-tests does not needs: shards" >&2
    return 1
  }

  [ "$(grep -c '^    name: Audit CI Tests$' "$WORKFLOW")" -eq 1 ] || {
    echo "expected exactly one raw '    name: Audit CI Tests' line" >&2
    return 1
  }
}

@test "W1 adversarial: renaming the aggregator's name is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w1a.yml"
  replace_line "$WORKFLOW" "    name: Audit CI Tests" "    name: Audit CI Tests Renamed" "$doctored"

  [ "$(read_wf name "$doctored" audit-ci-tests)" != "Audit CI Tests" ] || {
    echo "the renamed job still read back as Audit CI Tests" >&2
    return 1
  }
  [ "$(grep -c '^    name: Audit CI Tests$' "$doctored")" -eq 0 ] || {
    echo "the raw grep still found the old name after renaming" >&2
    return 1
  }
}

@test "W1 adversarial: two jobs carrying the same name is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w1b.yml"
  replace_line "$WORKFLOW" '    name: shard ${{ matrix.shard }}' "    name: Audit CI Tests" "$doctored"

  [ "$(grep -c '^    name: Audit CI Tests$' "$doctored")" -eq 2 ] || {
    echo "doctoring did not produce two matching name: lines" >&2
    return 1
  }
}

# W2. The aggregator runs on a dependency failure and on a dispatch.

@test "W2: the aggregator's if: admits always() and workflow_dispatch, never negated" {
  require_yaml_parser
  local expr
  expr="$(read_wf if "$WORKFLOW" audit-ci-tests)"
  printf '%s' "$expr" | grep -qF "always()" || { echo "aggregator if: missing always(): ${expr}" >&2; return 1; }
  printf '%s' "$expr" | grep -qF "workflow_dispatch" || { echo "aggregator if: missing workflow_dispatch: ${expr}" >&2; return 1; }
  printf '%s' "$expr" | grep -qF -- "!= 'workflow_dispatch'" && { echo "aggregator if: negates workflow_dispatch: ${expr}" >&2; return 1; }
  true
}

@test "W2 adversarial: stripping always() from the aggregator's if: is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w2.yml"
  replace_line "$WORKFLOW" \
    "    if: always() && (github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch')" \
    "    if: github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'" \
    "$doctored"

  local expr
  expr="$(read_wf if "$doctored" audit-ci-tests)"
  printf '%s' "$expr" | grep -qF "always()" && { echo "doctoring failed to strip always()" >&2; return 1; }
  true
}

# W3. The aggregator actually adjudicates the shard result: a step both
# references needs.shards.result and exits non-zero on a bad value.

@test "W3: the aggregator has a step that both reads and adjudicates needs.shards.result" {
  require_yaml_parser
  [ "$(read_wf aggok "$WORKFLOW" audit-ci-tests)" = "yes" ] || {
    echo "no aggregator step both references needs.shards.result and exits non-zero on a bad value" >&2
    return 1
  }
}

@test "W3 adversarial: a bare true aggregator step is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w3.yml"
  local replacement=$'      - name: Require every shard to have succeeded\n        run: true'
  replace_from "$WORKFLOW" "      - name: Require every shard to have succeeded" "$replacement" "$doctored"

  [ "$(read_wf aggok "$doctored" audit-ci-tests)" = "no" ] || {
    echo "a bare 'true' step still read as adjudicating the shard result" >&2
    return 1
  }
}

# W4. No step anywhere in the workflow is gated on a dispatch-skipped filter
# alone. The generalization of retrigger-reachability.bats' required-context-
# scoped test to every shard leg, which that suite no longer reaches once the
# only required-context job here is the filter-less aggregator.

@test "W4: no step in the workflow is gated on steps.filter.outputs. without also admitting workflow_dispatch" {
  require_yaml_parser
  local jid expr gaps="" count=0
  while IFS=$'\t' read -r jid expr; do
    [ -n "$jid" ] || continue
    count=$((count + 1))
    if printf '%s' "$expr" | grep -qF -- "!= 'workflow_dispatch'"; then
      gaps="${gaps}${jid}: negates workflow_dispatch -> ${expr}"$'\n'
      continue
    fi
    printf '%s' "$expr" | grep -qF -- "workflow_dispatch" || gaps="${gaps}${jid}: excludes workflow_dispatch -> ${expr}"$'\n'
  done < <(read_wf filterifs "$WORKFLOW")

  [ "$count" -gt 0 ] || {
    echo "no step in the workflow is gated on steps.filter.outputs.; this test asserted nothing" >&2
    return 1
  }
  [ -z "$gaps" ] || { printf '%s' "$gaps" >&2; return 1; }
}

@test "W4 adversarial: dropping the dispatch admission from one shard step is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w4.yml"
  replace_line "$WORKFLOW" \
    "      - if: matrix.shard != 'sandbox' && matrix.shard != 'concurrency' && (steps.filter.outputs.code == 'true' || github.event_name == 'workflow_dispatch')" \
    "      - if: matrix.shard != 'sandbox' && matrix.shard != 'concurrency' && steps.filter.outputs.code == 'true'" \
    "$doctored"

  local jid expr found_gap=""
  while IFS=$'\t' read -r jid expr; do
    [ -n "$jid" ] || continue
    printf '%s' "$expr" | grep -qF -- "workflow_dispatch" || found_gap="x"
  done < <(read_wf filterifs "$doctored")
  [ -n "$found_gap" ] || { echo "doctoring the step's if: did not produce a gap" >&2; return 1; }
}

# W5. Both jobs are capped with an integer literal, and the worst needs: chain
# fits the poller-derived ceiling.

@test "W5: both jobs declare an integer cap, and the worst chain fits the ceiling" {
  require_yaml_parser
  local jid gaps="" window minutes hops ceiling
  for jid in $(read_wf jobs "$WORKFLOW"); do
    [ "$(read_wf capkind "$WORKFLOW" "$jid")" = "int" ] || gaps="${gaps}${jid} "
  done
  [ -z "$gaps" ] || { echo "job(s) without an integer timeout-minutes:${gaps}" >&2; return 1; }

  window="$(poller_window_minutes "$POLLER_WORKFLOW")"
  [ -n "$window" ] || { echo "could not derive the poll window from $(basename "$POLLER_WORKFLOW")" >&2; return 1; }

  read -r minutes hops < <(read_wf chain "$WORKFLOW" "$POLLER_MARGIN_MIN")
  ceiling="$(chain_ceiling "$window" "$hops")"
  [ "$minutes" -le "$ceiling" ] || {
    echo "worst chain ${minutes}m over ${hops} hops exceeds the ${ceiling}m ceiling (window ${window}m)" >&2
    return 1
  }
}

@test "W5 adversarial: an over-cap aggregator is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w5a.yml" window minutes hops ceiling
  replace_line "$WORKFLOW" "    timeout-minutes: 2" "    timeout-minutes: 40" "$doctored"

  window="$(poller_window_minutes "$POLLER_WORKFLOW")"
  read -r minutes hops < <(read_wf chain "$doctored" "$POLLER_MARGIN_MIN")
  ceiling="$(chain_ceiling "$window" "$hops")"
  [ "$minutes" -gt "$ceiling" ] || {
    echo "raising the aggregator's cap to 40 did not exceed the ceiling" >&2
    return 1
  }
}

@test "W5 adversarial: a job with no timeout-minutes is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w5b.yml"
  delete_line "$WORKFLOW" "    timeout-minutes: 2" "$doctored"

  [ "$(read_wf capkind "$doctored" audit-ci-tests)" = "missing" ] || {
    echo "deleting timeout-minutes did not read back as missing" >&2
    return 1
  }
}

@test "W5 adversarial: an expression-valued cap is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w5c.yml"
  replace_line "$WORKFLOW" "    timeout-minutes: 13" "    timeout-minutes: \${{ github.event_name }}" "$doctored"

  [ "$(read_wf capkind "$doctored" shards)" = "other" ] || {
    echo "an expression-valued cap still read as an integer" >&2
    return 1
  }
}

# W6. The matrix and bats-shards.sh agree: the matrix is exactly the sharder's
# own shard ids plus sandbox and concurrency, no extras in either direction.

@test "W6: the matrix and the sharder agree" {
  require_yaml_parser
  local matrix_list expected
  matrix_list="$(read_wf matrix "$WORKFLOW" shards | LC_ALL=C sort)"
  expected="$(printf '%s\nsandbox\nconcurrency\n' "$(bash "$BATS_SHARDS" shards)" | LC_ALL=C sort)"

  [ "$matrix_list" = "$expected" ] || {
    echo "matrix shard list does not equal bats-shards.sh shards plus sandbox/concurrency" >&2
    echo "matrix:   $(printf '%s' "$matrix_list" | tr '\n' ' ')" >&2
    echo "expected: $(printf '%s' "$expected" | tr '\n' ' ')" >&2
    return 1
  }
}

@test "W6 adversarial: a bogus shard added to the matrix is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w6a.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" "$MATRIX_SHARD_PATTERN")" || return 1
  mutated="$(printf '%s' "$line" | sed 's/\]$/, bogus]/')"
  assert_doctored "$line" "$mutated" "appending a bogus shard id" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  local matrix_list expected
  matrix_list="$(read_wf matrix "$doctored" shards | LC_ALL=C sort)"
  expected="$(printf '%s\nsandbox\nconcurrency\n' "$(bash "$BATS_SHARDS" shards)" | LC_ALL=C sort)"
  [ "$matrix_list" != "$expected" ] || { echo "adding a bogus shard id did not desync the matrix from the sharder" >&2; return 1; }
}

@test "W6 adversarial: dropping lib from the matrix is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w6b.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" "$MATRIX_SHARD_PATTERN")" || return 1
  # Three forms because the list is comma-separated and lib can sit anywhere in
  # it. Each bounds both sides of the id, so a future shard whose name ENDS in
  # lib is not silently rewritten instead: that would leave a changed line
  # assert_doctored accepts while the case no longer performs the mutation its
  # name states.
  mutated="$(printf '%s' "$line" | sed -e 's/\[lib, /[/' -e 's/, lib, /, /' -e 's/, lib\]/]/')"
  assert_doctored "$line" "$mutated" "dropping lib" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  local matrix_list expected
  matrix_list="$(read_wf matrix "$doctored" shards | LC_ALL=C sort)"
  expected="$(printf '%s\nsandbox\nconcurrency\n' "$(bash "$BATS_SHARDS" shards)" | LC_ALL=C sort)"
  [ "$matrix_list" != "$expected" ] || { echo "dropping lib from the matrix did not desync it from the sharder" >&2; return 1; }
}

# W7. Exactly one dorny/paths-filter step in the whole workflow, pinning the
# decision not to narrow filters per shard.

@test "W7: exactly one dorny/paths-filter step in the whole workflow" {
  require_yaml_parser
  [ "$(read_wf filtercount "$WORKFLOW")" -eq 1 ] || {
    echo "expected exactly one dorny/paths-filter step, got $(read_wf filtercount "$WORKFLOW")" >&2
    return 1
  }
}

@test "W7 adversarial: a second dorny/paths-filter step is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w7.yml"
  local extra_job
  extra_job=$'  extra-filter-job:\n    runs-on: ubuntu-latest\n    timeout-minutes: 1\n    steps:\n      - uses: dorny/paths-filter@ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d # v4.0.3\n        id: filter2'
  insert_after "$WORKFLOW" "jobs:" "$extra_job" "$doctored"

  [ "$(read_wf filtercount "$doctored")" -eq 2 ] || {
    echo "adding a second paths-filter step did not raise the count" >&2
    return 1
  }
}

# W8. No run: body interpolates an expression; ${{ matrix.shard }} reaches a
# script only through env:.

@test "W8: no run: body in the workflow interpolates an expression" {
  require_yaml_parser
  local hits
  hits="$(read_wf runinterp "$WORKFLOW")"
  [ -z "$hits" ] || {
    echo "run: body interpolates an expression:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  }
}

@test "W8 adversarial: interpolating matrix.shard into a run: body is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w8.yml"
  replace_line "$WORKFLOW" \
    '        run: bash .gaia/tests/bats-shards.sh run "$SHARD"' \
    '        run: bash .gaia/tests/bats-shards.sh run "${{ matrix.shard }}"' \
    "$doctored"

  [ -n "$(read_wf runinterp "$doctored")" ] || {
    echo "interpolating matrix.shard into the run: body was not caught" >&2
    return 1
  }
}

# W9. The sandbox leg's reduced package set (no apt at all) stays true: no
# sandbox suite references zsh, python3, or require_yaml_parser. This is what
# converts that install step's missing apt line from an assumption into a
# checked invariant, per the sibling correction that a per-shard package list
# is a silent-green hazard unless something checks the reduced set.

# True when directory $1 holds at least one .bats. An unmatched glob stays
# LITERAL rather than expanding to nothing, so `-e` on the first expansion is
# the only way to tell a real match from the pattern itself. Lifted out of W9
# so the fixture below can point it at a directory of its own: a precondition
# only ever run against the healthy tree takes its passing branch every time,
# and a later refactor that neuters it would restore the vacuous pass with
# this suite still green.
sandbox_suites_present() {
  local dir="$1" suites
  suites=("$dir"/*.bats)
  [ -e "${suites[0]}" ] && return 0
  echo "no .bats suites under $dir: W9 would assert nothing" >&2
  return 1
}

@test "W9: no .gaia/tests/sandbox suite references zsh, python3, or require_yaml_parser" {
  local hits rc
  local suites
  require_repo_path -d "$REPO_ROOT/.gaia/tests/sandbox" "sandbox suite dir" || return 1
  sandbox_suites_present "$REPO_ROOT/.gaia/tests/sandbox" || return 1
  suites=("$REPO_ROOT"/.gaia/tests/sandbox/*.bats)
  # grep exits 1 on a clean no-match and 2 on a hard error (an unreadable
  # file, a bad pattern). A blanket `|| true` cannot tell those apart and
  # would report green on the error, which is the same assert-nothing pass
  # the precondition above exists to prevent, so only 1 is accepted.
  rc=0
  hits="$(grep -lE 'zsh|python3|require_yaml_parser' "${suites[@]}")" || rc=$?
  [ "$rc" -le 1 ] || {
    echo "W9: grep failed to scan the sandbox suites (exit $rc); nothing was asserted" >&2
    return 1
  }
  [ -z "$hits" ] || {
    echo "sandbox suite(s) reference a package the sandbox leg's install step does not carry:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  }
}

@test "W9 adversarial: a sandbox fixture naming zsh is caught" {
  local dir="$BATS_TEST_TMPDIR/sandbox-fixture" at test_line
  mkdir -p "$dir"
  # Built from a variable rather than written literally: bats' preprocessor
  # rewrites any line matching ^[[:blank:]]*@test[[:blank:]]+...{ anywhere in
  # this suite's own source, including inside this heredoc, so a literal
  # `@test "..." {` line here would be rewritten by bats parsing THIS file.
  at='@'
  test_line="${at}test \"needs zsh\" {"
  {
    printf '#!/usr/bin/env bats\n\n'
    printf '%s\n' "$test_line"
    printf '  command -v zsh\n'
    printf '}\n'
  } > "$dir/fixture.bats"

  grep -qE 'zsh|python3|require_yaml_parser' "$dir"/*.bats || {
    echo "a fixture naming zsh was not caught" >&2
    return 1
  }
}

# Pairs with W9's preconditions the way every other check here pairs with its
# own fixture: both vacuous-pass arms are driven against a directory of this
# test's own, since neither arm ever fires against the healthy tree.
@test "W9 adversarial: an empty or absent sandbox directory is caught" {
  local empty="$BATS_TEST_TMPDIR/sandbox-empty"
  local absent="$BATS_TEST_TMPDIR/sandbox-absent"
  local populated="$BATS_TEST_TMPDIR/sandbox-populated"

  mkdir -p "$empty" "$populated"
  printf '#!/usr/bin/env bats\n' >"$populated/real.bats"

  run sandbox_suites_present "$empty"
  [ "$status" -eq 1 ]
  run sandbox_suites_present "$absent"
  [ "$status" -eq 1 ]
  # The healthy arm, so a helper that simply always failed could not pass this.
  run sandbox_suites_present "$populated"
  [ "$status" -eq 0 ]
}

# W10. The apt step's shard list stays equal to the set of legs that actually
# draw a suite needing zsh or a YAML parser. W9 pins the sandbox leg's EMPTY
# package set; this pins the reduced set on the legs that do get one, which is
# the other half of the same argument: a per-shard package list is safe only
# while something recomputes it from the suites. Both dependencies fail
# asymmetrically, which is why this is a checked invariant rather than a
# comment. zsh-gated tests `skip` silently, so a leg that lost zsh reports a
# clean green having asserted nothing; the parser-gated suites fail loudly
# under GITHUB_ACTIONS, so a leg that lost python3-yaml reds. Only the first is
# invisible, and it is the one a round-robin reshuffle causes.
#
# Detection is deliberately over-inclusive rather than exact. Four patterns,
# matched anywhere in a file including inside an adversarial fixture that only
# prints the string: `command -v zsh` and `require_yaml_parser` catch a suite
# using the established gates, and `zsh -c` and `import yaml` catch one that
# reaches for either dependency without them, which is the case that would
# otherwise go undetected. An over-match adds a package to a leg that did not
# need it, which costs seconds; an under-match silently retires a suite's
# assertions. Cost is the acceptable error here and silence is not.
#
# Bare `python3` is deliberately NOT a pattern, even though W9 uses it for the
# sandbox leg. python3 itself is preinstalled on the runner; the package this
# step installs is PyYAML, and a great many suites here shell out to python3
# for structural JSON reads that need no YAML at all. Matching it would put
# nearly every leg back on the list and undo the narrowing entirely.

# shard_package_needs <bats-shards.sh> <repo-root>
#
# The shard ids holding at least one suite that names zsh or the YAML-parser
# gate, one per line, LC_ALL=C sorted. Takes both paths as arguments, never
# reading $REPO_ROOT directly, so the fixture below can drive this same code
# against a tree of its own -- the discipline this suite's header sets out.
# The loop deliberately does NOT pipe into `sort`. Piping would put the whole
# loop in a subshell, where the `return 1` below terminates only that subshell
# and the function's status becomes `sort`'s, which is 0: a grep hard error
# would abort the scan mid-way, truncate the shard list, and still report
# success, so every `|| return 1` at this helper's call sites would be dead
# code. Accumulate into a variable and sort afterwards, in the function's own
# shell, so the error actually reaches the caller.
shard_package_needs() {
  local sharder="$1" root="$2" id rel abs rc hits listing dirs dir helper found=''
  for id in $(bash "$sharder" shards); do
    hits=''
    dirs=''
    # Captured, and its status checked, rather than consumed straight from a
    # process substitution: the sharder exits 2 on a shard that resolves zero
    # files, and read from a `< <(...)` that status is unobservable. The loop
    # would simply see no input and the shard would report "needs nothing",
    # which is the fail-open this whole helper is written to avoid.
    rc=0
    listing="$(bash "$sharder" files "$id")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "shard_package_needs: the sharder could not list $id (exit $rc)" >&2
      return 1
    fi
    while IFS= read -r rel || [ -n "$rel" ]; do
      [ -n "$rel" ] || continue
      # `files` prints repo-relative for a path under the sharder's own root
      # and absolute for one reached through a seam override, the same split
      # its own `run` re-absolutizes. Prefixing unconditionally would build
      # <root>/<absolute> and grep would miss every file under an override.
      case "$rel" in
        /*) abs="$rel" ;;
        *) abs="$root/$rel" ;;
      esac
      dirs="$dirs${abs%/*}
"
      rc=0
      grep -qE "$PKG_PATTERN" "$abs" || rc=$?
      # 0 is a match, 1 a clean miss, anything else a hard grep error. An
      # error must not read as "this shard needs nothing", so it propagates.
      if [ "$rc" -eq 0 ]; then
        hits=yes
      elif [ "$rc" -ne 1 ]; then
        echo "shard_package_needs: grep failed on $abs (exit $rc)" >&2
        return 1
      fi
    done <<EOF
$listing
EOF
    # The suites' own helpers, which are sourced INTO them: a helper reaching
    # for either dependency arms the same silent skip the suite would, and a
    # scan of `.bats` alone never sees it. They are reached from each suite's
    # own directory rather than from a list of helper directories, so a new one
    # is covered by existing there. A helper is shared by every suite beside
    # it, so this can report a package for a leg whose own suites name nothing;
    # that is the over-inclusive direction this check already prefers.
    # Captured and status-checked for the same reason the sharder listing
    # above is: consumed straight from a heredoc the sort's status is
    # unobservable, and a failed sort yields an empty list, zero helper
    # iterations, and "no helper names a package" at status 0.
    #
    # Deliberately without an adversarial fixture, unlike the listing and grep
    # arms around it: both of those fail on inputs a test can construct (a
    # missing pinned hook, a mode-000 file), while this sorts a short string
    # already in memory. The check is here for symmetry of shape, not because
    # a reachable failure is being guarded.
    rc=0
    dirs="$(printf '%s' "$dirs" | LC_ALL=C sort -u)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "shard_package_needs: could not sort $id's helper directories (exit $rc)" >&2
      return 1
    fi
    while IFS= read -r dir || [ -n "$dir" ]; do
      [ -n "$dir" ] || continue
      for helper in "$dir/helpers" "$dir/lib"; do
        [ -d "$helper" ] || continue
        rc=0
        grep -rqE "$PKG_PATTERN" --include='*.sh' "$helper" || rc=$?
        if [ "$rc" -eq 0 ]; then
          hits=yes
        elif [ "$rc" -ne 1 ]; then
          echo "shard_package_needs: grep failed on $helper (exit $rc)" >&2
          return 1
        fi
      done
    done <<EOF
$dirs
EOF
    if [ -n "$hits" ]; then
      found="$found$id
"
    fi
  done
  [ -n "$found" ] || return 0
  printf '%s' "$found" | LC_ALL=C sort -u
}

@test "W10: the apt step's shard list equals the legs that need zsh or a YAML parser" {
  local declared needed
  # read_wf's reader imports yaml unconditionally, so without this gate a box
  # without PyYAML reports a workflow defect for a missing local dependency,
  # while every sibling check here skips. Fails rather than skips on CI, which
  # is the behavior this suite's own gate helper already defines.
  require_yaml_parser
  declared="$(read_wf stepshards "$WORKFLOW" shards 'Install the YAML parser and zsh')" || {
    echo "could not read the apt step's shard list" >&2
    return 1
  }
  needed="$(shard_package_needs "$BATS_SHARDS" "$REPO_ROOT")" || return 1

  [ -n "$needed" ] || {
    echo "no shard resolved a zsh or YAML-parser dependency; W10 would assert nothing" >&2
    return 1
  }
  [ "$declared" = "$needed" ] || {
    echo "the apt step's shard list and the suites disagree." >&2
    echo "workflow names:" >&2
    printf '%s\n' "$declared" >&2
    echo "suites need:" >&2
    printf '%s\n' "$needed" >&2
    echo "Repair: copy the 'suites need' set into the step's fromJSON list." >&2
    return 1
  }
}

@test "W10 adversarial: dropping a needed shard from the apt step is caught" {
  local doctored="$BATS_TEST_TMPDIR/dropped.yml" declared needed line mutated
  require_yaml_parser

  line="$(sole_line_matching "$WORKFLOW" "$APT_GATE_PATTERN")" || return 1
  # Only the final id is followed by the closing bracket, so this drops one
  # leg rather than the tail of the list.
  mutated="$(printf '%s' "$line" | sed 's/, "[^"]*"\]/]/')"
  assert_doctored "$line" "$mutated" "dropping the last shard id" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  declared="$(read_wf stepshards "$doctored" shards 'Install the YAML parser and zsh')" || {
    echo "the doctored workflow did not parse" >&2
    return 1
  }
  needed="$(shard_package_needs "$BATS_SHARDS" "$REPO_ROOT")" || return 1
  [ "$declared" = "$needed" ] && {
    echo "dropping the last shard id from the apt step was not caught" >&2
    return 1
  }
  true
}

# A whole fake seam under $1: a `needs` directory the hooks shards draw from
# and a `clean` one every other shard does, so both branches of the grep are
# exercised against a tree the caller owns. Driving the real sharder with its
# documented seam overrides is what keeps these fixtures honest -- it is the
# same code path W10 runs.
#
# Each directory is filled with as many suites as the sharder has shards, which
# is not padding: a shard resolving zero files is a fail-closed exit 2 that
# shard_package_needs propagates, so a directory holding fewer suites than its
# group has buckets would fail every fixture here for a reason none of them is
# about. Deriving the count from the sharder keeps that true as groups resize.
# local-janitor.bats is written because hooks-1 pins it by name; its body is
# plain, so hooks-1 never joins the reported set.
seed_seam_tree() {
  local root="$1" n i
  mkdir -p "$root/needs" "$root/clean"
  n="$(bash "$BATS_SHARDS" shards | wc -l | tr -d ' ')"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '#!/usr/bin/env bats\n' >"$root/needs/plain-$i.bats"
    printf '#!/usr/bin/env bats\n' >"$root/clean/plain-$i.bats"
    i=$((i + 1))
  done
  printf '#!/usr/bin/env bats\n' >"$root/needs/local-janitor.bats"
}

# Runs shard_package_needs over a tree seeded by seed_seam_tree, with every
# seam pointed at it.
seam_tree_needs() {
  local root="$1"
  HOOKS_DIR="$root/needs" SCRIPTS_TESTS_DIR="$root/clean" \
    AUDIT_TESTS_DIR="$root/clean" LIB_DIR="$root/clean" \
    FORENSICS_DIR="$root/clean" STATUSLINE_DIR="$root/clean" \
    shard_package_needs "$BATS_SHARDS" "$root"
}

# The apt list is only meaningful as a MEMBERSHIP list, and a negated gate
# produces a byte-identical one meaning the exact complement: the step would
# run on every leg except the ones that need it, W10 would compare two equal
# lists, and the check would green over the worst possible arrangement. This
# pins that stepshards refuses the shape instead of reading it.
@test "W10 adversarial: a negated apt gate is refused rather than read as the same list" {
  local doctored="$BATS_TEST_TMPDIR/negated.yml" declared rc=0 line mutated
  require_yaml_parser

  # Wrapped in ${{ }} because a bare leading `!` is a YAML tag indicator and
  # the file would not parse at all, which is a different failure from the one
  # under test. normalize() strips the wrapper, so the gate reaches the reader
  # exactly as GitHub would evaluate it.
  line="$(sole_line_matching "$WORKFLOW" "$APT_GATE_PATTERN")" || return 1
  mutated="$(printf '%s' "$line" | sed 's/- if: \(.*\)$/- if: ${{ !\1 }}/')"
  assert_doctored "$line" "$mutated" "negating the gate" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  declared="$(read_wf stepshards "$doctored" shards 'Install the YAML parser and zsh' 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "a negated gate was read as a shard list rather than refused:" >&2
    printf '%s\n' "$declared" >&2
    return 1
  }
}

@test "W10 adversarial: a shard whose suite names zsh is detected wherever it lands" {
  local root="$BATS_TEST_TMPDIR/tree" out reported
  seed_seam_tree "$root"
  printf '#!/usr/bin/env bats\ncommand -v zsh\n' >"$root/needs/uses-zsh.bats"

  out="$(seam_tree_needs "$root")" || return 1

  # Asserted as "exactly one hooks leg other than the pinned one", not as a
  # named leg: which shard a file lands on is the weighted assignment's call,
  # and pinning the answer here would make this fixture a second, silent copy
  # of that assignment. What it is actually for is the claim in its own name --
  # the file is detected wherever it lands.
  reported="$(printf '%s\n' "$out" | grep -c .)"
  [ "$reported" -eq 1 ] || {
    echo "expected exactly one shard to be reported, got $reported:" >&2
    printf '%s\n' "$out" >&2
    return 1
  }
  grep -qE '^hooks-[0-9]+$' <<<"$out" || {
    echo "the shard holding a zsh-naming suite was not a hooks leg:" >&2
    printf '%s\n' "$out" >&2
    return 1
  }
  grep -qx 'hooks-1' <<<"$out" && {
    echo "hooks-1 holds only the plain pinned file, but was reported as needing a package" >&2
    return 1
  }
  true
}

@test "W10 adversarial: a helper sourced by a suite is detected, not just the suite" {
  local root="$BATS_TEST_TMPDIR/helpers-tree" out reported
  seed_seam_tree "$root"
  # No .bats file names either dependency anywhere in this tree. The only
  # mention is in a helper the suites source, which is the shape a scan of
  # `.bats` alone cannot see: the suite would skip its zsh-gated tests silently
  # on a leg the apt step never served.
  mkdir -p "$root/needs/helpers"
  printf '#!/usr/bin/env bash\ncommand -v zsh >/dev/null 2>&1 || return 0\n' \
    >"$root/needs/helpers/zsh-gate.sh"

  out="$(seam_tree_needs "$root")" || return 1

  # Every hooks leg draws from the directory the helper sits beside, so all of
  # them are reported: the helper is shared, and there is no way to tell from
  # the tree which suites source it. Over-inclusive is the direction this scan
  # is written to fail in.
  reported="$(printf '%s\n' "$out" | grep -c .)"
  [ "$reported" -ge 1 ] || {
    echo "a helper naming zsh was not detected at all" >&2
    return 1
  }
  grep -qE '^hooks-[0-9]+$' <<<"$out" || {
    echo "the helper's own hooks legs were not reported:" >&2
    printf '%s\n' "$out" >&2
    return 1
  }
  grep -qE '^(audit|lib|misc|scripts-[0-9]+)$' <<<"$out" && {
    echo "a shard drawing only from the clean directory was reported" >&2
    return 1
  }
  true
}

@test "W10 adversarial: a shard that cannot be listed fails the scan rather than reporting it clean" {
  local root="$BATS_TEST_TMPDIR/unlistable"
  seed_seam_tree "$root"
  printf '#!/usr/bin/env bats\ncommand -v zsh\n' >"$root/needs/uses-zsh.bats"

  # Healthy arm first, so a helper that always failed could not pass this.
  run seam_tree_needs "$root"
  [ "$status" -eq 0 ]

  # hooks-1 pins local-janitor.bats by name, so removing it makes the sharder
  # exit 2 for that shard. Read from a process substitution that status is
  # invisible and the leg silently reports "needs nothing"; the scan has to
  # fail instead.
  rm -f "$root/needs/local-janitor.bats"
  run seam_tree_needs "$root"
  [ "$status" -ne 0 ] || {
    echo "a shard the sharder refused to list reported a clean scan" >&2
    return 1
  }
}

# `sandbox` and `concurrency` are matrix legs the sharder does not name, so
# W10's recomputation reaches neither. W9 pins sandbox's empty package set.
# This pins the other one, which the narrowed apt step stopped serving: it drew
# both packages implicitly from the old `matrix.shard != 'sandbox'` gate and now
# draws neither, leaving it the one leg whose package set nothing asserted.

# concurrency_tree_needs_packages <dir> — 0 when some file under $1 reaches for
# zsh or a YAML parser by W10's own four patterns, 1 when none does. Same
# argument-taking shape as the helpers above so the fixture drives this code
# rather than a copy of it.
concurrency_tree_needs_packages() {
  local dir="$1" rc=0
  grep -rqE "$PKG_PATTERN" \
    --include='*.bats' --include='*.sh' "$dir" || rc=$?
  [ "$rc" -le 1 ] || {
    echo "concurrency_tree_needs_packages: grep failed on $dir (exit $rc)" >&2
    return 2
  }
  return "$rc"
}

@test "W10: the concurrency leg reaches for neither package the apt step dropped" {
  local declared
  require_yaml_parser
  require_repo_path -d "$REPO_ROOT/.gaia/tests/concurrency" "concurrency tree" || return 1

  declared="$(read_wf stepshards "$WORKFLOW" shards 'Install the YAML parser and zsh')" || return 1
  grep -qx 'concurrency' <<<"$declared" && {
    echo "the apt step names concurrency, but W10 derives its list from the sharder, which never emits it" >&2
    return 1
  }

  # `run`, because a clean tree is the non-zero case and a bare call would
  # abort the test under bats' `set -e` before the status could be read.
  run concurrency_tree_needs_packages "$REPO_ROOT/.gaia/tests/concurrency"
  # 2 is the helper's hard-error status, and it has to be told apart from 0
  # here: both are "not 1", so folding them together would report a tree that
  # was never successfully read as a tree that reaches for a package, sending
  # the reader to look for a dependency that may not exist.
  [ "$status" -ne 2 ] || {
    echo "the scan over .gaia/tests/concurrency hard-errored, so nothing was established" >&2
    printf '%s\n' "$output" >&2
    return 1
  }
  [ "$status" -eq 1 ] || {
    echo "a file under .gaia/tests/concurrency reaches for zsh or a YAML parser, but that leg's" >&2
    echo "steps install neither. A zsh-gated test would skip silently there." >&2
    grep -rlE "$PKG_PATTERN" \
      --include='*.bats' --include='*.sh' "$REPO_ROOT/.gaia/tests/concurrency" >&2
    return 1
  }
}

@test "W10 adversarial: a concurrency file reaching for zsh is caught" {
  local dir="$BATS_TEST_TMPDIR/conc"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\necho clean\n' >"$dir/clean.sh"
  # The healthy arm first, so a helper that always reported "needs packages"
  # could not pass this.
  run concurrency_tree_needs_packages "$dir"
  [ "$status" -eq 1 ]

  printf '#!/usr/bin/env bash\ncommand -v zsh >/dev/null 2>&1 || exit 0\n' >"$dir/uses-zsh.sh"
  run concurrency_tree_needs_packages "$dir"
  [ "$status" -eq 0 ]

  # The third status, and the reason the caller has to tell it apart from 0:
  # an unreadable tree is neither "needs a package" nor "needs none".
  require_non_root
  chmod 000 "$dir"
  run concurrency_tree_needs_packages "$dir"
  chmod 755 "$dir"
  [ "$status" -eq 2 ] || {
    echo "an unreadable tree reported $status rather than the hard-error status" >&2
    return 1
  }
}

# Pins the error propagation directly. Before the pipeline came off this
# helper, its `return 1` fired inside `| sort`'s subshell and the function
# still exited 0, so a grep hard error truncated the scan and reported a clean
# one. Nothing above catches that: the truncated list can still equal the
# workflow's, which is exactly how it would green.
@test "W10 adversarial: a grep hard error fails the scan rather than reporting it clean" {
  local root="$BATS_TEST_TMPDIR/unreadable" status_ok status_err
  require_non_root
  seed_seam_tree "$root"
  printf '#!/usr/bin/env bats\ncommand -v zsh\n' >"$root/needs/uses-zsh.bats"

  # Driven through `run`, not called directly: the whole point of this check is
  # that the helper returns non-zero, and bats runs a test body under `set -e`,
  # where a bare non-zero call aborts before its status can be read.

  # Healthy arm first, so a helper that always failed could not pass this.
  run seam_tree_needs "$root"
  status_ok="$status"

  printf '#!/usr/bin/env bats\n' >"$root/needs/locked.bats"
  chmod 000 "$root/needs/locked.bats"
  run seam_tree_needs "$root"
  status_err="$status"
  chmod 644 "$root/needs/locked.bats"

  [ "$status_ok" -eq 0 ] || {
    echo "the readable fixture tree did not scan cleanly (exit $status_ok)" >&2
    return 1
  }
  [ "$status_err" -ne 0 ] || {
    echo "an unreadable suite reported a clean scan; the grep error did not propagate" >&2
    return 1
  }
}

# W11. workflow-filter-coverage.bats only reaches a repo-relative path a gated
# step names literally in its run: body, and none of the literal tokens in
# shards' gated steps is or implies these three (each names a runner, an
# installer, or a composite action, never the files those read), so the
# script-capabilities manifest, its schema, and .gaia/release-exclude are
# transitive inputs that guard never reaches. These two tests are the
# regression guard for the three lines SPEC-072 added to close that hole.
#
# .gaia/manifest.json is the same shape on the cli-tests side, and it is
# asserted here for the same reason. None of the literal tokens in
# distribution-harness' gated steps is or implies the manifest either -- each
# names a runner, a committed binary, or a composite action, never the files
# those read -- while two of the scenarios it runs read the staged manifest
# (01-files-present.sh walks its files{} keys; 16-audit-remit-parity.sh reads
# two classes out of it). A manifest-only change -- a regeneration, a
# ship-or-withhold answer -- matches no other entry in that filter, so before
# #1473 it resolved code=false and greened the job having run the scenarios
# that would have caught a bad manifest zero times.

@test "W11: audit-ci-tests.yml's code filter lists the script-capabilities manifest, its schema, and release-exclude" {
  require_yaml_parser
  local list
  list="$(read_wf codefilter "$WORKFLOW" shards)"
  for path in '.gaia/script-capabilities.json' '.gaia/script-capabilities.schema.json' '.gaia/release-exclude'; do
    printf '%s\n' "$list" | grep -qxF -- "$path" || {
      echo "audit-ci-tests.yml's code: filter is missing $path" >&2
      return 1
    }
  done
}

@test "W11: cli-tests.yml's distribution-harness code filter lists the script-capabilities manifest, its schema, and the release manifest" {
  require_yaml_parser
  local list
  list="$(read_wf codefilter "$CLI_WORKFLOW" distribution-harness)"
  for path in '.gaia/script-capabilities.json' '.gaia/script-capabilities.schema.json' '.gaia/manifest.json'; do
    printf '%s\n' "$list" | grep -qxF -- "$path" || {
      echo "cli-tests.yml's distribution-harness code: filter is missing $path" >&2
      return 1
    }
  done
}

@test "W11 adversarial: dropping a line from audit-ci-tests.yml's code filter is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w11a.yml" line
  line="$(sole_line_matching "$WORKFLOW" "^ *- '\\.gaia/release-exclude'\$")" || return 1
  delete_line "$WORKFLOW" "$line" "$doctored"

  local list
  list="$(read_wf codefilter "$doctored" shards)"
  printf '%s\n' "$list" | grep -qxF -- '.gaia/release-exclude' && {
    echo "deleting the .gaia/release-exclude filter line did not drop it from the parsed code: list" >&2
    return 1
  }
  true
}

@test "W11 adversarial: dropping a line from cli-tests.yml's distribution-harness code filter is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w11b.yml" line
  line="$(sole_line_matching "$CLI_WORKFLOW" "^ *- '\\.gaia/script-capabilities\\.schema\\.json'\$")" || return 1
  delete_line "$CLI_WORKFLOW" "$line" "$doctored"

  local list
  list="$(read_wf codefilter "$doctored" distribution-harness)"
  printf '%s\n' "$list" | grep -qxF -- '.gaia/script-capabilities.schema.json' && {
    echo "deleting the schema filter line did not drop it from the parsed code: list" >&2
    return 1
  }
  true
}
