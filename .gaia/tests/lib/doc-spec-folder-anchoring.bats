#!/usr/bin/env bats
#
# Doc-conformance suite for SPEC-folder coherence: proves that GAIA's
# SPEC-folder writes land in the MAIN checkout when the acting session runs
# inside a linked git worktree.
#
# THE PROBLEM. The registry declares `specs/` main-only (`.gaia/state-registry.json`,
# entry `specs-main`), and `gaia_registry_main_only_dirs`'s own contract
# (.gaia/scripts/state-registry-lib.sh) says a linked worktree has NO OWN COPY
# of a main-only directory. A relative `.gaia/local/specs/...` write issued
# from a worktree therefore does not reach main -- it forks a second specs
# tree inside the worktree. Three sites write the SPEC folder and must each
# resolve main first: spec.md step 3's folder creation (the mkdir fence),
# and spec.md's 7d (AUDIT.md write) and 7c (where the AUDIT.md path the
# applier's report lands at is built).
#
# THE READ SIDE IS THE SAME CLASS. Once the writes land in main, a read that
# still builds a relative `.gaia/local/specs` path looks into a tree that holds
# no SPECs at all. Three read sites in spec.md build the path themselves rather
# than handing it to a library: step 2's cold-consolidation sweep (the ledger
# scan plus the per-candidate folder), step 2's resume-point recency comparison
# (the canonical `SPEC.md` half of it; the draft cache is per-tree and stays in
# the acting worktree), and step 9.2's read of the `dollars` field from the
# SPEC folder's `cost.json` sidecar -- whose write, one block above it, is
# already main-anchored.
#
# EXECUTE THE ARTIFACT, DO NOT PARAPHRASE IT. The precedent is
# doc-merge-workflow-fences.bats's "fence resolve-mode: eval-ing it puts a
# resolved_mode and a should_run in scope" test: it writes the fragment's OWN
# literal to a script and runs it, rather than re-typing an approximation, so
# the test executes the artifact instead of a paraphrase of it. A plain
# `grep` for `main-root-lib.sh` would pass on prose that merely NAMES the
# resolver while still joining a relative path.
# Tests 1 and 2 below extract the real literal/block from the live source
# files and run it; only test 3 (the weakest, deliberately third) is a plain
# grep, and it is scoped tightly to the converted sites, not repo-wide.
#
# FIXTURE. A real `git init` main checkout plus a real `git worktree add`
# linked worktree, both under BATS_TEST_TMPDIR. `.gaia/scripts/main-root-lib.sh`
# is copied into the main checkout and committed BEFORE the worktree is
# created, so the worktree receives it the same way it would receive any
# other tracked repo script -- via git, not a second copy. Every extracted
# block runs with the WORKTREE as the working directory. setup() self-checks
# the fixture (`bash .gaia/scripts/main-root-lib.sh` from the worktree must
# print MAIN's path) and fails loudly if that basic precondition does not
# hold, so a fixture bug is never mistaken for a real red.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
# WHAT EACH TEST CATCHES. Test 1 catches a bare-relative folder creation in
# step 3: run with cwd=worktree it creates the folder IN the worktree, not
# main, and it also runs the fence with the resolver failing to prove the
# fail-closed branch creates nothing. Test 2 catches an AUDIT.md path that 7d either never builds in shell
# (named only in inline prose, so there is nothing to execute) or builds
# without the resolver, so it lands in the acting worktree. Test 3 catches the
# bare relative `.gaia/local/specs/` literal returning to any of the three
# write sites. Each extraction failure reports a legible reason rather than an
# opaque bash error.
#
# The two read tests use a DECOY: the worktree is seeded with its own forked
# specs tree naming a different SPEC id, and main with the canonical one. A
# read that resolves main returns main's id; a read that stays relative returns
# the decoy. That distinguishes a genuinely anchored read from one that merely
# happens to find something, which an "is the result non-empty" assertion
# cannot. The third read site (step 9.2's `cost.json` read) is prose an agent
# executes with a file read, not a shell block, so it is covered by the
# read-side negative-space test rather than by execution.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"

  MAIN="$BATS_TEST_TMPDIR/main"
  WORKTREE="$BATS_TEST_TMPDIR/worktree"

  mkdir -p "$MAIN/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"
  # The cold-consolidation sweep gates each candidate on the real verify
  # script, so the fixture carries the real script rather than letting a
  # missing-file failure stand in for a failed verify.
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$MAIN/.gaia/scripts/summary-verify.sh"

  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email 'test@example.com'
  git -C "$MAIN" config user.name 'Test'
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m 'init'
  git -C "$MAIN" worktree add -q -b wt-branch "$WORKTREE" main

  MAIN_PHYSICAL_PATH="$(cd "$MAIN" && pwd -P)"
  WORKTREE_PHYSICAL_PATH="$(cd "$WORKTREE" && pwd -P)"

  # Fixture soundness gate. If this does not hold, everything built on the
  # fixture is meaningless, so fail here with a clear reason instead of
  # letting a downstream assertion fail for a confusing reason.
  resolved="$(cd "$WORKTREE" && bash .gaia/scripts/main-root-lib.sh)"
  if [ "$resolved" != "$MAIN_PHYSICAL_PATH" ]; then
    printf 'FIXTURE BROKEN: main-root-lib.sh run from the worktree resolved to "%s", expected main "%s"\n' \
      "$resolved" "$MAIN_PHYSICAL_PATH" >&2
    return 1
  fi
}

