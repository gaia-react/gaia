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
# resolve main first: the preset's step-2 item 3 (mkdir + first SPEC.md copy),
# and spec.md's 7d (AUDIT.md write) and 7c (the no-op guard's --audit-md
# argument).
#
# EXECUTE THE ARTIFACT, DO NOT PARAPHRASE IT. The precedent is
# doc-isolation.bats's "the policy read literal defaults to prefer-branch"
# test: it writes the fragment's OWN literal to a script and runs it, rather
# than re-typing an approximation, so the test executes the artifact instead
# of a paraphrase of it. A plain `grep` for `main-root-lib.sh` would pass on
# prose that merely NAMES the resolver while still joining a relative path.
# Tests 1 and 2 below extract the real literal/block from the live source
# files and run it; only test 3 (the weakest, deliberately third) is a plain
# grep, and it is scoped tightly to the three converted sites, not repo-wide.
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
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Absence
# checks are written as `<positive-condition-for-the-bad-case> && return 1`
# (or `case`+`return 1`), and POSIX `[ ]` covers equality/numeric/empty/file
# checks. A test whose LAST statement is such a check ends with an explicit
# `true`.
#
# WHAT EACH TEST CATCHES. Test 1 catches a bare-relative folder creation in
# the preset: run with cwd=worktree it creates the folder IN the worktree, not
# main. Test 2 catches an AUDIT.md path that 7d either never builds in shell
# (named only in inline prose, so there is nothing to execute) or builds
# without the resolver, so it lands in the acting worktree. Test 3 catches the
# bare relative `.gaia/local/specs/` literal returning to any of the three
# sites. Each extraction failure reports a legible reason rather than an
# opaque bash error.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PRESET_MD="$REPO_ROOT/.specify/presets/gaia/commands/speckit.specify.md"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"

  MAIN="$BATS_TEST_TMPDIR/main"
  WORKTREE="$BATS_TEST_TMPDIR/worktree"

  mkdir -p "$MAIN/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"

  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email 'test@example.com'
  git -C "$MAIN" config user.name 'Test'
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m 'init'
  git -C "$MAIN" worktree add -q -b wt-branch "$WORKTREE" main

  MAIN_PHYS="$(cd "$MAIN" && pwd -P)"
  WORKTREE_PHYS="$(cd "$WORKTREE" && pwd -P)"

  # Fixture soundness gate. If this does not hold, everything built on the
  # fixture is meaningless, so fail here with a clear reason instead of
  # letting a downstream assertion fail for a confusing reason.
  resolved="$(cd "$WORKTREE" && bash .gaia/scripts/main-root-lib.sh)"
  if [ "$resolved" != "$MAIN_PHYS" ]; then
    printf 'FIXTURE BROKEN: main-root-lib.sh run from the worktree resolved to "%s", expected main "%s"\n' \
      "$resolved" "$MAIN_PHYS" >&2
    return 1
  fi
}

# 1-based line number of the first line containing a fixed-string anchor.
_anchor_line() {
  grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1
}

# Text between two fixed-string anchors in a file: [start_anchor, end_anchor).
range_between() {
  local file="$1" start_pat="$2" end_pat="$3" s e
  s="$(_anchor_line "$file" "$start_pat")"
  e="$(_anchor_line "$file" "$end_pat")"
  sed -n "${s},$((e - 1))p" "$file"
}

@test "S1: the preset's step-2 item-3 mkdir literal executes into main, not the worktree" {
  block="$(range_between "$PRESET_MD" '3. Create the SPEC folder' '4. Stamp GAIA frontmatter')"

  # Run the fragment's real literal, rather than re-typing it, so this test
  # executes the artifact instead of a paraphrase of it. Item 3 can carry the
  # folder creation in either of two forms -- a ```bash fence (which resolves
  # the main checkout first, so one resolver call serves both the folder and
  # the copy) or a bare inline `mkdir -p` literal. Prefer the fence when one
  # is present and fall back to the inline literal, so the extraction stays
  # agnostic to the form and the assertions below judge only WHERE the folder
  # lands.
  create_literal="$(printf '%s\n' "$block" | awk '/^[[:space:]]*```bash/{f=1;next} /^[[:space:]]*```[[:space:]]*$/{f=0} f')"
  if [ -z "$create_literal" ]; then
    create_literal="$(printf '%s\n' "$block" | grep -oE '`mkdir -p [^`]*`' | head -1 | sed -E 's/^`//; s/`$//')"
  fi
  if [ -z "$create_literal" ]; then
    printf 'no shell fence and no `mkdir -p` literal found in the preset step-2 item 3\n' >&2
    return 1
  fi

  mkdir_cmd="${create_literal//<SPEC-NNN>/SPEC-999}"

  run bash -c "cd '$WORKTREE' && $mkdir_cmd"
  [ "$status" -eq 0 ]

  # (a) main must have received the folder.
  if [ ! -d "$MAIN_PHYS/.gaia/local/specs/SPEC-999" ]; then
    printf 'main never received .gaia/local/specs/SPEC-999 (ran: %s)\n' "$mkdir_cmd" >&2
    return 1
  fi

  # (b) THE LOAD-BEARING ASSERTION. Prose that merely names the resolver but
  # still joins a relative path cannot fake this: running a bare
  # `mkdir -p .gaia/local/specs/...` with cwd=worktree creates the folder
  # THERE, which this assertion catches even when (a) above happens to hold.
  if [ -d "$WORKTREE_PHYS/.gaia/local/specs" ]; then
    printf 'a forked .gaia/local/specs tree exists in the worktree: %s\n' "$WORKTREE_PHYS/.gaia/local/specs" >&2
    return 1
  fi
  true
}

