#!/usr/bin/env bats
# Executable-truth coverage for the shell fences in
# `wiki/concepts/PR Merge Workflow.md`.
#
# Why this suite exists, and how it differs from every other prose suite in
# this directory. The existing prose suites (doc-machinery-waive-prose.bats,
# doc-countability-prose.bats, doc-debt-query.bats, ...) assert phrase
# presence, phrase absence, or cross-file byte-identity. All of them enforce
# prose-to-prose consistency, and none of them can tell whether a sentence is
# TRUE. A claim can be identical across five files, pinned by four tests, and
# false in all five; that is close to what #1537 turned out to be.
#
# `.claude/rules/pr-merge.md` makes reading that page a precondition of
# `gh pr merge` ("do not merge from memory"), so every command line in it is
# executable instruction: an agent reads the page and runs what it says. This
# suite treats the fences as the contract they already are.
#
# Three lenses, weakest to strongest:
#
#   1. The fence SET is covered. Every shell fence in the page matches exactly
#      one entry in the disposition table below, and every entry matches
#      exactly one fence. A fence added to the page with no entry stops this
#      suite, which is what forces the "can this one run here?" decision to be
#      made rather than skipped.
#   2. Every fence, runnable or not, parses; every repo path it cites exists;
#      and every `--flag` it hands a repo script is a flag that script accepts.
#      This is the lens that catches a rename or a flag drift in a fence
#      nobody can execute, which is most of them.
#   3. The runnable fences are EXECUTED, and the page's own stated outcome is
#      asserted against what they actually do.
#
# The fence body is pulled out of the page at run time and executed, never
# transcribed into this file. That is the whole point: a transcription would
# make this one more prose-to-prose suite, green while the page drifts. Where
# a fence carries a placeholder (`<N>`, `<wave-stamp>`) or reaches the
# network, the test substitutes a fixture value into the extracted body by
# literal replacement, and says at the substitution site what it replaced and
# why.
#
# Honest limits, stated rather than implied:
#
#   - The fences that cannot run here at all, the ones reaching github.com and
#     the ones mutating this checkout, get lens 2 only. The disposition table
#     carries the reason per fence, which is the per-entry warrant, so this
#     names the set rather than counting it or listing it a second time.
#   - Lens 2's flag check proves a script still carries a parse arm for the
#     flag, not that the arm does what the page says it does. It is anchored
#     to the arm rather than matching the file anywhere, because a flag
#     deleted from a `case` and left behind in a usage comment would otherwise
#     keep the lens green, which is the shape it exists to catch.
#   - Nothing here reads the page's prose. A false sentence sitting beside a
#     correct fence is invisible to this suite. That class has no oracle in
#     this repository and is addressed by procedure instead: the page's own
#     `### 2. Fix all issues` tells the sweep to grep the tree for the claim
#     rather than re-read a citation list, and states when the sweep has
#     converged.
#   - Backticked repo paths in the page's BODY PROSE are already covered, for
#     the whole wiki rather than this page, by `gaia wiki dead-paths` behind
#     the lint stage of `/gaia-wiki`. That primitive reads inline code spans, which fence
#     bodies are not, so the two divide the surface rather than overlap; a
#     path lens over prose here would be a second copy of it.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of wiki-style.md's scope.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/wiki/concepts/PR Merge Workflow.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Disposition table
#
# One row per shell fence, `id|anchor|mode|note`. The anchor is a literal
# substring that identifies exactly one fence; lens 1 proves that, so a
# copy-paste that makes two fences share an anchor stops the suite instead of
# silently halving its coverage. Line numbers are deliberately not used: they
# rot on the first edit above them, and a rotted anchor here would point at
# the wrong fence while still matching.
#
# mode `exec` promises a runner @test below whose name contains the id; lens 1
# checks that promise, so an `exec` row with no runner is a hole that fails
# rather than a row nobody notices.
# ---------------------------------------------------------------------------
fence_table() {
  cat <<'TABLE'
fork-check|--json isCrossRepository|static|reaches github.com for a live PR's fork flag
audit-check-state|grep GAIA-Audit|static|reaches github.com for a live PR's check rows
catchup-merge|git merge --no-edit origin/main|static|merges `origin/main` into this checkout
spawn-roster|resolve-audit-members.sh|exec|runs verbatim against this checkout
noop-classify|audit-noop-detect.sh --shape audit-team-member|exec|runs against a fixture root, marker and sidecar
wave-stamp|WAVE_STAMP="$(mktemp)"|exec|runs verbatim, and the claim under test is where mktemp puts the file
loop-round-index|audit-loop-eval.sh current-round|exec|runs against a fixture branch whose seeded history records two rounds
fix-baseline|audit-fix-verify.sh baseline --root|exec|runs against a clean fixture checkout, and against a dirty one it must refuse, writing into a fixture run folder
fixer-classify|audit-noop-detect.sh --shape agent-report-file|exec|runs against fixture fixer results, one complete and one short
fix-verify|audit-fix-verify.sh check --root|static|needs a live round's dispositions, baseline, fixer result and the digests recorded for them
fix-stage-delta|.changed_paths[], .reverted_paths[]|exec|runs against a fixture checkout and run folder, and the claim under test is which paths it stages
gate-paths|gate_snapshot() {|exec|runs against a fixture checkout with a stand-in autofix substituted for the gate placeholder
fix-round-check|audit-fix-verify.sh round-check|exec|runs against a fixture run folder with and without a passing verifier output
filing-reconcile|audit-dispositions-check.sh check-outcomes|static|needs a live round's dispositions file and the outcome file the filing script wrote against a live issue backend
record-publish|audit-loop-record.sh --pr <N> --values-json -|static|rewrites a live PR's body
checkpoint-brief|audit-loop-eval.sh brief --root|static|needs a branch history with recorded rounds and a pending checkpoint
resume-drift|audit-fix-verify.sh drift --root|exec|runs against a fixture checkout before and after a stand-in fixer edit
residual-enumerate|gh pr list --state merged|exec|the --jq PROGRAM TEXT is extracted and run against the committed residue-corpus fixture, standing in for the network call
findings-block|post-findings-block.sh --pr|static|posts a comment to a live PR
post-status|post-audit-status.sh <current-member-marker>|static|posts a commit status to a live PR head
merge-and-poll|gh pr merge <N> --squash|static|merges a live PR
merge-poll|pr-wait-merge.sh --pr <N>|static|waits on a live PR's merge state and required checks
local-sync-confirm|gh pr view <N> --json state|static|reads a live PR's state to tell a failed local sync from a failed merge
main-checkout-head|rev-parse --abbrev-ref HEAD|exec|read-only git plumbing, runs against a fixture checkout substituted for the placeholder
cleanup-branch|git checkout main && git pull origin main|static|checks out main and deletes a branch in this checkout
cleanup-worktree|git worktree remove --force|static|removes a worktree in this checkout
TABLE
}

# ---------------------------------------------------------------------------
# Fence extraction
# ---------------------------------------------------------------------------

# FENCE_OPEN_REGEX: the fence openers discovery reads. Every tag that carries
# shell, not `bash` alone, and tolerant of trailing whitespace.
#
# One constant rather than the pattern written at each site. Narrowed to
# ```bash, the lenses skipped a ```sh or ```shell fence entirely, and lens 1
# could not see the omission either: it reconciles the table against
# fence_count(), so both sides of that comparison came from the same narrowed
# pattern and agreed about a fence neither had read.
FENCE_OPEN_REGEX='^```(bash|sh|shell)[[:space:]]*$'

# fence_count: how many shell fences the page opens.
fence_count() {
  awk -v regex="$FENCE_OPEN_REGEX" '$0 ~ regex { opener_count++ } END { print opener_count + 0 }' "$PAGE"
}

# fence_body <n>: the body of the n-th shell fence, verbatim.
fence_body() {
  awk -v want="$1" -v regex="$FENCE_OPEN_REGEX" '
    $0 ~ regex { opener_count++; if (opener_count == want) { inside = 1 } ; next }
    /^```[[:space:]]*$/ && inside { inside = 0; next }
    inside { print }
  ' "$PAGE"
}

# untagged_fence_bodies [<file>]: the bodies of fences opened with a bare
# ```, which discovery does not read.
#
# The complement of the discovery set, so the guard below can ask whether
# anything hides in it. A tagged non-shell fence is deliberately not here: a
# tag declares the block data rather than a command line.
untagged_fence_bodies() {
  awk '
    /^```/ {
      if (inside) { inside = 0; tag = ""; next }
      inside = 1
      tag = substr($0, 4)
      sub(/[[:space:]]+$/, "", tag)
      next
    }
    inside && tag == "" { print }
  ' "${1:-$PAGE}"
}

# fence_indices_for <anchor>: every fence index whose body contains <anchor>
# as a literal substring, one per line. Literal via index(), never a regex:
# the anchors carry `-`, `.`, `$`, `(`, `{` and `<`, and a regex reading would
# match fences the table never meant to name.
fence_indices_for() {
  local anchor="$1" total i body
  total="$(fence_count)"
  i=1
  while [ "$i" -le "$total" ]; do
    body="$(fence_body "$i")"
    if awk -v anchor_text="$anchor" 'index($0, anchor_text) { found = 1 } END { exit found ? 0 : 1 }' <<<"$body"; then
      printf '%s\n' "$i"
    fi
    i=$((i + 1))
  done
}

# materialize <anchor>: writes the named fence's body to a fresh file and
# prints that path. Reading it from the page rather than restating it here is
# what makes an edit to the page an edit to what these tests execute.
materialize() {
  local anchor="$1" fence_index script
  fence_index="$(fence_indices_for "$anchor" | head -1)"
  [ -n "$fence_index" ] || {
    echo "no fence carries the anchor: ${anchor}" >&2
    return 1
  }
  script="${BATS_TEST_TMPDIR}/fence-${fence_index}.sh"
  fence_body "$fence_index" >"$script"
  printf '%s\n' "$script"
}

# sub_literal <file> <needle> <replacement>: literal, non-regex substitution,
# in place. Returns non-zero when the needle is absent, so a substitution that
# stops matching after a page edit fails the test rather than running an
# un-substituted body against the network.
sub_literal() {
  local file="$1" needle="$2" replacement="$3" substituted_file_path
  substituted_file_path="${file}.sub"
  awk -v needle_text="$needle" -v replacement_text="$replacement" '
    {
      line = $0
      rebuilt_line = ""
      while ((needle_position = index(line, needle_text)) > 0) {
        rebuilt_line = rebuilt_line substr(line, 1, needle_position - 1) replacement_text
        line = substr(line, needle_position + length(needle_text))
        hits++
      }
      print rebuilt_line line
    }
    END { exit hits ? 0 : 1 }
  ' "$file" >"$substituted_file_path" || {
    echo "substitution needle absent from ${file}: ${needle}" >&2
    rm -f "$substituted_file_path"
    return 1
  }
  mv "$substituted_file_path" "$file"
}

# emit_values <script> <var>...: append a marker-prefixed print of each named
# variable to the materialized fence, so an assertion reads a value by name.
#
# Positional reads are what this exists to avoid. A fence's own commands write
# to stderr, `run` merges stderr into $output, and one warning line shifts
# every position after it. That is not hypothetical here: the per-author mode
# resolver emits an advisory warning whenever it cannot confirm the required
# check is registered, which it cannot without gh credentials, so the value
# that sits on line 1 with credentials sits on line 2 without them.
emit_values() {
  local script="$1"
  shift
  local variable_name
  for variable_name in "$@"; do
    printf 'printf "GAIA_FENCE_VALUE %s=%%s\\n" "$%s"\n' "$variable_name" "$variable_name" >>"$script"
  done
}

# value_of <name>: the value emit_values printed for <name>, read out of
# $output by name rather than by line.
value_of() {
  sed -n "s/^GAIA_FENCE_VALUE $1=//p" <<<"$output" | head -1
}

# bodies_source [<file>]: what the discovery functions below read. With no
# argument it is the page's own fences; with one, that file's contents.
#
# The seam exists for the non-vacuity control. A control that re-implements a
# lens's predicate inline certifies its own copy and not the lens, so it stays
# green while the extraction it vouches for drifts to reading nothing. Driving
# a fabricated body through these same functions is what makes it a control.
bodies_source() {
  if [ -n "${1:-}" ]; then
    cat "$1"
  else
    all_fence_bodies
  fi
}

# all_fence_bodies: every fence body concatenated, for the whole-page lenses.
all_fence_bodies() {
  local total i
  total="$(fence_count)"
  i=1
  while [ "$i" -le "$total" ]; do
    fence_body "$i"
    i=$((i + 1))
  done
}

# cited_scripts: every repo-relative script path any fence hands to `bash`,
# deduped. The `bash ` prefix and the `.sh` suffix are both required, so this
# never answers with a directory.
cited_scripts() {
  bodies_source "${1:-}" \
    | grep -oE 'bash (\.gaia|\.github|\.claude)/[A-Za-z0-9_./-]+\.sh' \
    | sed 's/^bash //' \
    | sort -u
}

# cited_paths: every repo-relative path any fence names, script or not.
#
# The character class stops at `<`, so a placeholder path arrives truncated
# rather than excluded: `.claude/worktrees/<branch-name>` yields the bare
# directory `.claude/worktrees`, which a clean checkout does not carry. The
# existence check below therefore carries an explicit skip arm for it, beside
# the `.gaia/local/*` one, and that arm is load-bearing rather than defensive.
cited_paths() {
  bodies_source "${1:-}" \
    | grep -oE '(\.gaia|\.github|\.claude)/[A-Za-z0-9_./-]+[A-Za-z0-9_-]' \
    | sort -u
}

# flags_for <script-path>: the `--flags` the fences hand that script.
#
# Window: from the script path to the end of its own command. The truncations
# are what keep a neighbouring command's flags out. `$(` first, because a
# command substitution opened after the script path belongs to an ARGUMENT of
# it (`--flag "$(gh pr view ... --json author)"`), and `--json`
# there is gh's flag, not the resolver's. Then `)`, which closes the
# substitution the whole invocation may itself sit inside.
flags_for() {
  local script="$1"
  bodies_source "${2:-}" \
    | sed -e ':a' -e '/\\$/{N; s/\\\n[[:space:]]*/ /; ta' -e '}' \
    | awk -v script_command="bash $script" '
        {
          script_position = index($0, script_command)
          if (script_position == 0) next
          rest = substr($0, script_position + length(script_command))
          expression_position = index(rest, "$(")
          if (expression_position > 0) rest = substr(rest, 1, expression_position - 1)
          expression_position = index(rest, ")")
          if (expression_position > 0) rest = substr(rest, 1, expression_position - 1)
          print rest
        }
      ' \
    | grep -oE ' --[a-z][a-z-]*' \
    | tr -d ' ' \
    | sort -u
}

# script_parses_flag <script-path> <flag>: 0 when that script carries a parse
# arm for that flag.
#
# Anchored to the arm, not a substring match over the file. A flag deleted
# from a `case` and left behind in the usage header keeps a bare match green,
# which is precisely the drift the lens exists to see. Factored into a
# function rather than written inline in the lens, so the control below drives
# the same predicate the lens does; a control re-implementing it would
# certify its own copy.
script_parses_flag() {
  grep -qE "(^|[|[:space:]])${2//./\\.}[)|=]" "$1"
}

# ---------------------------------------------------------------------------
# Enumeration-query program extraction (residual-enumerate)
# ---------------------------------------------------------------------------

# jq_bin: `jq` or `gojq`, whichever is on PATH; empty when neither is.
# The enumeration query is line-scoped (the fence splits each pull-request
# body on newlines before it captures), so the negated bracket class the
# path field uses cannot cross a line either way; unlike debt.md's
# body-scoped capture, there is no newline-exclusion behavior here that
# differs between jq's Oniguruma and gojq's Go RE2, so one engine suffices.
jq_bin() {
  if command -v jq >/dev/null 2>&1; then
    echo jq
  elif command -v gojq >/dev/null 2>&1; then
    echo gojq
  fi
}

# extract_enumeration_jq_program <fence-file>: the residual-enumerate
# fence's bare --jq PROGRAM TEXT, run directly rather than transcribed.
#
# A different shape from doc-debt-query.bats' extract_jq_program, and
# reusing that extractor here would silently drop this program's first
# clause: debt.md opens its fence with a bare `--jq '` line and the program
# starts on the line AFTER it; this fence opens with `--jq '.[] as $pr` and
# the program starts on that SAME line, at the text following the quote. It
# closes the way this fence writes it too: the final unescaped `'` inline at
# the end of the last program line, never a bare-quote line of its own.
#
# Asserts the program's own first line is the literal `.[] as $pr` before
# returning it, so a future reflow of the fence, or a page edit that moves
# the anchor, reds here with a message naming the extraction rather than
# handing jq a truncated or empty program that fails somewhere else with no
# clue why.
extract_enumeration_jq_program() {
  awk -v single_quote="'" '
    !found {
      opener_position = index($0, "--jq " single_quote)
      if (opener_position == 0) next
      found = 1
      program_lines[++line_count] = substr($0, opener_position + length("--jq " single_quote))
      next
    }
    { program_lines[++line_count] = $0 }
    END {
      if (line_count == 0) {
        print "extract_enumeration_jq_program: no --jq " single_quote " opener found" > "/dev/stderr"
        exit 1
      }
      last = program_lines[line_count]
      if (substr(last, length(last), 1) != single_quote) {
        print "extract_enumeration_jq_program: the last program line does not end with a closing quote, the fence shape may have changed: " last > "/dev/stderr"
        exit 1
      }
      program_lines[line_count] = substr(last, 1, length(last) - 1)
      if (program_lines[1] != ".[] as $pr") {
        print "extract_enumeration_jq_program: expected the program to start with .[] as $pr, got: " program_lines[1] > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= line_count; i++) print program_lines[i]
    }
  ' "$1"
}

# residue_pr_fixture <number>...: a JSON array subset of the committed
# residue corpus (.gaia/tests/fixtures/residue-corpus/prs.json) holding only
# the named pull requests, written to a fresh file whose path is printed.
# Reusing that committed corpus, rather than hand-writing a pull-request
# body here, keeps this suite's subject the same body the
# residue-attribution conformance suite pins, not a second copy of it.
residue_pr_fixture() {
  local corpus="${REPO_ROOT}/.gaia/tests/fixtures/residue-corpus/prs.json"
  local subset_file_path pull_request_numbers
  # No .json suffix on the template: macOS mktemp does not randomize the
  # X-run when a literal suffix follows it, and silently reuses the same
  # literal path on a second call in the same test, which collided here.
  subset_file_path="$(mktemp "${BATS_TEST_TMPDIR}/pr-subset-XXXXXX")"
  pull_request_numbers="$(printf '%s,' "$@")"
  pull_request_numbers="[${pull_request_numbers%,}]"
  "$(jq_bin)" -c --argjson pull_request_numbers "$pull_request_numbers" \
    '[.[] | select(.number as $pull_request_number | $pull_request_numbers | index($pull_request_number) != null)]' \
    "$corpus" >"$subset_file_path"
  printf '%s\n' "$subset_file_path"
}

# ---------------------------------------------------------------------------
# Lens 1: the fence set is covered
# ---------------------------------------------------------------------------

@test "fence set: the page opens fences and the table is not empty" {
  # A derivation that comes back empty makes every per-fence claim below true
  # without meaning anything, so both derivations report empty as a failure.
  count="$(fence_count)"
  [ "$count" -gt 0 ]
  rows="$(fence_table | grep -c '|')"
  [ "$rows" -gt 0 ]
}

@test "fence set: every table anchor names exactly one fence" {
  fence_table | while IFS='|' read -r id anchor mode note; do
    [ -n "$id" ] || continue
    # `|| true`: grep -c exits 1 on no match, and under bats' set -e the
    # assignment inherits that status, so the zero case, the rotted anchor
    # this test exists to catch, aborted before printing which anchor rotted.
    hits="$(fence_indices_for "$anchor" | grep -c . || true)"
    if [ "$hits" -ne 1 ]; then
      echo "anchor for ${id} matched ${hits} fences, expected exactly one: ${anchor}" >&2
      exit 1
    fi
  done
}

@test "fence set: discovery reads every fence tag that can carry shell" {
  # Standing control for FENCE_OPEN_REGEX, driven off a fixture because the page
  # itself uses one spelling and cannot exercise the others. $PAGE is a plain
  # variable and bats runs each test in its own process, so reassigning it
  # here reaches the discovery functions and leaks nowhere.
  fixture="${BATS_TEST_TMPDIR}/tags.md"
  {
    printf '```bash\necho one\n```\n\n'
    printf '```sh\necho two\n```\n\n'
    printf '```shell\necho three\n```\n\n'
    printf '```bash \necho four\n```\n\n'
    printf '```json\n{}\n```\n'
  } >"$fixture"
  PAGE="$fixture"
  [ "$(fence_count)" -eq 4 ]
  grep -qx 'echo two' <<<"$(fence_body 2)"
  grep -qx 'echo three' <<<"$(fence_body 3)"
  grep -qx 'echo four' <<<"$(fence_body 4)"
  # The tagged non-shell fence stays out: a tag declares the block data.
  # The bodies are joined on newlines rather than concatenated: command
  # substitution strips each trailing newline, so a bare `$(fence_body 1)$(…)`
  # collapses the four onto one line and the whole-line match below could
  # never fire whatever the bodies held.
  bodies="${BATS_TEST_TMPDIR}/bodies"
  for i in 1 2 3 4; do fence_body "$i"; done >"$bodies"
  grep -qx '{}' "$bodies" && return 1
  true
}

@test "fence set: an untagged fence carries no line the covered fences lack" {
  # The complement guard. Discovery reads tagged shell fences, so an untagged
  # block is outside every lens; this asks whether anything is hiding there.
  #
  # An empty complement is the strongest pass rather than a vacuous one: it
  # means the discovery set is the whole set. The control below is what keeps
  # an extractor that reads nothing from producing the same green.
  covered="${BATS_TEST_TMPDIR}/covered"
  all_fence_bodies >"$covered"
  untagged_fence_bodies | while read -r line; do
    trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$trimmed" ] || continue
    if ! grep -qF -- "$trimmed" "$covered"; then
      echo "an untagged fence carries a line no covered fence does: ${trimmed}" >&2
      exit 1
    fi
  done
}

@test "fence set: the untagged-fence extractor reads a fixture that has one" {
  # Non-vacuity control for the guard above, whose own subject is legitimately
  # empty on a page that tags every fence.
  fixture="${BATS_TEST_TMPDIR}/untagged.md"
  printf '```bash\necho covered\n```\n\n```\necho hidden\n```\n' >"$fixture"
  grep -qx 'echo hidden' <<<"$(untagged_fence_bodies "$fixture")"
  grep -qx 'echo covered' <<<"$(untagged_fence_bodies "$fixture")" && return 1
  true
}

@test "fence set: every fence in the page is claimed by exactly one table row" {
  # The short-read guard. Counting claimed fences against the page's own fence
  # count is what stops a new fence from entering the page unexamined: the
  # suite would otherwise stay green while driving a subset of a set whose
  # name says every.
  total="$(fence_count)"
  # Derived once and reused. Written out twice, the count and the diagnostic
  # can be repaired independently, and the one nobody re-reads goes stale.
  claimed_list="${BATS_TEST_TMPDIR}/claimed"
  fence_table | while IFS='|' read -r id anchor mode note; do
    [ -n "$id" ] || continue
    fence_indices_for "$anchor"
  done | sort -u >"$claimed_list"
  claimed="$(grep -c . "$claimed_list" || true)"
  if [ "$claimed" -ne "$total" ]; then
    echo "the page opens ${total} shell fences and the table claims ${claimed}" >&2
    echo "unclaimed fence indices:" >&2
    # Both sides sorted the same way. `seq` counts numerically and `sort -u`
    # collates lexically, and the two orders diverge at 10, which the table
    # already passed: comm would report every index from 10 up as unclaimed
    # and send the reader to repair rows that are correct.
    comm -23 <(seq 1 "$total" | sort) <(sort "$claimed_list") >&2
    return 1
  fi
}

@test "fence set: every exec row has a runner test naming its id" {
  fence_table | while IFS='|' read -r id anchor mode note; do
    [ "$mode" = "exec" ] || continue
    if ! grep -qF -- "@test \"fence ${id}:" "$BATS_TEST_FILENAME"; then
      echo "table row ${id} is mode exec with no runner test in this file" >&2
      exit 1
    fi
  done
}

@test "fence set: every static row records why it cannot run here" {
  fence_table | while IFS='|' read -r id anchor mode note; do
    [ "$mode" = "static" ] || continue
    if [ -z "$note" ]; then
      echo "table row ${id} is mode static with no reason recorded" >&2
      exit 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Lens 2: static truth over every fence, runnable or not
# ---------------------------------------------------------------------------

@test "every fence parses as bash" {
  total="$(fence_count)"
  i=1
  while [ "$i" -le "$total" ]; do
    body="${BATS_TEST_TMPDIR}/parse-${i}.sh"
    # Placeholder tokens are normalized away first. `gh pr checks <N> | ...`
    # is not a parse error in the page, it is an unfilled argument slot: bash
    # reads `<N>` as an input redirect followed by an output redirect with no
    # target. Normalizing keeps the lens on real syntax rather than on the
    # page's own convention for naming a value the reader supplies.
    fence_body "$i" | sed 's/<[A-Za-z0-9|_.-]*>/PLACEHOLDER/g' >"$body"
    if ! bash -n "$body" 2>"${body}.err"; then
      echo "fence ${i} does not parse:" >&2
      cat "${body}.err" >&2
      return 1
    fi
    i=$((i + 1))
  done
}

@test "every repo path a fence cites exists in the tree" {
  paths="$(cited_paths)"
  [ -n "$paths" ] || {
    echo "no repo paths extracted from the fences; the extractor is broken" >&2
    return 1
  }
  printf '%s\n' "$paths" | while read -r cited_path; do
    [ -n "$cited_path" ] || continue
    # `.gaia/local/**` is runtime state a clean checkout does not carry, and
    # the fences name it as a destination rather than as a precondition.
    case "$cited_path" in
      .gaia/local/*) continue ;;
      .claude/worktrees*) continue ;;
    esac
    if [ ! -e "${REPO_ROOT}/${cited_path}" ]; then
      echo "a fence cites ${cited_path}, which is not in the tree" >&2
      exit 1
    fi
  done
}

@test "the script-path extractor and a plain count agree on how many scripts the fences cite" {
  # Two independent derivations, because a short read here is more dangerous
  # than an empty one: the per-flag test below would still pass while silently
  # covering fewer scripts than the fences name.
  extracted="$(cited_scripts | grep -c .)"
  plain="$(all_fence_bodies | grep -oE '(\.gaia|\.github|\.claude)/[A-Za-z0-9_./-]+\.sh' | sort -u | grep -c .)"
  if [ "$extracted" -ne "$plain" ]; then
    echo "bash-invocation extraction found ${extracted} scripts, a plain path scan found ${plain}" >&2
    cited_scripts >&2
    return 1
  fi
  [ "$extracted" -gt 0 ]
}

@test "every flag a fence hands a repo script resolves to a parse arm in it" {
  scripts="$(cited_scripts)"
  [ -n "$scripts" ] || {
    echo "no scripts extracted from the fences; the extractor is broken" >&2
    return 1
  }
  joined="${BATS_TEST_TMPDIR}/joined"
  all_fence_bodies | sed -e ':a' -e '/\\$/{N; s/\\\n[[:space:]]*/ /; ta' -e '}' >"$joined"
  printf '%s\n' "$scripts" | while read -r cited_script; do
    [ -n "$cited_script" ] || continue
    found="$(flags_for "$cited_script")"
    # Per-element short-read guard, by a second expression rather than the
    # same one. An invocation that carries a flag at all is decidable without
    # the window truncations flags_for applies, so an extractor that collapses
    # to reading nothing is caught here per script, where a whole-set
    # non-empty check would stay satisfied on the other scripts' flags.
    if grep -qE "bash ${cited_script//./\\.}[^)]*--" "$joined" && [ -z "$found" ]; then
      echo "the page hands ${cited_script} at least one flag and the extractor read none" >&2
      exit 1
    fi
    for flag in $found; do
      if ! script_parses_flag "${REPO_ROOT}/${cited_script}" "$flag"; then
        echo "a fence passes ${flag} to ${cited_script}, which parses no such flag" >&2
        exit 1
      fi
    done
  done
}

@test "the static lenses are not vacuous: the real extractors read a fabricated fence and it fails both" {
  # Non-vacuity control, deliberately sampling one fabricated body rather than
  # mutating every fence: one instance establishes that the lenses can fail,
  # and mutating the whole set buys the same signal at N times the cost.
  #
  # It runs the fabricated body through cited_paths, cited_scripts and
  # flags_for themselves. Asserting the lens PREDICATES inline instead, a bare
  # `[ ! -e ]` and a bare grep against hardcoded literals, would leave the
  # extraction functions uncertified, and those are the half that drifts.
  bad="${BATS_TEST_TMPDIR}/fabricated.sh"
  printf 'bash .gaia/scripts/does-not-exist-anywhere.sh --no-such-flag\n' >"$bad"

  grep -qx '\.gaia/scripts/does-not-exist-anywhere\.sh' <<<"$(cited_paths "$bad")"
  [ ! -e "${REPO_ROOT}/.gaia/scripts/does-not-exist-anywhere.sh" ]

  [ "$(cited_scripts "$bad")" = ".gaia/scripts/does-not-exist-anywhere.sh" ]

  [ "$(flags_for .gaia/scripts/does-not-exist-anywhere.sh "$bad")" = "--no-such-flag" ]
  script_parses_flag "${REPO_ROOT}/.gaia/scripts/audit-noop-detect.sh" --no-such-flag && return 1
  true
}

@test "the flag lens tells a parse arm apart from a usage comment" {
  # The anchoring is latent on this tree: every flag the page cites today
  # resolves to a real arm, so an un-anchored bare match would agree with the
  # anchored one on every live input and no mutation of the suite can show the
  # difference. A fixture carrying the two cases side by side is what makes
  # the discrimination testable at all.
  fake="${BATS_TEST_TMPDIR}/fake-script.sh"
  cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
# Usage: fake-script.sh [--retired-flag <value>] [--real-arm]
case "$1" in
  --real-arm) shift ;;
esac
FAKE
  script_parses_flag "$fake" --real-arm
  script_parses_flag "$fake" --retired-flag && return 1
  # And the bare match this replaced would have accepted the retired one,
  # which is the whole reason the predicate is anchored.
  grep -qF -- '--retired-flag' "$fake"
}

# ---------------------------------------------------------------------------
# Lens 3: the runnable fences run, and do what the page says
# ---------------------------------------------------------------------------

@test "fence spawn-roster: it exits 0 and prints deduped, sorted member names" {
  script="$(materialize 'resolve-audit-members.sh')"
  run bash -c "cd '$REPO_ROOT' && bash '$script' 2>/dev/null"
  [ "$status" -eq 0 ]
  sorted="$(printf '%s\n' "$output" | LC_ALL=C sort -u)"
  [ "$(printf '%s\n' "$output")" = "$sorted" ]
}

@test "fence noop-classify: a marker with its sidecar is real, and without it is a no-op" {
  root="${BATS_TEST_TMPDIR}/root"
  mkdir -p "${root}/.gaia/local/audit"
  git -C "$root" init -q -b fixture-branch
  member=code-audit-maintainer-shell
  digest="$(printf 'ab%.0s' $(seq 1 32))"
  marker="${BATS_TEST_TMPDIR}/${digest}.${member}.ok"
  printf '{"version":"1.6.1","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$member" "$digest" >"$marker"
  stamp="${BATS_TEST_TMPDIR}/wave-stamp"
  : >"$stamp"

  script="$(materialize 'audit-noop-detect.sh --shape audit-team-member')"
  sub_literal "$script" '<expected-marker-path>' "$marker"
  sub_literal "$script" '<RESOLVED_ROOT>' "$root"
  sub_literal "$script" '<wave-stamp>' "$stamp"

  # The lost-report shape first: the member wrote its marker and its report
  # never landed. The page says that classifies no-op and earns the one retry.
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 1 ]

  sidecar="${root}/.gaia/local/audit/deadbeef.fixture-branch.${member}.findings.json"
  printf '{"member":"%s","findings":[]}\n' "$member" >"$sidecar"
  touch "$sidecar"
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  grep -qx 'real' <<<"$output"
}

@test "fence wave-stamp: the stamp lands outside the audit directory" {
  script="$(materialize 'WAVE_STAMP="$(mktemp)"')"
  emit_values "$script" WAVE_STAMP
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  stamp="$(value_of WAVE_STAMP)"
  [ -f "$stamp" ]
  # The claim under test: a stamp under .gaia/local/audit/ would be shared by
  # every worktree auditing at once, because a linked worktree symlinks that
  # directory to main's.
  case "$stamp" in
    */.gaia/local/audit/*)
      echo "the wave stamp landed in the shared audit directory: ${stamp}" >&2
      rm -f "$stamp"
      return 1
      ;;
  esac
  rm -f "$stamp"
}

@test "fence main-checkout-head: it names the branch the main checkout is holding" {
  script="$(materialize 'rev-parse --abbrev-ref HEAD')"
  # A fixture checkout rather than this one. The page's claim is that this
  # command discriminates `main` from a peer session's branch, and a checkout
  # that happens to sit on one of the two exercises only that arm; the
  # fixture is driven through both.
  fixture="${BATS_TEST_TMPDIR}/main-checkout"
  git init -q -b main "$fixture"
  git -C "$fixture" -c user.email=fence@example.invalid -c user.name=fence \
    commit -q --allow-empty -m 'fixture'
  sub_literal "$script" '<main-checkout>' "$fixture"
  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'main' <<<"$output"
  git -C "$fixture" checkout -q -b peer-branch
  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'peer-branch' <<<"$output"
}

@test "fence residual-enumerate: the extracted enumeration query emits the spaced-path residual verbatim" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  fence="$(materialize 'gh pr list --state merged')"
  program="$(extract_enumeration_jq_program "$fence")"
  fixture="$(residue_pr_fixture 3006)"
  # PR 3006 is the committed residue-corpus fixture standing in for the
  # network call: the live merged record carries no dedup key on a spaced
  # path, so this residual is otherwise unreachable without editing a merged
  # pull request body, which the convention forbids.
  output="$("$bin" -r "$program" "$fixture")"
  expected=$'3006\tapp/my dir/file.ts:1\tv1 class=lint path=app/my dir/file.ts line=1'
  if [ "$output" != "$expected" ]; then
    echo "enumeration query emitted: ${output}" >&2
    echo "expected:                  ${expected}" >&2
    return 1
  fi
}

@test "fence residual-enumerate: the pre-change class misses the spaced path, and a bare greedy class splices a two-key line" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  fence="$(materialize 'gh pr list --state merged')"
  program="$(extract_enumeration_jq_program "$fence")"
  program_file="${BATS_TEST_TMPDIR}/enum-program.jq"
  printf '%s\n' "$program" >"$program_file"

  # Mutant 1, the pre-change spelling: [^ ]+ instead of [^>]+.
  reverted_file="${BATS_TEST_TMPDIR}/enum-program-reverted.jq"
  cp "$program_file" "$reverted_file"
  sub_literal "$reverted_file" 'path=(?<path>[^>]+)' 'path=(?<path>[^ ]+)'

  # Mutant 2, a bare greedy class that is not the alternative fix: .+
  # instead of [^>]+.
  greedy_file="${BATS_TEST_TMPDIR}/enum-program-greedy.jq"
  cp "$program_file" "$greedy_file"
  sub_literal "$greedy_file" 'path=(?<path>[^>]+)' 'path=(?<path>.+)'

  fixture_3006="$(residue_pr_fixture 3006)"
  fixture_3002="$(residue_pr_fixture 3002)"

  # Mutant 1 over PR 3006's spaced path: the committed [^>]+ class is what
  # makes this residual enumerable at all, so the reverted class must find
  # nothing for it.
  reverted_output="$("$bin" -r "$(cat "$reverted_file")" "$fixture_3006")"
  if [ -n "$reverted_output" ]; then
    echo "reverted [^ ]+ class unexpectedly emitted: ${reverted_output}" >&2
    return 1
  fi

  # Mutant 2 needs a different fixture to discriminate: over PR 3006's
  # single-key line the greedy class agrees with the committed one, there is
  # nothing on that line for it to overrun into. PR 3002 carries a single
  # line with two wrapped keys; a class able to cross the first key's own
  # '-->' splices the second key's line number onto the first key's path.
  committed_3002="$("$bin" -r "$(cat "$program_file")" "$fixture_3002")"
  expected_3002=$'3002\tapp/dup/first.ts:1\tv1 class=dupe path=app/dup/first.ts line=1'
  if [ "$committed_3002" != "$expected_3002" ]; then
    echo "committed [^>]+ class over the two-key line: ${committed_3002}" >&2
    return 1
  fi
  greedy_3002="$("$bin" -r "$(cat "$greedy_file")" "$fixture_3002")"
  if [ "$greedy_3002" = "$expected_3002" ]; then
    echo "expected the greedy .+ class to splice the two-key line, it did not" >&2
    return 1
  fi
  echo "greedy .+ class over the two-key line: ${greedy_3002}" >&2
}

@test "fence residual-enumerate: the extractor reds on a debt.md-shaped reflow rather than silently truncating" {
  fence="$(materialize 'gh pr list --state merged')"
  program="$(extract_enumeration_jq_program "$fence")"

  # Reflows the fence into debt.md's shape: the opening quote alone on its
  # own line, and the closing quote alone on its own line, rather than
  # inline at the end of the last program line. This suite's own extractor
  # is written for this fence's shape, not debt.md's, so it must red here
  # with its own message instead of silently handing jq a truncated program.
  reflowed="${BATS_TEST_TMPDIR}/enum-reflowed.sh"
  {
    printf 'gh pr list --state merged --limit 2000 --json number,body \\\n'
    printf "  --jq '\n"
    printf '%s\n' "$program"
    printf "'\n"
  } >"$reflowed"

  run extract_enumeration_jq_program "$reflowed"
  [ "$status" -ne 0 ]
  grep -qF -- "extract_enumeration_jq_program:" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# The fix round's fences (`#### The fix round: fixer, verifier, gate`)
# ---------------------------------------------------------------------------

# fix_fixture: a committed checkout holding a.txt, b.txt and c.txt, plus an
# empty run folder beside it. Sets FIX_ROOT and FIX_RUN_FOLDER.
fix_fixture() {
  FIX_ROOT="${BATS_TEST_TMPDIR}/fix-root"
  FIX_RUN_FOLDER="${BATS_TEST_TMPDIR}/run-folder"
  git init -q -b feat/fence-fix "$FIX_ROOT"
  printf 'a\n' >"${FIX_ROOT}/a.txt"
  printf 'b\n' >"${FIX_ROOT}/b.txt"
  printf 'c\n' >"${FIX_ROOT}/c.txt"
  git -C "$FIX_ROOT" add -A
  git -C "$FIX_ROOT" -c user.email=fence@example.invalid -c user.name=fence -c commit.gpgsign=false \
    commit -q -m fixture
  mkdir -p "$FIX_RUN_FOLDER"
}

@test "fence loop-round-index: it prints the round count the branch history records" {
  . "${REPO_ROOT}/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/fence-round
  alf_fill f.txt 2 one
  alf_commit r1
  alf_add_round '["code-audit-frontend"]'
  alf_set_line f.txt 1 two
  alf_commit r2
  alf_add_round '["code-audit-frontend"]'
  script="$(materialize 'audit-loop-eval.sh current-round')"
  sub_literal "$script" '<RESOLVED_ROOT>' "$ALF_ROOT"
  run bash -c "cd '$REPO_ROOT' && bash '$script' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "fence fix-baseline: a clean tree records an empty dirty set and both digests print" {
  fix_fixture
  printf '{"schema":1,"round":1,"entries":[]}\n' >"${FIX_RUN_FOLDER}/dispositions-1.json"
  script="$(materialize 'audit-fix-verify.sh baseline --root')"
  sub_literal "$script" '<RESOLVED_ROOT>' "$FIX_ROOT"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  jq -e '.dirty == {}' "${FIX_RUN_FOLDER}/baseline-1.json" >/dev/null
  # The pinned verifier the later fences run sits beside the baseline.
  [ -f "${FIX_RUN_FOLDER}/verifier-bin-1/audit-fix-verify.sh" ]
  jq -e '.verifier_digest | test("^[0-9a-f]{64}$")' "${FIX_RUN_FOLDER}/baseline-1.json" >/dev/null
  [ "$(grep -cE '^[0-9a-f]{64} ' <<<"$output")" -eq 2 ]
  grep -qF -- 'dispositions-1.json' <<<"$output"
  grep -qF -- 'baseline-1.json' <<<"$output"
}

@test "fence fix-baseline: a tree the member wave left dirty is refused with exit 4 and member-wave-dirty" {
  fix_fixture
  printf 'member edit\n' >>"${FIX_ROOT}/a.txt"
  printf 'member file\n' >"${FIX_ROOT}/fresh.txt"
  printf '{"schema":1,"round":1,"entries":[]}\n' >"${FIX_RUN_FOLDER}/dispositions-1.json"
  script="$(materialize 'audit-fix-verify.sh baseline --root')"
  sub_literal "$script" '<RESOLVED_ROOT>' "$FIX_ROOT"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 4 ]
  grep -qx 'member-wave-dirty' <<<"$output"
  grep -qx 'dirty a.txt' <<<"$output"
  grep -qx 'dirty fresh.txt' <<<"$output"
  [ ! -e "${FIX_RUN_FOLDER}/baseline-1.json" ]
}

@test "fence fix-verify: check, round-check and drift run the pinned copy and no fence runs the working-tree verifier except baseline" {
  local body runs
  body="$(all_fence_bodies)"
  runs="$(grep -E 'audit-fix-verify\.sh (baseline|check|round-check|drift)' <<<"$body")"
  [ "$(wc -l <<<"$runs" | tr -d ' ')" -eq 4 ]
  [ "$(grep -c '^bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh ' <<<"$runs")" -eq 3 ]
  [ "$(grep -c '^bash .gaia/scripts/audit-fix-verify.sh baseline ' <<<"$runs")" -eq 1 ]
  for sub in check round-check drift; do
    grep -qE "^bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh $sub " <<<"$runs"
  done
}

@test "fence fixer-classify: a complete fixer result is real and a short one is a no-op" {
  fix_fixture
  printf '{"schema":1,"round":1,"attempt":1,"results":[{"member":"code-audit-frontend","finding_class":"rule/x","path":"b.txt","line":1,"disposition":"fixed","reason":"r","changed_paths":["b.txt"]}],"changed_paths":["b.txt"],"reverted_paths":[]}\n' \
    >"${FIX_RUN_FOLDER}/fixer-1-audit.json"
  script="$(materialize 'audit-noop-detect.sh --shape agent-report-file')"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  short="${script}.short"
  cp "$script" "$short"
  sub_literal "$script" '<FIX_COUNT>' 1
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  grep -qx 'real' <<<"$output"
  # Two fix entries and one result: the truncated write the expected count
  # exists to catch.
  sub_literal "$short" '<FIX_COUNT>' 2
  run bash -c "cd '$REPO_ROOT' && bash '$short'"
  [ "$status" -eq 1 ]
}

@test "fence fix-stage-delta: it stages the fixer and autofix paths and nothing else" {
  fix_fixture
  bash "${REPO_ROOT}/.gaia/scripts/audit-fix-verify.sh" baseline --root "$FIX_ROOT" --round 1 \
    --out "${FIX_RUN_FOLDER}/baseline-1.json"
  printf 'fixer\n' >>"${FIX_ROOT}/b.txt"
  printf 'stray\n' >>"${FIX_ROOT}/c.txt"
  printf 'autofix\n' >"${FIX_ROOT}/e.txt"
  printf '{"schema":1,"round":1,"attempt":2,"results":[],"changed_paths":["b.txt"],"reverted_paths":[]}\n' \
    >"${FIX_RUN_FOLDER}/fixer-1-audit.json"
  printf 'e.txt\n' >"${FIX_RUN_FOLDER}/gate-1-1.paths"
  script="$(materialize '.changed_paths[], .reverted_paths[]')"
  sub_literal "$script" '<RESOLVED_ROOT>' "$FIX_ROOT"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  run bash "$script"
  [ "$status" -eq 0 ]
  staged="$(git -C "$FIX_ROOT" diff --cached --name-only -z | tr '\0' ' ')"
  [ "$staged" = "b.txt e.txt " ]
}

@test "fence gate-paths: it records the paths the gate changed and no path it left alone" {
  fix_fixture
  printf 'delta\n' >>"${FIX_ROOT}/a.txt"
  git -C "$FIX_ROOT" add -- a.txt
  printf 'untouched\n' >>"${FIX_ROOT}/b.txt"
  script="$(materialize 'gate_snapshot() {')"
  sub_literal "$script" '<RESOLVED_ROOT>' "$FIX_ROOT"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  sub_literal "$script" '<k>' 1
  # The stand-in autofix: rewrites a staged path and creates a new one. The
  # needle is the placeholder comment's own text, so the rest of that line
  # stays a comment after the substitution.
  sub_literal "$script" '# run the per-round verification here' "echo fixed >>'${FIX_ROOT}/a.txt'; echo new >'${FIX_ROOT}/n.txt' #"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ "$(LC_ALL=C sort "${FIX_RUN_FOLDER}/gate-1-1.paths" | tr '\n' ' ')" = "a.txt n.txt " ]
}

@test "fence gate-paths: it records the gate's paths when the before-snapshot is empty" {
  # Staging the whole delta first leaves nothing unstaged or untracked, the
  # documented common case; an NR == FNR comparison prints nothing here.
  fix_fixture
  printf 'delta\n' >>"${FIX_ROOT}/a.txt"
  git -C "$FIX_ROOT" add -- a.txt
  [ -z "$(git -C "$FIX_ROOT" diff --name-only -z | tr '\0' '\n')" ]
  [ -z "$(git -C "$FIX_ROOT" ls-files -z --others --exclude-standard | tr '\0' '\n')" ]
  script="$(materialize 'gate_snapshot() {')"
  sub_literal "$script" '<RESOLVED_ROOT>' "$FIX_ROOT"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  sub_literal "$script" '<k>' 1
  sub_literal "$script" '# run the per-round verification here' "echo new >'${FIX_ROOT}/n.txt' #"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' <"${FIX_RUN_FOLDER}/gate-1-1.paths")" = "n.txt " ]
}

@test "fence fix-round-check: a gate log without a passing verifier output fails the round" {
  fix_fixture
  bash "${REPO_ROOT}/.gaia/scripts/audit-fix-verify.sh" baseline --root "$FIX_ROOT" --round 1 \
    --out "${FIX_RUN_FOLDER}/baseline-1.json"
  : >"${FIX_RUN_FOLDER}/gate-1-1.log"
  script="$(materialize 'audit-fix-verify.sh round-check')"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 1 ]
  printf '{"schema":1,"round":1,"attempt":1,"pass":true,"errors":[]}\n' >"${FIX_RUN_FOLDER}/verifier-1-1.json"
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
}

@test "fence resume-drift: it passes on the baseline tree and names the path a fixer edited" {
  fix_fixture
  bash "${REPO_ROOT}/.gaia/scripts/audit-fix-verify.sh" baseline --root "$FIX_ROOT" --round 1 \
    --out "${FIX_RUN_FOLDER}/baseline-1.json"
  script="$(materialize 'audit-fix-verify.sh drift --root')"
  sub_literal "$script" '<RESOLVED_ROOT>' "$FIX_ROOT"
  sub_literal "$script" '<RUN_FOLDER>' "$FIX_RUN_FOLDER"
  sub_literal "$script" '<r>' 1
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  printf 'fixer\n' >>"${FIX_ROOT}/b.txt"
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 1 ]
  grep -qx 'drift: b.txt' <<<"$output"
}