# 1-based line number of the first line containing a fixed-string anchor.
_anchor_line() {
  grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1
}

# Text between two fixed-string anchors in a file: [start_anchor, end_anchor).
#
# Both anchors are checked before use. Without the guards a prose reflow that
# moves an anchor makes `$end_line` empty, `$((end_line - 1))` becomes -1, and sed aborts
# with `expected context address` BEFORE any assertion in the caller runs --
# so the test fails for a reason that names neither the anchor nor the file,
# and every assertion downstream of the extraction is silently not evaluated.
# Several call sites route through here, so the diagnosis is worth the lines
# it costs.
range_between() {
  local file="$1" start_pattern="$2" end_pattern="$3" start_line end_line
  start_line="$(_anchor_line "$file" "$start_pattern")"
  end_line="$(_anchor_line "$file" "$end_pattern")"
  [ -n "$start_line" ] || { printf 'start anchor not found in %s: %s\n' "$file" "$start_pattern" >&2; return 1; }
  [ -n "$end_line" ] || { printf 'end anchor not found in %s: %s\n' "$file" "$end_pattern" >&2; return 1; }
  sed -n "${start_line},$((end_line - 1))p" "$file"
}

@test "S1: spec.md step 3's folder-creation fence executes into main, not the worktree" {
  block="$(range_between "$SPEC_MD" '### 3. Initial draft' '### 4. Gate 1')"

  # Select ONLY the bash fence that creates the folder (the one carrying
  # `mkdir -p`), so the allocator fence beside it is never executed here.
  fence="$(printf '%s\n' "$block" | awk '
    /^```bash/ { inside_fence = 1; fence_text = ""; next }
    /^```[[:space:]]*$/ { if (inside_fence && fence_text ~ /mkdir -p/) { printf "%s", fence_text; exit } inside_fence = 0; next }
    inside_fence { fence_text = fence_text $0 "\n" }
  ')"
  if [ -z "$fence" ]; then
    printf 'no bash fence containing `mkdir -p` found in spec.md step 3\n' >&2
    return 1
  fi

  # Run the fence's real literal, rather than re-typing it, so this test
  # executes the artifact instead of a paraphrase of it.
  script="$BATS_TEST_TMPDIR/step3-create-folder.sh"
  printf '%s\n' "$fence" > "$script"

  run bash -c "cd '$WORKTREE' && SPEC_ID=SPEC-999 bash '$script'"
  [ "$status" -eq 0 ]

  # (a) main must have received the folder.
  if [ ! -d "$MAIN_PHYSICAL_PATH/.gaia/local/specs/SPEC-999" ]; then
    printf 'main never received .gaia/local/specs/SPEC-999 (ran: %s)\n' "$fence" >&2
    return 1
  fi

  # (b) THE LOAD-BEARING ASSERTION. Prose that merely names the resolver but
  # still joins a relative path cannot fake this: running a bare
  # `mkdir -p .gaia/local/specs/...` with cwd=worktree creates the folder
  # THERE, which this assertion catches even when (a) above happens to hold.
  if [ -d "$WORKTREE_PHYSICAL_PATH/.gaia/local/specs" ]; then
    printf 'a forked .gaia/local/specs tree exists in the worktree: %s\n' "$WORKTREE_PHYSICAL_PATH/.gaia/local/specs" >&2
    return 1
  fi

  # (c) Fail-closed branch: with a resolver that prints nothing and exits
  # non-zero, the fence must refuse with its own message, exit non-zero, and
  # create no specs tree anywhere under the fixture. Without the empty-MAIN_ROOT
  # guard it would attempt `mkdir -p /.gaia/local/specs/...` at the filesystem root.
  broken="$BATS_TEST_TMPDIR/broken-resolver"
  mkdir -p "$broken/.gaia/scripts"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$broken/.gaia/scripts/main-root-lib.sh"

  run bash -c "cd '$broken' && SPEC_ID=SPEC-998 bash '$script'"
  if [ "$status" -eq 0 ]; then
    printf 'the fence exited 0 although the main checkout could not be resolved\n' >&2
    return 1
  fi
  # The refusal message is what proves the guard, not a later mkdir failure
  # at a read-only filesystem root, ran.
  if ! printf '%s\n' "$output" | grep -qF 'refusing to create the SPEC folder'; then
    printf 'the fence failed without its own refusal message (output: "%s")\n' "$output" >&2
    return 1
  fi
  if find "$broken" -type d -name specs | grep -q .; then
    printf 'the fence created a specs tree under the fixture despite an unresolved main checkout\n' >&2
    return 1
  fi
  true
}

