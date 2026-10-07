#!/usr/bin/env bats
#
# Doc-conformance suite for the generated orchestrator's lifecycle steps.
#
# .claude/skills/gaia/references/plan.md step 4 holds five verbatim step
# blocks a planner copies into a generated ORCHESTRATOR.md, each opening with
# a sentinel line plan-verify.sh checks: the UAT render, the owning-phase UAT
# gate, the pre-audit UAT checks, the wiki promotion and the post-merge
# close. .claude/skills/gaia/references/spec/lifecycle.md holds the
# procedures those blocks point at. This suite pins:
#
#   - each sentinel sits once in plan.md, inside a fenced block, and each
#     block carries the command or pointer it exists for;
#   - nothing in plan.md archives the plan folder or removes SPEC.md before
#     the post-merge close, and lifecycle.md's close confirms MERGED first;
#   - the blocks, assembled the way a planner copies them (indentation
#     kept), pass plan-verify.sh, and a dropped or reordered block fails it;
#   - the literal PROGRESS.md lines and report heading the runbooks and
#     resume helper key on;
#   - both pre-flights point at the shared sweep, whose reconcile scan runs
#     before the reap that reads what it stamps;
#   - the new PROGRESS.md blocks never move plan-resume-point.sh's answer.
#
# Every check is a function taking the file(s) it reads, so each red twin
# runs the same function against a mutated copy and proves it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAN_MD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  PLAN_VERIFY="$REPO_ROOT/.gaia/scripts/spec/plan-verify.sh"
  RESUME_POINT="$REPO_ROOT/.gaia/scripts/plan-resume-point.sh"
  S_RENDER='<!-- gaia:orchestrator-step uat-render -->'
  S_GATE='<!-- gaia:orchestrator-step uat-gate -->'
  S_PRE='<!-- gaia:orchestrator-step uat-pre-audit -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
}

# ---------- helpers ----------

# sentinel_set: the sentinel literals plan-verify.sh requires, in its order.
# plan-verify.sh owns the set, so the suite derives it rather than retyping it.
sentinel_set() {
  grep -oE "'<!-- gaia:orchestrator-step [a-z-]+ -->'" "$PLAN_VERIFY" | tr -d "'" | awk '!seen[$0]++'
}

# count_trimmed <file> <literal>: lines equal to <literal> after trimming.
count_trimmed() {
  awk -v want="$2" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { n++ } END { print n + 0 }' "$1"
}

