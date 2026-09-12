#!/usr/bin/env bats

# Structural guard for pnpm/Node provisioning attribution across the whole
# tree, not one workflow. Two things here were defended by nothing before
# this suite existed.
#
# THE PROVISIONING-STEP SET. `.gaia/tests/lib/audit-ci-shards.bats`'s W12
# reads `.github/workflows/*.yml`/`*.yaml` only, and its match predicate
# covers `gaia-setup-node` call sites only. It never opens the composite
# action itself, never reaches the adopter template directories, and says
# nothing about a direct `pnpm/action-setup` step. Its subject derivation is
# deliberately single-authority and its own reach tests exist to pin THAT
# authority, so extending it would introduce a second derivation into the
# suite built to prevent exactly that -- this is a sibling, not an extension,
# and it does not touch W12 or its fixtures.
#
# THE COMPOSITE'S OWN RETRY CONSTRUCT. Nothing in the tree pinned it: before
# this suite, a tree-wide search for its internal step names matched only the
# composite file itself. That is a real match-region failure
# (.claude/rules/guards-must-fail.md): `.github/actions/gaia-setup-node/
# action.yml` carries the literal text "timeout -k" in a DOCBLOCK COMMENT
# describing work this repo has deliberately deferred (gaia-react/gaia#1783),
# so a naive substring search for that text is satisfied by prose over a
# composite with no bounded install at all, structural or otherwise. This
# suite's construct check reads `runs.steps` as parsed YAML instead, and
# ships the substring search as its own companion assertion, proving the
# oracle it replaces was the wrong one.
#
# Discovery walks four roots (.github/workflows, .github/actions,
# .gaia/cli/src/automation/templates/workflows,
# .gaia/cli/templates/workflows) from the tracked tree via `git ls-files`,
# matching `uses:` on either arm: the composite's normalized local path, or
# `pnpm/action-setup` before its `@`. Most of the tracked files under the two
# template roots are Handlebars sources and are not YAML: an unrendered
# `{{VAR}}` or `{{> partial }}` token means the file will never parse, on
# purpose, so this suite excludes a file carrying one of those from the
# parseable set BY NAME of the reason rather than folding it into "failed to
# parse" -- that would be the same silent discard `.gaia/tests/lib/
# audit-ci-shards.bats`'s W12 guards against for an unreadable workflow, one
# layer down. A file with no such token that still will not parse IS a
# reported failure; the two are distinguished on content, never on a hand-
# maintained filename list.
#
# One line-level exception to the parse-everything rule: the adopter partial
# fragment (partials/node-setup.yml.tmpl) has no owning job of its own, so its
# cap requirement is resolved by scanning its SIBLING `gaia-ci-*.yml.tmpl`
# files for the include marker and the nearest preceding job-level cap. Those
# siblings carry Handlebars tokens and never parse as YAML, so this one scan
# reads them as lines -- the single deliberate exemption from the structural-
# parse mandate everywhere else in this file.
#
# Every check here is driven through a predicate that takes a file list as
# ARGUMENTS, never a predicate written inline against the live tree, so every
# adversarial fixture exercises the same code the real check runs. That is
# the same reasoning `.gaia/tests/lib/audit-ci-shards.bats` gives for its own
# `setup_node_cap_gaps`: a predicate that only ever runs against the healthy
# tree has every branch it takes be the passing one, so a broken predicate
# still reports green.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], no `!`-negated non-final assertion, POSIX [ ] / grep -q /
# explicit `return 1`.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.
#
# Relationship to the step-body extractor roster
# (`.gaia/scripts/check-step-body-extractor-roster.sh`): this suite names
# `code-review-audit.yml` -- it is one of the files the four discovery roots
# reach -- but it never extracts a step BODY out of it, and none of its own
# literals reproduce that check's six-space step-header prefix (this suite's
# own anchors sit at four-space job-level or eight-space step-level
# indentation instead). It is therefore not a candidate under that check's
# own predicate and needs no entry in either of its tables. Deliberately
# described rather than quoted here, so this paragraph does not itself
# become the six-space literal it is explaining the absence of.

# Same gate as the sibling suite's own: on a CI runner an absent path means a
# rename this suite has not been told about, so the CI branch FAILS rather
# than reporting a clean pass over files it never opened.
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

