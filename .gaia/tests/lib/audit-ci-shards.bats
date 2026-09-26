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
  # under a fixtures/ sibling of this suite's directory.
  SPEC078_FIXTURES="$BATS_TEST_DIRNAME/fixtures/spec-078"
  # The dorny/paths-filter version lever one's premises were verified
  # against, recorded once here so W14 and its header comment cannot
  # disagree with each other about which pin they mean.
  PATHS_FILTER_PINNED_SHA='ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d'
  PATHS_FILTER_PINNED_TAG='v4.0.3'

  require_repo_path -f "$WORKFLOW" "audit-ci-tests.yml" || return 1
  require_repo_path -f "$POLLER_WORKFLOW" "code-review-audit.yml" || return 1
  require_repo_path -f "$CLI_WORKFLOW" "cli-tests.yml" || return 1
  require_repo_path -d "$WORKFLOW_DIR" ".github/workflows/" || return 1
  require_repo_path -f "$BATS_SHARDS" "bats-shards.sh" || return 1
  require_repo_path -f "$SPEC078_FIXTURES/paths-filter-pin-bumped.yml" \
    "fixtures/spec-078/paths-filter-pin-bumped.yml" || return 1

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
#   runinterp               one `<job-id>\t<step-name>` line per step whose RAW
#                         (unnormalized) `run:` body contains a literal `${{`
#   setupnodecaps          one
#                         `<job-id>\t<step-name>\t<capkind>\t<cap>\t<job-cap>`
#                         line per step whose `uses:`, normalized, is exactly
#                         the gaia-setup-node composite action or a bare
#                         `actions/setup-node`, across EVERY
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
            # Exact on each action's identity, not a substring of its path: a
            # sibling action named with one of these as a prefix
            # (`gaia-setup-node-foo`) is a DIFFERENT action, and a substring
            # test would report it under this check's name while missing that
            # the real one had been renamed away. Normalized first because
            # `uses:` legally spells the same local action several ways, and
            # the normalization has to reach every one of them: a spelling it
            # misses is SKIPPED rather than reported, which is a short read
            # rather than an empty one, so the sites spelled the expected way
            # keep `setup_node_cap_gaps` out of its empty-set arm and the check
            # reports clean over a step it never opened.
            #
            # Two identities, because a workflow provisions Node either
            # through the composite or by calling `actions/setup-node`
            # itself, and an uncapped step of either shape burns the owning
            # job's whole cap and reds as a job timeout attributed to no
            # step. The marketplace ref is compared BEFORE the `./` strip:
            # `./actions/setup-node` names a local action in this repository
            # that happens to share the path, which is a different thing.
            raw = str(step.get('uses', '')).strip().split('@', 1)[0]
            local = raw[2:] if raw.startswith('./') else raw
            local = local.rstrip('/')
            if (local != '.github/actions/gaia-setup-node'
                    and raw != 'actions/setup-node'):
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
# PATHS_FILTER_PINNED_TAG, the pair lever one's premises were verified
# against. A version drift moving either half invalidates those premises
# silently -- a grouped dependency bump nobody reads closely -- so the refusal names both recorded values and where to
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
  echo "$workflow pins dorny/paths-filter@$sha ($tag), lever one's premises, were verified against $PATHS_FILTER_PINNED_SHA ($PATHS_FILTER_PINNED_TAG). Re-derive against the pinned source at the new SHA: the accepted change-status set (file.ts:6-13) and its unvalidated per-entry cast (filter.ts:171-176); the plain array membership check that lets an unrecognized token match nothing forever (filter.ts:123-125); and the pull-request lane's rename decomposition -- the token input defaults to github.token (action.yml:5-8), so this lane takes getChangedFilesFromApi (main.ts:101-107), which replaces a renamed row with an added-new-path row plus a deleted-previous-path row (main.ts:227-239)." >&2
  return 1
}

# The parser gate above is the single point where every parser-gated test in
# this file, W10 among them, can be turned off at once, and nothing else here
# would notice if it started skipping on CI: a lib leg that lost python3-yaml
# would report `ok ... # skip` for each of them and green the job with the
# shard-list invariant retired. This test is what makes that weakening red.
# Same shape as the sibling gates' own proving tests in
# workflow-filter-coverage.bats and retrigger-reachability.bats. Not itself
# gated.

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
# shards' gated steps is or implies .gaia/release-exclude (each names a
# runner, an installer, or a composite action, never the files those read),
# so it is a transitive input that guard never reaches. These two tests are
# the regression guard for the lines SPEC-072 added to close that hole.
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