# count_in_fences <file> <literal>: trimmed matches inside ``` fences.
count_in_fences() {
  awk -v want="$2" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^```/ { in_fence = !in_fence; next }
    in_fence && t == want { n++ }
    END { print n + 0 }' "$1"
}

# fence_with <file> <literal>: the raw lines (indentation kept, fence lines
# dropped) of the first ``` fence holding a line that trims to <literal>.
fence_with() {
  awk -v want="$2" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^```/ {
      if (in_fence) { if (hit) { printf "%s", buffer; exit } in_fence = 0 }
      else { in_fence = 1; buffer = ""; hit = 0 }
      next
    }
    in_fence { buffer = buffer $0 "\n"; if (t == want) hit = 1 }' "$1"
}

# line_of <file> <fixed string>: first line number holding it, or empty.
line_of() {
  grep -nF -m1 -- "$2" "$1" | cut -d: -f1
}

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

# section_of <file> <heading>: a "## " section up to the next "## " heading
# outside a fence (lifecycle.md carries "## " record lines inside fences).
section_of() {
  awk -v heading="$2" '
    { t = $0; sub(/^[ \t]+/, "", t) }
    t ~ /^```/ { in_fence = !in_fence }
    !in_fence && /^## / { if (inside) exit; if ($0 == heading) inside = 1 }
    inside { print }' "$1"
}

# ---------- checks (each returns non-zero with a reason) ----------

check_sentinels_once_in_fences() {
  local file="$1" sentinel total fenced count=0
  while IFS= read -r sentinel; do
    count=$((count + 1))
    total="$(count_trimmed "$file" "$sentinel")"
    fenced="$(count_in_fences "$file" "$sentinel")"
    if [ "$total" -ne 1 ] || [ "$fenced" -ne 1 ]; then
      printf '%s: %s appears %s times, %s inside a fence (want 1 and 1)\n' "$file" "$sentinel" "$total" "$fenced" >&2
      return 1
    fi
  done < <(sentinel_set)
  [ "$count" -eq 5 ] || { printf 'derived %s sentinels from plan-verify.sh, want 5\n' "$count" >&2; return 1; }
}

# check_block_has <file> <sentinel> <needle>...
check_block_has() {
  local file="$1" sentinel="$2" block needle
  shift 2
  block="$(fence_with "$file" "$sentinel")"
  [ -n "$block" ] || { printf 'no fenced block holds %s\n' "$sentinel" >&2; return 1; }
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$block" || { printf 'block %s lacks: %s\n' "$sentinel" "$needle" >&2; return 1; }
  done
}

check_block_contents() {
  local file="$1"
  check_block_has "$file" "$S_RENDER" 'uat-write.sh' '{SPEC_PATH}' '--routing' || return 1
  check_block_has "$file" "$S_GATE" 'uat-gate.sh' '--phase' || return 1
  check_block_has "$file" "$S_PRE" '--all' || return 1
  check_block_has "$file" "$S_WIKI" 'wiki-promote.md' || return 1
  check_block_has "$file" "$S_CLOSE" 'plan-archive.sh` runs only after `MERGED` is confirmed' || return 1
}

# Nothing above the post-merge-close sentinel names plan-archive.sh or
# removes SPEC.md / AUDIT.md.
check_plan_close_order() {
  local file="$1" close_line early
  close_line="$(awk -v want="$S_CLOSE" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print NR; exit }' "$file")"
  [ -n "$close_line" ] || { printf 'no post-merge-close sentinel in %s\n' "$file" >&2; return 1; }
  early="$(head -n "$((close_line - 1))" "$file" | grep -nF 'plan-archive.sh' || true)"
  [ -z "$early" ] || { printf 'plan-archive.sh named before the post-merge close: %s\n' "$early" >&2; return 1; }
  early="$(head -n "$((close_line - 1))" "$file" | grep -nE '(^|[^a-z])rm [^|;]*(SPEC|AUDIT)\.md' || true)"
  [ -z "$early" ] || { printf 'SPEC.md or AUDIT.md removed before the post-merge close: %s\n' "$early" >&2; return 1; }
}

# lifecycle.md's close confirms MERGED before it archives or removes.
check_lifecycle_close_order() {
  local file="$1" section merged archive removal
  section="$(section_of "$file" '## Post-merge close')"
  [ -n "$section" ] || { printf 'no ## Post-merge close section\n' >&2; return 1; }
  merged="$(grep -nF -m1 'MERGED' <<<"$section" | cut -d: -f1)"
  archive="$(grep -nF -m1 'plan-archive.sh' <<<"$section" | cut -d: -f1)"
  removal="$(grep -nE -m1 'rm [^|;]*SPEC\.md' <<<"$section" | cut -d: -f1)"
  { [ -n "$merged" ] && [ -n "$archive" ] && [ -n "$removal" ]; } || {
    printf 'close section lacks MERGED (%s), plan-archive.sh (%s) or the SPEC.md removal (%s)\n' "$merged" "$archive" "$removal" >&2
    return 1
  }
  [ "$merged" -lt "$archive" ] || { printf 'plan-archive.sh precedes MERGED in the close\n' >&2; return 1; }
  [ "$merged" -lt "$removal" ] || { printf 'SPEC.md removal precedes MERGED in the close\n' >&2; return 1; }
}

check_pinned_literals() {
  local plan="$1" lifecycle="$2" range block
  range="$(range_of "$plan" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**')"
  grep -qxE '[[:space:]]*### Logical UAT divergence' <<<"$range" || { printf 'sub-agent template lacks the divergence heading\n' >&2; return 1; }
  range="$(range_of "$plan" '**Stop conditions.**' '**Final summary.**')"
  grep -qF 'Reason: logical UAT divergence' <<<"$range" || { printf 'stop conditions lack Reason: logical UAT divergence\n' >&2; return 1; }
  grep -qiF 'reopen the SPEC' <<<"$range" || { printf 'stop conditions do not name the SPEC reopen\n' >&2; return 1; }
  check_block_has "$plan" "$S_RENDER" 'Skipped: no e2e-routed UATs' '## UAT render (HALTED)' 'Reason: UAT render conflict' || return 1
  block="$(fence_with "$plan" "$S_RENDER")"
  grep -qF 'Exit 3' <<<"$block" || { printf 'render block does not route exit 3\n' >&2; return 1; }
  grep -qF 'every resume' <<<"$block" || { printf 'render block does not run on resume\n' >&2; return 1; }
  section_of "$lifecycle" '## Owning-phase UAT gate' | grep -qF 'Reason: UAT gate failed' || { printf 'gate section lacks Reason: UAT gate failed\n' >&2; return 1; }
  check_block_has "$plan" "$S_WIKI" '## Wiki promotion' 'skipped-unattended' || return 1
}

check_preflight_sites() {
  local plan="$1" spec="$2" lifecycle="$3" range section scan reap
  range="$(range_of "$plan" '### 0. Pre-flight sweep' '### 1. Get description')"
  { grep -qF 'spec/lifecycle.md' <<<"$range" && grep -qF '## Pre-flight sweep' <<<"$range"; } || { printf 'plan.md step 0 does not point at the sweep\n' >&2; return 1; }
  range="$(range_of "$spec" '### 2. Resume-vs-start-new' '### 3. ')"
  { grep -qF 'spec/lifecycle.md' <<<"$range" && grep -qF '## Pre-flight sweep' <<<"$range"; } || { printf 'spec.md step 2 does not point at the sweep\n' >&2; return 1; }
  section="$(section_of "$lifecycle" '## Pre-flight sweep')"
  scan="$(grep -nF -m1 'plan-reconcile.sh "$PWD"' <<<"$section" | cut -d: -f1)"
  reap="$(grep -nF -m1 'plan-archive-merged.sh' <<<"$section" | cut -d: -f1)"
  { [ -n "$scan" ] && [ -n "$reap" ]; } || { printf 'sweep lacks the reconcile scan (%s) or the plan reap (%s)\n' "$scan" "$reap" >&2; return 1; }
  [ "$scan" -lt "$reap" ] || { printf 'the plan reap runs before the reconcile scan\n' >&2; return 1; }
  grep -qF 'GAIA_SPEC_RETENTION_DAYS' <<<"$section" || { printf 'sweep does not name GAIA_SPEC_RETENTION_DAYS\n' >&2; return 1; }
  section="$(section_of "$lifecycle" '## Post-merge close')"
  grep -E 'plan-reconcile\.sh' <<<"$section" | grep -F '"$PLAN_ID"' | grep -qE '"\$PLAN_ID" +"[^"]+"' || { printf 'post-merge close does not pass the PR number to plan-reconcile.sh\n' >&2; return 1; }
}

# assemble_orchestrator <plan.md> <out> <order...>: an ORCHESTRATOR.md made of
# the extracted blocks, indentation kept, in the given sentinel order.
assemble_orchestrator() {
  local source="$1" out="$2" sentinel block
  shift 2
  printf '# Orchestrator\n\nResume detection, pre-flight isolation, RUNNING sentinel.\n\n' >"$out"
  for sentinel in "$@"; do
    block="$(fence_with "$source" "$sentinel")"
    [ -n "$block" ] || { printf 'no block for %s\n' "$sentinel" >&2; return 1; }
    block="${block//\{SPEC_PATH\}/$FIXTURE_SPEC}"
    block="${block//\{PLAN_DIR\}/$FIXTURE_PLAN}"
    printf '%s\n\nprose between steps\n\n' "$block" >>"$out"
  done
}

write_plan_fixture() {
  FIXTURE_PLAN="$BATS_TEST_TMPDIR/plan"
  FIXTURE_SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  mkdir -p "$FIXTURE_PLAN"
  cat >"$FIXTURE_SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
---
EOF
  cat >"$FIXTURE_PLAN/README.md" <<'EOF'
# Plan

## UAT routing

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | e2e | 1 | checkout | guest-checkout-confirms-order.spec.ts |
<!-- gaia:uat-routing:end -->
EOF
  printf 'You are the orchestrator.\n' >"$FIXTURE_PLAN/KICKOFF.md"
  printf '# Task\n\n- builds checkout\n' >"$FIXTURE_PLAN/task-checkout.md"
}

# ---------- sentinels and block contents ----------

@test "each orchestrator sentinel sits once in plan.md, inside a fenced block" {
  check_sentinels_once_in_fences "$PLAN_MD"
}

@test "red twin: a duplicated or unfenced sentinel fails the sentinel check" {
  copy="$BATS_TEST_TMPDIR/plan.md"
  cp "$PLAN_MD" "$copy"
  printf '\n%s\n' "$S_GATE" >>"$copy"
  run check_sentinels_once_in_fences "$copy"
  [ "$status" -ne 0 ]
  # Unfenced: drop every fence line, so the sentinel lines sit in prose.
  grep -vE '^[[:space:]]*```' "$PLAN_MD" >"$copy"
  run check_sentinels_once_in_fences "$copy"
  [ "$status" -ne 0 ]
}

@test "each block carries the command or pointer it exists for" {
  check_block_contents "$PLAN_MD"
}

@test "red twin: a block missing its command fails the contents check" {
  copy="$BATS_TEST_TMPDIR/plan.md"
  local needle
  for needle in 'uat-write.sh' '--phase' '--all' 'wiki-promote.md' 'runs only after'; do
    awk -v needle="$needle" '{ gsub(needle, "removed") } { print }' "$PLAN_MD" >"$copy"
    run check_block_contents "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail the check" >&2; return 1; }
  done
}

