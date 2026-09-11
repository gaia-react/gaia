#!/usr/bin/env bats

# Structural guard for .github/workflows/audit-ci-tests.yml's fan-out shape:
# a matrix job (`shards`) plus a thin aggregator (`audit-ci-tests`) that
# carries the declared-required check name. This is the workflow-shape half of
# what .gaia/local/plans/PLAN-014/SUMMARY.md's `## Guards` section describes;
# most of the W-numbered checks below guard a constraint that page lays out for
# this workflow, since breaking any one of them wedges every pull request. That
# page is under `.gaia/local/`, which is gitignored, so it is absent on a fresh
# clone and this pointer resolves only where the plan was run. The range is
# deliberately unbounded here: several checks postdate that page and guard
# surfaces it never named, so a bounded list would be a count this file has to
# keep in step with itself. Each check's own header says what it guards.
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
  WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
  BATS_SHARDS="$REPO_ROOT/.gaia/tests/bats-shards.sh"
  CHECK_WIKI_STATE_COLLISION="$REPO_ROOT/.gaia/scripts/check-wiki-state-collision.sh"
  # Matches retrigger-reachability.bats' own constant: the self-heal poller
  # margin charged per hop of the needs: chain.
  POLLER_MARGIN_MIN=5
  # The four patterns W10 detects a zsh or PyYAML dependency by, written once
  # because three scans have to agree on them: two disagreeing copies would
  # each report a defensible set and W10 would compare them against each other.
  # The reasoning behind the four, and behind excluding bare `python3`, is in
  # the W10 header below.
  PKG_PATTERN='command -v zsh|zsh -c|require_yaml_parser|import yaml'
  # The matrix line the adversarial cases doctor, addressed by shape rather
  # than by text so a repack that rewrites the list stays a one-site edit in
  # the workflow. It matches exactly one line today, which sole_line_matching
  # re-checks on every use; the reasoning for deriving it is above that helper.
  #
  # The apt gate has no pattern here and is reached through gate_line_for_step
  # instead. A shape pattern for it addressed the step as "the only `if:`
  # carrying a contains(fromJSON(...)) gate", which is a property of how many
  # such steps the workflow happens to have rather than of the apt step, and a
  # second one made it ambiguous. Naming the step stays true as steps are
  # added.
  MATRIX_SHARD_PATTERN='^ *shard: \['

  # Committed fixtures for the lever-one guards (W13, W14, W15). They sit
  # under a fixtures/ sibling of this suite's directory, inside the
  # leg-arming scan's own input set. Only codefilter-token-out-of-set.yml
  # names wiki/.state.json, making it a namer of that page attributed to
  # `lib`; paths-filter-pin-bumped.yml names no narrowable page. Either way
  # it is harmless, because `lib` arms unconditionally regardless.
  SPEC078_FIXTURES="$BATS_TEST_DIRNAME/fixtures/spec-078"
  # The dorny/paths-filter version lever one's premises (step 0 of the task
  # doc), and leg-arming.sh's listing-cap premise, were verified against,
  # recorded once here so W14 and its header comment cannot disagree with
  # each other about which pin they mean.
  PATHS_FILTER_PINNED_SHA='ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d'
  PATHS_FILTER_PINNED_TAG='v4.0.3'
  # The per-leg arming gate W16 to W18 pin, and the concurrency seam it scans
  # beside the directories the sharder discovers.
  ARMING_SCRIPT="$REPO_ROOT/.gaia/tests/leg-arming.sh"
  ARMING_CONCURRENCY_DIR="$REPO_ROOT/.gaia/tests/concurrency"

  require_repo_path -f "$WORKFLOW" "audit-ci-tests.yml" || return 1
  require_repo_path -f "$ARMING_SCRIPT" "leg-arming.sh" || return 1
  require_repo_path -d "$ARMING_CONCURRENCY_DIR" ".gaia/tests/concurrency" || return 1
  require_repo_path -f "$POLLER_WORKFLOW" "code-review-audit.yml" || return 1
  require_repo_path -f "$CLI_WORKFLOW" "cli-tests.yml" || return 1
  require_repo_path -d "$WORKFLOW_DIR" ".github/workflows/" || return 1
  require_repo_path -f "$BATS_SHARDS" "bats-shards.sh" || return 1
  require_repo_path -f "$SPEC078_FIXTURES/codefilter-token-out-of-set.yml" \
    "fixtures/spec-078/codefilter-token-out-of-set.yml" || return 1
  require_repo_path -f "$SPEC078_FIXTURES/paths-filter-pin-bumped.yml" \
    "fixtures/spec-078/paths-filter-pin-bumped.yml" || return 1
  require_repo_path -f "$CHECK_WIKI_STATE_COLLISION" \
    "check-wiki-state-collision.sh" || return 1

  # W12's subject set: every workflow file in the directory, derived from the
  # directory rather than listed, so a workflow added later is scanned without
  # an edit here. Derived once in setup() so the check and the reach assertions
  # below cannot enumerate differently -- a second expansion is a second
  # authority, and re-narrowing one of them is exactly the regression the reach
  # tests exist to catch.
  #
  # Both extensions, because GitHub accepts both and a call site added under the
  # spelling this file did not glob would be SKIPPED rather than reported. A
  # glob that matches nothing expands to its own literal, which is not a file,
  # so the `-f` filter is what keeps that literal out of the set.
  WORKFLOW_FILES=()
  local wf_candidate
  for wf_candidate in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
    if [ -f "$wf_candidate" ]; then
      WORKFLOW_FILES+=("$wf_candidate")
    fi
  done
  # A per-element claim over an empty set is true and means nothing, and every
  # W12 test below expands this array, so an empty one would green them all.
  [ "${#WORKFLOW_FILES[@]}" -gt 0 ] || {
    echo "no workflow files under $WORKFLOW_DIR; every W12 test would assert over an empty set" >&2
    return 1
  }
}

teardown() {
  local p
  if [ -f "$BATS_TEST_TMPDIR/scratch-copies" ]; then
    while IFS= read -r p || [ -n "$p" ]; do
      if [ -n "$p" ]; then
        rm -f "$p"
      fi
    done <"$BATS_TEST_TMPDIR/scratch-copies"
  fi
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
#                         reason every other mode here parses structurally. A
#                         change-type mapping entry (e.g. `- deleted: 'x'`)
#                         unwraps to its one value, so the one-path-per-line
#                         contract holds for both the bare-string and the
#                         mapping shape. A mapping with no values, or with
#                         more than one, exits 2 naming the offending entry
#                         rather than guessing which value it meant.
#                         Exits 2 when the job has no such step or the step
#                         has no `code:` list.
#   codefilterentries <job-id>
#                         that job's dorny/paths-filter step's `code:` list,
#                         one `<key>\t<path>` line per entry: a bare-string
#                         entry prints `-` as its key, a change-type mapping
#                         entry prints its key, so the change-type key
#                         `codefilter` discards survives for a reader that
#                         needs it. A mapping entry carrying several
#                         change-type keys
#                         prints one line per key, each paired with that
#                         key's own path. Same exit-2 conditions as
#                         `codefilter`.
#   filtercount            total dorny/paths-filter steps in the whole file
#   filterifs              one `<job-id>\t<normalized-if>` line per step, across
#                         EVERY job, whose `if:` mentions steps.filter.outputs.
#   stepgates <job-id>      one `<step-name>\t<normalized-if>` line per step in
#                         that job, in document order; `if` is empty for a
#                         step with no gate.
#   stepfield <job-id> <step-name> <field>
#                         the scalar value of `<field>` (a dotted path reaches
#                         one level of nesting, e.g. `with.list-files`) on the
#                         step named `<step-name>` in that job. Empty when the
#                         field is absent. Exits 2 when no step carries the
#                         name, or the field resolves to a mapping or list.
#   filterwith <job-id> <key>
#                         the value of `<key>` under `with:` on that job's
#                         dorny/paths-filter step. Empty when the key is
#                         absent.
#   filteridjobs            one `<job-id>\t<name-or-uses>` line per step across
#                         EVERY job whose `id:` is exactly `filter`.
#   armingifs               one `<job-id>\t<normalized-if>` line per step,
#                         across EVERY job, whose `if:` mentions
#                         steps.leg-arming.outputs.
#   runinterp               one `<job-id>\t<step-name>` line per step whose RAW
#                         (unnormalized) `run:` body contains a literal `${{`
#   setupnodecaps          one
#                         `<job-id>\t<step-name>\t<capkind>\t<cap>\t<job-cap>`
#                         line per step whose `uses:`, normalized, is exactly
#                         the gaia-setup-node composite action, across EVERY
#                         job. `capkind` comes from the same kind_of
#                         callee cap_kind uses, so a job cap and a step cap
#                         cannot answer differently; `cap`
#                         and `job-cap` are the integers, or the sentinel `-`
#                         where the corresponding kind is not 'int'. A
#                         sentinel rather than an empty field because tab is
#                         IFS *whitespace*, so a bash `IFS=$'\t' read` folds
#                         two adjacent tabs into one delimiter and every later
#                         field binds one position early. Enumerated from the
#                         `uses:` value rather than from a list of step names,
#                         so a call site added later is reached by
#                         construction rather than by remembering to add it
#                         here.
#   aggok <job-id>         'yes' when EVERY entry in that job's own `needs:`
#                         has some single step that both references
#                         needs.<entry>.result (in its `run:` body or through
#                         an `env:` mapping) AND exits non-zero on a bad
#                         value, else 'no'. Derived per entry rather than
#                         pinned to one leg, so an entry joining `needs:`
#                         without its comparison reds. 'no' on a job with an
#                         empty `needs:`, so the coverage claim can never
#                         pass over an empty set.
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


def kind_of(mapping):
    """The cap kind a job or step mapping declares: 'missing', 'other' (a
    bool or any non-int, which reads as uncapped downstream), or 'int'. One
    callee for both, because a job cap and a step cap answer the same question
    and two copies of the rule would drift apart silently, each exercised by a
    different check."""
    if 'timeout-minutes' not in mapping:
        return 'missing'
    value = mapping['timeout-minutes']
    if isinstance(value, bool) or not isinstance(value, int):
        return 'other'
    return 'int'


def cap_kind(jid):
    return kind_of(jobs[jid])


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


def filter_step_for(jid):
    """That job's dorny/paths-filter step, found by `uses:` identity. Shared
    by every mode that reads a property of that one step, so the identity
    check lives in one place."""
    for step in jobs[jid].get('steps') or []:
        if isinstance(step, dict) and 'dorny/paths-filter' in str(step.get('uses', '')):
            return step
    die('job %r has no dorny/paths-filter step' % jid)


def code_list_for(jid):
    """That job's dorny/paths-filter step's `code:` list, as parsed YAML
    entries (bare strings and change-type mappings alike). Shared by
    `codefilter` and `codefilterentries`, which read the same list and differ
    only in whether the change-type key survives."""
    filter_step = filter_step_for(jid)
    filters_raw = (filter_step.get('with') or {}).get('filters')
    if not isinstance(filters_raw, str):
        die('job %r paths-filter step has no filters: string' % jid)
    try:
        filters_doc = yaml.safe_load(filters_raw)
    except yaml.YAMLError as exc:
        die('job %r filters: block is not valid YAML (%s)' % (jid, exc.__class__.__name__))
    code_list = (filters_doc or {}).get('code')
    if not isinstance(code_list, list):
        die('job %r filters: block has no code: list' % jid)
    return code_list


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
    for item in code_list_for(rest[0]):
        if isinstance(item, dict):
            values = list(item.values())
            if len(values) != 1:
                die('job %r filters: code: entry %r is a change-type mapping with %d values, expected exactly 1' % (rest[0], item, len(values)))
            print(str(values[0]))
        else:
            print(str(item))
elif mode == 'codefilterentries':
    require_job(rest[0])
    for item in code_list_for(rest[0]):
        if isinstance(item, dict):
            for key, value in item.items():
                print('%s\t%s' % (key, value))
        else:
            print('-\t%s' % item)
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
elif mode == 'stepgates':
    # That job's steps, one `<name>\t<normalized-if>` line per step, in
    # document order. `name` falls back to `uses:` for an unnamed step, the
    # same fallback `setupnodecaps` and `runinterp` use, so an anonymous
    # checkout step still prints an identity rather than an empty field. `if`
    # is empty for a step with no gate. W19 derives its armed-conjunct and
    # filter-conjunct sets from this rather than scraping the raw text.
    require_job(rest[0])
    for step in jobs[rest[0]].get('steps') or []:
        if not isinstance(step, dict):
            continue
        name = str(step.get('name', '')) or str(step.get('uses', ''))
        print('%s\t%s' % (name, normalize(step.get('if', ''))))
elif mode == 'stepfield':
    # The scalar value of one field on the step named `rest[1]` inside job
    # `rest[0]`, found by its `name:` field. `rest[2]` may be a dotted path
    # (`with.list-files`) to reach one level of nesting. Exits 2 on a mapping
    # or list value, so a caller expecting a scalar cannot silently stringify
    # a nested structure and get a false comparison; prints nothing when the
    # field is absent, which lets a caller compare against an expected
    # literal without special-casing "missing" separately from "empty".
    require_job(rest[0])
    wanted, key_path = rest[1], rest[2].split('.')
    found = False
    for step in jobs[rest[0]].get('steps') or []:
        if not isinstance(step, dict) or str(step.get('name', '')) != wanted:
            continue
        found = True
        value = step
        for part in key_path:
            value = value.get(part) if isinstance(value, dict) else None
        if isinstance(value, (dict, list)):
            die('stepfield: %r on step %r resolves to a %s, not a scalar' % (rest[2], wanted, type(value).__name__))
        if value is not None:
            print(str(value))
        break
    if not found:
        die('stepfield: no step named %r in job %r' % (wanted, rest[0]))
elif mode == 'filterwith':
    # The value of one `with:` key on job `rest[0]`'s dorny/paths-filter step.
    # Prints nothing when the key is absent, the same "missing reads as empty"
    # contract `stepfield` uses, since W19 needs to red identically whether
    # `list-files:` was changed to another value or deleted outright.
    require_job(rest[0])
    step = filter_step_for(rest[0])
    value = (step.get('with') or {}).get(rest[1])
    if value is not None:
        print(str(value))
elif mode == 'filteridjobs':
    # One `<job-id>\t<name-or-uses>` line per step across EVERY job whose
    # `id:` is exactly `filter`. The workflow carries this id on the shards
    # job's real dorny/paths-filter step and on the two standalone jobs' own
    # hand-rolled gates (FC-2's `scope_boundaries.never`: widening the
    # coverage suite's hand-rolled `id: filter` pin is forbidden), and W19
    # reads this to prove the new arming step joined under a distinct id
    # rather than colliding with any of those three.
    for jid, job in jobs.items():
        for step in job.get('steps') or []:
            if not isinstance(step, dict):
                continue
            if str(step.get('id', '')) == 'filter':
                name = str(step.get('name', '')) or str(step.get('uses', ''))
                print('%s\t%s' % (jid, name))
elif mode == 'armingifs':
    # One `<job-id>\t<normalized-if>` line per step across EVERY job whose
    # `if:` mentions steps.leg-arming.outputs. -- the mirror of `filterifs`,
    # used by W19 to prove the arming conjunct stays inside the shards job
    # rather than reaching either standalone hop-1 job.
    for jid, job in jobs.items():
        for step in job.get('steps') or []:
            if not isinstance(step, dict):
                continue
            gate = normalize(step.get('if', ''))
            if 'steps.leg-arming.outputs.' in gate:
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
elif mode == 'setupnodecaps':
    for jid, job in jobs.items():
        job_kind = cap_kind(jid)
        job_cap = cap_of(jid)
        for step in job.get('steps') or []:
            if not isinstance(step, dict):
                continue
            # Exact on the action's identity, not a substring of its path: a
            # sibling action named with this one as a prefix
            # (`gaia-setup-node-foo`) is a DIFFERENT action, and a substring
            # test would report it under this check's name while missing that
            # the real one had been renamed away. Normalized first because
            # `uses:` legally spells the same local action several ways, and
            # the normalization has to reach every one of them: a spelling it
            # misses is SKIPPED rather than reported, which is a short read
            # rather than an empty one, so the sites spelled the expected way
            # keep `setup_node_cap_gaps` out of its empty-set arm and the check
            # reports clean over a step it never opened.
            used = str(step.get('uses', '')).strip().split('@', 1)[0]
            if used.startswith('./'):
                used = used[2:]
            used = used.rstrip('/')
            if used != '.github/actions/gaia-setup-node':
                continue
            name = str(step.get('name', '')) or str(step.get('uses', ''))
            kind = kind_of(step)
            # `-` rather than an empty string for an absent value: tab is IFS
            # whitespace in bash, so `IFS=$'\t' read` collapses adjacent tabs
            # and an empty field silently shifts every field after it.
            cap = str(step['timeout-minutes']) if kind == 'int' else '-'
            print('%s\t%s\t%s\t%s\t%s' % (
                jid, name, kind, cap, str(job_cap) if job_kind == 'int' else '-'))
elif mode == 'aggok':
    require_job(rest[0])
    exit_re = re.compile(r'\bexit\s+[1-9][0-9]*\b')
    steps = [item for item in (jobs[rest[0]].get('steps') or []) if isinstance(item, dict)]
    deps = needs_of(rest[0])
    # An empty `needs:` prints 'no' rather than a vacuous 'yes'. The caller
    # reads this as "the aggregator adjudicates its dependencies", and a
    # per-element claim over an empty set is the one answer that is true
    # without meaning anything.
    covered = bool(deps)
    for dep in deps:
        ref = 'needs.%s.result' % dep
        hit = False
        for step in steps:
            body = str(step.get('run', ''))
            mapping = step.get('env') if isinstance(step.get('env'), dict) else {}
            mapped = any(ref in str(value) for value in mapping.values())
            if (ref in body or mapped) and exit_re.search(body):
                hit = True
                break
        if not hit:
            covered = False
            break
    print('yes' if covered else 'no')
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

# Prints the `- if:` line that opens the step named $2 in $1, so a case can
# doctor that step's gate. Locates the step by name, then takes the last YAML
# list-item line at or above it, and refuses when that opening line is not an
# `if:` -- a step whose gate this returns must actually have one, and a step
# that opens some other way would otherwise hand back the PREVIOUS step's gate
# and doctor the wrong one.
#
# Fails on zero or several matches for the name, for the same reason
# sole_line_matching does: either means the workflow changed shape, which this
# suite has to see rather than doctor a line it did not mean to.
gate_line_for_step() {
  local src="$1" step="$2" hits count name_no open_no open_line
  hits="$(grep -nF -- "name: $step" "$src")" || {
    echo "gate_line_for_step: no step named '$step' in $src" >&2
    return 1
  }
  count="$(printf '%s\n' "$hits" | grep -c '')"
  [ "$count" -eq 1 ] || {
    echo "gate_line_for_step: 'name: $step' matches $count lines in $src, expected exactly 1" >&2
    printf '%s\n' "$hits" >&2
    return 1
  }
  name_no="${hits%%:*}"
  # Numbered against the head, whose line numbers are the file's own.
  open_no="$(head -n "$name_no" "$src" | grep -nE '^ *- ' | tail -1 | cut -d: -f1)"
  [ -n "$open_no" ] || {
    echo "gate_line_for_step: the step named '$step' opens no list item in $src" >&2
    return 1
  }
  open_line="$(sed -n "${open_no}p" "$src")"
  case "$open_line" in
    *"- if: "*) printf '%s' "$open_line" ;;
    *)
      echo "gate_line_for_step: the step named '$step' does not open with an if: gate" >&2
      printf '%s\n' "$open_line" >&2
      return 1
      ;;
  esac
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

# Shared checks for W13, W14 and W15 (SPEC-078 lever one). Each is a plain
# function rather than a script, so the healthy assertion and its adversarial
# case run the identical code against a healthy and a doctored input, the
# same posture every other guard in this file takes.

# assert_wiki_state_key_is_deleted <workflow>: the code: filter's entry for
# wiki/.state.json is keyed on exactly `deleted`. Whole-field string equality
# against read_wf codefilterentries' key column, never a substring test, so a
# compound key like `deleted|renamed` reds rather than passing on the
# substring it contains.
assert_wiki_state_key_is_deleted() {
  local workflow="$1" entries key count
  entries="$(read_wf codefilterentries "$workflow" shards)" || return 1
  key="$(printf '%s\n' "$entries" | awk -F'\t' '$2 == "wiki/.state.json" { print $1 }')"
  count="$(printf '%s\n' "$key" | grep -c '.')"
  [ "$count" -eq 1 ] || {
    echo "expected exactly one code: entry naming wiki/.state.json in $workflow, found $count" >&2
    return 1
  }
  [ "$key" = "deleted" ] && return 0
  echo "$workflow's code: entry for wiki/.state.json is keyed '$key', expected exactly 'deleted'" >&2
  return 1
}

# assert_no_renamed_or_copied_tokens <workflow>: no code: filter entry
# anywhere in <workflow> carries `renamed` or `copied` in its change-type
# key, split on `|` so a compound key like `deleted|renamed` is caught by its
# individual tokens rather than missed as a whole-field mismatch.
assert_no_renamed_or_copied_tokens() {
  local workflow="$1" entries key path token bad=""
  entries="$(read_wf codefilterentries "$workflow" shards)" || return 1
  while IFS=$'\t' read -r key path; do
    [ -n "$key" ] || continue
    [ "$key" = "-" ] && continue
    for token in $(printf '%s' "$key" | tr '|' ' '); do
      case "$token" in
        renamed | copied)
          bad="${bad}${key} (on ${path}) "
          ;;
      esac
    done
  done <<<"$entries"
  [ -z "$bad" ] || {
    echo "$workflow's code: filter carries a forbidden renamed/copied change-type token: $bad" >&2
    return 1
  }
  return 0
}

# assert_paths_filter_pin_matches <workflow>: the sole dorny/paths-filter
# `uses:` line's SHA and tag comment equal PATHS_FILTER_PINNED_SHA and
# PATHS_FILTER_PINNED_TAG, the pair lever one's premises (task-lever-one.md
# step 0), and the listing cap leg-arming.sh's pagination rule rests on, were
# verified against. A version drift moving either half
# invalidates those premises silently -- a grouped dependency bump nobody
# reads closely -- so the refusal names both recorded values and where to
# re-derive each premise.
assert_paths_filter_pin_matches() {
  local workflow="$1" line count sha tag
  line="$(grep -E "dorny/paths-filter@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+" "$workflow")" || {
    echo "no dorny/paths-filter uses: line found in $workflow" >&2
    return 1
  }
  count="$(printf '%s\n' "$line" | grep -c '.')"
  [ "$count" -eq 1 ] || {
    echo "expected exactly one dorny/paths-filter uses: line in $workflow, found $count" >&2
    return 1
  }
  sha="$(printf '%s' "$line" | sed -E 's/.*dorny\/paths-filter@([0-9a-f]{40}) # v.*/\1/')"
  tag="$(printf '%s' "$line" | sed -E 's/.*# (v[0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
  if [ "$sha" = "$PATHS_FILTER_PINNED_SHA" ] && [ "$tag" = "$PATHS_FILTER_PINNED_TAG" ]; then
    return 0
  fi
  echo "$workflow pins dorny/paths-filter@$sha ($tag), lever one's premises, and the listing cap leg-arming.sh's pagination rule rests on, were verified against $PATHS_FILTER_PINNED_SHA ($PATHS_FILTER_PINNED_TAG). Re-derive against the pinned source at the new SHA: the accepted change-status set (file.ts:6-13) and its unvalidated per-entry cast (filter.ts:171-176); the plain array membership check that lets an unrecognized token match nothing forever (filter.ts:123-125); the pull-request lane's rename decomposition -- the token input defaults to github.token (action.yml:5-8), so this lane takes getChangedFilesFromApi (main.ts:101-107), which replaces a renamed row with an added-new-path row plus a deleted-previous-path row (main.ts:227-239); and that lane's listing cap, which leg-arming.sh's PAGINATION_CAP threshold must match -- it pages pulls.listFiles (main.ts:211-218) and returns whatever the pages yield, reconciling no total, so the list stops exactly where GitHub's endpoint stops listing." >&2
  return 1
}