# audit-ci-tests.yml installs python3-yaml in the same job that runs this
# suite (the `lib` leg), so the CI branch FAILS rather than skips.
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
  ACTION_FILE="$REPO_ROOT/.github/actions/gaia-setup-node/action.yml"
  WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
  ACTIONS_DIR="$REPO_ROOT/.github/actions"
  SRC_TEMPLATES_DIR="$REPO_ROOT/.gaia/cli/src/automation/templates/workflows"
  BUILT_TEMPLATES_DIR="$REPO_ROOT/.gaia/cli/templates/workflows"
  CODE_REVIEW_AUDIT="$WORKFLOW_DIR/code-review-audit.yml"
  FORENSICS_TRIAGE="$WORKFLOW_DIR/forensics-triage.yml"
  TESTS_WORKFLOW="$WORKFLOW_DIR/tests.yml"
  PARTIAL_SRC="$SRC_TEMPLATES_DIR/partials/node-setup.yml.tmpl"
  PNPM_AUDIT_TMPL_SRC="$SRC_TEMPLATES_DIR/gaia-ci-pnpm-audit.yml.tmpl"

  require_repo_path -f "$ACTION_FILE" "gaia-setup-node/action.yml" || return 1
  require_repo_path -d "$WORKFLOW_DIR" ".github/workflows/" || return 1
  require_repo_path -d "$ACTIONS_DIR" ".github/actions/" || return 1
  require_repo_path -d "$SRC_TEMPLATES_DIR" \
    ".gaia/cli/src/automation/templates/workflows/" || return 1
  require_repo_path -d "$BUILT_TEMPLATES_DIR" \
    ".gaia/cli/templates/workflows/" || return 1
  require_repo_path -f "$CODE_REVIEW_AUDIT" "code-review-audit.yml" || return 1
  require_repo_path -f "$FORENSICS_TRIAGE" "forensics-triage.yml" || return 1
  require_repo_path -f "$TESTS_WORKFLOW" "tests.yml" || return 1
  require_repo_path -f "$PARTIAL_SRC" "partials/node-setup.yml.tmpl" || return 1
  require_repo_path -f "$PNPM_AUDIT_TMPL_SRC" "gaia-ci-pnpm-audit.yml.tmpl" || return 1

  # The four discovery roots -- .github/workflows, .github/actions, and the
  # two adopter template directories under .gaia/cli -- are the whole
  # tracked-tree surface that can carry a provisioning uses: line: the first
  # two are where a maintainer-authored workflow or composite action lives,
  # the other two are where the CLI renders and bundles the same shapes for
  # adopters. Derived from the tracked tree via git ls-files rather than
  # from a list kept beside this suite, so a call site added under any of
  # them is reached by construction rather than by remembering to widen a
  # hand-kept enumeration. `**` crosses directories under git's own pathspec
  # wildcard matching with no `:(glob)` magic needed for this shape.
  PROVISIONING_FILES=()
  local f
  while IFS= read -r -d '' f; do
    [ -n "$f" ] && PROVISIONING_FILES+=("$REPO_ROOT/$f")
  done < <(git -C "$REPO_ROOT" ls-files -z -- \
    '.github/workflows/*.yml' '.github/workflows/*.yaml' \
    '.github/actions/**/action.yml' \
    '.gaia/cli/src/automation/templates/workflows/**' \
    '.gaia/cli/templates/workflows/**')

  [ "${#PROVISIONING_FILES[@]}" -gt 0 ] || {
    echo "no files discovered across the four provisioning-discovery roots; every test here would assert over an empty set" >&2
    return 1
  }
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR:?}/partial-fixture" 2>/dev/null || true
}

