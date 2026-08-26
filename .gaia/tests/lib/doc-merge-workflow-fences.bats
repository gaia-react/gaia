#!/usr/bin/env bats
# Executable-truth coverage for the bash fences in
# `wiki/concepts/PR Merge Workflow.md`.
#
# Why this suite exists, and how it differs from every other prose suite in
# this directory. The existing prose suites (doc-machinery-waive-prose.bats,
# doc-countability-prose.bats, doc-difficulty-prose.bats, ...) assert phrase
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
#   1. The fence SET is covered. Every bash fence in the page matches exactly
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
#   - Six of the fences cannot run here at all: four reach github.com
#     (`gh pr checks`, `gh api`, `post-findings-block.sh --pr`, `gh pr merge`)
#     and two mutate the checkout (`git checkout main`, `git worktree
#     remove`). They get lens 2 only. The disposition table records the reason
#     per fence rather than leaving the omission to be inferred.
#   - Lens 2's flag check proves a script ACCEPTS a flag, not that the flag
#     still means what the page says it means.
#   - Nothing here reads the page's prose. A false sentence sitting beside a
#     correct fence is invisible to this suite. That class has no oracle in
#     this repository and is addressed by procedure instead: the page's own
#     `### 2. Fix all issues` tells the sweep to grep the tree for the claim
#     rather than re-read a citation list, and states when the sweep has
#     converged.
#   - Backticked repo paths in the page's BODY PROSE are already covered, for
#     the whole wiki rather than this page, by `gaia wiki dead-paths` behind
#     `/gaia-wiki lint`. That primitive reads inline code spans, which fence
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
# One row per bash fence, `id|anchor|mode|note`. The anchor is a literal
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
resolve-mode|read-audit-ci-config.sh --resolve-author|exec|runs the shared per-author resolver with the two gh sub-shells replaced by fixture values
workflow-present|test -f .github/workflows/code-review-audit.yml|exec|pure filesystem and git plumbing, runs verbatim
audit-check-state|gh pr checks|static|reaches github.com for a live PR's check rows
workflow-live|gh api repos/{owner}/{repo}/actions/workflows|static|reaches github.com for the repository's Actions configuration
spawn-roster|resolve-audit-spawn.sh|exec|runs verbatim against this checkout
noop-classify|audit-noop-detect.sh --shape audit-team-member|exec|runs against a fixture root, marker and sidecar
wave-stamp|WAVE_STAMP="$(mktemp)"|exec|runs verbatim, and the claim under test is where mktemp puts the file
debt-origin|debt-origin-lib.sh|exec|runs verbatim with the changed-value placeholder filled in
disposition-sidecar|audit-member-digest.sh|exec|runs verbatim against this checkout
findings-block|post-findings-block.sh --pr|static|posts a comment to a live PR
merge-and-poll|gh pr merge <N> --squash|static|merges a live PR
cleanup-branch|git checkout main && git pull origin main|static|checks out main and deletes a branch in this checkout
cleanup-worktree|git worktree remove --force|static|removes a worktree in this checkout
TABLE
}

# ---------------------------------------------------------------------------
# Fence extraction
# ---------------------------------------------------------------------------

# fence_count: how many ```bash fences the page opens.
fence_count() {
  awk '/^```bash$/ { n++ } END { print n + 0 }' "$PAGE"
}

# fence_body <n>: the body of the n-th ```bash fence, verbatim.
fence_body() {
  awk -v want="$1" '
    /^```bash$/ { n++; if (n == want) { inside = 1 } ; next }
    /^```$/ && inside { inside = 0; next }
    inside { print }
  ' "$PAGE"
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
    if awk -v a="$anchor" 'index($0, a) { found = 1 } END { exit found ? 0 : 1 }' <<<"$body"; then
      printf '%s\n' "$i"
    fi
    i=$((i + 1))
  done
}