# make_state_collision_fixture_repo <name> <state-bytes>: a fresh git repo
# under BATS_TEST_TMPDIR with wiki/.state.json tracked and committed holding
# exactly <state-bytes>, and no .gitattributes. Mirrors the `git init`
# incantation .gaia/scripts/tests/check-wiki-state-collision.bats's own
# make_fixture_repo uses, so both suites build the identical fixture shape
# for check-wiki-state-collision.sh.
make_state_collision_fixture_repo() {
  local name="$1" bytes="$2" dir
  dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/wiki"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  printf '%s' "$bytes" >"$dir/wiki/.state.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m seed
  printf '%s' "$dir"
}

# assert_checker_is_content_blind <checker-script>: builds two fixture repos
# identical except for the bytes inside wiki/.state.json, sources
# <checker-script> and runs gaia_check_wiki_state_collision against each,
# and requires the exit status and the combined stdout+stderr to be
# byte-identical. A behavioral oracle rather than a spelling-specific scan:
# "the checker reads the file's contents" is not statically decidable in
# shell, and a scan tuned to one spelling would miss a helper it sources or
# a different way of reading the bytes.
assert_checker_is_content_blind() {
  local checker="$1" repoA repoB statusA outputA statusB outputB
  repoA="$(make_state_collision_fixture_repo w15-a 'aaaaaaa-oracle-fixture-bytes')"
  repoB="$(make_state_collision_fixture_repo w15-b 'zzzzzzz-oracle-fixture-different')"

  run bash -c 'source "$1" && gaia_check_wiki_state_collision "$2"' _ "$checker" "$repoA"
  statusA="$status"
  outputA="$output"
  run bash -c 'source "$1" && gaia_check_wiki_state_collision "$2"' _ "$checker" "$repoB"
  statusB="$status"
  outputB="$output"

  [ "$statusA" -eq "$statusB" ] || {
    echo "$checker's exit status differs between two repos differing only in wiki/.state.json's bytes: $statusA vs $statusB" >&2
    return 1
  }
  [ "$outputA" = "$outputB" ] || {
    echo "$checker's output differs between two repos differing only in wiki/.state.json's bytes" >&2
    printf 'repo A output:\n%s\n' "$outputA" >&2
    printf 'repo B output:\n%s\n' "$outputB" >&2
    return 1
  }
  return 0
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

# W3. The aggregator actually adjudicates every entry in its own needs: list:
# per entry, a step that both references that entry's result and exits non-zero
# on a bad value. Deliberately no count here or in any name below -- the
# entries are the authority on how many, and a count rots the next time a job
# joins needs:, which is the failure this pass repaired.

@test "W3: the aggregator adjudicates every entry in its needs list" {
  require_yaml_parser
  [ "$(read_wf aggok "$WORKFLOW" audit-ci-tests)" = "yes" ] || {
    echo "an entry in the aggregator's needs: has no step that both references its result and exits non-zero on a bad value" >&2
    return 1
  }
}

@test "W3 non-vacuity: the aggregator's needs list is non-empty" {
  require_yaml_parser
  local count
  count="$(read_wf needs "$WORKFLOW" audit-ci-tests | grep -c '.' || true)"
  [ "$count" -gt 0 ] || {
    echo "the aggregator declares no needs:, so W3's per-entry assertion would pass over an empty set" >&2
    return 1
  }
}

@test "W3 adversarial: a bare true aggregator step is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w3.yml"
  local replacement=$'      - name: Require every dependency in needs to have concluded success\n        run: true'
  replace_from "$WORKFLOW" "      - name: Require every dependency in needs to have concluded success" "$replacement" "$doctored"

  [ "$(read_wf aggok "$doctored" audit-ci-tests)" = "no" ] || {
    echo "a bare 'true' step still read as adjudicating the needs list" >&2
    return 1
  }
}

# The case this arm exists for: one entry stays in needs: while the binding
# that carried its result into the adjudicating step goes (#1552). It is read
# out of the workflow rather than restated, so this stays pointed at a real
# dependency after the list is repacked; the last one is the one a fresh
# addition lands on.
@test "W3 adversarial: a needs entry whose result nothing reads is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w3b.yml" dep binding
  dep="$(read_wf needs "$WORKFLOW" audit-ci-tests | grep '.' | tail -1)"
  [ -n "$dep" ] || { echo "the aggregator declares no needs: to doctor" >&2; return 1; }

  binding="$(sole_line_matching "$WORKFLOW" "needs\.${dep}\.result")" || return 1
  delete_line "$WORKFLOW" "$binding" "$doctored"
  assert_doctored "$binding" "$(sole_line_matching "$doctored" "needs\.${dep}\.result" 2>/dev/null || true)" \
    "dropping the ${dep} binding" || return 1

  [ "$(read_wf aggok "$doctored" audit-ci-tests)" = "no" ] || {
    echo "needs entry ${dep} still read as adjudicated with nothing reading its result" >&2
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
  local doctored="$BATS_TEST_TMPDIR/w4.yml" line mutated

  line="$(gate_line_for_step "$WORKFLOW" 'Run a bats shard')" || return 1
  # Removes the disjunct wherever it sits in the line, not anchored on
  # end-of-line, so this survives a later conjunct appended after it.
  mutated="$(printf '%s' "$line" | sed "s/ || github.event_name == 'workflow_dispatch'//")"
  assert_doctored "$line" "$mutated" "dropping the dispatch admission" || return 1
  # This gate line is byte-identical at two sites in the workflow (the apt
  # step's gate matches it too), and replace_line replaces every line equal
  # to the search text. Doctoring both still produces the gap this test
  # asserts, so the double replacement is not a bug here.
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  local jid expr found_gap=""
  while IFS=$'\t' read -r jid expr; do
    [ -n "$jid" ] || continue
    printf '%s' "$expr" | grep -qF -- "workflow_dispatch" || found_gap="x"
  done < <(read_wf filterifs "$doctored")
  [ -n "$found_gap" ] || { echo "doctoring the step's if: did not produce a gap" >&2; return 1; }
}

# W5. Every job is capped with an integer literal, and the worst needs: chain
# fits the poller-derived ceiling.

@test "W5: every job declares an integer cap, and the worst chain fits the ceiling" {
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
  local doctored="$BATS_TEST_TMPDIR/w8.yml" line mutated

  # Anchored on the script's own path, not on the surrounding if:, so this
  # stays stable across the if: edits later phases make; those never touch
  # an existing step's run: body.
  line="$(sole_line_matching "$WORKFLOW" 'bats-shards\.sh run "\$SHARD"')" || return 1
  mutated="$(printf '%s' "$line" | sed 's/"\$SHARD"/"${{ matrix.shard }}"/')"
  assert_doctored "$line" "$mutated" "interpolating matrix.shard" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

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
#
# What is compared against the workflow is the needing legs ROUNDED UP TO
# WHOLE EXCHANGE GROUPS, not the needing legs themselves. The raw per-leg set
# is a function of the sharder's weighted assignment, so it moves whenever any
# suite in a weighted group changes size, with no semantic relationship to the
# packages: exactly one suite in the whole hooks directory reaches for either
# dependency, and its leg moved three times on one branch because an unrelated
# suite beside it grew (#1554). Every one of those moves reds this check and
# buys a workflow edit that changes nothing about what the suites need.
#
# A group is the set of legs a file can move between without anyone editing
# the sharder, which `bats-shards.sh group` reports and its own S14 proves is a
# partition. Rounding the set up to whole groups is therefore stable under
# every reshuffle and moves only when a suite's dependency really changes,
# which is the event worth an edit. It costs one apt on the legs of a needing
# group that hold no needing suite themselves -- the same over-inclusive
# direction this scan already prefers, for the same reason: an over-match costs
# seconds, an under-match silently retires a suite's assertions.
#
# The comparison stays exact EQUALITY rather than relaxing to "declared is a
# superset of needed". Relaxing would also absorb the churn, and it would give
# up the other half of the check with it: a gratuitously listed leg, or the
# whole list widened back to every shard, would then read as clean. Rounding up
# keeps both halves, because the closure is a derived set with one right value.

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

# shard_package_legs <bats-shards.sh> <repo-root>
#
# shard_package_needs' answer rounded up to whole exchange groups: every leg of
# every group holding at least one needing suite, one per line, LC_ALL=C
# sorted. This is the set the apt step's `if:` list is checked against; the
# W10 header above carries why the rounding is there.
#
# The groups come from the sharder rather than from a list written down here,
# for the reason the workflow's own list stopped being written down: a second
# copy of the group definitions would be one edit from disagreeing with the
# assignment it is supposed to describe, and W10 would then be comparing this
# suite's idea of the groups against the workflow's rather than against the
# sharder's. Takes both paths as arguments for the same reason its input does,
# so the fixtures below drive it against a tree of their own.
#
# Like the helper it wraps, this deliberately does not pipe its loop: a
# `return 1` inside a pipeline's subshell would be swallowed and a sharder that
# refused to resolve a group would truncate the closure and still report
# success.
shard_package_legs() {
  local sharder="$1" root="$2" needed id group rc legs=''
  needed="$(shard_package_needs "$sharder" "$root")" || return 1
  [ -n "$needed" ] || return 0
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    rc=0
    group="$(bash "$sharder" group "$id")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "shard_package_legs: the sharder could not resolve $id's group (exit $rc)" >&2
      return 1
    fi
    legs="$legs$group
"
  done <<EOF
$needed
EOF
  printf '%s' "$legs" | LC_ALL=C sort -u
}

@test "W10: the apt step's shard list equals the exchange groups that need zsh or a YAML parser" {
  local declared legs
  # read_wf's reader imports yaml unconditionally, so without this gate a box
  # without PyYAML reports a workflow defect for a missing local dependency,
  # while every sibling check here skips. Fails rather than skips on CI, which
  # is the behavior this suite's own gate helper already defines.
  require_yaml_parser
  declared="$(read_wf stepshards "$WORKFLOW" shards 'Install the YAML parser and zsh')" || {
    echo "could not read the apt step's shard list" >&2
    return 1
  }
  legs="$(shard_package_legs "$BATS_SHARDS" "$REPO_ROOT")" || return 1

  [ -n "$legs" ] || {
    echo "no shard resolved a zsh or YAML-parser dependency; W10 would assert nothing" >&2
    return 1
  }
  [ "$declared" = "$legs" ] || {
    echo "the apt step's shard list and the suites disagree." >&2
    echo "workflow names:" >&2
    printf '%s\n' "$declared" >&2
    echo "suites need, rounded up to whole exchange groups:" >&2
    printf '%s\n' "$legs" >&2
    echo "Repair: copy the 'suites need' set into the step's fromJSON list." >&2
    return 1
  }
}

@test "W10 adversarial: dropping a needed shard from the apt step is caught" {
  local doctored="$BATS_TEST_TMPDIR/dropped.yml" declared needed line mutated
  require_yaml_parser

  line="$(gate_line_for_step "$WORKFLOW" 'Install the YAML parser and zsh')" || return 1
  # Only the final id is followed by the closing bracket, so this drops one
  # leg rather than the tail of the list.
  mutated="$(printf '%s' "$line" | sed 's/, "[^"]*"\]/]/')"
  assert_doctored "$line" "$mutated" "dropping the last shard id" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  declared="$(read_wf stepshards "$doctored" shards 'Install the YAML parser and zsh')" || {
    echo "the doctored workflow did not parse" >&2
    return 1
  }
  needed="$(shard_package_legs "$BATS_SHARDS" "$REPO_ROOT")" || return 1
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
# Why local-janitor.bats is seeded, and into both trees, is stated at its own
# write site below rather than restated here.
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
  # local-janitor.bats goes in BOTH trees because hooks-1 pins it by name and
  # the sharder exits 2 for a shard it cannot resolve: whichever tree HOOKS_DIR
  # is pointed at has to carry it, and the scripts-seam fixtures below point it
  # at the clean one. Its body is plain in both, so hooks-1 never joins the
  # reported set either way.
  printf '#!/usr/bin/env bats\n' >"$root/needs/local-janitor.bats"
  printf '#!/usr/bin/env bats\n' >"$root/clean/local-janitor.bats"
}

# seam_tree_scan <helper> <root> [group] [sharder]
#
# Points ONE seam at the seeded tree's needing directory and every other seam at
# its clean one, then runs <helper> (shard_package_needs or shard_package_legs)
# over the result. <group> selects which weighted group holds the needing
# suite: `hooks` (the default) or `scripts`.
#
# The group is a parameter rather than a second copy of this function because
# the two weighted groups are the two arms of group_for_shard, and a fixture set
# that only ever drives one of them cannot see a narrowing edit to the other.
# That is not hypothetical: before these fixtures covered both arms, the
# scripts arm could be reduced to a singleton with every test in this
# repository still green.
seam_tree_scan() {
  local fn="$1" root="$2" group="${3:-hooks}" sharder="${4:-$BATS_SHARDS}"
  local hooks_dir="$root/clean" scripts_dir="$root/clean"
  case "$group" in
    hooks) hooks_dir="$root/needs" ;;
    scripts) scripts_dir="$root/needs" ;;
    *)
      echo "seam_tree_scan: unknown group $group" >&2
      return 2
      ;;
  esac
  HOOKS_DIR="$hooks_dir" SCRIPTS_TESTS_DIR="$scripts_dir" \
    AUDIT_TESTS_DIR="$root/clean" LIB_DIR="$root/clean" \
    FORENSICS_DIR="$root/clean" STATUSLINE_DIR="$root/clean" \
    "$fn" "$sharder" "$root"
}

# Runs shard_package_needs over a tree seeded by seed_seam_tree, with the hooks
# seam holding the needing suite.
seam_tree_needs() {
  seam_tree_scan shard_package_needs "$1" hooks
}

# Runs shard_package_legs over the same seeded tree, hooks seam holding the
# needing suite. Takes the sharder as an optional $2 so the propagation fixture
# below can drive the same code against a doctored copy.
seam_tree_legs() {
  seam_tree_scan shard_package_legs "$1" hooks "${2:-$BATS_SHARDS}"
}

# A copy of the sharder with its `group` dispatch arm deleted: `shards` and
# `files` still answer, so only the closure step fails. Written beside this
# suite rather than under $BATS_TEST_TMPDIR because the sharder derives its own
# REPO_ROOT with `git -C "$(dirname BASH_SOURCE)" rev-parse --show-toplevel`,
# which fails outright from outside a working tree. teardown reaps it.
#
# The `.bats-shards-scratch.` prefix is deliberate and shared with
# .gaia/tests/lib/bats-shards.bats' own doctored copies: .gitignore carries
# exactly that one pattern, so a run killed before teardown leaves an IGNORED
# stray rather than an untracked file that a later `git add -A` can sweep into
# a commit. A prefix of this fixture's own would need a second .gitignore entry
# to say the same thing.
copy_sharder_without_group() {
  local dest
  dest="$(mktemp "$(dirname "$BATS_SHARDS")/.bats-shards-scratch.XXXXXX")"
  # Recorded in a FILE, not an array: this runs inside a command substitution,
  # where an array append would be made in the subshell and lost. teardown is
  # the ONLY reaper, on the passing and the failing path alike, and this record
  # is the whole mechanism it reaps by: a caller that creates a copy without
  # registering it here leaks one.
  printf '%s\n' "$dest" >>"$BATS_TEST_TMPDIR/scratch-copies"
  # Renames the dispatch label rather than deleting the arm: deleting three
  # lines out of a case arm leaves a stray `;;` and a copy that fails to parse
  # at all, which is a different failure from the one under test. Renamed, the
  # command falls through to the script's own unknown-command arm.
  sed 's/^    group)$/    group-disabled)/' "$BATS_SHARDS" >"$dest"
  printf '%s\n' "$dest"
}

# The defect W10's rounding exists for, reproduced end to end: one suite that
# needs a package, one unrelated suite beside it that grows, and a per-leg
# answer that moves for a reason that has nothing to do with packages. Growing
# a file is the whole mechanism -- the sharder splits a group by BYTE SIZE, so
# a comment added to an unrelated suite is enough.
#
# The loop is bounded and its failure to move is a test failure, not a skip: a
# fixture that never triggered the reshuffle would assert only that two equal
# things stayed equal, which is the shape this whole file's discipline rejects.
@test "W10: a within-group reshuffle moves the needing leg but not the declared legs" {
  local root="$BATS_TEST_TMPDIR/reshuffle" needs_before needs_after legs_before legs_after
  local i=0 moved=''
  seed_seam_tree "$root"
  printf '#!/usr/bin/env bats\ncommand -v zsh\n' >"$root/needs/uses-zsh.bats"

  needs_before="$(seam_tree_needs "$root")" || return 1
  legs_before="$(seam_tree_legs "$root")" || return 1

  # Rounding up has to actually widen here, or the stability below would be
  # trivially true: exactly one leg needs the package, and its group has more
  # legs than that.
  [ "$(printf '%s\n' "$needs_before" | grep -c .)" -eq 1 ] || {
    echo "the fixture did not produce a single needing leg:" >&2
    printf '%s\n' "$needs_before" >&2
    return 1
  }
  [ "$(printf '%s\n' "$legs_before" | grep -c .)" -gt 1 ] || {
    echo "rounding up to whole groups did not widen the set:" >&2
    printf '%s\n' "$legs_before" >&2
    return 1
  }
  grep -qx -- "$needs_before" <<<"$legs_before" || {
    echo "the needing leg is not inside the rounded-up set:" >&2
    printf '%s\n' "$legs_before" >&2
    return 1
  }

  # Grow an unrelated suite beside it until the weighted assignment hands the
  # zsh-naming file to a different leg. Padding in chunks rather than one big
  # write so the walk is crossed rather than jumped over.
  while [ "$i" -lt 24 ]; do
    printf '# pad %s\n' "$i" >>"$root/needs/plain-0.bats"
    i=$((i + 1))
    needs_after="$(seam_tree_needs "$root")" || return 1
    if [ "$needs_after" != "$needs_before" ]; then
      moved=yes
      break
    fi
  done
  [ -n "$moved" ] || {
    echo "growing an unrelated suite never moved the needing leg off $needs_before," >&2
    echo "so this fixture proved nothing about stability" >&2
    return 1
  }

  legs_after="$(seam_tree_legs "$root")" || return 1
  [ "$legs_after" = "$legs_before" ] || {
    echo "the needing leg moved from $needs_before to $needs_after and the declared" >&2
    echo "legs moved with it, which is the churn the rounding exists to stop:" >&2
    printf 'before: %s\n' "$(printf '%s' "$legs_before" | tr '\n' ' ')" >&2
    printf 'after:  %s\n' "$(printf '%s' "$legs_after" | tr '\n' ' ')" >&2
    return 1
  }
}

# Rounding up must not reach past the group that needs a package. Without this,
# a closure that simply returned every shard id would satisfy the stability
# check above perfectly and put an apt install on every leg in the matrix.
@test "W10 adversarial: rounding up stops at the needing leg's own group" {
  local root="$BATS_TEST_TMPDIR/closure-bound" legs
  seed_seam_tree "$root"
  printf '#!/usr/bin/env bats\ncommand -v zsh\n' >"$root/needs/uses-zsh.bats"

  legs="$(seam_tree_legs "$root")" || return 1

  # Every seam but HOOKS_DIR points at the clean tree, so no other group holds
  # a needing suite and none of their legs may appear.
  grep -qE '^(audit|lib|misc|scripts-[0-9]+)$' <<<"$legs" && {
    echo "rounding up reached a group with no needing suite:" >&2
    printf '%s\n' "$legs" >&2
    return 1
  }
  # hooks-1 pins its file by name, so it cannot exchange with the weighted
  # hooks legs and is a group of one: the plain pinned file needs nothing and
  # rounding up must not widen to it.
  grep -qx 'hooks-1' <<<"$legs" && {
    echo "rounding up widened to hooks-1, which exchanges files with nothing:" >&2
    printf '%s\n' "$legs" >&2
    return 1
  }
  grep -qE '^hooks-[0-9]+$' <<<"$legs" || {
    echo "the needing suite's own hooks group was not reported:" >&2
    printf '%s\n' "$legs" >&2
    return 1
  }
  true
}

@test "W10 adversarial: a group the sharder cannot resolve fails the closure rather than narrowing it" {
  local root="$BATS_TEST_TMPDIR/bad-group" broken status_ok status_err
  seed_seam_tree "$root"
  printf '#!/usr/bin/env bats\ncommand -v zsh\n' >"$root/needs/uses-zsh.bats"

  broken="$(copy_sharder_without_group)"

  # Prove the doctored copy is doctored in the one way this test is about, and
  # in no other: `files` still answers, `group` no longer does.
  run bash "$broken" files hooks-2
  [ "$status" -eq 0 ]
  run bash "$broken" group hooks-2
  [ "$status" -ne 0 ]

  # Healthy arm on the real sharder first, so a helper that always failed could
  # not pass this.
  run seam_tree_legs "$root"
  status_ok="$status"

  run seam_tree_legs "$root" "$broken"
  status_err="$status"

  [ "$status_ok" -eq 0 ] || {
    echo "the readable fixture tree did not close cleanly (exit $status_ok)" >&2
    return 1
  }
  [ "$status_err" -ne 0 ] || {
    echo "a sharder that could not resolve a group reported a clean closure" >&2
    return 1
  }
}

# The same two claims as the hooks fixtures above, driven through the OTHER
# weighted group. Without this, group_for_shard's scripts arm could be narrowed
# to a singleton and every test in this repository stayed green: S14 proves the
# declared groups partition the shard set, which a set of singletons also
# satisfies, so the partition alone cannot see a narrowing. The empirical half,
# that a declared group really is a superset of what a reshuffle can move
# across, is what has to be driven per arm.
@test "W10: rounding up survives a reshuffle in the scripts group too, not only hooks" {
  local root="$BATS_TEST_TMPDIR/scripts-seam" needs_before needs_after legs_before legs_after
  local i=0 moved=''
  seed_seam_tree "$root"
  printf '#!/usr/bin/env bats\ncommand -v zsh\n' >"$root/needs/uses-zsh.bats"

  needs_before="$(seam_tree_scan shard_package_needs "$root" scripts)" || return 1
  legs_before="$(seam_tree_scan shard_package_legs "$root" scripts)" || return 1

  [ "$(printf '%s\n' "$needs_before" | grep -c .)" -eq 1 ] || {
    echo "the fixture did not produce a single needing leg:" >&2
    printf '%s\n' "$needs_before" >&2
    return 1
  }
  grep -qE '^scripts-[0-9]+$' <<<"$needs_before" || {
    echo "the needing suite did not land on a scripts leg:" >&2
    printf '%s\n' "$needs_before" >&2
    return 1
  }
  # Rounding up has to widen, and widen only within the scripts group.
  [ "$(printf '%s\n' "$legs_before" | grep -c .)" -gt 1 ] || {
    echo "rounding up did not widen the scripts set:" >&2
    printf '%s\n' "$legs_before" >&2
    return 1
  }
  grep -qE '^(audit|lib|misc|hooks-[0-9]+)$' <<<"$legs_before" && {
    echo "rounding up reached outside the scripts group:" >&2
    printf '%s\n' "$legs_before" >&2
    return 1
  }

  while [ "$i" -lt 24 ]; do
    printf '# pad %s\n' "$i" >>"$root/needs/plain-0.bats"
    i=$((i + 1))
    needs_after="$(seam_tree_scan shard_package_needs "$root" scripts)" || return 1
    if [ "$needs_after" != "$needs_before" ]; then
      moved=yes
      break
    fi
  done
  [ -n "$moved" ] || {
    echo "growing an unrelated suite never moved the needing scripts leg off" >&2
    echo "$needs_before, so this fixture proved nothing about stability" >&2
    return 1
  }

  legs_after="$(seam_tree_scan shard_package_legs "$root" scripts)" || return 1
  [ "$legs_after" = "$legs_before" ] || {
    echo "the needing leg moved from $needs_before to $needs_after and the declared" >&2
    echo "legs moved with it, so the scripts group is not rounded up:" >&2
    printf 'before: %s\n' "$(printf '%s' "$legs_before" | tr '\n' ' ')" >&2
    printf 'after:  %s\n' "$(printf '%s' "$legs_after" | tr '\n' ' ')" >&2
    return 1
  }
}