@test "S2: 7c's AUDIT.md path resolves into main, not the worktree" {
  # The AUDIT.md path is built at the top of 7c, where the applier dispatch
  # that consumes ${SPEC_DIR}/${AUDIT_MD} first needs it; 7d writes the report
  # and resolves no path of its own. Anchor on the step that does the
  # resolving, not the step that does the writing.
  block="$(range_between "$SPEC_MD" '#### 7c. Disposition routing + apply' '#### 7d. Persist AUDIT.md')"

  # The range can carry more than one ```bash fence: the audit-window breadcrumb writer
  # sources `.gaia/scripts/audit-window-lib.sh` and calls its writer, neither
  # of which this fixture holds. Select ONLY the fence that constructs the
  # AUDIT.md path, so this test runs the block it measures and its status
  # reports on path anchoring alone.
  bash_fence="$(printf '%s\n' "$block" | awk '
    /^```bash/ { inside_fence = 1; fence_text = ""; next }
    /^```$/ { if (inside_fence && fence_text ~ /AUDIT\.md/) { printf "%s", fence_text; exit } inside_fence = 0; next }
    inside_fence { fence_text = fence_text $0 "\n" }
  ')"

  # Legible failure: no fence mentioning AUDIT.md means 7d names the path in
  # inline prose only, with no shell block to extract. Fail with a clear
  # reason here rather than an opaque bash error further down.
  if ! printf '%s\n' "$bash_fence" | grep -qF 'AUDIT.md'; then
    printf '7d has no shell block that constructs the AUDIT.md path; only inline prose names it.\n' >&2
    return 1
  fi

  audit_variable_name="$(printf '%s\n' "$bash_fence" | grep -m1 -E '^[A-Za-z_][A-Za-z0-9_]*=.*AUDIT\.md' | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/')"
  if [ -z "$audit_variable_name" ]; then
    printf 'found "AUDIT.md" text in the 7d shell block but no assignment line to read the resolved path from\n' >&2
    return 1
  fi

  script="$BATS_TEST_TMPDIR/audit-path.sh"
  {
    printf 'SPEC_ID="${SPEC_ID:-SPEC-999}"\n'
    printf 'spec_id="${spec_id:-SPEC-999}"\n'
    printf '%s\n' "$bash_fence"
    printf 'printf %%s "$%s"\n' "$audit_variable_name"
  } > "$script"

  run bash -c "cd '$WORKTREE' && bash '$script'"
  [ "$status" -eq 0 ]

  case "$output" in
    "$MAIN_PHYSICAL_PATH"/*) : ;;
    *)
      printf 'emitted AUDIT.md path "%s" is not under main root "%s"\n' "$output" "$MAIN_PHYSICAL_PATH" >&2
      return 1
      ;;
  esac

  case "$output" in
    "$WORKTREE_PHYSICAL_PATH"/*)
      printf 'emitted AUDIT.md path "%s" is under the WORKTREE, not main\n' "$output" >&2
      return 1
      ;;
  esac
  true
}

# The ```bash fence inside an extracted range, as a runnable script.
bash_fence_of() {
  printf '%s\n' "$1" | awk '/^```bash/{inside_fence=1;next} /^```[[:space:]]*$/{inside_fence=0} inside_fence'
}

# main holds the canonical SPEC-999; the worktree holds a forked SPEC-888. A
# read that resolves main sees 999; a read that stays relative sees 888.
seed_decoy() {
  mkdir -p "$MAIN_PHYSICAL_PATH/.gaia/local/specs/SPEC-999"
  printf '# canonical\n' > "$MAIN_PHYSICAL_PATH/.gaia/local/specs/SPEC-999/SPEC.md"
  printf '{"specs":[{"id":"SPEC-999","status":"merged"}]}\n' \
    > "$MAIN_PHYSICAL_PATH/.gaia/local/specs/ledger.json"

  mkdir -p "$WORKTREE_PHYSICAL_PATH/.gaia/local/specs/SPEC-888"
  printf '# forked decoy\n' > "$WORKTREE_PHYSICAL_PATH/.gaia/local/specs/SPEC-888/SPEC.md"
  printf '{"specs":[{"id":"SPEC-888","status":"merged"}]}\n' \
    > "$WORKTREE_PHYSICAL_PATH/.gaia/local/specs/ledger.json"
}

@test "R1: step 2's cold-consolidation sweep reads the ledger and folders from main" {
  # End anchor is the retention-sweep paragraph, not the "For each candidate
  # id" one: the latter's wording is prose that names the per-candidate folder
  # variable and is free to change, while this heading-like sentence opens the
  # next distinct pass. The intervening paragraph carries no ```bash fence, so
  # widening the range does not change which fence bash_fence_of selects.
  block="$(range_between "$SPEC_MD" 'Then, for any merged row whose folder still holds' 'Then delete any merged SPEC folder')"
  fence="$(bash_fence_of "$block")"

  if ! printf '%s\n' "$fence" | grep -qF 'ledger.json'; then
    printf "step 2's cold-consolidation sweep has no shell block that reads the SPEC ledger\n" >&2
    return 1
  fi

  seed_decoy

  script="$BATS_TEST_TMPDIR/sweep.sh"
  printf '%s\n' "$fence" > "$script"

  run bash -c "cd '$WORKTREE' && bash '$script'"
  [ "$status" -eq 0 ]

  if ! printf '%s\n' "$output" | grep -qF 'SPEC-999'; then
    printf 'the sweep run from the worktree never reached main'"'"'s merged SPEC-999 (output: "%s")\n' "$output" >&2
    return 1
  fi

  # THE LOAD-BEARING ASSERTION. Emitting the worktree's forked id is proof the
  # ledger scan and the per-candidate folder are still relative.
  if printf '%s\n' "$output" | grep -qF 'SPEC-888'; then
    printf 'the sweep read the worktree'"'"'s forked specs tree (emitted SPEC-888): "%s"\n' "$output" >&2
    return 1
  fi
  true
}

@test "R2: the resume-point comparison resolves the canonical SPEC path into main" {
  block="$(range_between "$SPEC_MD" 'Before prompting, gather context' 'Before presenting the resume choice')"
  fence="$(bash_fence_of "$block")"

  if ! printf '%s\n' "$fence" | grep -qF 'SPEC_PATH'; then
    printf "the resume-point block does not build SPEC_PATH; nothing to measure\n" >&2
    return 1
  fi

  seed_decoy
  # The block's own placeholder for the allocator's answer. Substituting it
  # keeps this an execution of the artifact rather than a re-typed paraphrase.
  fence="${fence//<from allocator>/SPEC-999}"

  script="$BATS_TEST_TMPDIR/resume.sh"
  {
    printf '%s\n' "$fence"
    printf 'printf %%s "$WORKING"\n'
  } > "$script"

  # No draft cache exists, so WORKING is the canonical artifact's path -- the
  # half of the comparison this task anchors. The draft cache is per-tree by
  # registry classification and deliberately stays relative to the acting tree.
  run bash -c "cd '$WORKTREE' && bash '$script'"
  [ "$status" -eq 0 ]

  case "$output" in
    "$MAIN_PHYSICAL_PATH"/*) : ;;
    *)
      printf 'the resume point "%s" is not under main root "%s"\n' "$output" "$MAIN_PHYSICAL_PATH" >&2
      return 1
      ;;
  esac

  case "$output" in
    "$WORKTREE_PHYSICAL_PATH"/*)
      printf 'the resume point "%s" is under the WORKTREE, not main\n' "$output" >&2
      return 1
      ;;
  esac
  true
}

@test "negative space: no bare relative .gaia/local/specs/ read survives at the three converted read sites" {
  sweep_range="$(range_between "$SPEC_MD" 'Then, for any merged row whose folder still holds' 'Then delete any merged SPEC folder')"
  resume_range="$(range_between "$SPEC_MD" 'Before prompting, gather context' 'Before presenting the resume choice')"
  session_helper_range="$(range_between "$SPEC_MD" 'The helper reads `CLAUDE_CODE_SESSION_ID`' '**Auto-mode:** the tally fires identically')"

  # Ranges are scoped to the executable instructions only. Display prose that
  # names the generic path for a human to read (the draft-phase note above the
  # resume block, step 9's own narration) sits outside all three and is
  # deliberately not converted.
  bad=""
  for site in "$sweep_range" "$resume_range" "$session_helper_range"; do
    hit="$(printf '%s\n' "$site" | grep -F '.gaia/local/specs/' | grep -v -E 'MAIN_ROOT|SPEC_DIR' || true)"
    if [ -n "$hit" ]; then
      bad="${bad}${hit}
"
    fi
  done

  if [ -n "$bad" ]; then
    printf 'unanchored .gaia/local/specs/ read survives at a converted site:\n%s\n' "$bad" >&2
    return 1
  fi
  true
}

@test "negative space: no bare relative .gaia/local/specs/ write survives at the converted sites" {
  step3_range="$(range_between "$SPEC_MD" '### 3. Initial draft' '### 4. Gate 1')"
  # routing_range (7c) is where the AUDIT.md path is actually constructed, so it is the
  # range this negative check earns its keep on; the positive assertion in S2
  # anchors there too. persist_range (7d) is retained as a genuine no-regression range:
  # 7d writes the report at the path it was handed and must never grow a path
  # construct of its own, relative or otherwise. Do not read persist_range passing as
  # evidence the write site is covered -- routing_range and S2 are what cover it.
  persist_range="$(range_between "$SPEC_MD" '#### 7d. Persist AUDIT.md' '### 8. Gate 2')"
  routing_range="$(range_between "$SPEC_MD" '#### 7c. Disposition routing + apply' '#### 7d. Persist AUDIT.md')"

  # Scoped tightly to the write sites (not repo-wide): design section 2e
  # notes that display prose elsewhere (spec.md:840, :916, :920, step 3's
  # confirmation line) names the generic path for a human to read and is
  # deliberately not converted. Those lines sit outside all three ranges
  # above, so this check never has to special-case them.
  bad=""
  for site in "$step3_range" "$persist_range" "$routing_range"; do
    hit="$(printf '%s\n' "$site" | grep -F '.gaia/local/specs/' | grep -v -E 'MAIN_ROOT|SPEC_DIR' || true)"
    if [ -n "$hit" ]; then
      bad="${bad}${hit}
"
    fi
  done

  if [ -n "$bad" ]; then
    printf 'unanchored .gaia/local/specs/ write survives at a converted site:\n%s\n' "$bad" >&2
    return 1
  fi
  true
}