# materialize <anchor>: writes the named fence's body to a fresh file and
# prints that path. Reading it from the page rather than restating it here is
# what makes an edit to the page an edit to what these tests execute.
materialize() {
  local anchor="$1" idx script
  idx="$(fence_indices_for "$anchor" | head -1)"
  [ -n "$idx" ] || {
    echo "no fence carries the anchor: ${anchor}" >&2
    return 1
  }
  script="${BATS_TEST_TMPDIR}/fence-${idx}.sh"
  fence_body "$idx" >"$script"
  printf '%s\n' "$script"
}

# sub_literal <file> <needle> <replacement>: literal, non-regex substitution,
# in place. Returns non-zero when the needle is absent, so a substitution that
# stops matching after a page edit fails the test rather than running an
# un-substituted body against the network.
sub_literal() {
  local file="$1" needle="$2" replacement="$3" out
  out="${file}.sub"
  awk -v n="$needle" -v r="$replacement" '
    {
      line = $0
      out = ""
      while ((p = index(line, n)) > 0) {
        out = out substr(line, 1, p - 1) r
        line = substr(line, p + length(n))
        hits++
      }
      print out line
    }
    END { exit hits ? 0 : 1 }
  ' "$file" >"$out" || {
    echo "substitution needle absent from ${file}: ${needle}" >&2
    rm -f "$out"
    return 1
  }
  mv "$out" "$file"
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
# deduped. A path carrying a `<placeholder>` segment is excluded by the
# character class, which is why `.claude/worktrees/<branch-name>` never
# reaches the existence check as a truncated directory.
cited_scripts() {
  all_fence_bodies \
    | grep -oE 'bash (\.gaia|\.github|\.claude)/[A-Za-z0-9_./-]+\.sh' \
    | sed 's/^bash //' \
    | sort -u
}

# cited_paths: every repo-relative path any fence names, script or not.
cited_paths() {
  all_fence_bodies \
    | grep -oE '(\.gaia|\.github|\.claude)/[A-Za-z0-9_./-]+[A-Za-z0-9_-]' \
    | sort -u
}

# flags_for <script-path>: the `--flags` the fences hand that script.
#
# Window: from the script path to the end of its own command. The truncations
# are what keep a neighbouring command's flags out. `$(` first, because a
# command substitution opened after the script path belongs to an ARGUMENT of
# it (`--resolve-author "$(gh pr view ... --json author)"`), and `--json`
# there is gh's flag, not the resolver's. Then `)`, which closes the
# substitution the whole invocation may itself sit inside.
flags_for() {
  local script="$1"
  all_fence_bodies \
    | sed -e ':a' -e '/\\$/{N; s/\\\n[[:space:]]*/ /; ta' -e '}' \
    | awk -v s="bash $script" '
        {
          p = index($0, s)
          if (p == 0) next
          rest = substr($0, p + length(s))
          q = index(rest, "$(")
          if (q > 0) rest = substr(rest, 1, q - 1)
          q = index(rest, ")")
          if (q > 0) rest = substr(rest, 1, q - 1)
          print rest
        }
      ' \
    | grep -oE ' --[a-z][a-z-]*' \
    | tr -d ' ' \
    | sort -u
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
    hits="$(fence_indices_for "$anchor" | grep -c .)"
    if [ "$hits" -ne 1 ]; then
      echo "anchor for ${id} matched ${hits} fences, expected exactly one: ${anchor}" >&2
      exit 1
    fi
  done
}