@test "W10 adversarial: seam_tree_scan refuses a group it does not know" {
  local root="$BATS_TEST_TMPDIR/bad-seam"
  seed_seam_tree "$root"
  # The healthy arms first, so a runner that always failed could not pass this,
  # and so a typo'd group name cannot read as "this group needs nothing".
  run seam_tree_scan shard_package_needs "$root" hooks
  [ "$status" -eq 0 ]
  run seam_tree_scan shard_package_needs "$root" scripts
  [ "$status" -eq 0 ]

  run seam_tree_scan shard_package_needs "$root" nope
  [ "$status" -eq 2 ]
  grep -qF -- 'nope' <<<"$output"
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
  line="$(gate_line_for_step "$WORKFLOW" 'Install the YAML parser and zsh')" || return 1
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
# regression guard for the lines SPEC-072 added to close that hole.
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

# read_wf codefilter unwraps a change-type mapping entry (`- deleted: 'x'`)
# to its bare value, which SPEC-078 needs before any check can read the
# wiki/.state.json entry once it becomes one. Doctored onto
# .gaia/release-exclude, not wiki/.state.json: SPEC-078 makes the mapping
# form of the wiki/.state.json entry the real workflow line, so a fixture
# doctoring that entry would produce a line identical to the real one from
# that point on, assert_doctored would find no change to make, and this case
# would go inert on the very next phase. .gaia/release-exclude is a bare
# entry this change never touches, and W11's own adversarial case above
# already derives that same line, so the pattern is proven.

@test "read_wf codefilter unwraps a change-type mapping entry to its path" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/codefilter-unwrap.yml" line mutated list

  line="$(sole_line_matching "$WORKFLOW" "^ *- '\\.gaia/release-exclude'\$")" || return 1
  mutated="$(printf '%s' "$line" | sed "s/^\\( *\\)- '\\(.*\\)'\$/\\1- deleted: '\\2'/")"
  assert_doctored "$line" "$mutated" "wrapping the entry in a change-type mapping" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  list="$(read_wf codefilter "$doctored" shards)"
  printf '%s\n' "$list" | grep -qxF -- '.gaia/release-exclude' || {
    echo "the unwrapped mapping entry did not print its bare path" >&2
    return 1
  }
  printf '%s\n' "$list" | grep -qF -- '{' && {
    echo "the unwrapped output still carries a Python dict repr" >&2
    return 1
  }
  true
}

@test "read_wf codefilter refuses a change-type mapping entry with more than one value" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/codefilter-two-value.yml" line mutated

  line="$(sole_line_matching "$WORKFLOW" "^ *- '\\.gaia/release-exclude'\$")" || return 1
  mutated="$(printf '%s' "$line" | sed "s/^\\( *\\)- '\\(.*\\)'\$/\\1- {deleted: '\\2', renamed: '\\2'}/")"
  assert_doctored "$line" "$mutated" "wrapping the entry in a two-value mapping" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run read_wf codefilter "$doctored" shards
  [ "$status" -ne 0 ] || {
    echo "a two-value change-type mapping entry did not exit non-zero" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- '.gaia/release-exclude' || {
    echo "the refusal message did not name the offending entry" >&2
    return 1
  }
}

# W13 (SPEC-078 lever one, UAT-003). dorny/paths-filter casts an unrecognized
# change-status token without validating it (filter.ts:171-176), so a
# misspelled or out-of-allowlist key parses cleanly and matches nothing
# forever. This pins the wiki/.state.json entry to exactly `deleted` and
# sweeps every code: entry for the two tokens the action accepts but this
# repository forbids, `renamed` and `copied` -- both are redundant with
# `deleted` on the pull-request lane, which decomposes a rename into a
# delete of the previous path plus an add of the new one before matching:
# the `token` input defaults to github.token (action.yml:5-8), so the
# pull-request lane takes getChangedFilesFromApi (main.ts:101-107), which
# does exactly that decomposition (main.ts:227-239).

@test "W13: audit-ci-tests.yml's code filter keys wiki/.state.json on exactly deleted" {
  require_yaml_parser
  assert_wiki_state_key_is_deleted "$WORKFLOW"
}

@test "W13: no code: filter entry anywhere carries a renamed or copied change-type token" {
  require_yaml_parser
  assert_no_renamed_or_copied_tokens "$WORKFLOW"
}

@test "W13 adversarial: the committed out-of-set-token fixture reds and names the token" {
  require_yaml_parser
  run assert_wiki_state_key_is_deleted "$SPEC078_FIXTURES/codefilter-token-out-of-set.yml"
  [ "$status" -ne 0 ] || {
    echo "the out-of-set token fixture did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "'changed'" || {
    echo "the refusal did not name the offending token 'changed'" >&2
    return 1
  }
}

@test "W13 adversarial: doctoring the entry to an in-set but wrong token reds and names it" {
  require_yaml_parser
  local line
  line="$(sole_line_matching "$WORKFLOW" "^ *- deleted: 'wiki/\\.state\\.json'\$")" || return 1

  local doctored_added="$BATS_TEST_TMPDIR/w13-added.yml" mutated_added
  mutated_added="$(printf '%s' "$line" | sed "s/deleted:/added:/")"
  assert_doctored "$line" "$mutated_added" "keying the entry on added" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated_added" "$doctored_added"
  run assert_wiki_state_key_is_deleted "$doctored_added"
  [ "$status" -ne 0 ] || {
    echo "keying the entry on 'added' did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "'added'" || {
    echo "the refusal did not name the offending token 'added'" >&2
    return 1
  }

  local doctored_compound="$BATS_TEST_TMPDIR/w13-compound.yml" mutated_compound
  mutated_compound="$(printf '%s' "$line" | sed "s/deleted:/deleted|renamed:/")"
  assert_doctored "$line" "$mutated_compound" "keying the entry on deleted|renamed" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated_compound" "$doctored_compound"
  run assert_wiki_state_key_is_deleted "$doctored_compound"
  [ "$status" -ne 0 ] || {
    echo "keying the entry on 'deleted|renamed' did not red, so the check is a substring test rather than whole-field equality" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "'deleted|renamed'" || {
    echo "the refusal did not name the offending compound token 'deleted|renamed'" >&2
    return 1
  }
}

@test "W13 adversarial: the renamed/copied sweep reds when a second, unrelated entry is doctored" {
  require_yaml_parser
  local line mutated doctored="$BATS_TEST_TMPDIR/w13-sweep.yml"
  line="$(sole_line_matching "$WORKFLOW" "^ *- '\\.gaia/release-exclude'\$")" || return 1
  mutated="$(printf '%s' "$line" | sed "s/^\\( *\\)- '\\(.*\\)'\$/\\1- renamed: '\\2'/")"
  assert_doctored "$line" "$mutated" "wrapping an unrelated entry in a renamed: mapping" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_no_renamed_or_copied_tokens "$doctored"
  [ "$status" -ne 0 ] || {
    echo "doctoring .gaia/release-exclude into a renamed: mapping did not red the sweep" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- '.gaia/release-exclude' || {
    echo "the sweep's refusal did not name the offending entry" >&2
    return 1
  }
}

# W14 (SPEC-078 lever one, UAT-025). Lever one's premises are properties of
# an unvendored dependency, dorny/paths-filter, that a grouped weekly
# dependency bump moves without anyone reading the diff. This pins the
# workflow's dorny/paths-filter version to the pair the premises in
# task-lever-one.md's step 0 were verified against. leg-arming.sh's
# pagination rule rests on one more property of the same pin, the
# pull-request lane's listing cap, so the refusal names that premise beside
# lever one's.

@test "W14: the workflow's dorny/paths-filter pin matches the version lever one's premises were verified against" {
  assert_paths_filter_pin_matches "$WORKFLOW"
}

@test "W14 adversarial: the committed bumped-pin fixture reds and names both versions" {
  run assert_paths_filter_pin_matches "$SPEC078_FIXTURES/paths-filter-pin-bumped.yml"
  [ "$status" -ne 0 ] || {
    echo "the bumped-pin fixture did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "$PATHS_FILTER_PINNED_SHA" || {
    echo "the refusal did not name the recorded SHA" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- '0000000000000000000000000000000000000000' || {
    echo "the refusal did not name the fixture's bumped SHA" >&2
    return 1
  }
}

@test "W14 adversarial: the bumped-pin refusal names the listing-cap premise leg-arming's pagination rule rests on" {
  run assert_paths_filter_pin_matches "$SPEC078_FIXTURES/paths-filter-pin-bumped.yml"
  [ "$status" -ne 0 ] || {
    echo "the bumped-pin fixture did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- 'pulls.listFiles (main.ts:211-218)' || {
    echo "the refusal did not cite the pinned source's listFiles pagination" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- 'PAGINATION_CAP' || {
    echo "the refusal did not name the leg-arming rule that rests on the listing cap" >&2
    return 1
  }
}

# W15 (SPEC-078 lever one, UAT-004). Lever one's whole premise is that
# check-wiki-state-collision.sh cannot see a difference between two commits
# that change only wiki/.state.json's bytes. "The checker reads the file's
# contents" is not statically decidable in shell, so this is a behavioral
# oracle rather than a spelling-specific scan: see assert_checker_is_content_
# blind's own header for why, and the adversarial case below for the proof
# that a checker perturbed to read the bytes makes the oracle disagree.

@test "W15: check-wiki-state-collision.sh is content-blind (behavioral oracle)" {
  assert_checker_is_content_blind "$CHECK_WIKI_STATE_COLLISION"
}

@test "W15 adversarial: the oracle fails when the checker is doctored to read the file's bytes" {
  local old mutated doctored_checker="$BATS_TEST_TMPDIR/doctored-check-wiki-state-collision.sh"
  old="$(sole_line_matching "$CHECK_WIKI_STATE_COLLISION" "printf 'wiki state file tracked: yes")" || return 1
  mutated='    printf '\''wiki state file tracked: yes (%s)\n'\'' "$(head -c 8 "$repo_root/wiki/.state.json" 2>/dev/null)"'
  assert_doctored "$old" "$mutated" "making the tracked verdict echo content-derived bytes" || return 1
  replace_line "$CHECK_WIKI_STATE_COLLISION" "$old" "$mutated" "$doctored_checker"

  run assert_checker_is_content_blind "$doctored_checker"
  [ "$status" -ne 0 ] || {
    echo "doctoring the checker to echo content-derived bytes did not fail the oracle" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "output differs" || {
    echo "the oracle's failure did not name the differing output" >&2
    return 1
  }
}

# W12. Every gaia-setup-node step in EVERY workflow is capped with an integer
# literal that fires before its job's own cap.
#
# The apt step already carries `timeout-minutes: 6` and says why in so many
# words -- "Sized for fast failure and honest attribution" -- so the reasoning
# was in this file before this check was. What was missing was anything that
# holds a NEW call site to it: W5 caps jobs and says nothing about steps, and
# a step with no cap runs until the job's 13-minute cap fires, which reds
# `Audit CI Tests` (a declared-required context) with a generic job-timeout
# message rather than an error attributed to the install.
#
# That gap is not hypothetical. gaia-react/gaia#1762 was filed against the two
# uncapped call sites this file then held; by the time it was drained a third
# had been added, uncapped, in the same shape. Enumerating the sites from the
# `uses:` value, rather than from a list of step names, is what makes the next
# one reachable without an edit here.
#
# The reach used to stop at this workflow, and that scope was itself the
# defect: `setupnodecaps` walked `$WORKFLOW` alone, so the same composite action
# invoked from any other workflow was outside what this check could report, and
# W5, the sibling that does run tree-wide, asserts a cap per JOB and says
# nothing about steps. Call sites across the other workflows sat uncapped
# behind that gap until gaia-react/gaia#1793 drained them. So the subject set
# is now every file in `.github/workflows/`, derived in `setup()` from the
# directory, and the reach tests below assert that derivation rather than
# trusting it: no workflow in the index is missing from it, and call sites are
# actually read across more than one file. Re-pinning the check to a single
# workflow reds them, which is what makes this widening durable rather than a
# repair of the instance.
#
# Enumerating steps from the `uses:` value and workflows from the directory are
# the same move applied to the two axes this check can be narrowed on. Neither
# is a convenience: each is what keeps a site added later reachable without an
# edit here, and a check narrowed on either axis reports clean over what it
# never opened.
#
# The cap must also be strictly under its job's cap. A step cap at or above
# the job's can never fire first, so it reads as a bound while buying none of
# the attribution that is the whole point.
#
# Every fixture below passes ONE doctored copy of this workflow rather than the
# whole scanned set, and the predicate is variadic so that still drives the same
# code the check runs. Doctoring one file inside the real set would leave the
# other workflows' healthy steps in the read, which is fine for the gap arms but
# would silently defeat the empty-set arm, whose whole subject is a read that
# came back with nothing in it.
#
# The step-cap fixtures below doctor by full-line equality on
# `        timeout-minutes: 5`, which every one of these steps carries at the
# same indentation, so each of those fixtures breaks all of them at once. That
# is W5's own fixture style and it is sufficient here: the check reports the
# whole set and reds on any member, so breaking the set proves the same branch
# a single member would. The eight-space indent is what keeps the pattern off
# the four-space job-level `timeout-minutes: 5`, which belongs to
# `hook-capabilities-live-tree` rather than to any step.
#
# The rest of the fixtures pin other literals, because the arms they drive are
# not about a step's own cap: the owning-job fixture deletes the four-space
# `    timeout-minutes: 13` the steps' own job declares, and the empty-set and
# normalization fixtures rewrite the `uses:` line. A maintainer repairing stale
# pins after the workflow moves owes every one of those literals, not the step
# cap alone.
#
# A stale pin fails closed, by two different routes. A fixture asserting a gap
# gets it structurally: a no-op `delete_line` / `replace_line` leaves the
# doctored copy equal to the original, so the predicate answers for the healthy
# file and the arm the fixture asserts never fires. The normalization fixture
# asserts the HEALTHY outcome, which a no-op doctoring also produces, so it
# cannot get that for free and compares the two files itself.
#
# Every fixture drives `setup_node_cap_gaps`, the same predicate the check
# itself calls, rather than re-reading `setupnodecaps` and re-deciding in its
# own body. There is one adversarial fixture per gap outcome that predicate can
# produce, each grepping the gap string only its own arm emits; the
# normalization fixture drives the same predicate and asserts the clean outcome
# instead, so it greps nothing. That is this file's own header rule at the top,
# and the reason for it is exact here: a predicate
# written inline in the `@test` body runs only against the healthy workflow,
# where every branch it takes is the passing one, so weakening the comparison
# or gutting an arm leaves the whole set green.
# `workflow_timeout_gaps` in .gaia/scripts/tests/retrigger-reachability.bats is
# the shape being copied.

setup_node_caps() {
  read_wf setupnodecaps "$1"
}

# Every capping gap the gaia-setup-node steps in <workflow-file>... present, one
# line per gap, each naming its own workflow, empty when they have none.
# Returns non-zero when NO step was read across the whole argument list, which
# is a gap of its own rather than a clean read: this enumerates its subjects
# from the `uses:` value instead of pinning them, so a renamed action yields
# nothing and would otherwise be indistinguishable from every step passing.
#
# The emptiness verdict is over the whole list, not per file. Most workflows
# legitimately call this action from no step at all, so a per-file verdict would
# report every one of them as reaching nothing the moment the check went
# tree-wide. The adversarial fixtures below pass a single doctored file, where
# the two verdicts coincide.
setup_node_cap_gaps() {
  local file wf
  local jid name kind cap job_cap seen="" gaps=""
  local caps="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/setup-node-caps.$$"

  for file in "$@"; do
    wf="$(basename "$file")"
    # `read_wf` exits 2 on a file it cannot load (unparseable YAML, unreadable
    # path) or that declares no `jobs:` mapping, and a process substitution
    # discards that status. Per file that was harmless while the emptiness
    # verdict was per file too, since the unread file's own zero lines tripped
    # it. Whole-list it is not: the other workflows keep `seen` set, so an
    # unreadable one would contribute nothing, report nothing, and leave the
    # check green over a file it never opened -- the same blindness the
    # tree-wide widening exists to remove, reintroduced one layer down. So the
    # read is captured and its status tested per file, and a failure becomes a
    # reported gap. `workflow_timeout_gaps` in
    # .gaia/scripts/tests/retrigger-reachability.bats reports its own per-file
    # zero for the same reason; this is that shape.
    if ! setup_node_caps "$file" > "$caps"; then
      gaps="${gaps}${wf}: could not be read (unparseable YAML, or no jobs mapping), so its gaia-setup-node steps were never opened"$'\n'
      continue
    fi
    while IFS=$'\t' read -r jid name kind cap job_cap; do
      [ -n "$jid" ] || continue
      seen="x"
      if [ "$kind" != "int" ]; then
        gaps="${gaps}${wf} ${jid}/${name}: cap is ${kind}, not an integer literal"$'\n'
        continue
      fi
      if [ "$job_cap" = "-" ]; then
        gaps="${gaps}${wf} ${jid}/${name}: the owning job declares no integer cap"$'\n'
        continue
      fi
      [ "$cap" -lt "$job_cap" ] \
        || gaps="${gaps}${wf} ${jid}/${name}: ${cap}m is not under the job's ${job_cap}m"$'\n'
    done < "$caps"
  done
  rm -f "$caps"

  # One condition now reaches an empty read: every workflow loaded and none
  # called the action, so it was renamed or its last call site removed. The
  # unreadable-file case used to land here too and no longer does; it is a
  # named gap above, which is the stronger report because it says which file.
  # Guarded on `gaps` as well as `seen` so a run whose only workflows were
  # unreadable reports them rather than replacing them with this message.
  if [ -z "$seen" ] && [ -z "$gaps" ]; then
    printf 'no gaia-setup-node step read across the workflows scanned, though every one of them loaded. The action was renamed, or its last call site was removed. Either way this check is now reaching nothing.\n'
    return 1
  fi

  printf '%s' "$gaps"
  [ -z "$gaps" ]
}

# The workflow files in <workflow-file>... that call gaia-setup-node from at
# least one step, one basename per line, and `unreadable:<basename>` for one
# that would not load. Only the reach tests read this; the check itself needs
# the gaps, not the file set.
setup_node_workflows() {
  local file caps="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/setup-node-workflows.$$"
  for file in "$@"; do
    # The same per-file status capture `setup_node_cap_gaps` makes, and this
    # helper needs it for a different reason. Piping into `grep -q` would
    # discard `read_wf`'s exit 2, leaving an unreadable workflow
    # indistinguishable from one that calls the action from no step. That
    # direction fails closed, since either way the file contributes no
    # basename and a lower count reds the reach assertion, so what is lost is
    # not the catch but the diagnosis: the assertion would blame a re-narrowed
    # scan set for a file that simply would not load, which is the wrong
    # repair. Marking it is what lets the caller tell those two apart.
    if ! setup_node_caps "$file" > "$caps"; then
      printf 'unreadable:%s\n' "$(basename "$file")"
      continue
    fi
    if grep -q '.' "$caps"; then
      basename "$file"
    fi
  done
  rm -f "$caps"
}

@test "W12: every gaia-setup-node step declares an integer cap under its job's cap" {
  require_yaml_parser
  local gaps
  gaps="$(setup_node_cap_gaps "${WORKFLOW_FILES[@]}")" || {
    echo "$gaps" >&2
    return 1
  }
  [ -z "$gaps" ] || { echo "$gaps" >&2; return 1; }
}

# The reach tests below assert the DERIVATION, which the check itself cannot: a
# narrowed subject set produces a clean read, and a clean read and a blind one
# are the same output. That indistinguishability is what let uncapped call
# sites stand green for as long as they did, so re-narrowing has to red
# something other than the check.
@test "W12 reach: every workflow in the index is in the scanned set" {
  local tracked missing="" listing="$BATS_TEST_TMPDIR/tracked-workflows"
  # The index is a second authority on the set, independent of the directory
  # glob setup() derives it from. A short read -- a glob narrowed to one
  # extension, one prefix, or one file -- leaves the check green over the
  # workflows it still opens, so the difference between the two is what has to
  # be reported.
  #
  # Captured to a file rather than read straight from a process substitution,
  # so this derivation's own status and emptiness are both testable. The loop
  # below is a per-element claim, and a per-element claim over an empty set is
  # true while asserting nothing: an unlisted index would report ok having
  # compared no workflow at all. setup() guards its own derivation exactly
  # this way, and feeding this loop from a substitution would leave this the
  # one derivation in the check without it. `-z` is what keeps a C-quoted
  # non-ASCII path from silently failing the comparison.
  git -C "$REPO_ROOT" ls-files -z -- \
    '.github/workflows/*.yml' '.github/workflows/*.yaml' > "$listing" || {
    echo "could not list tracked workflows; this assertion would otherwise pass over an empty set" >&2
    return 1
  }
  [ -s "$listing" ] || {
    echo "the index lists no workflow at all; this assertion would otherwise pass having compared nothing" >&2
    return 1
  }

  while IFS= read -r -d '' tracked; do
    [ -n "$tracked" ] || continue
    printf '%s\n' "${WORKFLOW_FILES[@]}" | grep -qxF "$REPO_ROOT/$tracked" \
      || missing="${missing}${tracked}"$'\n'
  done < "$listing"

  [ -z "$missing" ] || {
    printf 'tracked workflows absent from the W12 scan set:\n%s' "$missing" >&2
    return 1
  }
}

@test "W12 reach: gaia-setup-node call sites are read across more than one workflow" {
  require_yaml_parser
  local read_set scanned pinned unreadable
  # Counting the workflows that CONTRIBUTE a step, not the ones scanned: a set
  # widened to every file while the steps still come from one of them is the
  # same blindness with a longer argument list.
  read_set="$(setup_node_workflows "${WORKFLOW_FILES[@]}")"
  # A workflow that would not load contributes no basename, so it depresses
  # the count exactly as a re-narrowed set would. Reported separately and
  # first, because the two have different repairs and the count's own message
  # can only name one of them.
  unreadable="$(printf '%s\n' "$read_set" | grep '^unreadable:' || true)"
  [ -z "$unreadable" ] || {
    printf 'workflows that would not load, so the count below is not a verdict on the scan set:\n%s\n' "$unreadable" >&2
    return 1
  }
  scanned="$(printf '%s\n' "$read_set" | grep -c '.' || true)"
  # The pre-#1793 scope, driven through the same helper, as the control that
  # makes the assertion above discriminating rather than merely true: it must
  # answer 1, or `-gt 1` is passing for some reason other than the widening.
  pinned="$(setup_node_workflows "$WORKFLOW" | grep -c '.' || true)"

  [ "$pinned" -eq 1 ] || {
    echo "the single-workflow control read $pinned workflows, so the reach assertion below proves nothing" >&2
    return 1
  }
  [ "$scanned" -gt 1 ] || {
    echo "gaia-setup-node steps were read from $scanned workflow(s); the check has re-narrowed to a single file" >&2
    return 1
  }
}

@test "W12 adversarial: a gaia-setup-node step with no cap is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12a.yml" gaps
  delete_line "$WORKFLOW" "        timeout-minutes: 5" "$doctored"

  gaps="$(setup_node_cap_gaps "$doctored")" && {
    echo "deleting every step cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'cap is missing, not an integer literal' || {
    echo "an absent step cap was not reported as missing: ${gaps}" >&2
    return 1
  }
}

@test "W12 adversarial: an expression-valued step cap is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12b.yml" gaps
  replace_line "$WORKFLOW" "        timeout-minutes: 5" \
    "        timeout-minutes: \${{ github.event_name }}" "$doctored"

  gaps="$(setup_node_cap_gaps "$doctored")" && {
    echo "an expression-valued step cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'cap is other, not an integer literal' || {
    echo "an expression-valued step cap was not reported as non-integer: ${gaps}" >&2
    return 1
  }
}

@test "W12 adversarial: a step cap at the job's own cap is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12c.yml" gaps
  replace_line "$WORKFLOW" "        timeout-minutes: 5" "        timeout-minutes: 13" "$doctored"

  gaps="$(setup_node_cap_gaps "$doctored")" && {
    echo "a step cap equal to the job's own 13m left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF "13m is not under the job's 13m" || {
    echo "a step cap equal to the job's cap was not reported as over-capped: ${gaps}" >&2
    return 1
  }
}

@test "W12 adversarial: a step whose owning job declares no cap is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12e.yml" gaps
  delete_line "$WORKFLOW" "    timeout-minutes: 13" "$doctored"

  gaps="$(setup_node_cap_gaps "$doctored")" && {
    echo "removing the owning job's own cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'the owning job declares no integer cap' || {
    echo "a step whose job declares no cap was not reported: ${gaps}" >&2
    return 1
  }
}

# The one fixture here that passes TWO files, and it has to. The arm it drives
# only differs from the old behaviour when a healthy sibling is present to keep
# `seen` set: an unreadable file on its own trips the empty-read arm either way,
# so a single-file fixture would pass against the code that has this bug.
@test "W12 adversarial: a workflow that will not parse is reported, not skipped" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12g.yml" gaps
  # An unterminated flow mapping where the jobs block opens: PyYAML raises
  # rather than returning a partial document, which is the `read_wf` exit-2
  # path. Doctoring the workflow's own `jobs:` line rather than writing a
  # throwaway file keeps the fixture pointed at a real subject, the same way
  # every fixture above does.
  replace_line "$WORKFLOW" "jobs:" "jobs: {" "$doctored"

  gaps="$(setup_node_cap_gaps "$doctored" "$WORKFLOW")" && {
    echo "an unparseable workflow beside a healthy one left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'could not be read' || {
    echo "an unparseable workflow was silently skipped rather than reported: ${gaps}" >&2
    return 1
  }
}

