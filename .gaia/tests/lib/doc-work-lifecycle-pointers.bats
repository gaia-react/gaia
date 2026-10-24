#!/usr/bin/env bats
#
# Doc-pin: the two always-loaded or doctrine-injected pointer lines to the
# shared work-lifecycle reference stay single, resolvable and within budget,
# and no shipped lifecycle instruction creates a worktree with a plain
# `git worktree add`.
#
#   1. `.claude/rules/issue-claim.md` carries exactly one line naming
#      `work-lifecycle.md`; that line names the trigger (outside a GAIA skill,
#      committing) and the path it names exists.
#   2. `.claude/doctrine/execution.md` carries exactly one line naming
#      `work-lifecycle.md`, that line names the merge and cleanup steps, the
#      path exists, and the file passes the same shape check as the doctrine
#      sources suite: within the byte cap the injecting hook enforces (read
#      from the hook, never hard-coded here), one trailing newline, no control
#      bytes.
#   3. No fence in the files that carry the lifecycle holds `git worktree add`.
#
# Every check takes a root laid out like the repository, so the red twins run
# the same function against a mutated scratch copy.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCE='.claude/skills/gaia/references/work-lifecycle.md'
  ISSUE_CLAIM='.claude/rules/issue-claim.md'
  EXECUTION='.claude/doctrine/execution.md'
  HOOK='.claude/hooks/workflow-doctrine-inject.sh'
  REFERENCES='.claude/skills/gaia/references'
  FENCE_FILES=(
    "$REFERENCE"
    "$REFERENCES/isolation.md"
    "$REFERENCES/debt.md"
    "$REFERENCES/plan/planner.md"
    "$REFERENCES/spec/lifecycle.md"
    "$REFERENCES/fitness.md"
    "$REFERENCES/cleanse.md"
    "$REFERENCES/codify.md"
    "$REFERENCES/residue.md"
    .claude/skills/update-deps/SKILL.md
    .claude/skills/update-deps/references/publish.md
    .claude/skills/update-deps/references/worktree.md
    .claude/skills/update-gaia/SKILL.md
    "$ISSUE_CLAIM"
    "$EXECUTION"
  )
}

# byte_cap <root>: the maximum_bytes value the injecting hook enforces.
byte_cap() {
  sed -n 's/^maximum_bytes=\([0-9][0-9]*\)$/\1/p' "$1/$HOOK" | head -n 1
}

# shape_ok <file> <cap>: within the cap, one trailing newline, no control bytes.
shape_ok() {
  local file="$1" cap="$2"
  [ -f "$file" ] || return 1
  [ "$(wc -c <"$file" | tr -d ' ')" -le "$cap" ] || return 1
  [ "$(tail -c 1 "$file" | od -An -tx1 | tr -d ' \n')" = "0a" ] || return 1
  [ "$(tail -c 2 "$file" | od -An -tx1 | tr -d ' \n')" = "0a0a" ] && return 1
  LC_ALL=C grep -q $'[\x01-\x09\x0b-\x1f\x7f]' "$file" && return 1
  return 0
}

# pointer_line <file>: prints the lines of the file naming work-lifecycle.md.
pointer_line() { grep -F -- 'work-lifecycle.md' "$1" || true; }

# named_path_exists <root> <line>: the backticked repo path in the line exists.
named_path_exists() {
  local path
  path="$(printf '%s\n' "$2" | grep -oE '`[^`]*work-lifecycle\.md`' | head -n 1 | tr -d '`')"
  [ -n "$path" ] && [ -f "$1/$path" ]
}

# check_1 <root>
check_1() {
  local root="$1" lines
  lines="$(pointer_line "$root/$ISSUE_CLAIM")"
  [ -n "$lines" ] || { printf 'check1: no line names work-lifecycle.md\n'; return 1; }
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -eq 1 ] || { printf 'check1: more than one line names work-lifecycle.md\n'; return 1; }
  printf '%s\n' "$lines" | grep -qiF -- 'outside a GAIA skill' || { printf 'check1: the line does not name the trigger\n'; return 1; }
  printf '%s\n' "$lines" | grep -qF -- 'commit' || { printf 'check1: the line does not mention committing\n'; return 1; }
  named_path_exists "$root" "$lines" || { printf 'check1: the named path does not exist\n'; return 1; }
}