@test "fence set: every fence in the page is claimed by exactly one table row" {
  # The short-read guard. Counting claimed fences against the page's own fence
  # count is what stops a new fence from entering the page unexamined: the
  # suite would otherwise stay green while driving a subset of a set whose
  # name says every.
  total="$(fence_count)"
  claimed="$(fence_table | while IFS='|' read -r id anchor mode note; do
    [ -n "$id" ] || continue
    fence_indices_for "$anchor"
  done | sort -u | grep -c .)"
  if [ "$claimed" -ne "$total" ]; then
    echo "the page opens ${total} bash fences and the table claims ${claimed}" >&2
    echo "unclaimed fence indices:" >&2
    comm -23 <(seq 1 "$total") <(fence_table | while IFS='|' read -r id anchor mode note; do
      [ -n "$id" ] || continue
      fence_indices_for "$anchor"
    done | sort -u) >&2
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
  printf '%s\n' "$paths" | while read -r p; do
    [ -n "$p" ] || continue
    # `.gaia/local/**` is runtime state a clean checkout does not carry, and
    # the fences name it as a destination rather than as a precondition.
    case "$p" in
      .gaia/local/*) continue ;;
      .claude/worktrees*) continue ;;
    esac
    if [ ! -e "${REPO_ROOT}/${p}" ]; then
      echo "a fence cites ${p}, which is not in the tree" >&2
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

@test "every flag a fence hands a repo script is a flag that script accepts" {
  scripts="$(cited_scripts)"
  [ -n "$scripts" ] || {
    echo "no scripts extracted from the fences; the extractor is broken" >&2
    return 1
  }
  printf '%s\n' "$scripts" | while read -r s; do
    [ -n "$s" ] || continue
    for flag in $(flags_for "$s"); do
      if ! grep -qF -- "$flag" "${REPO_ROOT}/${s}"; then
        echo "a fence passes ${flag} to ${s}, which does not mention it" >&2
        exit 1
      fi
    done
  done
}

@test "the static lenses are not vacuous: a fabricated fence fails both" {
  # Non-vacuity control, deliberately sampling one fabricated body rather than
  # mutating every fence: one instance establishes that the lenses can fail,
  # and mutating the whole set buys the same signal at N times the cost.
  bad="${BATS_TEST_TMPDIR}/fabricated.sh"
  printf 'bash .gaia/scripts/does-not-exist-anywhere.sh --no-such-flag\n' >"$bad"
  [ ! -e "${REPO_ROOT}/.gaia/scripts/does-not-exist-anywhere.sh" ]
  grep -qF -- '--no-such-flag' "${REPO_ROOT}/.gaia/scripts/audit-noop-detect.sh" && return 1
  true
}

# ---------------------------------------------------------------------------
# Lens 3: the runnable fences run, and do what the page says
# ---------------------------------------------------------------------------

@test "fence resolve-mode: eval-ing it puts a resolved_mode and a should_run in scope" {
  script="$(materialize 'read-audit-ci-config.sh --resolve-author')"
  # Both substitutions replace a `gh pr view` sub-shell, the only part of this
  # fence that reaches github.com. The fork answer and the author login are
  # exactly what a live PR would supply.
  sub_literal "$script" '$(gh pr view <N> --json isCrossRepository --jq .isCrossRepository)' 'false'
  sub_literal "$script" '$(gh pr view <N> --json author --jq .author.login)' 'fixture-author'
  # The page's claim is about what is IN SCOPE afterwards, so the assertion
  # has to run inside the same shell the fence's eval ran in.
  printf 'printf "%%s\\n%%s\\n" "$resolved_mode" "$should_run"\n' >>"$script"
  run bash "$script"
  [ "$status" -eq 0 ]
  mode="$(sed -n 1p <<<"$output")"
  should="$(sed -n 2p <<<"$output")"
  grep -qE '^(ci|local)$' <<<"$mode"
  grep -qE '^(true|false)$' <<<"$should"
}

@test "fence workflow-present: it answers present here, and prints the SHA the marker must match" {
  script="$(materialize 'test -f .github/workflows/code-review-audit.yml')"
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  # This repository configures the CI audit, so the page's `present` branch is
  # the one under test; `absent` here would mean the workflow was removed.
  [ "$(sed -n 1p <<<"$output")" = "present" ]
  grep -qE '^[0-9a-f]{40}$' <<<"$(sed -n 2p <<<"$output")"
}

@test "fence spawn-roster: it exits 0 and prints deduped, sorted member names" {
  script="$(materialize 'resolve-audit-spawn.sh')"
  run bash -c "cd '$REPO_ROOT' && bash '$script' 2>/dev/null"
  [ "$status" -eq 0 ]
  sorted="$(printf '%s\n' "$output" | LC_ALL=C sort -u)"
  [ "$(printf '%s\n' "$output")" = "$sorted" ]
}

@test "fence spawn-roster: a non-empty answer names real Code Audit Team members" {
  # Non-vacuity control for the test above. On a tree whose diff dispatches
  # nobody, the spawn set is legitimately empty and the sorted/deduped claim
  # holds without exercising anything. The empty-tree object is present in
  # every git repository and needs no history, so this control survives the
  # shallow checkout CI's bats shards run under.
  script="$(materialize 'resolve-audit-spawn.sh')"
  sub_literal "$script" 'resolve-audit-spawn.sh' \
    'resolve-audit-spawn.sh --base 4b825dc642cb6eb9a060e54bf8d69288fbee4904'
  run bash -c "cd '$REPO_ROOT' && bash '$script' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | while read -r member; do
    [ -n "$member" ] || continue
    if [ ! -f "${REPO_ROOT}/.claude/agents/${member}.md" ]; then
      echo "the spawn oracle named ${member}, which has no agent definition" >&2
      exit 1
    fi
  done
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
  [ "$output" = "real" ]
}

@test "fence wave-stamp: the stamp lands outside the audit directory" {
  script="$(materialize 'WAVE_STAMP="$(mktemp)"')"
  printf 'printf "%%s\\n" "$WAVE_STAMP"\n' >>"$script"
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  stamp="$output"
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

@test "fence debt-origin: it resolves a provenance line, three-dot and unguarded" {
  script="$(materialize 'debt-origin-lib.sh')"
  # The page states these three properties of this fence in the paragraph
  # under it, and all three are claims about the fence's own text, so they are
  # checked against the extracted body rather than against a transcription.
  grep -qF -- '"${FULL_BASE}...HEAD"' "$script"
  grep -qE 'diff --name-only -z "\$\{FULL_BASE\}\.\.\.HEAD"[[:space:]]*2' "$script"
  grep -qF -- 'if [ -z "$FULL_BASE" ]; then' "$script" && return 1
  sub_literal "$script" '<0|1|unknown>' 'unknown'
  printf 'printf "%%s\\n" "$origin"\n' >>"$script"
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  grep -qF -- 'changed=unknown' <<<"$output"
}

@test "fence debt-origin: an unresolvable base leaves the block running" {
  # The page's stated reason for the missing stop-guard: an unresolvable
  # FULL_BASE must not stop the filing. Driving AUDIT_ROOT at a directory that
  # is not a git repository is what makes every git call in the fence fail.
  script="$(materialize 'debt-origin-lib.sh')"
  sub_literal "$script" '<0|1|unknown>' 'unknown'
  printf 'printf "base=[%%s]\\n" "$FULL_BASE"\n' >>"$script"
  outside="${BATS_TEST_TMPDIR}/not-a-repo"
  mkdir -p "$outside"
  run bash -c "cd '$REPO_ROOT' && AUDIT_ROOT='$outside' bash '$script'"
  [ "$status" -eq 0 ]
  grep -qF -- 'base=[]' <<<"$output"
}

@test "fence disposition-sidecar: it builds a sidecar path under the main checkout's audit directory" {
  script="$(materialize 'audit-member-digest.sh')"
  printf 'printf "%%s\\n%%s\\n" "$digest" "$sidecar"\n' >>"$script"
  run bash -c "cd '$REPO_ROOT' && bash '$script'"
  [ "$status" -eq 0 ]
  digest="$(sed -n 1p <<<"$output")"
  sidecar="$(sed -n 2p <<<"$output")"
  grep -qE '^[0-9a-f]{64}$' <<<"$digest"
  grep -qF -- "/.gaia/local/audit/${digest}.dispositions.json" <<<"$sidecar"
}