# The reach helper's own copy of the arm above. It needs its own fixture
# because the reach tests run over the real workflow set, where nothing fails
# to parse, so the marker would otherwise ship undriven. Two files again, and
# for the same reason: the marker only earns its keep when a healthy sibling
# is present to be counted normally beside it.
@test "W12 adversarial: the reach helper marks an unparseable workflow rather than counting it stepless" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12h.yml" read_set
  replace_line "$WORKFLOW" "jobs:" "jobs: {" "$doctored"

  read_set="$(setup_node_workflows "$doctored" "$WORKFLOW")"
  printf '%s\n' "$read_set" | grep -qF "unreadable:$(basename "$doctored")" || {
    echo "an unparseable workflow read as one that simply calls no step: ${read_set}" >&2
    return 1
  }
}

@test "W12 adversarial: a workflow with no gaia-setup-node step reds rather than passing empty" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12d.yml" gaps
  replace_line "$WORKFLOW" "        uses: ./.github/actions/gaia-setup-node" \
    "        uses: ./.github/actions/gaia-setup-node-renamed" "$doctored"

  gaps="$(setup_node_cap_gaps "$doctored")" && {
    echo "renaming the action away left the check reporting a clean read" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'this check is now reaching nothing' || {
    echo "an empty enumeration was not reported as reaching nothing: ${gaps}" >&2
    return 1
  }
}

# The fixture below inverts the adversarial ones above: it doctors a LEGAL
# alternate spelling and asserts the check still reads the steps. `uses:`
# accepts more than one spelling of the same local action, and a spelling the
# normalization misses is SKIPPED rather than reported, so on a real workflow
# the miss surfaces as a short read that the surviving call sites keep out of
# the empty-set arm. Doctoring every call site at once is what turns that short
# read into an empty one this assertion can see.
@test "W12 normalization: a trailing slash on the uses: path still reads the steps" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12f.yml" gaps
  replace_line "$WORKFLOW" "        uses: ./.github/actions/gaia-setup-node" \
    "        uses: ./.github/actions/gaia-setup-node/" "$doctored"
  cmp -s "$WORKFLOW" "$doctored" && {
    echo "the uses: pin is stale, so doctoring changed nothing and this fixture proves nothing" >&2
    return 1
  }

  gaps="$(setup_node_cap_gaps "$doctored")" || {
    echo "a trailing-slash spelling left the check reaching nothing: ${gaps}" >&2
    return 1
  }
  [ -z "$gaps" ] || { echo "$gaps" >&2; return 1; }
}

# W16 to W18 pin .gaia/tests/leg-arming.sh, the per-leg arming gate (SPEC-078
# lever two). The helpers below are shared by all of them. Each takes the
# sharder and the root it resolves against as arguments rather than reading
# $REPO_ROOT, so a fixture can drive the same code against a tree of its own,
# the discipline the W10 header sets out.

# arming_legs <workflow>
#
# The legs the arming step decides: the `shards` matrix minus `sandbox`, whose
# steps carry no `code:` conjunct and never reach the script. One per line,
# LC_ALL=C sorted. The matrix rather than the sharder, because the sharder
# refuses the concurrency leg outright and so cannot name every leg.
arming_legs() {
  local workflow="$1" list rc=0
  list="$(read_wf matrix "$workflow" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$list" ]; then
    echo "arming_legs: read no shards matrix from $workflow (exit $rc)" >&2
    return 1
  fi
  printf '%s\n' "$list" | awk '$0 != "" && $0 != "sandbox"' | LC_ALL=C sort -u
}

# arming_parser_class <workflow>
#
# The narrowable class as PyYAML reads it: the `code:` entries of the `shards`
# job's paths-filter step whose value begins `wiki/`, the script's own prefix
# test, one per line, LC_ALL=C sorted and deduplicated, the shape
# `leg-arming.sh class` prints.
arming_parser_class() {
  local workflow="$1" list rc=0
  list="$(read_wf codefilter "$workflow" shards)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "arming_parser_class: could not parse the code: filter in $workflow (exit $rc)" >&2
    return 1
  fi
  printf '%s\n' "$list" | awk 'index($0, "wiki/") == 1' | LC_ALL=C sort -u
}

# arming_concurrency_leg <sharder> <workflow>
#
# The one arming leg the sharder does not name: the leg the concurrency seam's
# suites resolve to. Derived rather than named, and refused unless exactly one
# leg answers, so a second unsharded leg cannot be folded into it silently.
arming_concurrency_leg() {
  local sharder="$1" workflow="$2" legs ids leg found='' n=0 rc=0
  legs="$(arming_legs "$workflow")" || return 1
  ids="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ids" ]; then
    echo "arming_concurrency_leg: the sharder listed no shard id (exit $rc)" >&2
    return 1
  fi
  while IFS= read -r leg || [ -n "$leg" ]; do
    [ -n "$leg" ] || continue
    if ! grep -qxF -- "$leg" <<<"$ids"; then
      found="$leg"
      n=$((n + 1))
    fi
  done <<EOF
$legs
EOF
  if [ "$n" -ne 1 ]; then
    echo "arming_concurrency_leg: $n arming legs are not sharder ids, expected exactly one" >&2
    return 1
  fi
  printf '%s\n' "$found"
}