@test "W11: audit-ci-tests.yml's code filter lists release-exclude" {
  require_yaml_parser
  local list
  list="$(read_wf codefilter "$WORKFLOW" shards)"
  printf '%s\n' "$list" | grep -qxF -- '.gaia/release-exclude' || {
    echo "audit-ci-tests.yml's code: filter is missing .gaia/release-exclude" >&2
    return 1
  }
}

@test "W11: cli-tests.yml's distribution-harness code filter lists the release manifest" {
  require_yaml_parser
  local list
  list="$(read_wf codefilter "$CLI_WORKFLOW" distribution-harness)"
  printf '%s\n' "$list" | grep -qxF -- '.gaia/manifest.json' || {
    echo "cli-tests.yml's distribution-harness code: filter is missing .gaia/manifest.json" >&2
    return 1
  }
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
  line="$(sole_line_matching "$CLI_WORKFLOW" "^ *- '\\.gaia/manifest\\.json'\$")" || return 1
  delete_line "$CLI_WORKFLOW" "$line" "$doctored"

  local list
  list="$(read_wf codefilter "$doctored" distribution-harness)"
  printf '%s\n' "$list" | grep -qxF -- '.gaia/manifest.json' && {
    echo "deleting the manifest filter line did not drop it from the parsed code: list" >&2
    return 1
  }
  true
}

# read_wf codefilter unwraps a change-type mapping entry (`- deleted: 'x'`)
# to its bare value. Doctored onto .gaia/release-exclude, a bare entry, so the
# doctored line always differs from the real one; W11's own adversarial case
# above already derives that same line, so the pattern is proven.

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
# forever. This sweeps every code: entry for the two tokens the action
# accepts but this repository forbids, `renamed` and `copied` -- both are
# redundant with `deleted` on the pull-request lane, which decomposes a
# rename into a delete of the previous path plus an add of the new one
# before matching: the `token` input defaults to github.token
# (action.yml:5-8), so the pull-request lane takes
# getChangedFilesFromApi (main.ts:101-107), which does exactly that
# decomposition (main.ts:227-239).

@test "W13: no code: filter entry anywhere carries a renamed or copied change-type token" {
  require_yaml_parser
  assert_no_renamed_or_copied_tokens "$WORKFLOW"
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
# workflow's dorny/paths-filter version to the pair lever one's premises were
# verified against.

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

# W12. Every Node-provisioning step in EVERY workflow is capped with an integer
# literal that fires before its job's own cap. Two step shapes provision Node,
# the `gaia-setup-node` composite and a bare `actions/setup-node`, and the
# attribution argument below is indifferent to which one stalls, so the subject
# set holds both. A workflow-level step is the only surface that can carry the
# cap at all: a composite action's own steps take no `timeout-minutes`, which is
# why the composite is bounded from its caller and why a direct call site has to
# declare its own. This check never opens the composite -- its subject set is
# `.github/workflows/` -- so that exemption needs no arm here; the sibling suite
# `.gaia/tests/lib/provisioning-attribution.bats`, whose discovery does reach
# `.github/actions`, is where it is spelled out.
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
# the same move applied to two of the axes this check can be narrowed on.
# Neither is a convenience: each is what keeps a site added later reachable
# without an edit here, and a check narrowed on either axis reports clean over
# what it never opened.
#
# The identity set is the third axis, and it is the one the first two cannot
# widen for themselves: a step spelled with an action this matcher does not
# admit is outside the check however many files and steps the other two reach,
# and a workflow holding only such steps reports clean. gaia-react/gaia#2042 is
# that axis narrowing in the same shape the other two already had: the caps on
# the direct `actions/setup-node` call sites were added with nothing holding
# them, so deleting one left every assertion here green. The fixtures at the end
# of this block pin the added arm on its own file, where a doctored cap cannot
# be answered for by a composite call site in the same workflow.
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
# a job-level `timeout-minutes:` declaration, which sits at four spaces.
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

# Every capping gap the Node-provisioning steps in <workflow-file>... present,
# one line per gap, each naming its own workflow, empty when they have none.
# Returns non-zero when NO step was read across the whole argument list, which
# is a gap of its own rather than a clean read: this enumerates its subjects
# from the `uses:` value instead of pinning them, so a renamed action yields
# nothing and would otherwise be indistinguishable from every step passing.
#
# The emptiness verdict is over the whole list, not per file. Most workflows
# legitimately provision Node from no step at all, so a per-file verdict would
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
      gaps="${gaps}${wf}: could not be read (unparseable YAML, or no jobs mapping), so its Node-provisioning steps were never opened"$'\n'
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
  # provisioned Node, so both actions were renamed or their last call sites
  # removed. The
  # unreadable-file case used to land here too and no longer does; it is a
  # named gap above, which is the stronger report because it says which file.
  # Guarded on `gaps` as well as `seen` so a run whose only workflows were
  # unreadable reports them rather than replacing them with this message.
  if [ -z "$seen" ] && [ -z "$gaps" ]; then
    printf 'no Node-provisioning step read across the workflows scanned, though every one of them loaded. Both actions this check admits were renamed, or their last call sites were removed. Either way this check is now reaching nothing.\n'
    return 1
  fi

  printf '%s' "$gaps"
  [ -z "$gaps" ]
}