# read_pv <mode> <file> -- structural reader over one provisioning-bearing
# file, parsed rather than scraped for the reason every sibling suite gives:
# a real parser already knows every shape a line scrape has to be taught one
# at a time.
#
#   steps <file>       One line per matching step, tab-separated:
#                       <surface>\t<job>\t<name>\t<match>\t<capkind>\t<cap>\t
#                       <job-capkind>\t<job-cap>. `surface` is `workflow` (a
#                       `jobs:` document), `composite` (a `runs.steps`
#                       document -- the action's OWN steps, `job` is `-` and
#                       `job-capkind` is the literal `exempt`, since a
#                       composite step cannot declare its own timeout and is
#                       bounded by its caller instead) or `partial` (a bare
#                       step-sequence document, `job` is `-` and
#                       `job-capkind` is the literal `external`, since the
#                       fragment has no owning job of its own -- see
#                       partial_job_cap_floor). `match` is `composite` or
#                       `direct`, mirroring the two match arms. Before
#                       parsing, the raw text is checked for an unrendered
#                       Handlebars token (`{{` not immediately preceded by
#                       `$`, which excludes a GitHub Actions `${{ }}`
#                       expression): a file carrying one prints the sentinel
#                       line `EXCLUDED-MUSTACHE` and exits 0 rather than
#                       attempting a parse that cannot succeed. Exits 2,
#                       naming the file, on a file with no such token that
#                       still will not parse, or that parses to neither a
#                       `jobs:` mapping, a `runs.steps` mapping, nor a bare
#                       step sequence.
#   construct <file>    Asserts the composite's own two-step retry over
#                       `runs.steps`: a first-attempt step carrying
#                       `continue-on-error: true`, an `id`, and a
#                       `pnpm/action-setup` `uses:`; then, later in the same
#                       list, a step whose `uses:` is also
#                       `pnpm/action-setup`, gated
#                       `if: steps.<that id>.outcome == 'failure'`, carrying
#                       NO `continue-on-error`. Exits 0 silently on success;
#                       exits 2 naming the missing half of the construct on
#                       failure, and naming unreadable YAML separately when
#                       that is why it could not check at all.
read_pv() {
  python3 - "$@" <<'PY'
import re
import sys

import yaml

mode = sys.argv[1]
path = sys.argv[2]


def die(msg):
    sys.stderr.write('%s: %s\n' % (path, msg))
    sys.exit(2)


def normalize(expr):
    """Collapse a gate to one comparable line: `if: <x>` and
    `if: ${{ <x> }}` are the same condition, and a folded scalar arrives
    already joined but irregularly spaced. Same fold every sibling suite
    applies."""
    return ' '.join(str(expr).replace('${{', ' ').replace('}}', ' ').split())


def kind_of(mapping):
    """The cap kind a job or step mapping declares: 'missing', 'other' (a
    bool or any non-int, which reads as uncapped downstream), or 'int'. One
    callee for both so a job cap and a step cap cannot answer the question
    differently."""
    if 'timeout-minutes' not in mapping:
        return 'missing'
    value = mapping['timeout-minutes']
    if isinstance(value, bool) or not isinstance(value, int):
        return 'other'
    return 'int'


def classify_uses(raw_uses):
    """'composite', 'direct', or None. Exact identity, never a substring: a
    sibling action named with this one as a prefix is a DIFFERENT action,
    and the `@`-pinned suffix is stripped before either comparison so a SHA
    bump cannot change the verdict. `uses:` legally spells the local action
    several ways (a leading `./`, a trailing `/`); the normalization has to
    reach every one of them, because a spelling it misses is SKIPPED rather
    than reported, which is a short read rather than an empty one."""
    used_full = str(raw_uses).strip()
    if not used_full:
        return None
    used = used_full.split('@', 1)[0]
    local = used[2:] if used.startswith('./') else used
    local = local.rstrip('/')
    if local == '.github/actions/gaia-setup-node':
        return 'composite'
    if used == 'pnpm/action-setup':
        return 'direct'
    return None


with open(path, encoding='utf-8') as handle:
    raw = handle.read()

if mode == 'steps':
    # A file carrying an unrendered Handlebars token is not YAML and never
    # will be until it is rendered; excluded from the parseable set BY
    # CONSTRUCTION, not reported as a parse failure. `${{ ... }}` (a GitHub
    # Actions expression, already valid in a rendered or pass-through
    # template) must not trip this: the negative lookbehind excludes any
    # `{{` immediately preceded by `$`.
    if re.search(r'(?<!\$)\{\{', raw):
        print('EXCLUDED-MUSTACHE')
        sys.exit(0)
    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        die('unreadable YAML (%s)' % exc.__class__.__name__)
    rows = []
    if isinstance(doc, dict) and isinstance(doc.get('jobs'), dict) and doc['jobs']:
        for jid, job in doc['jobs'].items():
            if not isinstance(job, dict):
                continue
            job_kind = kind_of(job)
            job_cap = job.get('timeout-minutes') if job_kind == 'int' else None
            for step in job.get('steps') or []:
                if not isinstance(step, dict):
                    continue
                match = classify_uses(step.get('uses', ''))
                if not match:
                    continue
                name = str(step.get('name', '')) or str(step.get('uses', ''))
                skind = kind_of(step)
                scap = step.get('timeout-minutes') if skind == 'int' else None
                rows.append(('workflow', str(jid), name, match, skind,
                             str(scap) if scap is not None else '-',
                             job_kind, str(job_cap) if job_cap is not None else '-'))
    elif isinstance(doc, dict) and isinstance(doc.get('runs'), dict):
        for step in doc['runs'].get('steps') or []:
            if not isinstance(step, dict):
                continue
            match = classify_uses(step.get('uses', ''))
            if not match:
                continue
            name = str(step.get('name', '')) or str(step.get('uses', ''))
            skind = kind_of(step)
            scap = step.get('timeout-minutes') if skind == 'int' else None
            rows.append(('composite', '-', name, match, skind,
                         str(scap) if scap is not None else '-', 'exempt', '-'))
    elif isinstance(doc, list):
        for step in doc:
            if not isinstance(step, dict):
                continue
            match = classify_uses(step.get('uses', ''))
            if not match:
                continue
            name = str(step.get('name', '')) or str(step.get('uses', ''))
            skind = kind_of(step)
            scap = step.get('timeout-minutes') if skind == 'int' else None
            rows.append(('partial', '-', name, match, skind,
                         str(scap) if scap is not None else '-', 'external', '-'))
    # Any other valid, parseable shape (a bare mapping fragment such as an
    # `env:` or `concurrency:` block, a null document, a bare scalar) has no
    # `steps:` a provisioning `uses:` could live under, so it contributes no
    # rows. This is not the unparseable-file arm: the document loaded fine,
    # it simply names nothing this check tracks.
    for row in rows:
        print('\t'.join(row))
elif mode == 'construct':
    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        die('unreadable YAML (%s)' % exc.__class__.__name__)
    if not (isinstance(doc, dict) and isinstance(doc.get('runs'), dict)):
        die('not a composite action (no runs: mapping)')
    steps = doc['runs'].get('steps')
    if not isinstance(steps, list) or not steps:
        die('composite declares no runs.steps')
    first_idx = None
    first_id = None
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        if (classify_uses(step.get('uses', '')) == 'direct'
                and step.get('continue-on-error') is True
                and step.get('id')):
            first_idx, first_id = i, str(step['id'])
            break
    if first_idx is None:
        die('no first-attempt pnpm/action-setup step carries continue-on-error: true with an id')
    retry_ok = False
    for step in steps[first_idx + 1:]:
        if not isinstance(step, dict):
            continue
        if classify_uses(step.get('uses', '')) != 'direct':
            continue
        gate = normalize(step.get('if', ''))
        if gate == "steps.%s.outcome == 'failure'" % first_id and 'continue-on-error' not in step:
            retry_ok = True
            break
    if not retry_ok:
        die("no retry pnpm/action-setup step gated on steps.%s.outcome == 'failure' carries zero continue-on-error" % first_id)
else:
    die('unknown mode %r' % mode)
PY
}