# ---------- close order: nothing irreversible before MERGED ----------

@test "plan.md archives and removes layers only in or after the post-merge close" {
  check_plan_close_order "$PLAN_MD"
}

@test "red twin: an archive or a SPEC.md removal above the post-merge close fails" {
  copy="$BATS_TEST_TMPDIR/plan.md"
  { sed -n '1,20p' "$PLAN_MD"; printf '      bash .gaia/scripts/plan-archive.sh {PLAN_DIR}\n'; sed -n '21,$p' "$PLAN_MD"; } >"$copy"
  run check_plan_close_order "$copy"
  [ "$status" -ne 0 ]
  { sed -n '1,20p' "$PLAN_MD"; printf '      On exit 0, rm the folder SPEC.md and AUDIT.md.\n'; sed -n '21,$p' "$PLAN_MD"; } >"$copy"
  run check_plan_close_order "$copy"
  [ "$status" -ne 0 ]
}

@test "lifecycle.md's post-merge close confirms MERGED before archive and removal" {
  check_lifecycle_close_order "$LIFECYCLE_MD"
}

@test "red twin: an archive above the MERGED confirmation fails the close order" {
  copy="$BATS_TEST_TMPDIR/lifecycle.md"
  awk '{ print } /^## Post-merge close$/ { print ""; print "bash .gaia/scripts/plan-archive.sh <PLAN_DIR>" }' "$LIFECYCLE_MD" >"$copy"
  run check_lifecycle_close_order "$copy"
  [ "$status" -ne 0 ]
}