# check_2 <root>
check_2() {
  local root="$1" lines cap
  lines="$(pointer_line "$root/$EXECUTION")"
  [ -n "$lines" ] || { printf 'check2: no line names work-lifecycle.md\n'; return 1; }
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -eq 1 ] || { printf 'check2: more than one line names work-lifecycle.md\n'; return 1; }
  if ! printf '%s\n' "$lines" | grep -qF -- '## 7. Merge (when asked)'; then
    printf '%s\n' "$lines" | grep -qF -- 'Merge' && printf '%s\n' "$lines" | grep -qF -- 'Cleanup' ||
      { printf 'check2: the line does not name the merge and cleanup steps\n'; return 1; }
  fi
  named_path_exists "$root" "$lines" || { printf 'check2: the named path does not exist\n'; return 1; }
  cap="$(byte_cap "$root")"
  [ -n "$cap" ] || { printf 'check2: no maximum_bytes line in %s\n' "$HOOK"; return 1; }
  shape_ok "$root/$EXECUTION" "$cap" || { printf 'check2: %s fails the shape check at cap %s\n' "$EXECUTION" "$cap"; return 1; }
}

# fence_with_worktree_add <file>: prints the number of fences holding `git worktree add`.
fence_with_worktree_add() {
  awk '
    !open && /^[[:space:]]*```/ { open = 1; body = ""; next }
    open && /^[[:space:]]*```[[:space:]]*$/ { open = 0; if (index(body, "git worktree add") > 0) hits++; next }
    open { body = body $0 "\n" }
    END { print hits + 0 }
  ' "$1"
}

# check_3 <root>
check_3() {
  local root="$1" failed=0 relative
  for relative in "${FENCE_FILES[@]}"; do
    if [ ! -f "$root/$relative" ]; then
      printf 'check3: %s missing\n' "$relative"
      failed=1
      continue
    fi
    if [ "$(fence_with_worktree_add "$root/$relative")" -gt 0 ]; then
      printf 'check3: %s holds a fence with git worktree add\n' "$relative"
      failed=1
    fi
  done
  return "$failed"
}

# scratch_copy: copies every file this suite reads into a scratch root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root" relative
  rm -rf "$copy"
  for relative in "${FENCE_FILES[@]}" "$HOOK"; do
    mkdir -p "$copy/$(dirname "$relative")"
    cp "$REPO_ROOT/$relative" "$copy/$relative"
  done
  printf '%s\n' "$copy"
}

# --- the checks on the real tree -----------------------------------------

# bats test_tags=whole-tree
@test "issue-claim.md carries one pointer line naming the trigger and an existing path" {
  run check_1 "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "execution.md carries one pointer line naming merge and cleanup, within the hook's byte cap" {
  run check_2 "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "no lifecycle instruction holds a fence with git worktree add" {
  run check_3 "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# --- red twins -----------------------------------------------------------

@test "red twin: a second line naming work-lifecycle.md in an issue-claim copy fails check 1" {
  local copy
  copy="$(scratch_copy)"
  run check_1 "$copy"
  [ "$status" -eq 0 ]
  printf -- '- Also see `%s` outside a GAIA skill when you commit.\n' "$REFERENCE" >>"$copy/$ISSUE_CLAIM"
  run check_1 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'more than one line'
}

@test "red twin: a pointer to a path that does not exist fails check 1" {
  local copy
  copy="$(scratch_copy)"
  sed 's#skills/gaia/references/work-lifecycle\.md#skills/gaia/missing/work-lifecycle.md#' "$copy/$ISSUE_CLAIM" >"$copy/claim.tmp"
  mv "$copy/claim.tmp" "$copy/$ISSUE_CLAIM"
  run check_1 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'does not exist'
}

@test "red twin: an execution.md copy padded past the cap fails check 2" {
  local copy cap size
  copy="$(scratch_copy)"
  run check_2 "$copy"
  [ "$status" -eq 0 ]
  cap="$(byte_cap "$copy")"
  size="$(wc -c <"$copy/$EXECUTION" | tr -d ' ')"
  head -c $((cap - size + 1)) /dev/zero | tr '\0' 'x' >"$BATS_TEST_TMPDIR/padding"
  { cat "$copy/$EXECUTION"; cat "$BATS_TEST_TMPDIR/padding"; printf '\n'; } >"$copy/execution.tmp"
  mv "$copy/execution.tmp" "$copy/$EXECUTION"
  run check_2 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'shape check'
}

@test "red twin: a git worktree add fence appended to a debt.md copy fails check 3 and names debt.md" {
  local copy
  copy="$(scratch_copy)"
  run check_3 "$copy"
  [ "$status" -eq 0 ]
  printf '\n```bash\ngit worktree add .claude/worktrees/x -b x\n```\n' >>"$copy/$REFERENCES/debt.md"
  run check_3 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "check3: $REFERENCES/debt.md "
}