@test "S2: 7d's AUDIT.md path resolves into main, not the worktree" {
  block="$(range_between "$SPEC_MD" '#### 7d. Persist AUDIT.md' '### 8. Gate 2')"

  # 7d carries more than one ```bash fence: the audit-window breadcrumb writer
  # sources `.gaia/scripts/audit-window-lib.sh` and calls its writer, neither
  # of which this fixture holds. Select ONLY the fence that constructs the
  # AUDIT.md path, so this test runs the block it measures and its status
  # reports on path anchoring alone.
  bash_fence="$(printf '%s\n' "$block" | awk '
    /^```bash/ { f = 1; buf = ""; next }
    /^```$/ { if (f && buf ~ /AUDIT\.md/) { printf "%s", buf; exit } f = 0; next }
    f { buf = buf $0 "\n" }
  ')"

  # Legible failure: no fence mentioning AUDIT.md means 7d names the path in
  # inline prose only, with no shell block to extract. Fail with a clear
  # reason here rather than an opaque bash error further down.
  if ! printf '%s\n' "$bash_fence" | grep -qF 'AUDIT.md'; then
    printf '7d has no shell block that constructs the AUDIT.md path; only inline prose names it.\n' >&2
    return 1
  fi

  audit_var="$(printf '%s\n' "$bash_fence" | grep -m1 -E '^[A-Za-z_][A-Za-z0-9_]*=.*AUDIT\.md' | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/')"
  if [ -z "$audit_var" ]; then
    printf 'found "AUDIT.md" text in the 7d shell block but no assignment line to read the resolved path from\n' >&2
    return 1
  fi

  script="$BATS_TEST_TMPDIR/audit-path.sh"
  {
    printf 'SPEC_ID="${SPEC_ID:-SPEC-999}"\n'
    printf 'spec_id="${spec_id:-SPEC-999}"\n'
    printf '%s\n' "$bash_fence"
    printf 'printf %%s "$%s"\n' "$audit_var"
  } > "$script"

  run bash -c "cd '$WORKTREE' && bash '$script'"
  [ "$status" -eq 0 ]

  case "$output" in
    "$MAIN_PHYS"/*) : ;;
    *)
      printf 'emitted AUDIT.md path "%s" is not under main root "%s"\n' "$output" "$MAIN_PHYS" >&2
      return 1
      ;;
  esac

  case "$output" in
    "$WORKTREE_PHYS"/*)
      printf 'emitted AUDIT.md path "%s" is under the WORKTREE, not main\n' "$output" >&2
      return 1
      ;;
  esac
  true
}

@test "negative space: no bare relative .gaia/local/specs/ write survives at the three converted sites" {
  s1="$(range_between "$PRESET_MD" '3. Create the SPEC folder' '4. Stamp GAIA frontmatter')"
  s2="$(range_between "$SPEC_MD" '#### 7d. Persist AUDIT.md' '### 8. Gate 2')"
  s3="$(range_between "$SPEC_MD" '#### 7c. Disposition routing + apply' '#### 7d. Persist AUDIT.md')"

  # Scoped tightly to the three write sites (not repo-wide): design section 2e
  # notes that display prose elsewhere (spec.md:840, :916, :920, the preset's
  # confirmation line) names the generic path for a human to read and is
  # deliberately not converted. Those lines sit outside all three ranges
  # above, so this check never has to special-case them.
  bad=""
  for site in "$s1" "$s2" "$s3"; do
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