# arming_units_file <sharder> <root>
#
# The sharder's view of a tree, written to a scratch file whose path is
# printed: `G<TAB><id><TAB><group ids>` per shard, `F<TAB><id><TAB><path>` per
# suite it lists, each path absolutized against <root>. A shard that lists
# nothing, or whose group will not resolve, is a refusal rather than a shard
# with no suites: the zero-files rule the sharder applies to itself, and the
# direction the arming script fails in.
arming_units_file() {
  local sharder="$1" root="$2" ids id listing group data f abs rc=0
  ids="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ids" ]; then
    echo "arming_units_file: the sharder listed no shard id (exit $rc)" >&2
    return 1
  fi
  data="$(mktemp "$BATS_TEST_TMPDIR/arming-units.XXXXXX")"
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    rc=0
    listing="$(bash "$sharder" files "$id")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$listing" ]; then
      echo "arming_units_file: the sharder listed no suite for shard $id (exit $rc)" >&2
      return 1
    fi
    rc=0
    group="$(bash "$sharder" group "$id")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$group" ]; then
      echo "arming_units_file: the sharder resolved no exchange group for shard $id (exit $rc)" >&2
      return 1
    fi
    printf 'G\t%s\t%s\n' "$id" "$(printf '%s\n' "$group" | paste -sd' ' -)" >>"$data"
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      case "$f" in
        /*) abs="$f" ;;
        *) abs="$root/$f" ;;
      esac
      printf 'F\t%s\t%s\n' "$id" "$abs" >>"$data"
    done <<EOF
$listing
EOF
  done <<EOF
$ids
EOF
  printf '%s\n' "$data"
}

# arming_scan_py <mode> <units-file>
#
# The arming scan's frozen rules, reimplemented in Python rather than shared
# with the script, so W16's recomputation is a second implementation and not
# the script's own code read back. Discovery: every suite in <units-file>; each
# suite directory's helpers/, lib/ and fixtures/ subtrees, recursively and
# with no include filter, symlinks skipped as `grep -r` skips them; and the
# concurrency seam's suites and its lib/ subtree. Attribution: a suite to its
# shard, a subtree file to every shard holding a suite in that directory, a
# concurrency-seam file to the concurrency leg.
#
#   inputs   one `<kind><TAB><path>` line per input file
#   w18      the input files W18 reads: every one except a fixtures/ file that
#            is not shell by extension or shebang, which a suite reads as data
#            rather than runs to build a path
#   table    one `<page>|<armed legs>` row per class member: the union of the
#            exchange groups holding a file that names the page by full path
#            or bare basename, fixed-string, plus the group holding this suite
#            (rule 5); every leg when no file names the page, or when the
#            namer-of-all rule leaves it no namer (rule 7). ARMING_STATS, when
#            set, receives the discovery counts.
#
# Inputs through the environment: ARMING_CONC_DIR, ARMING_CONC_LEG, and for
# `table` also ARMING_CLASS, ARMING_LEGS and ARMING_ROOT.
arming_scan_py() {
  python3 - "$@" <<'PY'
import glob
import os
import re
import sys

mode, data = sys.argv[1], sys.argv[2]
env = os.environ


def die(msg):
    sys.stderr.write('arming scan: %s\n' % msg)
    sys.exit(1)


def raise_error(exc):
    raise exc


groups = {}
suites = []
with open(data, encoding='utf-8') as handle:
    for line in handle:
        kind, sid, value = line.rstrip('\n').split('\t', 2)
        if kind == 'G':
            groups[sid] = value.split()
        else:
            suites.append((value, sid))
if not suites:
    die('the sharder discovered no suite')

inputs = []
by_dir = {}
for path, sid in suites:
    inputs.append((path, 'suite', {sid}))
    by_dir.setdefault(os.path.dirname(path), set()).add(sid)


def walk(top, kind, ids):
    for dirpath, dirnames, filenames in os.walk(top, onerror=raise_error):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                inputs.append((path, kind, set(ids)))


for directory in sorted(by_dir):
    for sub in ('helpers', 'lib', 'fixtures'):
        top = os.path.join(directory, sub)
        if os.path.isdir(top):
            walk(top, sub, by_dir[directory])

conc_dir, conc_leg = env['ARMING_CONC_DIR'], env['ARMING_CONC_LEG']
if not os.path.isdir(conc_dir):
    die('the concurrency seam %s is not a directory' % conc_dir)
conc = sorted(glob.glob(os.path.join(glob.escape(conc_dir), '*.bats')))
if not conc:
    die('the concurrency seam %s holds no suite' % conc_dir)
for path in conc:
    inputs.append((path, 'concurrency', {conc_leg}))
if os.path.isdir(os.path.join(conc_dir, 'lib')):
    walk(os.path.join(conc_dir, 'lib'), 'concurrency-lib', [conc_leg])

if mode == 'inputs':
    for path, kind, _ids in inputs:
        print('%s\t%s' % (kind, path))
    sys.exit(0)

if mode == 'w18':
    shebang = re.compile(r'^#!.*(^|[/ ])(bash|sh|zsh|bats)(\s|$)')
    for path, kind, _ids in inputs:
        if kind == 'fixtures' and not path.endswith(('.sh', '.bash', '.bats')):
            with open(path, 'rb') as handle:
                first = handle.readline().decode('utf-8', 'replace')
            if not shebang.match(first):
                continue
        print(path)
    sys.exit(0)

members = [m for m in env['ARMING_CLASS'].split('\n') if m]
legs = [leg for leg in env['ARMING_LEGS'].split('\n') if leg]
if not members:
    die('the narrowable class is empty')
if not legs:
    die('the leg set is empty')

check = os.path.join(env['ARMING_ROOT'], '.gaia/tests/lib/audit-ci-shards.bats')
holders = sorted({sid for path, sid in suites if path == check})
if len(holders) != 1:
    die('%d shards list %s, expected exactly one' % (len(holders), check))


def group_of(sid):
    if sid in groups:
        return groups[sid]
    if sid == conc_leg:
        return [conc_leg]
    die('no exchange group for %s' % sid)


needles = [(m.encode('utf-8'), m.rsplit('/', 1)[-1].encode('utf-8')) for m in members]
names = {}
for path, _kind, _ids in inputs:
    if path in names:
        continue
    try:
        with open(path, 'rb') as handle:
            body = handle.read()
    except OSError as exc:
        die('could not read %s (%s)' % (path, exc.__class__.__name__))
    names[path] = frozenset(
        i for i, (full, base) in enumerate(needles) if full in body or base in body)

everything = frozenset(range(len(members)))
rows = []
for i, member in enumerate(members):
    named = False
    contributors = set()
    for path, _kind, ids in inputs:
        if i not in names[path]:
            continue
        if len(members) > 1 and names[path] == everything:
            continue
        named = True
        contributors |= ids
    if not named:
        armed = set(legs)
    else:
        armed = set(group_of(holders[0]))
        for sid in contributors:
            armed |= set(group_of(sid))
    rows.append('%s|%s' % (member, ' '.join(sorted(armed))))

stats = env.get('ARMING_STATS', '')
if stats:
    with open(stats, 'w', encoding='utf-8') as handle:
        handle.write('suites %d\n' % len({path for path, _sid in suites}))
        handle.write('subtree %d\n' % sum(
            1 for _p, kind, _i in inputs if kind in ('helpers', 'lib', 'fixtures')))
        handle.write('concurrency %d\n' % sum(
            1 for _p, kind, _i in inputs if kind.startswith('concurrency')))
print('\n'.join(rows))
PY
}

# arming_recompute <sharder> <root> <workflow> <conc-dir> <conc-leg> [stats-file]
#
# W16's recomputation from the tree, one `<page>|<armed legs>` row per page of
# the class PyYAML reads from <workflow>. See arming_scan_py for the rules.
#
# Two kinds of file in the input set name narrowable pages without reading them,
# and both are counted rather than special-cased. This suite is a discovered
# `lib` suite, and w16_declared_table names every page, so it is a namer of all
# and the namer-of-all rule drops it. Of the committed fixtures under
# .gaia/tests/lib/fixtures/spec-078/, which sit in a fixtures/ subtree beside
# the `lib` suites, only codefilter-token-out-of-set.yml names wiki/.state.json,
# so it attributes to `lib`; paths-filter-pin-bumped.yml names no narrowable
# page. Neither can move an armed set: `lib` holds this suite, which rule 5
# arms on every page anyway.
arming_recompute() {
  local sharder="$1" root="$2" workflow="$3" conc_dir="$4" conc_leg="$5" stats="${6:-}"
  local class legs data
  class="$(arming_parser_class "$workflow")" || return 1
  legs="$(arming_legs "$workflow")" || return 1
  data="$(arming_units_file "$sharder" "$root")" || return 1
  ARMING_CLASS="$class" ARMING_LEGS="$legs" ARMING_ROOT="$root" \
    ARMING_CONC_DIR="$conc_dir" ARMING_CONC_LEG="$conc_leg" ARMING_STATS="$stats" \
    arming_scan_py table "$data"
}

# arming_inputs <sharder> <root> <conc-dir> <conc-leg> [mode]
#
# The arming scan's input set through the same discovery arming_recompute
# scans, so W16 and W18 cannot read different sets. [mode] is `inputs` (the
# default) or `w18`, as arming_scan_py documents them.
arming_inputs() {
  local sharder="$1" root="$2" conc_dir="$3" conc_leg="$4" mode="${5:-inputs}" data
  data="$(arming_units_file "$sharder" "$root")" || return 1
  ARMING_CONC_DIR="$conc_dir" ARMING_CONC_LEG="$conc_leg" arming_scan_py "$mode" "$data"
}

# assert_arming_input_complete <stats-file> <sharder>
#
# The recomputation read every suite <sharder> lists, recounted from the
# sharder rather than from the recomputation's own listing, and read something
# under both the subtrees and the concurrency seam. A short read is the more
# dangerous failure: it greens every row it happened to reach.
assert_arming_input_complete() {
  local stats="$1" sharder="$2" ids id listing suites subtree conc expected=0 rc=0
  [ -s "$stats" ] || {
    echo "the recomputation wrote no discovery counts to $stats" >&2
    return 1
  }
  suites="$(awk '$1 == "suites" { print $2 }' "$stats")"
  subtree="$(awk '$1 == "subtree" { print $2 }' "$stats")"
  conc="$(awk '$1 == "concurrency" { print $2 }' "$stats")"
  rc=0
  ids="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ids" ]; then
    echo "assert_arming_input_complete: the sharder listed no shard id (exit $rc)" >&2
    return 1
  fi
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    rc=0
    listing="$(bash "$sharder" files "$id")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "assert_arming_input_complete: the sharder could not list shard $id (exit $rc)" >&2
      return 1
    fi
    expected=$((expected + $(printf '%s\n' "$listing" | awk 'NF { n++ } END { print n + 0 }')))
  done <<EOF
$ids
EOF
  [ "$expected" -gt 0 ] || {
    echo "the sharder lists no suite, so the arming scan would read nothing" >&2
    return 1
  }
  [ "$suites" = "$expected" ] || {
    echo "the recomputation scanned ${suites:-no} discovered suites, and the sharder lists $expected" >&2
    return 1
  }
  [ "${subtree:-0}" -gt 0 ] || {
    echo "the recomputation read no file under a helpers/, lib/ or fixtures/ subtree" >&2
    return 1
  }
  [ "${conc:-0}" -gt 0 ] || {
    echo "the recomputation read no file under the concurrency seam" >&2
    return 1
  }
}

# assert_arming_rows_nonempty <table> <label>: <table> has a row, and every row
# arms at least one leg. A per-page claim over an empty row is true and means
# nothing, and every row arms at least the leg holding this suite.
assert_arming_rows_nonempty() {
  local table="$1" label="$2" line legs n=0 bad=''
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    legs=''
    case "$line" in
      *'|'*) legs="${line#*|}" ;;
    esac
    [ -n "${legs// /}" ] || bad="$bad ${line%%|*};"
  done <<EOF
$table
EOF
  [ "$n" -gt 0 ] || {
    echo "$label has no row at all" >&2
    return 1
  }
  [ -z "$bad" ] || {
    echo "$label arms no leg for:$bad" >&2
    return 1
  }
}

compare_arming_tables_py() {
  python3 - <<'PY'
import os


def parse(text, label, problems):
    rows = {}
    for line in text.split('\n'):
        if not line:
            continue
        if '|' not in line:
            problems.append('%s carries a row with no separator: %r' % (label, line))
            continue
        page, legs = line.split('|', 1)
        if page in rows:
            problems.append('%s carries more than one row for %s' % (label, page))
        rows[page] = set(legs.split())
    return rows


left_label = os.environ['LEFT_LABEL']
right_label = os.environ['RIGHT_LABEL']
problems = []
left = parse(os.environ['LEFT'], left_label, problems)
right = parse(os.environ['RIGHT'], right_label, problems)
for page in sorted(set(left) | set(right)):
    if page not in right:
        problems.append('%s: %s has a row for this page and %s has none' % (page, left_label, right_label))
        continue
    if page not in left:
        problems.append('%s: %s has a row for this page and %s has none' % (page, right_label, left_label))
        continue
    for leg in sorted(left[page] - right[page]):
        problems.append('%s: %s arms %s, which %s does not' % (page, left_label, leg, right_label))
    for leg in sorted(right[page] - left[page]):
        problems.append('%s: %s arms %s, which %s does not' % (page, right_label, leg, left_label))
print('\n'.join(problems))
PY
}

# compare_arming_tables <left> <right> <left-label> <right-label> [repair]
#
# Exact equality of two `<page>|<armed legs>` tables, per page and in both
# directions: a leg one side arms and the other does not reds from either side,
# and so does a page only one side has a row for. On a disagreement it names
# each page and leg, then prints <right> verbatim, so where <right> is the
# side that is right the repair is a copy.
compare_arming_tables() {
  local left="$1" right="$2" left_label="$3" right_label="$4" repair="${5:-}" problems rc=0
  problems="$(LEFT="$left" RIGHT="$right" LEFT_LABEL="$left_label" \
    RIGHT_LABEL="$right_label" compare_arming_tables_py)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "compare_arming_tables: the comparison itself failed (exit $rc)" >&2
    return 1
  fi
  [ -n "$problems" ] || return 0
  printf '%s and %s disagree:\n%s\n' "$left_label" "$right_label" "$problems" >&2
  printf '%s, verbatim:\n%s\n' "$right_label" "$right" >&2
  if [ -n "$repair" ]; then
    printf '%s\n' "$repair" >&2
  fi
  return 1
}

# arming_json_list <path>...: a JSON array of the arguments, the shape the
# paths-filter step exposes, built by an encoder rather than by hand so a path
# carrying a quote, a backslash or a newline arrives exactly as written.
arming_json_list() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@"
}

# arming_answer <script> <sharder> <root> <leg> <changed-json> <pr-changed-files> [event]
#
# One run of the arming script, stdout only, on the pull-request lane unless
# [event] says otherwise. Every input the contract names is set explicitly: a
# CI runner exports GITHUB_EVENT_NAME for its own event, and inheriting it
# would put every answer on whichever lane the job happened to run on.
arming_answer() {
  GITHUB_EVENT_NAME="${7:-pull_request}" CHANGED_FILES_JSON="$5" \
    PR_CHANGED_FILES="$6" LEG_ID="$4" LEG_ARMING_ROOT="$3" \
    LEG_ARMING_SHARDER="$2" bash "$1" </dev/null 2>/dev/null
}

# arming_answer_into <dest> <arming_answer args>...: arming_answer, with its
# stdout in <dest>.out and its exit status in <dest>.rc.
arming_answer_into() {
  local dest="$1" rc=0
  shift
  arming_answer "$@" >"$dest.out" || rc=$?
  printf '%s\n' "$rc" >"$dest.rc"
}

# arming_script_row <script> <sharder> <root> <page> <legs>
#
# The script's own answer for <page> alone on every leg in <legs>, as one
# `<page>|<legs answering true>` row. The legs run concurrently: each run
# lists every shard, and a page-by-leg sweep run in series is most of this
# suite's wall clock. An answer that is not exactly one `true` or `false` line,
# or a non-zero exit, fails the row rather than reading as either.
arming_script_row() {
  local script="$1" sharder="$2" root="$3" page="$4" legs="$5" json dir leg i=0 k rc out row=''
  json="$(arming_json_list "$page")" || return 1
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/arming-row.XXXXXX")"
  while IFS= read -r leg || [ -n "$leg" ]; do
    [ -n "$leg" ] || continue
    printf '%s\n' "$leg" >"$dir/$i.leg"
    arming_answer_into "$dir/$i" "$script" "$sharder" "$root" "$leg" "$json" '' &
    i=$((i + 1))
  done <<EOF
$legs
EOF
  wait
  [ "$i" -gt 0 ] || {
    echo "arming_script_row: no leg to ask about $page" >&2
    return 1
  }
  k=0
  while [ "$k" -lt "$i" ]; do
    leg="$(cat "$dir/$k.leg")"
    [ -f "$dir/$k.rc" ] || {
      echo "arming_script_row: the run for $page on $leg recorded no exit status" >&2
      return 1
    }
    rc="$(cat "$dir/$k.rc")"
    out="$(cat "$dir/$k.out")"
    if [ "$rc" != 0 ] || [ "$(grep -c '' "$dir/$k.out")" -ne 1 ]; then
      echo "arming_script_row: $page on $leg exited $rc printing '$out', expected exit 0 and one line" >&2
      return 1
    fi
    case "$out" in
      true) row="$row $leg" ;;
      false) ;;
      *)
        echo "arming_script_row: $page on $leg printed '$out', neither literal" >&2
        return 1
        ;;
    esac
    k=$((k + 1))
  done
  printf '%s|%s\n' "$page" "${row# }"
}

# arming_script_table <script> <sharder> <root> <pages> <legs>: one
# arming_script_row per page, in <pages>' order.
arming_script_table() {
  local script="$1" sharder="$2" root="$3" pages="$4" legs="$5" page row rows=''
  while IFS= read -r page || [ -n "$page" ]; do
    [ -n "$page" ] || continue
    row="$(arming_script_row "$script" "$sharder" "$root" "$page" "$legs")" || return 1
    rows="$rows$row
"
  done <<EOF
$pages
EOF
  printf '%s' "$rows"
}

# memo_sharder <sharder> <dir>
#
# A stand-in for <sharder> answering `shards`, and `files` and `group` for each
# id, from the real sharder's output captured once, and handing any other call
# to the real sharder. It reaches the arming script through the script's own
# LEG_ARMING_SHARDER seam. A run's cost is almost all shard listing, and the
# sharder is a pure function of the tree, so the captured answer is the answer
# each run would get and nothing the script decides is substituted. Prints the
# stand-in's path.
memo_sharder() {
  local sharder="$1" dir="$2" ids id cmd out rc=0
  mkdir -p "$dir"
  ids="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ids" ]; then
    echo "memo_sharder: the sharder listed no shard id (exit $rc)" >&2
    return 1
  fi
  printf '%s\n' "$ids" >"$dir/shards"
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    for cmd in files group; do
      rc=0
      out="$(bash "$sharder" "$cmd" "$id")" || rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        echo "memo_sharder: the sharder gave no answer to $cmd $id (exit $rc)" >&2
        return 1
      fi
      printf '%s\n' "$out" >"$dir/$cmd.$id"
    done
  done <<EOF
$ids
EOF
  {
    printf '#!/usr/bin/env bash\n'
    printf 'memo=%q\n' "$dir"
    printf 'real=%q\n' "$sharder"
    cat <<'WRAP'
answer=''
case "${1:-}" in
  shards) [ "$#" -eq 1 ] && answer="$memo/shards" ;;
  files | group) [ "$#" -eq 2 ] && answer="$memo/$1.$2" ;;
esac
if [ -n "$answer" ] && [ -f "$answer" ]; then
  cat "$answer"
  exit 0
fi
exec bash "$real" "$@"
WRAP
  } >"$dir/sharder.sh"
  printf '%s\n' "$dir/sharder.sh"
}

# seed_arming_tree <sharder> <root> <workflow>
#
# A tree the arming script can place every leg in, driven through the sharder's
# seams by arming_tree_run. The script arms any leg it cannot place, so without
# each piece no answer in the tree could be `false`: a stand-in for this suite
# at the path rule 5 looks for, listed through the lib seam; a concurrency seam
# holding a suite; local-janitor.bats, which hooks-1 pins by name; and as many
# plain suites in each weighted directory as the sharder has shards, the count
# seed_seam_tree derives for the same reason. <workflow> is copied to the path
# the script's workflow seam defaults to.
seed_arming_tree() {
  local sharder="$1" root="$2" workflow="$3" n i d
  n="$(bash "$sharder" shards | grep -c .)"
  for d in hooks scripts audit forensics statusline .gaia/tests/lib .gaia/tests/concurrency .github/workflows; do
    mkdir -p "$root/$d"
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '#!/usr/bin/env bats\n' >"$root/hooks/plain-$i.bats"
    printf '#!/usr/bin/env bats\n' >"$root/scripts/plain-$i.bats"
    i=$((i + 1))
  done
  for d in hooks/local-janitor audit/plain forensics/plain statusline/plain \
    .gaia/tests/lib/audit-ci-shards .gaia/tests/concurrency/plain; do
    printf '#!/usr/bin/env bats\n' >"$root/$d.bats"
  done
  cp "$workflow" "$root/.github/workflows/audit-ci-tests.yml"
}

# arming_tree_run <root> <command>...: <command> with every sharder directory
# seam pointed into a tree seed_arming_tree built. The arming script's own
# seams need nothing here: each defaults to a path under LEG_ARMING_ROOT.
arming_tree_run() {
  local root="$1"
  shift
  HOOKS_DIR="$root/hooks" SCRIPTS_TESTS_DIR="$root/scripts" \
    AUDIT_TESTS_DIR="$root/audit" LIB_DIR="$root/.gaia/tests/lib" \
    FORENSICS_DIR="$root/forensics" STATUSLINE_DIR="$root/statusline" \
    "$@"
}

# arming_shard_of <sharder> <root> <file>: the shard whose listing holds
# <file>, each listed path absolutized against <root>.
arming_shard_of() {
  local sharder="$1" root="$2" file="$3" ids id listing f abs rc=0
  ids="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ids" ]; then
    echo "arming_shard_of: the sharder listed no shard id (exit $rc)" >&2
    return 1
  fi
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    rc=0
    listing="$(bash "$sharder" files "$id")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "arming_shard_of: the sharder could not list shard $id (exit $rc)" >&2
      return 1
    fi
    while IFS= read -r f || [ -n "$f" ]; do
      case "$f" in
        /*) abs="$f" ;;
        *) abs="$root/$f" ;;
      esac
      if [ "$abs" = "$file" ]; then
        printf '%s\n' "$id"
        return 0
      fi
    done <<EOF
$listing
EOF
  done <<EOF
$ids
EOF
  echo "arming_shard_of: no shard lists $file" >&2
  return 1
}

# arming_tree_expected_row <sharder> <root> <page> <suite>...
#
# The row the arming script owes <page> in a seeded tree whose namers of it
# sit in or beside <suite>...: the exchange groups of the shards holding them,
# plus the group holding the stand-in for this suite, which rule 5 arms
# unconditionally. A mention under a helpers/ or fixtures/ subtree is passed
# as a suite in that directory, which is the attribution the script gives it.
arming_tree_expected_row() {
  local sharder="$1" root="$2" page="$3" f id group legs='' rc
  shift 3
  for f in "$root/.gaia/tests/lib/audit-ci-shards.bats" "$@"; do
    id="$(arming_shard_of "$sharder" "$root" "$f")" || return 1
    rc=0
    group="$(bash "$sharder" group "$id")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$group" ]; then
      echo "arming_tree_expected_row: the sharder resolved no group for $id (exit $rc)" >&2
      return 1
    fi
    legs="$legs$group
"
  done
  printf '%s|%s\n' "$page" "$(printf '%s' "$legs" | awk 'NF' | LC_ALL=C sort -u | paste -sd' ' -)"
}

# write_namer <file> <path>...: a plain suite naming each <path> on a comment
# line of its own.
write_namer() {
  local file="$1" path
  shift
  printf '#!/usr/bin/env bats\n' >"$file"
  for path in "$@"; do
    printf '# reads %s\n' "$path" >>"$file"
  done
}

# drop_wiki_code_entries <workflow> <out> [keep]
#
# Writes a copy of <workflow> with every quoted `code:`-list entry whose value
# begins `wiki/` removed, bare or keyed on a change type, except the one whose
# value is exactly [keep].
drop_wiki_code_entries() {
  KEEP="${3:-}" python3 - "$1" "$2" <<'PY'
import os
import re
import sys

src, out = sys.argv[1], sys.argv[2]
keep = os.environ['KEEP']
entry = re.compile(r'^\s*- (?:[A-Za-z|]+: )?[\x27](wiki/[^\x27]*)[\x27]\s*$')
kept = []
with open(src, encoding='utf-8') as handle:
    for line in handle.read().split('\n'):
        found = entry.match(line)
        if found and found.group(1) != keep:
            continue
        kept.append(line)
with open(out, 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(kept))
PY
}

# code_entry_line <workflow> <path>: the one line of <workflow> reading
# exactly `- '<path>'` after its indent. Fails unless exactly one does.
code_entry_line() {
  awk -v want="- '$2'" '
    { s = $0; sub(/^ +/, "", s) }
    s == want { print; n++ }
    END { exit n == 1 ? 0 : 1 }
  ' "$1" || {
    echo "code_entry_line: $1 does not carry exactly one \`- '$2'\` line" >&2
    return 1
  }
}

# arming_declining_pair <table> <legs>: the first page of <table> and the first
# leg of <legs> its row does not arm, as `<page>|<leg>`. A lane that must show
# a `false` beside its `true` picks its input here rather than naming one.
arming_declining_pair() {
  local table="$1" legs="$2" line armed leg
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    armed=" ${line#*|} "
    while IFS= read -r leg || [ -n "$leg" ]; do
      [ -n "$leg" ] || continue
      case "$armed" in
        *" $leg "*) ;;
        *)
          printf '%s|%s\n' "${line%%|*}" "$leg"
          return 0
          ;;
      esac
    done <<EOF
$legs
EOF
  done <<EOF
$table
EOF
  echo "arming_declining_pair: every page arms every leg, so no lane can show a false" >&2
  return 1
}

# arming_baseline_false <script> <sharder> <root> <changed-json> <leg>: the
# healthy answer for <changed-json> on <leg> is `false`, exit 0. Each arm that
# shows the script arming on a condition calls this first on the same input
# without that condition, so the arm could not pass against a script that arms
# everything.
arming_baseline_false() {
  local out rc=0
  out="$(arming_answer "$1" "$2" "$3" "$5" "$4" '')" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = false ] && return 0
  echo "the healthy baseline on leg $5 answered '$out' (exit $rc), expected false, so this arm could not tell arming from narrowing" >&2
  return 1
}

# W16 (SPEC-078 lever two; discharges UAT-009 and UAT-019, and holds UAT-011).
# The arming script narrows a pull request that touches only the `wiki/` pages
# the `code:` filter names to the legs holding a file that names one of them.
# Nothing else stops a suite from starting to name such a page on a leg the gate
# does not arm, which is exactly the silent green the narrowing exists to risk,
# so this pins the map three ways: the declared table in w16_declared_table, a
# recomputation from the tree (arming_recompute), and the script's own answer
# for each page alone on every leg (arming_script_table). Each is compared with
# the declared table as exact set equality in both directions: an unarmed leg
# holding a namer reds, and so does a gratuitously armed one.
#
# The declared table is the one checked-in list the design permits, the W10
# shape: a list a both-ways equality check recomputes and compares. It is not
# redundant with the other two sides, and the reason is what this check can and
# cannot see. A mention added to a suite in a temp tree is seen identically by
# the recomputation and by the script, so a tree doctoring can never red those
# two against each other. The declared table does not move with the tree, which
# is why the adversarial cases below doctor the table and the script rather than
# the tree.
#
# WHAT THIS DOES NOT CATCH. If the script, the recomputation and the declared
# table all implement the same wrong rule, all three agree. The table was
# written from the script's measured answers, so it inherits the script's answer
# on the day it was written: its value is regression detection, not initial
# correctness. Initial correctness rests on the script's driven observations and
# on a verification pass that drives each guard here into its failing state.
#
# The class comparison is the one genuinely two-implementation check: the
# script's awk reader against PyYAML, reading the same workflow. It is also what
# makes a new `wiki/` entry in `code:` a visible event: the class grows, the
# class comparison still holds, and the table comparisons red until the new
# page gets a row.
#
# The script's answers are gathered through memo_sharder, whose header carries
# why that substitutes nothing the script decides. The recomputation, the
# pagination lane and the degraded-input lanes below run the real sharder.

# w16_declared_table
#
# W16's declared side: one `<page>|<armed legs>` row per narrowable page, legs
# LC_ALL=C sorted, the format compare_arming_tables prints a disagreeing table
# in, so a repair is a copy of that table.
w16_declared_table() {
  cat <<'TABLE'
wiki/.state.json|concurrency hooks-1 hooks-2 hooks-3 hooks-4 lib misc scripts-1 scripts-2 scripts-3
wiki/concepts/Audit Disposition and Debt Fix.md|lib scripts-1 scripts-2 scripts-3
wiki/concepts/Claude Hooks.md|lib scripts-1 scripts-2 scripts-3
wiki/concepts/Code Review Audit Agent.md|lib
wiki/concepts/GAIA Audit.md|lib
wiki/concepts/PR Merge Workflow.md|hooks-2 hooks-3 hooks-4 lib misc scripts-1 scripts-2 scripts-3
wiki/concepts/Policy-Memory Loop.md|lib
wiki/concepts/Task Orchestration.md|lib scripts-1 scripts-2 scripts-3
TABLE
}

W16_REPAIR='Repair: if the change that moved it is intended, copy that table into w16_declared_table in .gaia/tests/lib/audit-ci-shards.bats; otherwise a suite now names a page on a leg the gate does not arm, or the gate arms a leg holding no namer.'

# assert_arming_class <script> <workflow>
#
# The arming script's awk reader and PyYAML read the same narrowable class from
# <workflow>, as sorted sets; the class is non-empty; and it is as large as the
# number of `code:` entries whose value begins `wiki/`, counted from the parsed
# entries rather than written down.
assert_arming_class() {
  local script="$1" workflow="$2" parsed entries declared held awk_class err rc=0
  parsed="$(arming_parser_class "$workflow")" || return 1
  [ -n "$parsed" ] || {
    echo "the code: filter in $workflow names no wiki/ entry, so the narrowable class is empty and W16 would compare nothing" >&2
    return 1
  }
  entries="$(read_wf codefilterentries "$workflow" shards)" || {
    echo "could not read the code: filter's entries from $workflow" >&2
    return 1
  }
  declared="$(printf '%s\n' "$entries" | awk -F'\t' 'index($2, "wiki/") == 1 { n++ } END { print n + 0 }')"
  held="$(printf '%s\n' "$parsed" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$held" -eq "$declared" ] || {
    echo "the code: filter in $workflow declares $declared wiki/ entries and the class holds $held pages" >&2
    return 1
  }
  err="$BATS_TEST_TMPDIR/arming-class.err"
  awk_class="$(LEG_ARMING_WORKFLOW="$workflow" bash "$script" class 2>"$err")" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the arming script could not derive the class from $workflow (exit $rc), which PyYAML reads as:" >&2
    printf '%s\n' "$parsed" >&2
    cat "$err" >&2
    return 1
  }
  [ "$awk_class" = "$parsed" ] || {
    echo "the arming script's awk reader and PyYAML read different classes from $workflow" >&2
    printf 'awk:\n%s\nPyYAML:\n%s\n' "$awk_class" "$parsed" >&2
    return 1
  }
}

# assert_sharder_ids_in_legs <sharder> <legs>: every id the sharder names is an
# arming leg. W6 pins the matrix against the sharder from the other side; this
# is the half W16's leg set depends on, since a sharder id outside it would be
# a leg nothing here asks about.
assert_sharder_ids_in_legs() {
  local sharder="$1" legs="$2" ids id missing='' rc=0
  ids="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ids" ]; then
    echo "assert_sharder_ids_in_legs: the sharder listed no shard id (exit $rc)" >&2
    return 1
  fi
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    grep -qxF -- "$id" <<<"$legs" || missing="$missing $id"
  done <<EOF
$ids
EOF
  [ -z "$missing" ] || {
    echo "sharder ids missing from the arming leg set:$missing" >&2
    return 1
  }
}

# assert_undiscovered <sharder> <root> <dir>: no shard lists a path under
# <dir>, which must exist and hold a file, so an absent directory cannot pass
# for an undiscovered one.
assert_undiscovered() {
  local sharder="$1" root="$2" dir="$3" ids id listing f abs found='' rc=0
  [ -d "$dir" ] && [ -n "$(find "$dir" -type f | head -n 1)" ] || {
    echo "$dir is absent or holds no file, so its being undiscovered proves nothing" >&2
    return 1
  }
  ids="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ids" ]; then
    echo "assert_undiscovered: the sharder listed no shard id (exit $rc)" >&2
    return 1
  fi
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    rc=0
    listing="$(bash "$sharder" files "$id")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "assert_undiscovered: the sharder could not list shard $id (exit $rc)" >&2
      return 1
    fi
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      case "$f" in
        /*) abs="$f" ;;
        *) abs="$root/$f" ;;
      esac
      case "$abs" in
        "$dir"/*) found="$found $id:$abs" ;;
      esac
    done <<EOF
$listing
EOF
  done <<EOF
$ids
EOF
  [ -z "$found" ] || {
    echo "the sharder discovers a suite under $dir, where a committed fixture would run as a real suite:$found" >&2
    return 1
  }
}

@test "W16: the arming leg set is the matrix minus sandbox and holds every sharder id" {
  require_yaml_parser
  local legs
  legs="$(arming_legs "$WORKFLOW")" || return 1
  grep -qx sandbox <<<"$legs" && {
    echo "the arming leg set carries sandbox, whose steps never reach the arming script" >&2
    return 1
  }
  assert_sharder_ids_in_legs "$BATS_SHARDS" "$legs"
}

@test "W16 adversarial: a sharder id missing from the arming leg set is caught" {
  require_yaml_parser
  local legs first doctored
  legs="$(arming_legs "$WORKFLOW")" || return 1
  first="$(bash "$BATS_SHARDS" shards | sed -n 1p)"
  doctored="$(printf '%s\n' "$legs" | grep -vxF -- "$first")"
  assert_doctored "$legs" "$doctored" "dropping the sharder's first id from the leg set" || return 1
  run assert_sharder_ids_in_legs "$BATS_SHARDS" "$doctored"
  [ "$status" -ne 0 ] || {
    echo "a leg set missing $first was accepted" >&2
    return 1
  }
  grep -qF -- " $first" <<<"$output"
}

@test "W16: the declared armed-leg table equals the tree's recomputation" {
  require_yaml_parser
  local conc_leg recomputed stats="$BATS_TEST_TMPDIR/w16-scan-counts"
  conc_leg="$(arming_concurrency_leg "$BATS_SHARDS" "$WORKFLOW")" || return 1
  recomputed="$(arming_recompute "$BATS_SHARDS" "$REPO_ROOT" "$WORKFLOW" \
    "$ARMING_CONCURRENCY_DIR" "$conc_leg" "$stats")" || return 1
  assert_arming_input_complete "$stats" "$BATS_SHARDS" || return 1
  assert_arming_rows_nonempty "$(w16_declared_table)" 'the declared table' || return 1
  assert_arming_rows_nonempty "$recomputed" "the tree's recomputation" || return 1
  compare_arming_tables "$(w16_declared_table)" "$recomputed" \
    'the declared table' "the tree's recomputation" "$W16_REPAIR"
}

@test "W16: the declared armed-leg table equals the arming script's answers" {
  require_yaml_parser
  local pages legs memo answered
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  legs="$(arming_legs "$WORKFLOW")" || return 1
  memo="$(memo_sharder "$BATS_SHARDS" "$BATS_TEST_TMPDIR/memo")" || return 1
  answered="$(arming_script_table "$ARMING_SCRIPT" "$memo" "$REPO_ROOT" "$pages" "$legs")" || return 1
  assert_arming_rows_nonempty "$answered" "the arming script's answers" || return 1
  compare_arming_tables "$(w16_declared_table)" "$answered" \
    'the declared table' "the arming script's answers" "$W16_REPAIR"
}

@test "W16: the arming script's class equals the wiki/ entries PyYAML reads from the code: filter" {
  require_yaml_parser
  assert_arming_class "$ARMING_SCRIPT" "$WORKFLOW"
}

@test "W16: the committed fixture directory holds no path the sharder discovers" {
  assert_undiscovered "$BATS_SHARDS" "$REPO_ROOT" "$REPO_ROOT/.gaia/tests/lib/fixtures"
}

@test "W16 adversarial: the undiscovered-fixture check reds on a directory the sharder does discover" {
  run assert_undiscovered "$BATS_SHARDS" "$REPO_ROOT" "$REPO_ROOT/.gaia/tests/lib"
  [ "$status" -ne 0 ] || {
    echo "the lib suite directory passed as undiscovered" >&2
    return 1
  }
  grep -qF -- "lib:$REPO_ROOT/.gaia/tests/lib/" <<<"$output"
}

@test "W16 adversarial: a leg removed from one declared row reds against the recomputation, naming the page and the leg" {
  require_yaml_parser
  local declared recomputed conc_leg row page legs leg doctored recomputed_row
  declared="$(w16_declared_table)"
  conc_leg="$(arming_concurrency_leg "$BATS_SHARDS" "$WORKFLOW")" || return 1
  recomputed="$(arming_recompute "$BATS_SHARDS" "$REPO_ROOT" "$WORKFLOW" \
    "$ARMING_CONCURRENCY_DIR" "$conc_leg")" || return 1
  # Sampled on purpose: one row proves the comparison can red, and W16's own
  # test covers every row. A row with more than one leg, so the doctored row is
  # still non-empty and the red comes from the comparison, not from emptiness.
  row="$(printf '%s\n' "$declared" | awk -F'|' 'split($2, legs, " ") > 1 { print; exit }')"
  [ -n "$row" ] || {
    echo "no declared row arms more than one leg, so no leg can be removed from one" >&2
    return 1
  }
  page="${row%%|*}"
  legs="${row#*|}"
  leg="${legs%% *}"
  doctored="$(printf '%s\n' "$declared" | awk -F'|' -v page="$page" -v row="$page|${legs#"$leg" }" \
    '$1 == page { print row; next } { print }')"
  assert_doctored "$declared" "$doctored" "removing $leg from the row for $page" || return 1

  run compare_arming_tables "$doctored" "$recomputed" 'the declared table' "the tree's recomputation" "$W16_REPAIR"
  [ "$status" -ne 0 ] || {
    echo "removing $leg from the declared row for $page was not caught" >&2
    return 1
  }
  grep -qF -- "$page: the tree's recomputation arms $leg, which the declared table does not" <<<"$output" || {
    echo "the refusal did not name $page and $leg" >&2
    return 1
  }
  # The repair is a copy: the recomputed row for the page is printed verbatim.
  recomputed_row="$(printf '%s\n' "$recomputed" | awk -F'|' -v page="$page" '$1 == page')"
  grep -qxF -- "$recomputed_row" <<<"$output" || {
    echo "the refusal did not print the recomputed table verbatim" >&2
    return 1
  }
}

@test "W16 adversarial: a script doctored to arm a group holding no namer reds against the declared table, naming its legs" {
  require_yaml_parser
  local declared ids row id group g hit pick='' page shard armed legs memo line mutated
  local doctored="$BATS_TEST_TMPDIR/leg-arming.sh" answered declared_row
  declared="$(w16_declared_table)"
  ids="$(bash "$BATS_SHARDS" shards)" || return 1
  # The first page and shard whose exchange group the page's row does not touch
  # at all, so every leg of that group is a leg the doctored script arms
  # gratuitously. Sampled on purpose, like the case above.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    armed=" ${row#*|} "
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      group="$(bash "$BATS_SHARDS" group "$id")" || return 1
      hit=''
      while IFS= read -r g; do
        case "$armed" in
          *" $g "*) hit=yes ;;
        esac
      done <<<"$group"
      if [ -z "$hit" ]; then
        pick="${row%%|*}|$id"
        break 2
      fi
    done <<<"$ids"
  done <<<"$declared"
  [ -n "$pick" ] || {
    echo "every declared row touches every exchange group, so no group can be armed gratuitously" >&2
    return 1
  }
  page="${pick%%|*}"
  shard="${pick#*|}"
  group="$(bash "$BATS_SHARDS" group "$shard")" || return 1

  # Every namer the scan finds contributes its unit's shards; the doctored copy
  # adds <shard> to every contribution, arming its whole group for any page
  # with a namer.
  line="$(sole_line_matching "$ARMING_SCRIPT" 'contrib\+=\("\$id"\)$')" || return 1
  mutated="${line%?} '$shard')"
  assert_doctored "$line" "$mutated" "adding $shard to every namer's contribution" || return 1
  replace_line "$ARMING_SCRIPT" "$line" "$mutated" "$doctored"

  legs="$(arming_legs "$WORKFLOW")" || return 1
  memo="$(memo_sharder "$BATS_SHARDS" "$BATS_TEST_TMPDIR/memo")" || return 1
  answered="$(arming_script_row "$doctored" "$memo" "$REPO_ROOT" "$page" "$legs")" || return 1
  declared_row="$(printf '%s\n' "$declared" | awk -F'|' -v page="$page" '$1 == page')"
  run compare_arming_tables "$declared_row" "$answered" 'the declared table' "the doctored script's answers"
  [ "$status" -ne 0 ] || {
    echo "a script arming $shard's group for $page was not caught" >&2
    return 1
  }
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    grep -qF -- "$page: the doctored script's answers arms $g, which the declared table does not" <<<"$output" || {
      echo "the refusal did not name $g, a leg of the gratuitously armed group" >&2
      return 1
    }
  done <<<"$group"
}

# The workflow shapes adversarial cases use for the class comparison are ones
# PyYAML reads and the awk reader refuses, confirmed inside each case before the
# comparison is asked about: a double-quoted scalar carrying an escape the awk
# reader does not decode; and a plain scalar folded onto a continuation line
# that opens with `- `, which PyYAML folds into one path and a reader taking
# every `- ` line as an entry would split into two. A plain double-quoted
# scalar with no escape reads identically in both, so it could not red. An
# entry shifted shallower than the list's entry indent is refused too, and
# PyYAML rejects that workflow outright rather than reading it.
#
# The comparison's own disagreement branch is driven by a doctored script
# rather than a doctored workflow: a shape both readers accept and read
# differently is exactly what the awk reader exists to refuse, so a healthy
# reader offers none.
@test "W16 adversarial: an escaped double-quoted code: entry reds the class comparison" {
  require_yaml_parser
  local pages page line mutated doctored="$BATS_TEST_TMPDIR/class-escape.yml"
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | grep -F ' ' | sed -n 1p)"
  [ -n "$page" ] || {
    echo "no narrowable page carries a space for the escape to stand in for" >&2
    return 1
  }
  line="$(code_entry_line "$WORKFLOW" "$page")" || return 1
  mutated="${line%%-*}- \"${page/ /\\x20}\""
  assert_doctored "$line" "$mutated" "rewriting the entry for $page as an escaped double-quoted scalar" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  # Confirm the divergence before relying on it: PyYAML still reads the page.
  arming_parser_class "$doctored" | grep -qxF -- "$page" || {
    echo "PyYAML did not decode the escaped entry back to $page, so the readers do not diverge here" >&2
    return 1
  }
  run assert_arming_class "$ARMING_SCRIPT" "$doctored"
  [ "$status" -ne 0 ] || {
    echo "an entry the awk reader refuses and PyYAML reads was not caught" >&2
    return 1
  }
  grep -qF -- 'could not derive the class' <<<"$output"
}

@test "W16 adversarial: a folded plain code: entry is refused by the awk reader rather than split into two entries" {
  require_yaml_parser
  local pages page head tail indent line doctored="$BATS_TEST_TMPDIR/class-fold.yml"
  local err="$BATS_TEST_TMPDIR/class-fold.err" rc=0
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | grep -F ' ' | sed -n 1p)"
  [ -n "$page" ] || {
    echo "no narrowable page carries a space to fold the entry at" >&2
    return 1
  }
  head="${page%% *}"
  tail="${page#* }"
  line="$(code_entry_line "$WORKFLOW" "$page")" || return 1
  indent="${line%%-*}"
  replace_line "$WORKFLOW" "$line" "$indent- $head
$indent  - $tail" "$doctored"
  cmp -s "$WORKFLOW" "$doctored" && {
    echo "folding the entry for $page changed nothing" >&2
    return 1
  }

  # Confirm the premise before relying on it: PyYAML reads one folded path.
  arming_parser_class "$doctored" | grep -qxF -- "$head - $tail" || {
    echo "PyYAML did not fold the entry into '$head - $tail'" >&2
    return 1
  }
  LEG_ARMING_WORKFLOW="$doctored" bash "$ARMING_SCRIPT" class >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the awk reader accepted an entry PyYAML folds into '$head - $tail'" >&2
    return 1
  }
  grep -qF -- 'multi-line entry' "$err" || {
    echo "the awk reader refused the folded entry for another reason:" >&2
    cat "$err" >&2
    return 1
  }

  run assert_arming_class "$ARMING_SCRIPT" "$doctored"
  [ "$status" -ne 0 ] || {
    echo "a folded entry the awk reader refuses was not caught" >&2
    return 1
  }
  grep -qF -- 'could not derive the class' <<<"$output"
}

@test "W16 adversarial: a code: entry shifted shallower than the list's entry indent is refused by the awk reader" {
  require_yaml_parser
  local pages page line mutated doctored="$BATS_TEST_TMPDIR/class-shallow.yml"
  local err="$BATS_TEST_TMPDIR/class-shallow.err" rc=0
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  # code_entry_line finds only a bare quoted entry, never a change-type
  # mapping; the space-carrying pages the cases above pick are written bare.
  page="$(printf '%s\n' "$pages" | grep -F ' ' | sed -n 1p)"
  line="$(code_entry_line "$WORKFLOW" "$page")" || return 1
  mutated="${line# }"
  assert_doctored "$line" "$mutated" "shifting the entry for $page one column shallower" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  # Confirm the premise before relying on it: PyYAML reads no entry here.
  arming_parser_class "$doctored" >/dev/null 2>&1 && {
    echo "PyYAML read the shifted entry for $page, so refusing it would be a divergence" >&2
    return 1
  }
  LEG_ARMING_WORKFLOW="$doctored" bash "$ARMING_SCRIPT" class >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the awk reader accepted an entry shifted off the list's entry indent" >&2
    return 1
  }
  grep -qF -- 'off the entry indent' "$err" || {
    echo "the awk reader refused the shifted entry for another reason:" >&2
    cat "$err" >&2
    return 1
  }
}

@test "W16 adversarial: an arming script reading a different class than PyYAML reds the class comparison" {
  require_yaml_parser
  local line mutated doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  line="$(sole_line_matching "$ARMING_SCRIPT" 'index\(v, "wiki/"\) == 1\) print v$')" || return 1
  mutated="$line \"-doctored\""
  assert_doctored "$line" "$mutated" "suffixing every page the awk reader prints" || return 1
  replace_line "$ARMING_SCRIPT" "$line" "$mutated" "$doctored"

  # The copy sits outside any checkout, so it cannot derive its root itself.
  export LEG_ARMING_ROOT="$REPO_ROOT"
  run assert_arming_class "$doctored" "$WORKFLOW"
  [ "$status" -ne 0 ] || {
    echo "a script reading a class PyYAML does not was not caught" >&2
    return 1
  }
  grep -qF -- 'read different classes' <<<"$output"
}

@test "W16 non-vacuity: an empty narrowable class is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/class-empty.yml"
  drop_wiki_code_entries "$WORKFLOW" "$doctored"
  cmp -s "$WORKFLOW" "$doctored" && {
    echo "dropping the wiki/ code: entries changed nothing" >&2
    return 1
  }
  run assert_arming_class "$ARMING_SCRIPT" "$doctored"
  [ "$status" -ne 0 ] || {
    echo "an empty narrowable class was accepted" >&2
    return 1
  }
  grep -qF -- 'the narrowable class is empty' <<<"$output"
}

@test "W16 non-vacuity: a class shorter than the wiki/ entries the code: filter declares is caught" {
  require_yaml_parser
  local pages page line doctored="$BATS_TEST_TMPDIR/class-short.yml"
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | grep -F ' ' | sed -n 1p)"
  line="$(code_entry_line "$WORKFLOW" "$page")" || return 1
  # A duplicated entry: both readers deduplicate, so the class stays the same
  # size while the declared entries grow by one.
  insert_after "$WORKFLOW" "$line" "$line" "$doctored"
  run assert_arming_class "$ARMING_SCRIPT" "$doctored"
  [ "$status" -ne 0 ] || {
    echo "a class shorter than its declared entries was accepted" >&2
    return 1
  }
  grep -qF -- 'wiki/ entries and the class holds' <<<"$output"
}

@test "W16 non-vacuity: a page whose armed set is empty is caught" {
  local declared row doctored
  declared="$(w16_declared_table)"
  row="$(printf '%s\n' "$declared" | sed -n 1p)"
  doctored="$(printf '%s\n' "$declared" | awk -F'|' -v page="${row%%|*}" '$1 == page { print page "|"; next } { print }')"
  assert_doctored "$declared" "$doctored" "emptying the row for ${row%%|*}" || return 1
  run assert_arming_rows_nonempty "$doctored" 'the doctored table'
  [ "$status" -ne 0 ] || {
    echo "an empty armed set was accepted" >&2
    return 1
  }
  grep -qF -- "${row%%|*}" <<<"$output"
}

@test "W16 non-vacuity: a scan reading fewer suites than the sharder lists is caught" {
  require_yaml_parser
  local memo dir id victim before conc_leg stats="$BATS_TEST_TMPDIR/short-counts"
  memo="$(memo_sharder "$BATS_SHARDS" "$BATS_TEST_TMPDIR/memo")" || return 1
  dir="${memo%/*}"
  # A short listing from the stand-in, while the recount reads the real sharder.
  while IFS= read -r id; do
    if [ "$(grep -c . "$dir/files.$id")" -gt 1 ]; then
      victim="$dir/files.$id"
      break
    fi
  done <"$dir/shards"
  [ -n "${victim:-}" ] || {
    echo "no shard lists more than one suite, so none can be shortened" >&2
    return 1
  }
  before="$(cat "$victim")"
  sed '$d' "$victim" >"$victim.short"
  mv "$victim.short" "$victim"
  assert_doctored "$before" "$(cat "$victim")" "dropping the last suite from $victim" || return 1

  conc_leg="$(arming_concurrency_leg "$BATS_SHARDS" "$WORKFLOW")" || return 1
  arming_recompute "$memo" "$REPO_ROOT" "$WORKFLOW" "$ARMING_CONCURRENCY_DIR" "$conc_leg" "$stats" >/dev/null || return 1
  run assert_arming_input_complete "$stats" "$BATS_SHARDS"
  [ "$status" -ne 0 ] || {
    echo "a scan that read one suite fewer than the sharder lists was accepted" >&2
    return 1
  }
  grep -qF -- 'discovered suites, and the sharder lists' <<<"$output"
}

@test "W16 non-vacuity: an empty discovery fails the recomputation rather than reading as no namer" {
  require_yaml_parser
  local conc_leg stub="$BATS_TEST_TMPDIR/empty-sharder.sh" empty="$BATS_TEST_TMPDIR/empty-seam"
  conc_leg="$(arming_concurrency_leg "$BATS_SHARDS" "$WORKFLOW")" || return 1
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stub"
  run arming_recompute "$stub" "$REPO_ROOT" "$WORKFLOW" "$ARMING_CONCURRENCY_DIR" "$conc_leg"
  [ "$status" -ne 0 ] || {
    echo "a sharder listing no shard produced a table" >&2
    return 1
  }
  grep -qF -- 'the sharder listed no shard id' <<<"$output" || return 1

  mkdir -p "$empty"
  run arming_recompute "$BATS_SHARDS" "$REPO_ROOT" "$WORKFLOW" "$empty" "$conc_leg"
  [ "$status" -ne 0 ] || {
    echo "a concurrency seam holding no suite produced a table" >&2
    return 1
  }
  grep -qF -- 'holds no suite' <<<"$output"
}

# UAT-011. The weighted groups reshuffle files among their own legs whenever a
# suite changes size, so a gate keyed on the leg a namer happens to sit on would
# churn with no change to any reader. Every lookup here resolves through the
# sharder's `group` command, so a within-group move must leave both the script's
# answers and the recomputation byte-identical. Built the way the W10 reshuffle
# cases are: grow an unrelated suite beside the namer until the weighted
# assignment moves it, bounded, with a failure to move reported rather than
# skipped.
@test "W16: a within-group reshuffle leaves a page's armed legs byte-identical (UAT-011)" {
  require_yaml_parser
  local root="$BATS_TEST_TMPDIR/arming-reshuffle" legs conc_leg pages page namer
  local held_before held_after group expected c_before c_after b_all b_before b_after i=0 moved=''
  legs="$(arming_legs "$WORKFLOW")" || return 1
  conc_leg="$(arming_concurrency_leg "$BATS_SHARDS" "$WORKFLOW")" || return 1
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | sed -n 1p)"
  seed_arming_tree "$BATS_SHARDS" "$root" "$WORKFLOW"
  namer="$root/hooks/names-page.bats"
  write_namer "$namer" "$page"

  held_before="$(arming_tree_run "$root" arming_shard_of "$BATS_SHARDS" "$root" "$namer")" || return 1
  group="$(bash "$BATS_SHARDS" group "$held_before")" || return 1
  [ "$(printf '%s\n' "$group" | grep -c .)" -gt 1 ] || {
    echo "the namer landed on $held_before, a group of one, so no reshuffle can move it and this case proves nothing" >&2
    return 1
  }
  expected="$(arming_tree_run "$root" arming_tree_expected_row "$BATS_SHARDS" "$root" "$page" "$namer")" || return 1
  c_before="$(arming_tree_run "$root" arming_script_row "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$page" "$legs")" || return 1
  b_all="$(arming_tree_run "$root" arming_recompute "$BATS_SHARDS" "$root" \
    "$root/.github/workflows/audit-ci-tests.yml" "$root/.gaia/tests/concurrency" "$conc_leg")" || return 1
  b_before="$(printf '%s\n' "$b_all" | awk -F'|' -v page="$page" '$1 == page')"
  compare_arming_tables "$expected" "$c_before" "the namer's own group" 'the arming script' || return 1
  [ "$b_before" = "$c_before" ] || {
    printf 'the recomputation and the script disagree before the reshuffle:\n%s\n%s\n' "$b_before" "$c_before" >&2
    return 1
  }

  while [ "$i" -lt 24 ]; do
    printf '# pad %s\n' "$i" >>"$root/hooks/plain-0.bats"
    i=$((i + 1))
    held_after="$(arming_tree_run "$root" arming_shard_of "$BATS_SHARDS" "$root" "$namer")" || return 1
    if [ "$held_after" != "$held_before" ]; then
      moved=yes
      break
    fi
  done
  [ -n "$moved" ] || {
    echo "growing an unrelated suite never moved the namer off $held_before, so this case proved nothing about stability" >&2
    return 1
  }

  c_after="$(arming_tree_run "$root" arming_script_row "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$page" "$legs")" || return 1
  b_all="$(arming_tree_run "$root" arming_recompute "$BATS_SHARDS" "$root" \
    "$root/.github/workflows/audit-ci-tests.yml" "$root/.gaia/tests/concurrency" "$conc_leg")" || return 1
  b_after="$(printf '%s\n' "$b_all" | awk -F'|' -v page="$page" '$1 == page')"
  [ "$c_after" = "$c_before" ] || {
    printf 'the namer moved from %s to %s and the script'"'"'s answers moved with it:\nbefore: %s\nafter:  %s\n' \
      "$held_before" "$held_after" "$c_before" "$c_after" >&2
    return 1
  }
  [ "$b_after" = "$b_before" ] || {
    printf 'the namer moved from %s to %s and the recomputation moved with it:\nbefore: %s\nafter:  %s\n' \
      "$held_before" "$held_after" "$b_before" "$b_after" >&2
    return 1
  }
  # The record the verification pass reads: bats shows it on a failure, or on
  # a pass under --show-output-of-passing-tests.
  printf 'namer moved %s -> %s\nbefore: %s\nafter:  %s\n' "$held_before" "$held_after" "$c_before" "$c_after"
}

# W17 (SPEC-078 lever two; UAT-008, UAT-015, UAT-016, UAT-017, UAT-021,
# UAT-022). The arming script's lanes, driven directly. Every arm asserts the
# exit status as well as the answer: the workflow step reads the printed
# literal, and a non-zero exit there is a failed step rather than an answer, so
# the fallback is worth nothing unless the script exits 0 on every path. An arm
# showing the script arming on some condition first shows it narrowing the same
# input on the same leg without that condition; an arm that only ever observed
# `true` would pass against a script that arms everything.

# assert_dispatch_lane <script> <sharder> <root> <legs> <expected-count>: the
# dispatch lane, with every filter output empty, arms each of <legs> and exits
# 0, over exactly <expected-count> legs and never zero.
assert_dispatch_lane() {
  local script="$1" sharder="$2" root="$3" legs="$4" expected="$5" leg out rc n=0
  while IFS= read -r leg || [ -n "$leg" ]; do
    [ -n "$leg" ] || continue
    rc=0
    out="$(arming_answer "$script" "$sharder" "$root" "$leg" '' '' workflow_dispatch)" || rc=$?
    [ "$rc" -eq 0 ] || {
      echo "the dispatch lane exited $rc on leg $leg, expected 0" >&2
      return 1
    }
    [ "$out" = true ] || {
      echo "the dispatch lane answered '$out' on leg $leg with every filter output empty, expected true" >&2
      return 1
    }
    n=$((n + 1))
  done <<EOF
$legs
EOF
  [ "$n" -gt 0 ] && [ "$n" -eq "$expected" ] || {
    echo "the dispatch lane was driven over $n legs, and the matrix declares $expected" >&2
    return 1
  }
}

# assert_dispatch_overrides <script> <sharder> <root> <changed-json> <leg>
#
# The dispatch arm is a rule of its own, not the empty-list rule answering for
# it. With every filter output empty the two reach the same `true`, so the lane
# above cannot tell them apart: this drives dispatch with a list that narrows
# <leg> on the pull-request lane, and requires the two empty-list lanes to give
# different reasons.
assert_dispatch_overrides() {
  local script="$1" sharder="$2" root="$3" json="$4" leg="$5" out rc=0 dispatch_reason pr_reason
  arming_baseline_false "$script" "$sharder" "$root" "$json" "$leg" || return 1
  out="$(arming_answer "$script" "$sharder" "$root" "$leg" "$json" '' workflow_dispatch)" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = true ] || {
    echo "the dispatch lane answered '$out' (exit $rc) on leg $leg for a list that narrows it, so dispatch is not a rule of its own" >&2
    return 1
  }
  dispatch_reason="$(GITHUB_EVENT_NAME=workflow_dispatch CHANGED_FILES_JSON='' PR_CHANGED_FILES='' \
    LEG_ID="$leg" LEG_ARMING_ROOT="$root" LEG_ARMING_SHARDER="$sharder" bash "$script" 2>&1 >/dev/null </dev/null)"
  pr_reason="$(GITHUB_EVENT_NAME=pull_request CHANGED_FILES_JSON='' PR_CHANGED_FILES='' \
    LEG_ID="$leg" LEG_ARMING_ROOT="$root" LEG_ARMING_SHARDER="$sharder" bash "$script" 2>&1 >/dev/null </dev/null)"
  [ -n "$dispatch_reason" ] && [ "$dispatch_reason" != "$pr_reason" ] || {
    echo "the dispatch lane and the empty-list lane give the same reason, so the two conditions are conflated: $dispatch_reason" >&2
    return 1
  }
}

@test "W17: the dispatch lane arms every leg the matrix declares with every filter output empty (UAT-008)" {
  require_yaml_parser
  local matrix expected
  matrix="$(read_wf matrix "$WORKFLOW" shards)" || return 1
  expected="$(printf '%s\n' "$matrix" | awk 'NF { n++ } END { print n + 0 }')"
  assert_dispatch_lane "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "$matrix" "$expected"
}

@test "W17: the dispatch lane overrides a narrowing list, and its reason differs from the empty-list lane's" {
  require_yaml_parser
  local legs pair json
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  json="$(arming_json_list "${pair%%|*}")" || return 1
  assert_dispatch_overrides "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "$json" "${pair#*|}"
}

@test "W17 adversarial: a script with its dispatch arm doctored out reds the dispatch lane" {
  require_yaml_parser
  local legs pair json line mutated matrix expected doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  line="$(sole_line_matching "$ARMING_SCRIPT" '= workflow_dispatch \]; then$')" || return 1
  mutated="${line%%if*}if false; then"
  assert_doctored "$line" "$mutated" "disabling the dispatch arm" || return 1
  replace_line "$ARMING_SCRIPT" "$line" "$mutated" "$doctored"

  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  json="$(arming_json_list "${pair%%|*}")" || return 1
  run assert_dispatch_overrides "$doctored" "$BATS_SHARDS" "$REPO_ROOT" "$json" "${pair#*|}"
  [ "$status" -ne 0 ] || {
    echo "a script with no dispatch arm passed the dispatch lane" >&2
    return 1
  }
  grep -qF -- 'dispatch is not a rule of its own' <<<"$output" || return 1

  # Non-vacuity: the per-leg lane reds when it is handed no leg at all.
  matrix="$(read_wf matrix "$WORKFLOW" shards)" || return 1
  expected="$(printf '%s\n' "$matrix" | awk 'NF { n++ } END { print n + 0 }')"
  run assert_dispatch_lane "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" '' "$expected"
  [ "$status" -ne 0 ] || {
    echo "the dispatch lane passed over an empty leg set" >&2
    return 1
  }
  grep -qF -- 'driven over 0 legs' <<<"$output"
}

# assert_pagination_lane <script> <sharder> <root> <changed-json> <leg>
#
# The pagination cap in both directions, on a page and leg that narrow to
# `false` with no count. One below the cap is the arm that matters, and it
# carries its own message: a rule that fired there would arm every leg on an
# ordinary pull request, and the narrowing would ship inert with every check
# still green.
assert_pagination_lane() {
  local script="$1" sharder="$2" root="$3" json="$4" leg="$5" out rc
  rc=0
  out="$(arming_answer "$script" "$sharder" "$root" "$leg" "$json" 2999)" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = false ] || {
    echo "PR_CHANGED_FILES=2999, one below the cap, answered '$out' (exit $rc) on leg $leg: the pagination rule fires below the cap, so an ordinary pull request arms every leg and the narrowing is inert" >&2
    return 1
  }
  rc=0
  out="$(arming_answer "$script" "$sharder" "$root" "$leg" "$json" 3000)" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = true ] || {
    echo "PR_CHANGED_FILES=3000, at the cap, answered '$out' (exit $rc) on leg $leg, expected true" >&2
    return 1
  }
  rc=0
  out="$(arming_answer "$script" "$sharder" "$root" "$leg" "$json" abc)" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = false ] || {
    echo "a non-decimal PR_CHANGED_FILES answered '$out' (exit $rc) on leg $leg, expected false" >&2
    return 1
  }
  rc=0
  out="$(arming_answer "$script" "$sharder" "$root" "$leg" "$json" '')" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = false ] || {
    echo "an empty PR_CHANGED_FILES answered '$out' (exit $rc) on leg $leg, expected false" >&2
    return 1
  }
}

@test "W17: the pagination cap arms at the cap and not one below it" {
  require_yaml_parser
  local legs pair json
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  json="$(arming_json_list "${pair%%|*}")" || return 1
  assert_pagination_lane "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "$json" "${pair#*|}"
}

@test "W17 adversarial: a pagination rule doctored into a count reconcile reds one below the cap" {
  require_yaml_parser
  local legs pair json line doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  # The reconcile the threshold replaced: compare the count against the parsed
  # list's length, which arms whenever a changed file matched no filter.
  line="$(sole_line_matching "$ARMING_SCRIPT" '^  pcf="\$\{PR_CHANGED_FILES:-\}"$')" || return 1
  replace_line "$ARMING_SCRIPT" "$line" '  if [ -n "${PR_CHANGED_FILES:-}" ] && [ "$PR_CHANGED_FILES" != "${#changed[@]}" ]; then arm reconcile; return 0; fi
  pcf='"''"'' "$doctored"
  cmp -s "$ARMING_SCRIPT" "$doctored" && {
    echo "doctoring the pagination rule changed nothing" >&2
    return 1
  }
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  json="$(arming_json_list "${pair%%|*}")" || return 1
  run assert_pagination_lane "$doctored" "$BATS_SHARDS" "$REPO_ROOT" "$json" "${pair#*|}"
  [ "$status" -ne 0 ] || {
    echo "a count reconcile passed the pagination lane" >&2
    return 1
  }
  grep -qF -- 'one below the cap' <<<"$output"
}

@test "W17: an empty changed-file list on the pull-request lane arms, exit 0 (UAT-022)" {
  require_yaml_parser
  local legs pair json out rc=0
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  json="$(arming_json_list "${pair%%|*}")" || return 1
  arming_baseline_false "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "$json" "${pair#*|}" || return 1
  out="$(arming_answer "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "${pair#*|}" '' '')" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = true ] || {
    echo "an empty CHANGED_FILES_JSON on the pull-request lane answered '$out' (exit $rc), expected true and exit 0" >&2
    return 1
  }
}

@test "W17: an unreadable workflow seam arms, exit 0 (UAT-022)" {
  require_yaml_parser
  require_non_root
  local legs pair json copy="$BATS_TEST_TMPDIR/unreadable.yml" out rc=0
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  json="$(arming_json_list "${pair%%|*}")" || return 1
  cp "$WORKFLOW" "$copy"
  LEG_ARMING_WORKFLOW="$copy" arming_baseline_false "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "$json" "${pair#*|}" || return 1
  chmod 000 "$copy"
  out="$(LEG_ARMING_WORKFLOW="$copy" arming_answer "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "${pair#*|}" "$json" '')" || rc=$?
  chmod 644 "$copy"
  [ "$rc" -eq 0 ] && [ "$out" = true ] || {
    echo "an unreadable workflow seam answered '$out' (exit $rc), expected true and exit 0" >&2
    return 1
  }
}

@test "W17: a sharder that exits non-zero arms, exit 0 (UAT-022)" {
  require_yaml_parser
  local legs pair json stub="$BATS_TEST_TMPDIR/failing-sharder.sh" out rc=0
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  json="$(arming_json_list "${pair%%|*}")" || return 1
  arming_baseline_false "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "$json" "${pair#*|}" || return 1
  printf '#!/usr/bin/env bash\nexit 3\n' >"$stub"
  out="$(arming_answer "$ARMING_SCRIPT" "$stub" "$REPO_ROOT" "${pair#*|}" "$json" '')" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = true ] || {
    echo "a sharder exiting 3 answered '$out' (exit $rc), expected true and exit 0" >&2
    return 1
  }
}

@test "W17: a grep hard error in the scan arms, exit 0 (UAT-022)" {
  require_yaml_parser
  require_non_root
  local root="$BATS_TEST_TMPDIR/arming-grep-error" legs pages page expected leg json out rc=0
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | sed -n 1p)"
  seed_arming_tree "$BATS_SHARDS" "$root" "$WORKFLOW"
  write_namer "$root/scripts/names-page.bats" "$page"
  expected="$(arming_tree_run "$root" arming_tree_expected_row "$BATS_SHARDS" "$root" "$page" \
    "$root/scripts/names-page.bats")" || return 1
  leg="$(arming_declining_pair "$expected" "$legs")" || return 1
  leg="${leg#*|}"
  json="$(arming_json_list "$page")" || return 1
  arming_tree_run "$root" arming_baseline_false "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$json" "$leg" || return 1

  mkdir -p "$root/hooks/fixtures"
  printf 'unreadable\n' >"$root/hooks/fixtures/locked.txt"
  chmod 000 "$root/hooks/fixtures/locked.txt"
  out="$(arming_tree_run "$root" arming_answer "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$leg" "$json" '')" || rc=$?
  chmod 644 "$root/hooks/fixtures/locked.txt"
  [ "$rc" -eq 0 ] && [ "$out" = true ] || {
    echo "a scan hitting an unreadable file answered '$out' (exit $rc) on leg $leg, expected true and exit 0" >&2
    return 1
  }
}

# seed_mention_tree <sharder> <root> <workflow> <subtree> <page>: a seeded tree
# whose one mention of <page> sits in a file under the scripts seam's
# <subtree> directory, `helpers` or `fixtures`, and in no suite.
seed_mention_tree() {
  local sharder="$1" root="$2" workflow="$3" sub="$4" page="$5"
  seed_arming_tree "$sharder" "$root" "$workflow"
  mkdir -p "$root/scripts/$sub"
  printf 'reads %s\n' "$page" >"$root/scripts/$sub/mention-$sub"
}

# assert_mention_arms <script> <sharder> <root> <page> <legs>
#
# The script's row for <page>, in a tree seed_mention_tree built, is exactly the
# scripts seam's group plus the group rule 5 arms. Exact rather than "the
# scripts legs answer true": a script that stopped reading the mention would
# still arm those legs through the empty-namer fallback, and only the legs that
# must answer `false` tell the two apart.
assert_mention_arms() {
  local script="$1" sharder="$2" root="$3" page="$4" legs="$5" expected answered
  expected="$(arming_tree_run "$root" arming_tree_expected_row "$sharder" "$root" "$page" \
    "$root/scripts/plain-0.bats")" || return 1
  answered="$(arming_tree_run "$root" arming_script_row "$script" "$sharder" "$root" "$page" "$legs")" || return 1
  compare_arming_tables "$expected" "$answered" "the mention's own group" 'the arming script'
}

@test "W17: a narrowable page named only under a suite directory's helpers/ arms that suite's group (UAT-021)" {
  require_yaml_parser
  local root="$BATS_TEST_TMPDIR/arming-helpers" legs pages page
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | sed -n 1p)"
  seed_mention_tree "$BATS_SHARDS" "$root" "$WORKFLOW" helpers "$page"
  assert_mention_arms "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$page" "$legs"
}

@test "W17: a narrowable page named only under a suite directory's fixtures/ arms that suite's group (UAT-021)" {
  require_yaml_parser
  local root="$BATS_TEST_TMPDIR/arming-fixtures" legs pages page
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | sed -n 1p)"
  seed_mention_tree "$BATS_SHARDS" "$root" "$WORKFLOW" fixtures "$page"
  assert_mention_arms "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$page" "$legs"
}

@test "W17 adversarial: a script that scans suites only reds both the helper-only and the fixture-only arm" {
  require_yaml_parser
  local legs pages page line mutated sub doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  line="$(sole_line_matching "$ARMING_SCRIPT" '^ *for sub in helpers lib fixtures; do$')" || return 1
  mutated="${line%%for*}for sub in no-subtree; do"
  assert_doctored "$line" "$mutated" "dropping every subtree from the scan" || return 1
  replace_line "$ARMING_SCRIPT" "$line" "$mutated" "$doctored"
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  page="$(printf '%s\n' "$pages" | sed -n 1p)"
  for sub in helpers fixtures; do
    seed_mention_tree "$BATS_SHARDS" "$BATS_TEST_TMPDIR/arming-$sub" "$WORKFLOW" "$sub" "$page"
    run assert_mention_arms "$doctored" "$BATS_SHARDS" "$BATS_TEST_TMPDIR/arming-$sub" "$page" "$legs"
    [ "$status" -ne 0 ] || {
      echo "the $sub-only mention passed against a script that scans suites only" >&2
      return 1
    }
    grep -qF -- 'the arming script arms' <<<"$output" || {
      echo "the $sub-only arm did not red on a gratuitously armed leg" >&2
      return 1
    }
  done
}

# assert_all_but_one_arms <script> <sharder> <root> <workflow> <legs>
#
# In a seeded tree, a suite naming every narrowable page but one, the page under
# test among them, still arms its group: the namer-of-all rule excludes at
# exactly all, and is not a threshold.
assert_all_but_one_arms() {
  local script="$1" sharder="$2" root="$3" workflow="$4" legs="$5" class member page expected answered
  local members=()
  class="$(arming_parser_class "$workflow")" || return 1
  while IFS= read -r member || [ -n "$member" ]; do
    if [ -n "$member" ]; then
      members+=("$member")
    fi
  done <<<"$class"
  [ "${#members[@]}" -gt 2 ] || {
    echo "the class has too few members for a file to name all but one of them and still name the page" >&2
    return 1
  }
  page="${members[0]}"
  seed_arming_tree "$sharder" "$root" "$workflow"
  write_namer "$root/hooks/names-most.bats" "${members[@]:0:${#members[@]}-1}"
  write_namer "$root/scripts/names-page.bats" "$page"
  expected="$(arming_tree_run "$root" arming_tree_expected_row "$sharder" "$root" "$page" \
    "$root/hooks/names-most.bats" "$root/scripts/names-page.bats")" || return 1
  answered="$(arming_tree_run "$root" arming_script_row "$script" "$sharder" "$root" "$page" "$legs")" || return 1
  compare_arming_tables "$expected" "$answered" 'every namer of the page' 'the arming script'
}

@test "W17: a file naming every narrowable page does not arm its group for a page named elsewhere too" {
  require_yaml_parser
  local root="$BATS_TEST_TMPDIR/arming-namer-all" legs class member page expected answered
  local members=()
  legs="$(arming_legs "$WORKFLOW")" || return 1
  class="$(arming_parser_class "$WORKFLOW")" || return 1
  while IFS= read -r member || [ -n "$member" ]; do
    if [ -n "$member" ]; then
      members+=("$member")
    fi
  done <<<"$class"
  [ "${#members[@]}" -gt 1 ] || {
    echo "the class has a single member, where the namer-of-all rule is inert by design" >&2
    return 1
  }
  page="${members[0]}"
  seed_arming_tree "$BATS_SHARDS" "$root" "$WORKFLOW"
  write_namer "$root/hooks/names-all.bats" "${members[@]}"
  write_namer "$root/scripts/names-page.bats" "$page"
  # The whole-class file is the page's only namer in its own group, and the page
  # has a namer elsewhere, so the empty-namer fallback cannot arm every leg.
  expected="$(arming_tree_run "$root" arming_tree_expected_row "$BATS_SHARDS" "$root" "$page" \
    "$root/scripts/names-page.bats")" || return 1
  answered="$(arming_tree_run "$root" arming_script_row "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$page" "$legs")" || return 1
  compare_arming_tables "$expected" "$answered" 'the namers other than the whole-class file' 'the arming script'
}

@test "W17: a file naming all but one narrowable page still arms its group" {
  require_yaml_parser
  local legs
  legs="$(arming_legs "$WORKFLOW")" || return 1
  assert_all_but_one_arms "$ARMING_SCRIPT" "$BATS_SHARDS" "$BATS_TEST_TMPDIR/arming-namer-most" "$WORKFLOW" "$legs"
}

@test "W17: the namer-of-all rule is inert on a single-member class" {
  require_yaml_parser
  local root="$BATS_TEST_TMPDIR/arming-single" legs class member page one expected answered
  local members=()
  legs="$(arming_legs "$WORKFLOW")" || return 1
  class="$(arming_parser_class "$WORKFLOW")" || return 1
  while IFS= read -r member || [ -n "$member" ]; do
    if [ -n "$member" ]; then
      members+=("$member")
    fi
  done <<<"$class"
  page="${members[0]}"
  seed_arming_tree "$BATS_SHARDS" "$root" "$WORKFLOW"
  drop_wiki_code_entries "$WORKFLOW" "$root/.github/workflows/audit-ci-tests.yml" "$page"
  one="$(LEG_ARMING_ROOT="$root" bash "$ARMING_SCRIPT" class 2>/dev/null)" || {
    echo "the arming script could not read the single-member fixture's class" >&2
    return 1
  }
  [ "$one" = "$page" ] || {
    echo "the single-member fixture's class is not exactly $page:" >&2
    printf '%s\n' "$one" >&2
    return 1
  }
  # Every namer of a single-member class names all of it; the rule is inert, so
  # the file still arms its group.
  write_namer "$root/hooks/names-all.bats" "${members[@]}"
  expected="$(arming_tree_run "$root" arming_tree_expected_row "$BATS_SHARDS" "$root" "$page" \
    "$root/hooks/names-all.bats")" || return 1
  answered="$(arming_tree_run "$root" arming_script_row "$ARMING_SCRIPT" "$BATS_SHARDS" "$root" "$page" "$legs")" || return 1
  compare_arming_tables "$expected" "$answered" "the namer's own group" 'the arming script'
}

@test "W17 adversarial: a namer-of-all rule doctored into a threshold reds the all-but-one arm" {
  require_yaml_parser
  local legs reset tally mutated_reset mutated_tally step="$BATS_TEST_TMPDIR/leg-arming.step.sh"
  local doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  # Exclude a file that misses at most one member, rather than none.
  reset="$(sole_line_matching "$ARMING_SCRIPT" '^ *excluded=1$')" || return 1
  tally="$(sole_line_matching "$ARMING_SCRIPT" '^ *if ! line_in "\$f" ')" || return 1
  mutated_reset="$reset misses=0"
  mutated_tally="${tally%; then}"' && [ "$((misses += 1))" -gt 1 ]; then'
  assert_doctored "$reset" "$mutated_reset" "resetting a miss tally per file" || return 1
  assert_doctored "$tally" "$mutated_tally" "excluding a file at one miss" || return 1
  replace_line "$ARMING_SCRIPT" "$reset" "$mutated_reset" "$step"
  replace_line "$step" "$tally" "$mutated_tally" "$doctored"

  legs="$(arming_legs "$WORKFLOW")" || return 1
  run assert_all_but_one_arms "$doctored" "$BATS_SHARDS" "$BATS_TEST_TMPDIR/arming-threshold" "$WORKFLOW" "$legs"
  [ "$status" -ne 0 ] || {
    echo "a threshold namer-of-all rule passed the all-but-one arm" >&2
    return 1
  }
  grep -qF -- 'every namer of the page arms' <<<"$output"
}

@test "W17: a space-bearing changed path is read whole, and a plain one resolves the same way (UAT-015)" {
  require_yaml_parser
  local pages spaced plain legs memo answered declared
  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  spaced="$(printf '%s\n' "$pages" | grep -F ' ' | sed -n 1p)"
  plain="$(printf '%s\n' "$pages" | grep -vF ' ' | sed -n 1p)"
  [ -n "$spaced" ] && [ -n "$plain" ] || {
    echo "the class lacks a page with a space or a page without one, so the split cannot be driven" >&2
    return 1
  }
  legs="$(arming_legs "$WORKFLOW")" || return 1
  memo="$(memo_sharder "$BATS_SHARDS" "$BATS_TEST_TMPDIR/memo")" || return 1
  answered="$(arming_script_table "$ARMING_SCRIPT" "$memo" "$REPO_ROOT" "$spaced
$plain" "$legs")" || return 1
  declared="$(w16_declared_table | awk -F'|' -v a="$spaced" -v b="$plain" '$1 == a || $1 == b')"
  compare_arming_tables "$declared" "$answered" 'the declared table' "the arming script's answers"
}

@test "W17 adversarial: a word-splitting JSON read reds the space-bearing arm rather than arming everything invisibly" {
  require_yaml_parser
  local pages spaced legs memo line mutated answered declared doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  line="$(sole_line_matching "$ARMING_SCRIPT" 'changed\+=\("\$rec"\)$')" || return 1
  mutated="${line%%changed*}"'changed+=($rec)'
  assert_doctored "$line" "$mutated" "word-splitting each parsed path" || return 1
  replace_line "$ARMING_SCRIPT" "$line" "$mutated" "$doctored"

  pages="$(arming_parser_class "$WORKFLOW")" || return 1
  spaced="$(printf '%s\n' "$pages" | grep -F ' ' | sed -n 1p)"
  legs="$(arming_legs "$WORKFLOW")" || return 1
  memo="$(memo_sharder "$BATS_SHARDS" "$BATS_TEST_TMPDIR/memo")" || return 1
  answered="$(arming_script_row "$doctored" "$memo" "$REPO_ROOT" "$spaced" "$legs")" || return 1
  declared="$(w16_declared_table | awk -F'|' -v a="$spaced" '$1 == a')"
  run compare_arming_tables "$declared" "$answered" 'the declared table' "the doctored script's answers"
  [ "$status" -ne 0 ] || {
    echo "a script word-splitting $spaced passed the space-bearing arm" >&2
    return 1
  }
  grep -qF -- "$spaced: the doctored script's answers arms" <<<"$output"
}

# assert_hostile_list_contained <script> <sharder> <root> <scratch-dir> <leg>
#
# A changed-file list carrying an embedded newline, a single quote and a
# `$(...)` sequence arms, exits 0 with one line, expands nothing, and leaves
# $GITHUB_OUTPUT, $GITHUB_ENV and $GITHUB_STEP_SUMMARY, each pointed at a
# scratch file, untouched. Those files are line-oriented, so a filename echoed
# into one could append a record of its own.
assert_hostile_list_contained() {
  local script="$1" sharder="$2" root="$3" scratch="$4" leg="$5" canary json out rc=0 step_file
  canary="$scratch/expanded"
  mkdir -p "$scratch"
  : >"$scratch/GITHUB_OUTPUT"
  : >"$scratch/GITHUB_ENV"
  : >"$scratch/GITHUB_STEP_SUMMARY"
  json="$(arming_json_list "$(printf 'wiki/concepts/a\nb.md')" "it's.md" "\$(touch $canary).md")" || return 1
  out="$(GITHUB_OUTPUT="$scratch/GITHUB_OUTPUT" GITHUB_ENV="$scratch/GITHUB_ENV" \
    GITHUB_STEP_SUMMARY="$scratch/GITHUB_STEP_SUMMARY" \
    arming_answer "$script" "$sharder" "$root" "$leg" "$json" '')" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = true ] || {
    echo "the hostile list answered '$out' (exit $rc), expected exactly one true line and exit 0" >&2
    return 1
  }
  for step_file in GITHUB_OUTPUT GITHUB_ENV GITHUB_STEP_SUMMARY; do
    [ -s "$scratch/$step_file" ] && {
      echo "the arming script wrote to \$$step_file on a hostile changed-file list:" >&2
      cat "$scratch/$step_file" >&2
      return 1
    }
  done
  [ -e "$canary" ] && {
    echo "a \$(...) sequence in a changed filename was expanded" >&2
    return 1
  }
  true
}

@test "W17: a hostile changed-file list arms without writing to any step file (UAT-016)" {
  require_yaml_parser
  local legs pair
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  assert_hostile_list_contained "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "$BATS_TEST_TMPDIR/hostile" "${pair#*|}"
}

@test "W17 adversarial: a script echoing a changed filename into GITHUB_OUTPUT is caught" {
  require_yaml_parser
  local legs pair line indent doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  line="$(sole_line_matching "$ARMING_SCRIPT" 'changed\+=\("\$rec"\)$')" || return 1
  indent="${line%%changed*}"
  insert_after "$ARMING_SCRIPT" "$line" "$indent"'printf "leak=%s\n" "$rec" >>"$GITHUB_OUTPUT"' "$doctored"
  cmp -s "$ARMING_SCRIPT" "$doctored" && {
    echo "inserting the leak changed nothing" >&2
    return 1
  }
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  run assert_hostile_list_contained "$doctored" "$BATS_SHARDS" "$REPO_ROOT" "$BATS_TEST_TMPDIR/hostile" "${pair#*|}"
  [ "$status" -ne 0 ] || {
    echo "a script leaking a filename into GITHUB_OUTPUT passed" >&2
    return 1
  }
  grep -qF -- 'wrote to $GITHUB_OUTPUT' <<<"$output"
}

# assert_substring_arms <script> <sharder> <root> <page> <legs>: a changed path
# that merely contains <page> arms each of <legs>, because membership is exact
# string equality against the class.
assert_substring_arms() {
  local script="$1" sharder="$2" root="$3" page="$4" legs="$5" json leg out rc n=0
  json="$(arming_json_list ".gaia/scripts/$page.sh")" || return 1
  while IFS= read -r leg || [ -n "$leg" ]; do
    [ -n "$leg" ] || continue
    rc=0
    out="$(arming_answer "$script" "$sharder" "$root" "$leg" "$json" '')" || rc=$?
    [ "$rc" -eq 0 ] && [ "$out" = true ] || {
      echo "a path merely containing $page answered '$out' (exit $rc) on leg $leg, expected true: membership is a substring test" >&2
      return 1
    }
    n=$((n + 1))
  done <<EOF
$legs
EOF
  [ "$n" -gt 0 ] || {
    echo "the substring lane was driven over no leg" >&2
    return 1
  }
}

@test "W17: a changed path that merely contains a narrowable page arms every leg (UAT-017)" {
  require_yaml_parser
  local legs pair
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  assert_substring_arms "$ARMING_SCRIPT" "$BATS_SHARDS" "$REPO_ROOT" "${pair%%|*}" "$legs"
}

@test "W17 adversarial: a membership test doctored into a substring match is caught" {
  require_yaml_parser
  local legs pair line mutated doctored="$BATS_TEST_TMPDIR/leg-arming.sh"
  line="$(sole_line_matching "$ARMING_SCRIPT" 'if \[ "\$path" = "\$\{class\[\$i\]\}" \]; then$')" || return 1
  mutated="${line%%if*}"'if [[ "$path" == *"${class[$i]}"* ]]; then'
  assert_doctored "$line" "$mutated" "turning membership into a substring match" || return 1
  replace_line "$ARMING_SCRIPT" "$line" "$mutated" "$doctored"
  legs="$(arming_legs "$WORKFLOW")" || return 1
  pair="$(arming_declining_pair "$(w16_declared_table)" "$legs")" || return 1
  # Sampled on purpose: the one leg the page narrows to `false` is the leg a
  # substring match can disarm, and one is enough to show the lane reds.
  run assert_substring_arms "$doctored" "$BATS_SHARDS" "$REPO_ROOT" "${pair%%|*}" "${pair#*|}"
  [ "$status" -ne 0 ] || {
    echo "a substring membership test passed the substring lane" >&2
    return 1
  }
  grep -qF -- 'membership is a substring test' <<<"$output"
}

# W18 (SPEC-078 lever two, UAT-010). The arming scan finds a page by literal
# mention, so a suite reaching a narrowable page through a path it builds at
# run time is invisible to it, and invisible here means a leg that stops
# arming for a page one of its suites reads. This fails on a `wiki/`-rooted
# path whose remainder below `wiki/` is not fully literal, a `$VAR`, `${VAR}`
# or `$(...)` segment or a `*`, `?` or `[`, in a suite or helper the scan reads,
# and only where the remainder could match a narrowable page.
#
# Exempt, each for a stated reason. A variable PREFIX before a literal remainder
# (`"$ROOT/wiki/concepts/GAIA Audit.md"`): the scan matches by basename, so it
# sees it. A single-quoted token: nothing expands inside single quotes, so the
# text is a pattern or an allowlist rather than a path a suite builds. A
# `@test` name and a comment: neither builds a path. A fixtures/ file that is
# not shell: a suite reads it as data rather than runs it, and the literal scan
# already reaches whatever it names.
#
# WHAT THIS DOES NOT CATCH. The reader is shell-shaped and tracks quotes one
# line at a time, so a path assembled across lines, or by another language's
# string operations inside a program a heredoc embeds, reads as literal or not
# at all.

dynamic_wiki_paths_py() {
  python3 - "$@" <<'PY'
import os
import re
import sys

members = [m for m in os.environ['ARMING_CLASS'].split('\n') if m]
with open(sys.argv[1], encoding='utf-8') as handle:
    paths = [p for p in handle.read().split('\n') if p]
BOUNDARY = set('_.-')
STOP = set(' \t;|&<>()\'"`')


def balanced(line, k, opener, closer):
    depth = 0
    while k < len(line):
        if line[k] == opener:
            depth += 1
        elif line[k] == closer:
            depth -= 1
            if depth == 0:
                return k + 1
        k += 1
    return k


def remainder(line, k, quoted):
    parts = []
    dynamic = False
    n = len(line)
    while k < n:
        c = line[k]
        if quoted and c == '"':
            break
        if not quoted and c in STOP:
            break
        if c == '\\' and k + 1 < n:
            parts.append(re.escape(line[k + 1]))
            k += 2
            continue
        if c == '$' and k + 1 < n:
            nxt = line[k + 1]
            if nxt == '(':
                k = balanced(line, k + 1, '(', ')')
            elif nxt == '{':
                k = balanced(line, k + 1, '{', '}')
            elif nxt.isalpha() or nxt == '_':
                k += 2
                while k < n and (line[k].isalnum() or line[k] == '_'):
                    k += 1
            elif nxt.isdigit() or nxt in '@*#?$!-':
                k += 2
            else:
                parts.append(re.escape(c))
                k += 1
                continue
            parts.append('.*')
            dynamic = True
            continue
        if c in '*?[':
            parts.append('.*')
            dynamic = True
            if c == '[':
                close = line.find(']', k + 1)
                k = close + 1 if close > 0 else k + 1
            else:
                k += 1
            continue
        parts.append(re.escape(c))
        k += 1
    return k, dynamic, ''.join(parts)


def scan(line):
    stripped = line.lstrip()
    if stripped.startswith('#') or stripped.startswith('@test '):
        return []
    hits = []
    single = double = False
    k = 0
    n = len(line)
    while k < n:
        c = line[k]
        if single:
            if c == "'":
                single = False
            k += 1
            continue
        if c == '\\':
            k += 2
            continue
        if c == "'" and not double:
            single = True
            k += 1
            continue
        if c == '"':
            double = not double
            k += 1
            continue
        if c == '#' and not double and (k == 0 or line[k - 1] in ' \t'):
            break
        if line.startswith('wiki/', k) and (
                k == 0 or not (line[k - 1].isalnum() or line[k - 1] in BOUNDARY)):
            end, dynamic, rx = remainder(line, k + 5, double)
            if dynamic and any(re.fullmatch('wiki/' + rx, m) for m in members):
                hits.append(line[k:end])
            k = max(end, k + 5)
            continue
        k += 1
    return hits


scanned = 0
for path in paths:
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write('could not read %s (%s)\n' % (path, exc.__class__.__name__))
        sys.exit(2)
    scanned += 1
    for number, line in enumerate(text.split('\n'), 1):
        for expr in scan(line):
            print('hit\t%s:%d: %s' % (path, number, expr))
print('scanned\t%d' % scanned)
PY
}

# assert_no_dynamic_wiki_paths <class> <list-file>: no file in <list-file>
# reaches a member of <class> through a non-literal `wiki/` path, and the
# detector read every file on the list, which is non-empty.
assert_no_dynamic_wiki_paths() {
  local class="$1" list="$2" expected out scanned hits rc=0
  expected="$(awk 'NF { n++ } END { print n + 0 }' "$list")"
  [ "$expected" -gt 0 ] || {
    echo "W18's input set is empty, so it would assert over nothing" >&2
    return 1
  }
  out="$(ARMING_CLASS="$class" dynamic_wiki_paths_py "$list")" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the dynamic wiki/ path detector failed (exit $rc)" >&2
    printf '%s\n' "$out" >&2
    return 1
  }
  scanned="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "scanned" { print $2 }')"
  [ "$scanned" = "$expected" ] || {
    echo "the detector read ${scanned:-no} files of an input set holding $expected" >&2
    return 1
  }
  hits="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "hit" { print $2 }')"
  [ -z "$hits" ] || {
    echo "a suite or helper reaches a narrowable page through a wiki/ path that is not fully literal, which the arming scan cannot see:" >&2
    printf '%s\n' "$hits" >&2
    echo "Repair: spell the path literally, or single-quote it where it is a pattern rather than a path." >&2
    return 1
  }
}

@test "W18: no suite or helper in the arming scan's input set reaches a narrowable page through a non-literal wiki/ path (UAT-010)" {
  require_yaml_parser
  local conc_leg class list="$BATS_TEST_TMPDIR/w18-files"
  conc_leg="$(arming_concurrency_leg "$BATS_SHARDS" "$WORKFLOW")" || return 1
  class="$(arming_parser_class "$WORKFLOW")" || return 1
  arming_inputs "$BATS_SHARDS" "$REPO_ROOT" "$ARMING_CONCURRENCY_DIR" "$conc_leg" w18 >"$list" || return 1
  assert_no_dynamic_wiki_paths "$class" "$list" || return 1
  printf 'W18 read %s files and found no non-literal wiki/ path\n' "$(awk 'NF { n++ } END { print n + 0 }' "$list")"
}

@test "W18: the detector flags a non-literal remainder and exempts the stated shapes" {
  require_yaml_parser
  local class probe="$BATS_TEST_TMPDIR/w18-probe.bats" list="$BATS_TEST_TMPDIR/w18-probe-list"
  class="$(arming_parser_class "$WORKFLOW")" || return 1
  # Every line is written from a single-quoted string, so this suite's own text
  # carries none of the shapes it probes.
  {
    printf '%s\n' 'cat "$ROOT/wiki/concepts/GAIA Audit.md"'
    printf '%s\n' "grep -oE 'wiki/[A-Za-z]+\\.md' \"\$f\""
    printf '%s\n' '# cat "$ROOT/wiki/concepts/${page}"'
    printf '%s\n' '@test "every wiki/*.md page" {'
  } >"$probe"
  printf '%s\n' "$probe" >"$list"
  run assert_no_dynamic_wiki_paths "$class" "$list"
  [ "$status" -eq 0 ] || {
    echo "an exempt shape was flagged:" >&2
    printf '%s\n' "$output" >&2
    return 1
  }
  printf '%s\n' 'for f in $ROOT/wiki/concepts/*.md; do' >>"$probe"
  printf '%s\n' 'cat "$ROOT/wiki/$(page_of "$f")"' >>"$probe"
  run assert_no_dynamic_wiki_paths "$class" "$list"
  [ "$status" -ne 0 ] || {
    echo "a glob and a command substitution below wiki/ were not flagged" >&2
    return 1
  }
  # The expected expressions are single-quoted for the reason the probe lines
  # are: W18 reads this suite too.
  grep -qF -- "$probe:5: "'wiki/concepts/*.md' <<<"$output" || return 1
  grep -qF -- "$probe:6: "'wiki/$(page_of' <<<"$output"
}

@test "W18 adversarial: a suite reaching a narrowable page through a variable segment is caught, naming the suite and the expression" {
  require_yaml_parser
  local conc_leg class inputs suite doctored="$BATS_TEST_TMPDIR/doctored-suite.bats" list="$BATS_TEST_TMPDIR/w18-doctored"
  conc_leg="$(arming_concurrency_leg "$BATS_SHARDS" "$WORKFLOW")" || return 1
  class="$(arming_parser_class "$WORKFLOW")" || return 1
  inputs="$(arming_inputs "$BATS_SHARDS" "$REPO_ROOT" "$ARMING_CONCURRENCY_DIR" "$conc_leg")" || return 1
  suite="$(printf '%s\n' "$inputs" | awk -F'\t' '$1 == "suite" { print $2; exit }')"
  [ -n "$suite" ] || {
    echo "the arming scan discovered no suite to doctor a copy of" >&2
    return 1
  }
  cp "$suite" "$doctored"
  printf '%s\n' '  cat "$REPO_ROOT/wiki/concepts/${page_name}"' >>"$doctored"
  assert_doctored "$(cat "$suite")" "$(cat "$doctored")" "appending a variable-segment wiki/ path to a copy of $suite" || return 1
  printf '%s\n' "$doctored" >"$list"
  run assert_no_dynamic_wiki_paths "$class" "$list"
  [ "$status" -ne 0 ] || {
    echo "a variable segment below wiki/ reaching a narrowable page was not caught" >&2
    return 1
  }
  grep -qF -- "$doctored:" <<<"$output" || {
    echo "the refusal did not name the doctored suite" >&2
    return 1
  }
  grep -qF -- 'wiki/concepts/${page_name}' <<<"$output"
}

# W19 (SPEC-078 lever two, FC-2). Pins the wiring lever two lands: `json`
# list-files on the shards job's own paths-filter step, the arming step
# immediately after it, and the narrowed conjunct
# (`steps.leg-arming.outputs.arm == 'true'`) on every per-leg `code:`-gated
# step in that job -- ADDITIONAL to the existing filter conjunct those steps
# already carry, never a replacement.
#
# Every derivation below is scoped to the shards job on purpose, not as an
# optimization: the two standalone hop-1 jobs (hook-capabilities-live-tree,
# verb-arming-adoption) each carry their own hand-rolled `id: filter` gate and
# must never carry the arming conjunct, so an unscoped comparison would red on
# the merged tree for a reason that is not a real one.
ARMING_STEP_NAME='Resolve whether this leg holds a suite naming the changed wiki pages'

# w19_armed_names / w19_filtered_names <workflow>: names of every shards-job
# step whose if: reads steps.leg-arming.outputs.arm / steps.filter.outputs.code
# respectively, LC_ALL=C sorted, one per line. `filtered` excludes the arming
# step's own name: its gate admits the filter conjunct so it can hand the
# script a real answer, but it never gates on its own output, so it is not a
# member of the set this compares against.
w19_armed_names() {
  local workflow="$1" name gate
  while IFS=$'\t' read -r name gate; do
    [ -n "$name" ] || continue
    if printf '%s' "$gate" | grep -qF -- 'steps.leg-arming.outputs.arm'; then
      printf '%s\n' "$name"
    fi
  done < <(read_wf stepgates "$workflow" shards) | LC_ALL=C sort
}

w19_filtered_names() {
  local workflow="$1" name gate
  while IFS=$'\t' read -r name gate; do
    [ -n "$name" ] || continue
    [ "$name" = "$ARMING_STEP_NAME" ] && continue
    if printf '%s' "$gate" | grep -qF -- 'steps.filter.outputs.code'; then
      printf '%s\n' "$name"
    fi
  done < <(read_wf stepgates "$workflow" shards) | LC_ALL=C sort
}

# assert_list_files_json <workflow>: the shards job's own paths-filter step
# exposes list-files as exactly json. Several narrowable class pages carry a
# space in their path, and every other format the action offers is space- or
# comma-joined, so anything else would silently shred a path and ship the
# narrowing inert while every criterion here still read green.
assert_list_files_json() {
  local workflow="$1" value
  value="$(read_wf filterwith "$workflow" shards list-files)"
  [ "$value" = "json" ] && return 0
  echo "$workflow's shards paths-filter step's list-files is '$value', expected json" >&2
  return 1
}

# assert_retained_filter_conjunct <workflow>: no shards-job step reads
# steps.leg-arming.outputs. without also reading steps.filter.outputs.code --
# the load-bearing invariant: the arming conjunct is ADDITIONAL, never a
# replacement, and dropping the filter conjunct from a narrowed step would
# silently retire it from workflow-filter-coverage.bats's gated set and from
# W4's population.
assert_retained_filter_conjunct() {
  local workflow="$1" name gate gaps=""
  while IFS=$'\t' read -r name gate; do
    [ -n "$name" ] || continue
    printf '%s' "$gate" | grep -qF -- 'steps.leg-arming.outputs.' || continue
    printf '%s' "$gate" | grep -qF -- 'steps.filter.outputs.code' || gaps="${gaps}${name}; "
  done < <(read_wf stepgates "$workflow" shards)
  [ -z "$gaps" ] || {
    echo "step(s) in shards read the arming conjunct without the filter conjunct: $gaps" >&2
    return 1
  }
  return 0
}

# assert_conjunct_sets_equal <workflow>: within shards, the set of steps
# carrying the arming conjunct equals the set carrying the filter conjunct
# (minus the arming step itself). A step gated indirectly through another
# step's output -- the CLI-workspace install, gated on
# steps.needs-cli-workspace.outputs.needed -- never reads either conjunct
# literally, so it is already absent from both sides without an explicit
# exclusion.
assert_conjunct_sets_equal() {
  local workflow="$1" armed filtered
  armed="$(w19_armed_names "$workflow")"
  filtered="$(w19_filtered_names "$workflow")"
  [ "$armed" = "$filtered" ] && return 0
  echo "the arming-conjunct and filter-conjunct sets in shards disagree (excluding the arming step, and excluding any step -- e.g. the CLI-workspace install -- gated only indirectly through another step's output)." >&2
  echo "arming conjunct:" >&2
  printf '%s\n' "$armed" >&2
  echo "filter conjunct:" >&2
  printf '%s\n' "$filtered" >&2
  return 1
}

# assert_arming_conjunct_scoped_to_shards <workflow>: no job other than
# shards carries the arming conjunct. Proves the job scoping above is a real
# boundary rather than a silent exclusion: hook-capabilities-live-tree and
# verb-arming-adoption each gate a step on their OWN hand-rolled id: filter
# step and must never carry steps.leg-arming.outputs. at all.
assert_arming_conjunct_scoped_to_shards() {
  local workflow="$1" rows
  rows="$(read_wf armingifs "$workflow" | awk -F'\t' '$1 != "shards"')"
  [ -z "$rows" ] && return 0
  echo "the arming conjunct reached a job outside shards:" >&2
  printf '%s\n' "$rows" >&2
  return 1
}

# assert_arming_step_id_is_leg_arming <workflow>: the arming step's id is
# leg-arming, never filter -- the workflow already carries three id: filter
# steps (the shards job's real paths-filter step and the two standalone
# jobs' hand-rolled gates), and workflow-filter-coverage.bats's hand-rolled
# pin over the latter two must not widen to a fourth.
assert_arming_step_id_is_leg_arming() {
  local workflow="$1" id
  id="$(read_wf stepfield "$workflow" shards "$ARMING_STEP_NAME" id)"
  [ "$id" = "leg-arming" ] && return 0
  echo "the arming step's id is '$id', expected leg-arming" >&2
  return 1
}

# assert_arming_fallback_present <workflow>: the arming step's run: body
# carries the default-to-true case arm, matched as the construct rather than
# a whole-body snapshot so a comment edit elsewhere in the step never reds
# this.
assert_arming_fallback_present() {
  local workflow="$1" body
  body="$(read_wf stepfield "$workflow" shards "$ARMING_STEP_NAME" run)"
  printf '%s' "$body" | grep -qF -- '*) arm=true ;;' && return 0
  echo "the arming step's run: body is missing its default-to-true case arm" >&2
  return 1
}

# assert_changed_files_json_bounded <workflow>: the arming step's
# env.CHANGED_FILES_JSON reads steps.filter.outputs.code_files only under a
# github.event.pull_request.changed_files bound, falling back to '' on an
# oversized list. An unbounded value can exceed the kernel's per-string
# MAX_ARG_STRLEN, which fails the step's execve before leg-arming.sh's own
# fail-open can run. The match anchors the whole value end to end, `${{` to
# `}}` with only optional whitespace outside the construct, so no trailing
# clause after the '' fallback can widen what the expression evaluates. The
# operator is pinned to <= so a flipped or widened comparison cannot turn the
# bound into a floor that arms every leg. The integer is pinned to a positive
# number of at most four digits: wide enough that a retune within that range
# still matches, narrow enough to rule out an effectively unbounded value --
# the kernel's per-string limit is 131072 bytes, and a five-digit count could
# never fit under it at any realistic path length.
assert_changed_files_json_bounded() {
  local workflow="$1" value
  value="$(read_wf stepfield "$workflow" shards "$ARMING_STEP_NAME" env.CHANGED_FILES_JSON)"
  printf '%s' "$value" | grep -qE -- "^\\\$\{\{ *github\.event\.pull_request\.changed_files *<= *[1-9][0-9]{0,3} *&& *steps\.filter\.outputs\.code_files *\|\| *'' *\}\}\$" && return 0
  echo "the '$ARMING_STEP_NAME' step's env.CHANGED_FILES_JSON is '$value', expected steps.filter.outputs.code_files gated behind a github.event.pull_request.changed_files <= bound of at most four digits, anchored end to end with an '' fallback (the guard against an oversized env string failing this step's execve before the script's own fail-open runs)" >&2
  return 1
}

# assert_arming_body_no_changed_files_leak <workflow>: the arming step's
# run: body writes only fixed literals to GITHUB_OUTPUT and
# GITHUB_STEP_SUMMARY, never CHANGED_FILES_JSON -- those two sinks are
# line-oriented and a changed filename may carry a newline, so nothing
# derived from the changed-file list may reach either one.
assert_arming_body_no_changed_files_leak() {
  local workflow="$1" body
  body="$(read_wf stepfield "$workflow" shards "$ARMING_STEP_NAME" run)"
  printf '%s' "$body" | grep -qF -- 'GITHUB_OUTPUT' || {
    echo "the arming step's run: body no longer writes to GITHUB_OUTPUT" >&2
    return 1
  }
  printf '%s' "$body" | grep -qF -- 'CHANGED_FILES_JSON' && {
    echo "the arming step's run: body references CHANGED_FILES_JSON directly; nothing derived from the changed-file list may reach GITHUB_OUTPUT or GITHUB_STEP_SUMMARY" >&2
    return 1
  }
  return 0
}

@test "W19: the shards job's paths-filter step exposes list-files as json" {
  require_yaml_parser
  assert_list_files_json "$WORKFLOW"
}

@test "W19: every shards-job step reading the arming conjunct also reads the filter conjunct" {
  require_yaml_parser
  assert_retained_filter_conjunct "$WORKFLOW"
}

@test "W19: within shards, the arming-conjunct set equals the filter-conjunct set" {
  require_yaml_parser
  assert_conjunct_sets_equal "$WORKFLOW"
}

@test "W19: the arming conjunct never reaches a job other than shards" {
  require_yaml_parser
  assert_arming_conjunct_scoped_to_shards "$WORKFLOW"
}

@test "W19: the arming step's id is leg-arming, and the workflow's other id: filter steps are unchanged" {
  require_yaml_parser
  assert_arming_step_id_is_leg_arming "$WORKFLOW"

  local rows
  rows="$(read_wf filteridjobs "$WORKFLOW")"
  printf '%s\n' "$rows" | grep -qF -- "$ARMING_STEP_NAME" && {
    echo "the arming step's name appeared among the id: filter steps" >&2
    return 1
  }
  printf '%s\n' "$rows" | awk -F'\t' '$1 == "shards"' | grep -qF -- 'dorny/paths-filter' || {
    echo "shards' id: filter step is no longer the real paths-filter step" >&2
    return 1
  }
  printf '%s\n' "$rows" | grep -qF -- 'hook-capabilities-live-tree' || {
    echo "hook-capabilities-live-tree's hand-rolled id: filter gate is missing" >&2
    return 1
  }
  printf '%s\n' "$rows" | grep -qF -- 'verb-arming-adoption' || {
    echo "verb-arming-adoption's hand-rolled id: filter gate is missing" >&2
    return 1
  }
}

@test "W19: the arming step's run: body carries the default-to-true fallback" {
  require_yaml_parser
  assert_arming_fallback_present "$WORKFLOW"
}

@test "W19: the arming step's run: body writes only fixed literals, never a changed filename, to GITHUB_OUTPUT or GITHUB_STEP_SUMMARY" {
  require_yaml_parser
  assert_arming_body_no_changed_files_leak "$WORKFLOW"
}

@test "W19 adversarial: list-files changed to shell is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-listfiles-shell.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" '^ *list-files: json$')" || return 1
  mutated="$(printf '%s' "$line" | sed 's/json/shell/')"
  assert_doctored "$line" "$mutated" "changing list-files to shell" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_list_files_json "$doctored"
  [ "$status" -ne 0 ] || {
    echo "changing list-files to shell did not red" >&2
    return 1
  }
}

@test "W19 adversarial: list-files deleted outright is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-listfiles-absent.yml" line
  line="$(sole_line_matching "$WORKFLOW" '^ *list-files: json$')" || return 1
  delete_line "$WORKFLOW" "$line" "$doctored"

  run assert_list_files_json "$doctored"
  [ "$status" -ne 0 ] || {
    echo "deleting list-files did not red" >&2
    return 1
  }
}

@test "W19 adversarial: the filter conjunct removed from one narrowed step is caught, naming the step" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-drop-filter.yml" line mutated
  line="$(gate_line_for_step "$WORKFLOW" 'Run a bats shard')" || return 1
  mutated="$(printf '%s' "$line" | sed "s/ && (steps.filter.outputs.code == 'true' || github.event_name == 'workflow_dispatch')//")"
  assert_doctored "$line" "$mutated" "dropping the filter conjunct" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_retained_filter_conjunct "$doctored"
  [ "$status" -ne 0 ] || {
    echo "dropping the filter conjunct from 'Run a bats shard' did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- 'Run a bats shard' || {
    echo "the refusal did not name the step" >&2
    return 1
  }
}

@test "W19 adversarial: the arming conjunct removed from one narrowed step is caught, naming the step" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-drop-arming.yml" line mutated
  line="$(gate_line_for_step "$WORKFLOW" 'Install pinned bats')" || return 1
  mutated="$(printf '%s' "$line" | sed "s/ && steps.leg-arming.outputs.arm == 'true'//")"
  assert_doctored "$line" "$mutated" "dropping the arming conjunct" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_conjunct_sets_equal "$doctored"
  [ "$status" -ne 0 ] || {
    echo "dropping the arming conjunct from 'Install pinned bats' did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- 'Install pinned bats' || {
    echo "the refusal did not name the step" >&2
    return 1
  }
}

@test "W19 adversarial: a gratuitous arming conjunct added to a shards step with no filter conjunct is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-gratuitous.yml" line mutated
  line="$(gate_line_for_step "$WORKFLOW" 'Install the CLI workspace for the floor-check suite')" || return 1
  mutated="${line} && steps.leg-arming.outputs.arm == 'true'"
  assert_doctored "$line" "$mutated" "adding a gratuitous arming conjunct" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_conjunct_sets_equal "$doctored"
  [ "$status" -ne 0 ] || {
    echo "adding a gratuitous arming conjunct to 'Install the CLI workspace for the floor-check suite' did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- 'Install the CLI workspace for the floor-check suite' || {
    echo "the refusal did not name the step" >&2
    return 1
  }
}

@test "W19 adversarial: the arming conjunct added to hook-capabilities-live-tree's gated step is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-cross-job.yml" line mutated
  line="$(gate_line_for_step "$WORKFLOW" 'Run the hook-capabilities checker against the live tree')" || return 1
  mutated="${line} && steps.leg-arming.outputs.arm == 'true'"
  assert_doctored "$line" "$mutated" "adding the arming conjunct to a step outside shards" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_arming_conjunct_scoped_to_shards "$doctored"
  [ "$status" -ne 0 ] || {
    echo "adding the arming conjunct to hook-capabilities-live-tree's gated step did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- 'hook-capabilities-live-tree' || {
    echo "the refusal did not name the job" >&2
    return 1
  }
}

@test "W19 adversarial: the arming step's id changed to filter is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-id-filter.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" '^ *id: leg-arming$')" || return 1
  mutated="$(printf '%s' "$line" | sed 's/leg-arming/filter/')"
  assert_doctored "$line" "$mutated" "changing the arming step's id to filter" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_arming_step_id_is_leg_arming "$doctored"
  [ "$status" -ne 0 ] || {
    echo "changing the arming step's id to filter did not red" >&2
    return 1
  }
}

@test "W19 adversarial: the arming step's fallback case arm removed is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-no-fallback.yml" line
  line="$(sole_line_matching "$WORKFLOW" '^ *\*\) arm=true ;;$')" || return 1
  delete_line "$WORKFLOW" "$line" "$doctored"

  run assert_arming_fallback_present "$doctored"
  [ "$status" -ne 0 ] || {
    echo "removing the fallback case arm did not red" >&2
    return 1
  }
}

@test "W19: CHANGED_FILES_JSON reads code_files only under a changed_files bound, with an '' fallback" {
  require_yaml_parser
  assert_changed_files_json_bounded "$WORKFLOW"
}

@test "W19 adversarial: CHANGED_FILES_JSON reverted to the bare code_files expression is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-changed-files-json-unbounded.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" '^ *CHANGED_FILES_JSON: ')" || return 1
  mutated="$(printf '%s\n' "$line" | sed "s/CHANGED_FILES_JSON: .*/CHANGED_FILES_JSON: \${{ steps.filter.outputs.code_files }}/")"
  assert_doctored "$line" "$mutated" "reverting CHANGED_FILES_JSON to the bare code_files expression" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_changed_files_json_bounded "$doctored"
  [ "$status" -ne 0 ] || {
    echo "reverting CHANGED_FILES_JSON to the bare code_files expression did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "$ARMING_STEP_NAME" || {
    echo "the refusal did not name the step" >&2
    return 1
  }
}