# Same shape as bats-shards.sh's own relativize: strips REPO_ROOT for a
# message that names a tracked path rather than this host's absolute one.
provisioning_rel_path() {
  case "$1" in
    "$REPO_ROOT"/*) printf '%s\n' "${1#"$REPO_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# The second, independent authority the empty/short-read guard compares
# against: a git grep over the four real discovery roots, anchored on
# `uses:` so the pinned-SHA header comments in forensics-triage.yml and
# audit-ci-tests.yml (which name pnpm/action-setup in prose) are not counted
# as steps. Always reads the REAL repository tree regardless of which files
# a caller's own file-list argument narrows to -- that independence is the
# whole point: a fixture narrowing the file-list argument still gets
# compared against the true tracked-tree count, not against itself.
provisioning_tracked_count() {
  git -C "$REPO_ROOT" grep -nE \
    'uses:[[:space:]]*(\./)?\.github/actions/gaia-setup-node|uses:[[:space:]]*pnpm/action-setup' \
    -- '.github/workflows' '.github/actions' \
       '.gaia/cli/src/automation/templates/workflows' '.gaia/cli/templates/workflows' \
    | grep -c ''
}

# partial_job_cap_floor <partial-file> -- the adopter partial fragment has no
# owning job of its own, so its cap requirement is resolved from the
# sibling `gaia-ci-*.yml.tmpl` files (in the SAME parent-of-parent directory
# as the partial, so a scratch copy under a mirrored two-level layout
# resolves its own siblings rather than the real tree's) that include it.
# Every such sibling carries an unrendered Handlebars token and therefore
# never parses as YAML (see read_pv's mode == 'steps' above), so this is a
# LINE-level read by construction -- the one deliberate exemption from the
# structural-parse mandate everywhere else in this file. It tracks the
# nearest preceding job-level (4-space) integer `timeout-minutes:` as it
# scans down each file and prints that value at each include-marker line, so
# an include inside a second job in the same file (gaia-ci-update-deps.yml.tmpl's
# `run` and `wave_b`) resolves against ITS OWN job rather than the first.
# Prints the minimum across every occurrence found; returns 1 with no output
# when no sibling includes the partial at all, which the caller must read as
# a refusal, not a pass.
partial_job_cap_floor() {
  local partial_file="$1" root tmpl floor="" cap
  root="$(dirname "$(dirname "$partial_file")")"
  for tmpl in "$root"/gaia-ci-*.yml.tmpl; do
    [ -f "$tmpl" ] || continue
    while IFS= read -r cap; do
      [ -n "$cap" ] || continue
      if [ -z "$floor" ] || [ "$cap" -lt "$floor" ]; then
        floor="$cap"
      fi
    done < <(awk '
      /^    timeout-minutes: [0-9]+$/ { cap = $0; sub(/^    timeout-minutes: /, "", cap) }
      /\{\{> partials\/node-setup \}\}/ { if (cap != "") print cap }
    ' "$tmpl")
  done
  [ -n "$floor" ] || return 1
  printf '%s' "$floor"
}

# provisioning_attribution_gaps <file>... -- every attribution gap the given
# files present, one per line, empty when there are none. Mirrors
# `.gaia/tests/lib/audit-ci-shards.bats`'s own `setup_node_cap_gaps` in
# shape: a per-file read whose failure becomes a reported gap rather than a
# silent contribution of zero, an emptiness verdict over the WHOLE argument
# list (never per file, since most files legitimately call neither action
# from any step), and a short-read verdict this suite adds on top, comparing
# against the independent tracked-tree count above. Returns non-zero exactly
# when `gaps` is non-empty OR the derived set came back empty.
provisioning_attribution_gaps() {
  local file rel gaps="" derived=0 floor
  local out="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/provisioning-steps.$$"
  local err="${out}.err"

  for file in "$@"; do
    rel="$(provisioning_rel_path "$file")"
    if ! read_pv steps "$file" >"$out" 2>"$err"; then
      gaps="${gaps}${rel}: could not be read (unparseable YAML), so its provisioning steps were never opened -- $(cat "$err")"$'\n'
      continue
    fi
    if [ "$(head -n1 "$out")" = "EXCLUDED-MUSTACHE" ]; then
      continue
    fi
    # shellcheck disable=SC2034  # match (composite/direct) is a positional field in the tab-separated row read_pv prints; kept named and in place so the fields after it are not shifted, even though `surface` alone decides the branch below
    while IFS=$'\t' read -r surface job name match capkind cap jobcapkind jobcap; do
      [ -n "$surface" ] || continue
      derived=$((derived + 1))
      case "$surface" in
        composite)
          # Counted above; exempt here from the cap requirement, because a
          # composite step cannot declare its own timeout-minutes and is
          # bounded by its caller instead.
          continue
          ;;
        workflow)
          if [ "$capkind" != "int" ]; then
            gaps="${gaps}${rel} ${job}/${name}: cap is ${capkind}, not an integer literal"$'\n'
          elif [ "$jobcapkind" != "int" ]; then
            gaps="${gaps}${rel} ${job}/${name}: the owning job declares no integer cap"$'\n'
          elif [ "$cap" -ge "$jobcap" ]; then
            gaps="${gaps}${rel} ${job}/${name}: ${cap}m is not under the job's ${jobcap}m"$'\n'
          fi
          ;;
        partial)
          floor="$(partial_job_cap_floor "$file")" || floor=""
          if [ "$capkind" != "int" ]; then
            gaps="${gaps}${rel} ${name}: cap is ${capkind}, not an integer literal"$'\n'
          elif [ -z "$floor" ]; then
            gaps="${gaps}${rel} ${name}: no including gaia-ci-*.yml.tmpl template found, so the owning job cap cannot be resolved"$'\n'
          elif [ "$cap" -ge "$floor" ]; then
            gaps="${gaps}${rel} ${name}: ${cap}m is not under the including templates' floor of ${floor}m"$'\n'
          fi
          ;;
      esac
    done < "$out"
  done
  rm -f "$out" "$err"

  # One condition reaches an empty read: every readable file loaded and none
  # of them called either action, so it was renamed or its last call site
  # was removed. Checked before the short-read comparison below, which needs
  # a non-zero derived count to be a meaningful ratio at all.
  if [ "$derived" -eq 0 ]; then
    printf 'no provisioning step read across the files scanned, though every readable one loaded: both actions were renamed, or every call site was removed. Either way this check is now reaching nothing.\n'
    return 1
  fi

  local tracked
  tracked="$(provisioning_tracked_count)"
  if [ "$derived" -lt "$tracked" ]; then
    gaps="${gaps}derived set holds ${derived} provisioning step(s) across the files scanned; the tracked-tree git grep over the four discovery roots holds ${tracked}. This discovery is reading fewer call sites than exist."$'\n'
  fi

  printf '%s' "$gaps"
  [ -z "$gaps" ]
}

# ---- Doctoring helpers, copied from .gaia/tests/lib/audit-ci-shards.bats ----
# bats defines no functions across files; the contracts below are kept
# identical to that suite's copies on purpose, so a scratch fixture built
# with one behaves exactly as it would there.

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

assert_doctored() {
  local original="$1" doctored="$2" what="$3"
  [ "$doctored" != "$original" ] || {
    echo "$what: left the line unchanged, so the case would assert against an undoctored file" >&2
    echo "line: $original" >&2
    return 1
  }
}

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

# ---------------------------------------------------------------------------

@test "every provisioning step across the four discovery roots is capped, attributed, and complete" {
  require_yaml_parser
  local gaps
  gaps="$(provisioning_attribution_gaps "${PROVISIONING_FILES[@]}")" || {
    echo "$gaps" >&2
    return 1
  }
  [ -z "$gaps" ] || { echo "$gaps" >&2; return 1; }
}

@test "the composite pins a continue-on-error first attempt and a no-continue-on-error outcome-gated retry" {
  require_yaml_parser
  run read_pv construct "$ACTION_FILE"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# The companion assertion the header describes: a bare substring search for
# the composite's bounded-install literal is satisfied by the docblock
# comment alone, on the file exactly as it stands, which is what makes the
# structural check above load-bearing rather than decorative.
@test "a bare substring search for the composite's bounded-install literal is satisfied by prose alone" {
  run grep -n 'timeout -k' "$ACTION_FILE"
  [ "$status" -eq 0 ] || {
    echo "expected 'timeout -k' to appear in $ACTION_FILE (it lives in a docblock comment, not a bounded run: step); its absence would mean this companion assertion no longer demonstrates anything" >&2
    return 1
  }
}

@test "gap: a provisioning step with no cap is reported as missing, not as a clean read" {
  require_yaml_parser
  local line doctored="$BATS_TEST_TMPDIR/no-cap.yml" gaps
  line="$(sole_line_matching "$CODE_REVIEW_AUDIT" '^        timeout-minutes: 5$')" || return 1
  delete_line "$CODE_REVIEW_AUDIT" "$line" "$doctored"

  gaps="$(provisioning_attribution_gaps "$doctored")" && {
    echo "deleting the step's cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'cap is missing, not an integer literal' || {
    echo "an absent step cap was not reported as missing: ${gaps}" >&2
    return 1
  }
}

@test "gap: an expression-valued cap is reported as non-integer, not as a clean read" {
  require_yaml_parser
  local line mutated doctored="$BATS_TEST_TMPDIR/expr-cap.yml" gaps
  line="$(sole_line_matching "$CODE_REVIEW_AUDIT" '^        timeout-minutes: 5$')" || return 1
  mutated='        timeout-minutes: ${{ github.event_name }}'
  assert_doctored "$line" "$mutated" "widening the cap to an expression" || return 1
  replace_line "$CODE_REVIEW_AUDIT" "$line" "$mutated" "$doctored"

  gaps="$(provisioning_attribution_gaps "$doctored")" && {
    echo "an expression-valued step cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'cap is other, not an integer literal' || {
    echo "an expression-valued step cap was not reported as non-integer: ${gaps}" >&2
    return 1
  }
}

@test "gap: a step cap at or above its owning job's cap is reported as not under it" {
  require_yaml_parser
  local line mutated doctored="$BATS_TEST_TMPDIR/cap-at-job.yml" gaps
  line="$(sole_line_matching "$CODE_REVIEW_AUDIT" '^        timeout-minutes: 5$')" || return 1
  mutated="        timeout-minutes: 60"
  assert_doctored "$line" "$mutated" "raising the step cap to the job's own cap" || return 1
  replace_line "$CODE_REVIEW_AUDIT" "$line" "$mutated" "$doctored"

  gaps="$(provisioning_attribution_gaps "$doctored")" && {
    echo "a step cap equal to the job's own 60m left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF "60m is not under the job's 60m" || {
    echo "a step cap equal to the job's cap was not reported as over-capped: ${gaps}" >&2
    return 1
  }
}

@test "gap: a step whose owning job declares no integer cap is reported" {
  require_yaml_parser
  local line doctored="$BATS_TEST_TMPDIR/no-job-cap.yml" gaps
  line="$(sole_line_matching "$CODE_REVIEW_AUDIT" '^    timeout-minutes: 60$')" || return 1
  delete_line "$CODE_REVIEW_AUDIT" "$line" "$doctored"

  gaps="$(provisioning_attribution_gaps "$doctored")" && {
    echo "removing the owning job's own cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'the owning job declares no integer cap' || {
    echo "a step whose job declares no cap was not reported: ${gaps}" >&2
    return 1
  }
}

@test "gap: every call site renamed away fires the empty-set refusal rather than a clean pass" {
  require_yaml_parser
  local line mutated doctored="$BATS_TEST_TMPDIR/renamed.yml" gaps
  line="$(sole_line_matching "$CODE_REVIEW_AUDIT" \
    '^        uses: pnpm/action-setup@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6\.0\.10$')" || return 1
  mutated="        uses: pnpm/action-setup-renamed@0977fd99725f1db4007ccb2928dbb4e90d06cc86 # v6.0.10"
  assert_doctored "$line" "$mutated" "renaming the call site away" || return 1
  replace_line "$CODE_REVIEW_AUDIT" "$line" "$mutated" "$doctored"

  gaps="$(provisioning_attribution_gaps "$doctored")" && {
    echo "renaming the only call site away left the check reporting a clean read" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'this check is now reaching nothing' || {
    echo "an empty enumeration was not reported as reaching nothing: ${gaps}" >&2
    return 1
  }
}

# The one fixture here that passes TWO files, and it has to. The arm it
# drives only differs from a no-op the moment a healthy sibling is present to
# be counted normally alongside it: an unreadable file passed alone trips the
# empty-read arm either way, so a single-file fixture would pass against a
# check that swallowed the failure silently.
@test "gap: a file that will not parse is reported, not skipped, when passed beside a healthy one" {
  require_yaml_parser
  local line doctored="$BATS_TEST_TMPDIR/unparseable.yml" gaps
  line="$(sole_line_matching "$CODE_REVIEW_AUDIT" '^jobs:$')" || return 1
  replace_line "$CODE_REVIEW_AUDIT" "$line" "jobs: {" "$doctored"

  gaps="$(provisioning_attribution_gaps "$doctored" "$FORENSICS_TRIAGE")" && {
    echo "an unparseable file beside a healthy one left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'could not be read (unparseable YAML)' || {
    echo "an unparseable file was silently skipped rather than reported: ${gaps}" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF "$(basename "$doctored")" || {
    echo "the unparseable-file gap did not name the file: ${gaps}" >&2
    return 1
  }
}

@test "construct gap: removing continue-on-error from the first attempt names that construct" {
  require_yaml_parser
  local line doctored="$BATS_TEST_TMPDIR/no-continue-on-error.yml"
  line="$(sole_line_matching "$ACTION_FILE" '^      continue-on-error: true$')" || return 1
  delete_line "$ACTION_FILE" "$line" "$doctored"

  run read_pv construct "$doctored"
  [ "$status" -ne 0 ] || {
    echo "removing continue-on-error from the first attempt left the construct check passing" >&2
    return 1
  }
  printf '%s' "$output" | grep -qF 'no first-attempt pnpm/action-setup step carries continue-on-error: true with an id' || {
    echo "the missing continue-on-error was not named: ${output}" >&2
    return 1
  }
}

@test "construct gap: the retry step carrying continue-on-error is no longer the last word, and is named" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/retry-continue-on-error.yml"
  sole_line_matching "$ACTION_FILE" '^    - name: Retry the pnpm install$' >/dev/null || return 1
  insert_after "$ACTION_FILE" "    - name: Retry the pnpm install" \
    "      continue-on-error: true" "$doctored"
  cmp -s "$ACTION_FILE" "$doctored" && {
    echo "the retry step name is stale, so doctoring changed nothing and this fixture proves nothing" >&2
    return 1
  }

  run read_pv construct "$doctored"
  [ "$status" -ne 0 ] || {
    echo "giving the retry step its own continue-on-error left the construct check passing" >&2
    return 1
  }
  printf '%s' "$output" | grep -qF "no retry pnpm/action-setup step gated on steps.install-pnpm.outcome == 'failure' carries zero continue-on-error" || {
    echo "the retry step's construct violation was not named: ${output}" >&2
    return 1
  }
}

@test "gap: the partial fragment with its own cap removed reds against the resolved job-cap floor" {
  require_yaml_parser
  local fixture_root="$BATS_TEST_TMPDIR/partial-fixture" doctored line gaps
  mkdir -p "$fixture_root/partials"
  cp "$PNPM_AUDIT_TMPL_SRC" "$fixture_root/$(basename "$PNPM_AUDIT_TMPL_SRC")"
  doctored="$fixture_root/partials/$(basename "$PARTIAL_SRC")"
  line="$(sole_line_matching "$PARTIAL_SRC" '^        timeout-minutes: 5$')" || return 1
  delete_line "$PARTIAL_SRC" "$line" "$doctored"

  gaps="$(provisioning_attribution_gaps "$doctored")" && {
    echo "removing the partial's own cap left the check reporting no gaps" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF 'cap is missing, not an integer literal' || {
    echo "the partial's missing cap was not reported: ${gaps}" >&2
    return 1
  }
}

@test "gap: a root set narrower than the tracked tree fires the short-read refusal, naming the difference" {
  require_yaml_parser
  local tracked gaps
  tracked="$(provisioning_tracked_count)"

  # A single real, healthy file rather than the full four-root set: the
  # structural read of it is clean on its own terms (it has no attribution
  # gap of its own), so only the independent tracked-tree comparison can
  # catch that this is not the whole tree.
  gaps="$(provisioning_attribution_gaps "$FORENSICS_TRIAGE")" && {
    echo "narrowing the scanned set to one file left the check reporting a clean read" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF "derived set holds 1 provisioning step(s)" || {
    echo "the short read did not name its own derived count: ${gaps}" >&2
    return 1
  }
  printf '%s' "$gaps" | grep -qF "holds ${tracked}" || {
    echo "the short read did not name the independently tracked count (${tracked}): ${gaps}" >&2
    return 1
  }
}

# The fixture that inverts every adversarial one above: it doctors a LEGAL
# alternate uses: spelling and asserts the check still reads the step, rather
# than asserting a gap. `uses:` accepts more than one spelling of the same
# local action, and a spelling the normalization misses is SKIPPED rather
# than reported, which the surviving call sites elsewhere in the tree would
# hide as a short read rather than an empty one. Because this fixture asserts
# the HEALTHY outcome, which a no-op doctoring also produces, it has to
# compare the two files itself rather than lean on assert_doctored.
@test "normalization: a trailing slash on the composite's local uses: path still reads the step" {
  require_yaml_parser
  local doctored="$BATS_TEST_TMPDIR/trailing-slash.yml" rows
  replace_line "$TESTS_WORKFLOW" "        uses: ./.github/actions/gaia-setup-node" \
    "        uses: ./.github/actions/gaia-setup-node/" "$doctored"
  cmp -s "$TESTS_WORKFLOW" "$doctored" && {
    echo "the composite's uses: spelling in tests.yml is stale, so doctoring changed nothing and this fixture proves nothing" >&2
    return 1
  }

  # Read at the structural level rather than through the full gaps
  # aggregator: the aggregator's own short-read comparison (this suite's
  # addition over the tracked-tree count) would fire on any single-file
  # argument regardless of normalization, which would test the wrong thing
  # here. What this fixture is about is narrower -- does the match predicate
  # still recognize the doctored spelling at all.
  rows="$(read_pv steps "$doctored")" || {
    echo "a trailing-slash spelling left the file unreadable: ${rows}" >&2
    return 1
  }
  printf '%s' "$rows" | grep -qF "$(printf '\tcomposite\t')" || {
    echo "a trailing-slash spelling was not recognized as a composite match: ${rows}" >&2
    return 1
  }
}
