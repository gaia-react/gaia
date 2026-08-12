#!/usr/bin/env bats

# Structural guard for .github/workflows/audit-ci-tests.yml's fan-out shape:
# an 11-leg matrix job (`shards`) plus a thin aggregator (`audit-ci-tests`)
# that carries the declared-required check name. This is C3 in
# .gaia/local/plans/PLAN-014/README.md; the nine tests below (W1-W9) each
# guard one of the five constraints that page's task doc lays out for this
# workflow, since breaking any one of them wedges every pull request.
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
  BATS_SHARDS="$REPO_ROOT/.gaia/tests/bats-shards.sh"
  # Matches retrigger-reachability.bats' own constant: the self-heal poller
  # margin charged per hop of the needs: chain.
  POLLER_MARGIN_MIN=5

  require_repo_path -f "$WORKFLOW" "audit-ci-tests.yml" || return 1
  require_repo_path -f "$POLLER_WORKFLOW" "code-review-audit.yml" || return 1
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
  local doctored="$BATS_TEST_TMPDIR/w6a.yml"
  replace_line "$WORKFLOW" \
    "        shard: [hooks-1, hooks-2, hooks-3, hooks-4, scripts-1, scripts-2, audit, lib, misc, sandbox, concurrency]" \
    "        shard: [hooks-1, hooks-2, hooks-3, hooks-4, scripts-1, scripts-2, audit, lib, misc, sandbox, concurrency, bogus]" \
    "$doctored"

  local matrix_list expected
  matrix_list="$(read_wf matrix "$doctored" shards | LC_ALL=C sort)"
  expected="$(printf '%s\nsandbox\nconcurrency\n' "$(bash "$BATS_SHARDS" shards)" | LC_ALL=C sort)"
  [ "$matrix_list" != "$expected" ] || { echo "adding a bogus shard id did not desync the matrix from the sharder" >&2; return 1; }
}

@test "W6 adversarial: dropping lib from the matrix is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w6b.yml"
  replace_line "$WORKFLOW" \
    "        shard: [hooks-1, hooks-2, hooks-3, hooks-4, scripts-1, scripts-2, audit, lib, misc, sandbox, concurrency]" \
    "        shard: [hooks-1, hooks-2, hooks-3, hooks-4, scripts-1, scripts-2, audit, misc, sandbox, concurrency]" \
    "$doctored"

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

@test "W9: no .gaia/tests/sandbox suite references zsh, python3, or require_yaml_parser" {
  local hits
  hits="$(grep -lE 'zsh|python3|require_yaml_parser' "$REPO_ROOT"/.gaia/tests/sandbox/*.bats 2>/dev/null || true)"
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

  [ -n "$(grep -lE 'zsh|python3|require_yaml_parser' "$dir"/*.bats)" ] || {
    echo "a fixture naming zsh was not caught" >&2
    return 1
  }
}