# ---------- assembled blocks pass plan-verify.sh ----------

@test "blocks copied as a planner copies them pass plan-verify.sh --spec" {
  write_plan_fixture
  assemble_orchestrator "$PLAN_MD" "$FIXTURE_PLAN/ORCHESTRATOR.md" "$S_RENDER" "$S_GATE" "$S_PRE" "$S_WIKI" "$S_CLOSE"
  # The copy keeps the template's indentation, so the trim rule is exercised.
  grep -qE "^[[:space:]]+<!-- gaia:orchestrator-step uat-render -->$" "$FIXTURE_PLAN/ORCHESTRATOR.md"
  run bash "$PLAN_VERIFY" "$FIXTURE_PLAN" --spec "$FIXTURE_SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "red twin: a dropped render block fails plan-verify.sh naming the sentinel" {
  write_plan_fixture
  assemble_orchestrator "$PLAN_MD" "$FIXTURE_PLAN/ORCHESTRATOR.md" "$S_GATE" "$S_PRE" "$S_WIKI" "$S_CLOSE"
  run bash "$PLAN_VERIFY" "$FIXTURE_PLAN" --spec "$FIXTURE_SPEC"
  [ "$status" -eq 1 ]
  grep -qF -- "missing the sentinel line $S_RENDER" <<<"$output"
}

@test "red twin: a render block below the gate block fails plan-verify.sh as out of order" {
  write_plan_fixture
  assemble_orchestrator "$PLAN_MD" "$FIXTURE_PLAN/ORCHESTRATOR.md" "$S_GATE" "$S_RENDER" "$S_PRE" "$S_WIKI" "$S_CLOSE"
  run bash "$PLAN_VERIFY" "$FIXTURE_PLAN" --spec "$FIXTURE_SPEC"
  [ "$status" -eq 1 ]
  grep -qF -- "$S_RENDER is out of order" <<<"$output"
}

# ---------- pinned literals ----------

@test "the report heading and PROGRESS.md record lines are pinned" {
  check_pinned_literals "$PLAN_MD" "$LIFECYCLE_MD"
}