@test "W19 adversarial: CHANGED_FILES_JSON's <= operator flipped to >= is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-changed-files-json-op-flip.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" '^ *CHANGED_FILES_JSON: ')" || return 1
  mutated="$(printf '%s' "$line" | sed 's/<=/>=/')"
  assert_doctored "$line" "$mutated" "flipping the <= operator to >=" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_changed_files_json_bounded "$doctored"
  [ "$status" -ne 0 ] || {
    echo "flipping the <= operator to >= did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "$ARMING_STEP_NAME" || {
    echo "the refusal did not name the step" >&2
    return 1
  }
}

@test "W19 adversarial: CHANGED_FILES_JSON with a trailing clause after the '' fallback is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-changed-files-json-trailing.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" '^ *CHANGED_FILES_JSON: ')" || return 1
  mutated="$(printf '%s' "$line" | sed "s/|| '' }}/|| '' || steps.filter.outputs.code_files }}/")"
  assert_doctored "$line" "$mutated" "appending a trailing clause after the '' fallback" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_changed_files_json_bounded "$doctored"
  [ "$status" -ne 0 ] || {
    echo "appending a trailing clause after the '' fallback did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "$ARMING_STEP_NAME" || {
    echo "the refusal did not name the step" >&2
    return 1
  }
}

@test "W19 adversarial: CHANGED_FILES_JSON's bound widened to a five-digit value is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w19-changed-files-json-five-digit.yml" line mutated
  line="$(sole_line_matching "$WORKFLOW" '^ *CHANGED_FILES_JSON: ')" || return 1
  mutated="$(printf '%s' "$line" | sed 's/<= 1000/<= 10000/')"
  assert_doctored "$line" "$mutated" "widening the bound to a five-digit value" || return 1
  replace_line "$WORKFLOW" "$line" "$mutated" "$doctored"

  run assert_changed_files_json_bounded "$doctored"
  [ "$status" -ne 0 ] || {
    echo "widening the bound to a five-digit value did not red" >&2
    return 1
  }
  printf '%s\n' "$output" | grep -qF -- "$ARMING_STEP_NAME" || {
    echo "the refusal did not name the step" >&2
    return 1
  }
}