# The workflow files in <workflow-file>... that provision Node from at
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

@test "W12: every Node-provisioning step declares an integer cap under its job's cap" {
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

@test "W12 reach: Node-provisioning call sites are read across more than one workflow" {
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
    echo "Node-provisioning steps were read from $scanned workflow(s); the check has re-narrowed to a single file" >&2
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

@test "W12 adversarial: a workflow with no Node-provisioning step reds rather than passing empty" {
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

# The premise the two fixtures below rest on: this workflow provisions Node with
# a direct `actions/setup-node` step and with nothing else. Asserted rather than
# assumed, because a composite call site added to the same file later would
# answer for both of them through the arm that already existed, leaving each one
# green while it proved nothing about the direct arm it was written for. That is
# the same silent-widening failure the fixtures exist to catch, one layer up.
assert_direct_only_provisioning() {
  grep -qE '^[[:space:]]*uses:[[:space:]]*(\./)?\.github/actions/gaia-setup-node' "$1" && {
    echo "$(basename "$1") now calls the gaia-setup-node composite as well, so it no longer isolates the direct actions/setup-node arm" >&2
    return 1
  }
  grep -qE '^[[:space:]]*uses:[[:space:]]*actions/setup-node@' "$1" || {
    echo "$(basename "$1") no longer carries a direct actions/setup-node step, so a fixture resting on it proves nothing" >&2
    return 1
  }
}

@test "W12 reach: a workflow provisioning Node only through a direct actions/setup-node step is read" {
  require_yaml_parser
  local gaps
  assert_direct_only_provisioning "$POLLER_WORKFLOW" || return 1

  # The clean read IS the claim. While the matcher admitted the composite
  # alone, this file contributed no step at all and the predicate answered with
  # its empty-set refusal, so a non-zero status here is the check re-narrowing
  # to the composite rather than a capping gap.
  gaps="$(setup_node_cap_gaps "$POLLER_WORKFLOW")" || {
    echo "a workflow whose only Node provisioning is a direct actions/setup-node step read as reaching nothing: ${gaps}" >&2
    return 1
  }
  [ -z "$gaps" ] || { echo "$gaps" >&2; return 1; }
}

@test "W12 adversarial: a direct actions/setup-node step with no cap is caught" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/w12i.yml" gaps
  assert_direct_only_provisioning "$POLLER_WORKFLOW" || return 1

  delete_line "$POLLER_WORKFLOW" "        timeout-minutes: 3" "$doctored"
  cmp -s "$POLLER_WORKFLOW" "$doctored" && {
    echo "the direct step's cap literal is stale, so doctoring changed nothing and this fixture proves nothing" >&2
    return 1
  }

  gaps="$(setup_node_cap_gaps "$doctored")" && {
    echo "deleting the direct actions/setup-node step's cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'cap is missing, not an integer literal' || {
    echo "an absent cap on a direct actions/setup-node step was not reported as missing: ${gaps}" >&2
    return 1
  }
}