@test "red twin: removing any pinned literal fails the literal check" {
  local literal target copy
  for literal in '### Logical UAT divergence' 'Reason: logical UAT divergence' 'Skipped: no e2e-routed UATs' \
    '## UAT render (HALTED)' 'Reason: UAT render conflict' 'skipped-unattended' 'Reason: UAT gate failed'; do
    plan_copy="$BATS_TEST_TMPDIR/plan.md"
    lifecycle_copy="$BATS_TEST_TMPDIR/lifecycle.md"
    cp "$PLAN_MD" "$plan_copy"
    cp "$LIFECYCLE_MD" "$lifecycle_copy"
    case "$literal" in
      'Reason: UAT gate failed') target="$lifecycle_copy" ;;
      *) target="$plan_copy" ;;
    esac
    awk -v literal="$literal" '{ while ((i = index($0, literal)) > 0) $0 = substr($0, 1, i - 1) "removed" substr($0, i + length(literal)) } { print }' "$target" >"$target.new"
    mv "$target.new" "$target"
    run check_pinned_literals "$plan_copy" "$lifecycle_copy"
    [ "$status" -ne 0 ] || { echo "removing '$literal' did not fail the check" >&2; return 1; }
  done
}

# ---------- pre-flight sweep call sites and order ----------

@test "both pre-flights point at the sweep, and its scan precedes the reap" {
  check_preflight_sites "$PLAN_MD" "$SPEC_MD" "$LIFECYCLE_MD"
}

@test "red twin: a reap above the scan, or a close without the PR number, fails" {
  copy="$BATS_TEST_TMPDIR/lifecycle.md"
  # Move the plan reap line to the top of the sweep section.
  awk '
    /^## Pre-flight sweep$/ { print; print ""; print "bash .gaia/scripts/spec/plan-archive-merged.sh \"$PWD\" 2>/dev/null || true"; next }
    { print }' "$LIFECYCLE_MD" >"$copy"
  run check_preflight_sites "$PLAN_MD" "$SPEC_MD" "$copy"
  [ "$status" -ne 0 ]
  sed 's/"\$PLAN_ID" "<N>"/"$PLAN_ID"/' "$LIFECYCLE_MD" >"$copy"
  run check_preflight_sites "$PLAN_MD" "$SPEC_MD" "$copy"
  [ "$status" -ne 0 ]
  plan_copy="$BATS_TEST_TMPDIR/plan.md"
  sed 's/### 0. Pre-flight sweep/### 0. Something else/' "$PLAN_MD" >"$plan_copy"
  run check_preflight_sites "$plan_copy" "$SPEC_MD" "$LIFECYCLE_MD"
  [ "$status" -ne 0 ]
}

# ---------- the resume helper ignores the new PROGRESS.md blocks ----------

resume_fixture() {
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  git -C "$REPO" -c core.hooksPath=/dev/null -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m one
  SHA_ONE="$(git -C "$REPO" rev-parse --short HEAD)"
  git -C "$REPO" -c core.hooksPath=/dev/null -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m two
  SHA_TWO="$(git -C "$REPO" rev-parse --short HEAD)"
  PROGRESS_DIR="$BATS_TEST_TMPDIR/progress"
  mkdir -p "$PROGRESS_DIR"
}

resume_point() {
  bash "$RESUME_POINT" --plan-dir "$PROGRESS_DIR" --phases 3 --git-dir "$REPO" | sed -n 1p
}

@test "the UAT render, wiki promotion and gate HALTED blocks leave the resume point unchanged" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two\nCommit: %s\n\n_No notes._\n' "$SHA_ONE" "$SHA_TWO" >"$PROGRESS_DIR/PROGRESS.md"
  baseline="$(resume_point)"
  [ "$baseline" = "3" ]
  cat >>"$PROGRESS_DIR/PROGRESS.md" <<'EOF'

## UAT render
Commit: none (nothing changed)
Summary: written 0, rewritten 0, unchanged 1, preserved 0, deleted 0, conflict 0

## UAT render (HALTED)
Reason: UAT render conflict
Spec files: frontend/.playwright/e2e/checkout/a.spec.ts changed-and-edited

## Wiki promotion
Default: ask   Choice: skipped-unattended
Pages: none   Commit: none
Reason: ask with no human present

## Phase 3, Three (HALTED)
Reason: UAT gate failed
Spec files: frontend/.playwright/e2e/checkout/a.spec.ts failed
EOF
  [ "$(resume_point)" = "$baseline" ]
}

@test "red twin: a HALTED phase 2 with no Commit line lowers the resume point" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two (HALTED)\nReason: UAT gate failed\n' "$SHA_ONE" >"$PROGRESS_DIR/PROGRESS.md"
  [ "$(resume_point)" = "2" ]
}
