#!/usr/bin/env bats
#
# Doc-pin: every GAIA command that publishes its own pull request isolates its
# work through the shared isolation reference, and none keeps an "on any other
# branch, write in place" arm of its own.
#
#   1. Each command in the roster: its reference names isolation.md, binds the
#      slots, and mints the branch name from branch-name-lib.sh; no file of
#      the command carries an in-place arm.
#      The update commands isolate through their own worktree references
#      rather than the roster's slots, so they get the in-place scan alone.
#   2. Each command file keeps its worktree refusal, then the anchor line a
#      later pre-flight check goes beside, then the dispatch line, in that
#      order.
#   3. Census: every instruction file under .claude/commands and .claude/skills
#      that cuts a branch or opens a pull request names isolation.md, unless
#      the exemption list below names it with its reason. A command added
#      later without the pointer is caught here.
#
# Every check takes a root laid out like the repository, so the red twins run
# the same function against a mutated scratch copy.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES='.claude/skills/gaia/references'
  # command file|reference that isolates|branch kind|further files with no in-place arm
  ROSTER=(
    ".claude/commands/gaia-residue.md|$REFERENCES/residue.md|residue|"
    ".claude/commands/gaia-codify.md|$REFERENCES/codify.md|codify|"
    ".claude/commands/gaia-fitness.md|$REFERENCES/fitness.md|fitness|"
    ".claude/commands/gaia-cleanse.md|$REFERENCES/cleanse.md|cleanse|$REFERENCES/cleanse/publish.md $REFERENCES/cleanse/apply.md"
    ".claude/skills/gaia-wiki/SKILL.md|$REFERENCES/wiki.md|wiki|"
  )
  # Files that cut a branch or open a pull request without isolation.md, each
  # with its reason.
  EXEMPT=(
    # Release tags main: its preflight refuses any branch but a clean main.
    ".claude/commands/gaia-release.md"
    # Names `gh pr create` only to say which output a cost record reads.
    "$REFERENCES/cost-record.md"
    # The isolation reference itself.
    "$REFERENCES/isolation.md"
    # Publishes from the worktree its own references/worktree.md creates; the
    # update-command scan below still reads it for an in-place arm.
    ".claude/skills/update-deps/references/publish.md"
  )
  # Update-command files that must keep no in-place arm.
  UPDATE_FILES=(
    ".claude/skills/update-deps/SKILL.md"
    ".claude/skills/update-deps/references/publish.md"
    ".claude/skills/update-deps/references/worktree.md"
    ".claude/skills/update-gaia/SKILL.md"
    ".claude/skills/update-gaia/references/claim-flow.md"
    ".claude/skills/update-gaia/references/pull-mode.md"
  )
  ANCHOR='Anchor for the next pre-flight step'
}

# in_place_arms <file>: prints each line holding an in-place publish arm.
in_place_arms() {
  grep -nE 'On any other branch|Any other branch \(in-place|[Aa]ny other branch.*in place|[Ii]n place.*[Aa]ny other branch|already on a non-default branch|ride the current branch|apply in place|the run commits in place' "$1" || true
}

# check_roster <root>
check_roster() {
  local root="$1" row command_file reference kind further file failed=0
  [ "${#ROSTER[@]}" -eq 5 ] || { printf 'roster: expected 5 rows, read %s\n' "${#ROSTER[@]}"; return 1; }
  for row in "${ROSTER[@]}"; do
    IFS='|' read -r command_file reference kind further <<<"$row"
    if [ ! -f "$root/$reference" ]; then
      printf 'roster: %s missing\n' "$reference"
      failed=1
      continue
    fi
    grep -qF -- '`.claude/skills/gaia/references/isolation.md`' "$root/$reference" ||
      { printf 'roster: %s does not name isolation.md\n' "$reference"; failed=1; }
    grep -qF -- '{{SUBJECT}}' "$root/$reference" ||
      { printf 'roster: %s binds no isolation slots\n' "$reference"; failed=1; }
    grep -qF -- "bash .gaia/scripts/branch-name-lib.sh name $kind" "$root/$reference" ||
      { printf 'roster: %s does not mint a %s branch name\n' "$reference" "$kind"; failed=1; }
    # shellcheck disable=SC2086
    for file in "$command_file" "$reference" $further; do
      [ -f "$root/$file" ] || { printf 'roster: %s missing\n' "$file"; failed=1; continue; }
      if [ -n "$(in_place_arms "$root/$file")" ]; then
        printf 'roster: %s keeps an in-place arm:\n%s\n' "$file" "$(in_place_arms "$root/$file")"
        failed=1
      fi
    done
  done
  return "$failed"
}

# check_update_commands <root>
check_update_commands() {
  local root="$1" file failed=0
  [ "${#UPDATE_FILES[@]}" -eq 6 ] || { printf 'update: expected 6 files, read %s\n' "${#UPDATE_FILES[@]}"; return 1; }
  for file in "${UPDATE_FILES[@]}"; do
    [ -f "$root/$file" ] || { printf 'update: %s missing\n' "$file"; failed=1; continue; }
    if [ -n "$(in_place_arms "$root/$file")" ]; then
      printf 'update: %s keeps an in-place arm:\n%s\n' "$file" "$(in_place_arms "$root/$file")"
      failed=1
    fi
  done
  return "$failed"
}

# first_line <file> <fixed string>: the line number of the first line holding it, or 0.
first_line() {
  local number
  number="$(grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1)"
  printf '%s\n' "${number:-0}"
}

# check_preflight <root>
check_preflight() {
  local root="$1" row command_file refusal anchor dispatch failed=0
  for row in "${ROSTER[@]}"; do
    command_file="${row%%|*}"
    refusal="$(first_line "$root/$command_file" 'gaia_refuse_if_worktree "')"
    anchor="$(first_line "$root/$command_file" "$ANCHOR")"
    dispatch="$(first_line "$root/$command_file" 'Read `.claude/skills/gaia/references/')"
    if [ "$refusal" -eq 0 ] || [ "$anchor" -eq 0 ] || [ "$dispatch" -eq 0 ]; then
      printf 'preflight: %s lacks the refusal (%s), the anchor (%s) or the dispatch line (%s)\n' \
        "$command_file" "$refusal" "$anchor" "$dispatch"
      failed=1
      continue
    fi
    if [ "$refusal" -ge "$anchor" ] || [ "$anchor" -ge "$dispatch" ]; then
      printf 'preflight: %s orders refusal %s, anchor %s, dispatch %s\n' "$command_file" "$refusal" "$anchor" "$dispatch"
      failed=1
    fi
  done
  return "$failed"
}

# publishing_files <root>: instruction files that cut a branch or open a PR.
publishing_files() {
  (cd "$1" && grep -rlE 'gh pr create|git checkout -b|git -C [^ ]+ checkout -b' .claude/commands .claude/skills --include='*.md') | sort
}

# check_census <root>
check_census() {
  local root="$1" file exempt listed failed=0 count=0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    count=$((count + 1))
    listed=0
    for exempt in "${EXEMPT[@]}"; do
      [ "$file" = "$exempt" ] && listed=1
    done
    [ "$listed" -eq 1 ] && continue
    grep -qF -- 'isolation.md' "$root/$file" ||
      { printf 'census: %s cuts a branch or opens a PR without naming isolation.md\n' "$file"; failed=1; }
  done < <(publishing_files "$root")
  # A short read would leave the loop green over a subset: the roster's own
  # PR-opening references must all have been found.
  [ "$count" -ge 5 ] || { printf 'census: read only %s publishing files\n' "$count"; return 1; }
  return "$failed"
}

# scratch_copy: copies .claude/commands and .claude/skills into a scratch root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root"
  rm -rf "$copy"
  mkdir -p "$copy/.claude"
  cp -R "$REPO_ROOT/.claude/commands" "$REPO_ROOT/.claude/skills" "$copy/.claude/"
  printf '%s\n' "$copy"
}

# --- the checks on the real tree -----------------------------------------

# bats test_tags=whole-tree
@test "each publishing command isolates through isolation.md and keeps no in-place arm" {
  run check_roster "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "neither update command keeps an in-place arm" {
  run check_update_commands "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "each publishing command orders its refusal, the pre-flight anchor, then the dispatch line" {
  run check_preflight "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "every instruction file that cuts a branch or opens a PR names isolation.md or is exempt" {
  run check_census "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# --- red twins -----------------------------------------------------------

@test "red twin: an in-place arm restored to a residue.md copy fails the roster and names it" {
  local copy
  copy="$(scratch_copy)"
  run check_roster "$copy"
  [ "$status" -eq 0 ]
  printf '\n**On any other branch:** leave the changes in the working tree.\n' >>"$copy/$REFERENCES/residue.md"
  run check_roster "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "roster: $REFERENCES/residue.md keeps an in-place arm"
}

@test "red twin: a codify.md copy with its isolation pointer removed fails the roster" {
  local copy
  copy="$(scratch_copy)"
  sed 's#`.claude/skills/gaia/references/isolation.md`#the shared reference#g' "$copy/$REFERENCES/codify.md" >"$copy/codify.tmp"
  mv "$copy/codify.tmp" "$copy/$REFERENCES/codify.md"
  run check_roster "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "roster: $REFERENCES/codify.md does not name isolation.md"
}

@test "red twin: a fitness command copy with no anchor line fails the pre-flight order" {
  local copy
  copy="$(scratch_copy)"
  run check_preflight "$copy"
  [ "$status" -eq 0 ]
  grep -vF -- "$ANCHOR" "$copy/.claude/commands/gaia-fitness.md" >"$copy/fitness.tmp"
  mv "$copy/fitness.tmp" "$copy/.claude/commands/gaia-fitness.md"
  run check_preflight "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'preflight: .claude/commands/gaia-fitness.md lacks'
}

# bats test_tags=whole-tree
@test "red twin: a new command that opens a PR without isolation.md fails the census and names it" {
  local copy
  copy="$(scratch_copy)"
  run check_census "$copy"
  [ "$status" -eq 0 ]
  printf '# /new-flow\n\n```bash\ngit checkout -b "<BRANCH>"\ngh pr create --draft\n```\n' >"$copy/.claude/commands/new-flow.md"
  run check_census "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'census: .claude/commands/new-flow.md cuts a branch or opens a PR'
}

@test "red twin: the update-deps in-place mode restored to a SKILL.md copy fails the update scan and names it" {
  local copy
  copy="$(scratch_copy)"
  run check_update_commands "$copy"
  [ "$status" -eq 0 ]
  printf '\n5. **Any other branch.** The run works in place: no worktree, no branch, push only.\n' >>"$copy/.claude/skills/update-deps/SKILL.md"
  run check_update_commands "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'update: .claude/skills/update-deps/SKILL.md keeps an in-place arm'
}

@test "red twin: the update-gaia in-place mode restored to a SKILL.md copy fails the update scan and names it" {
  local copy
  copy="$(scratch_copy)"
  run check_update_commands "$copy"
  [ "$status" -eq 0 ]
  printf '\n3. **In place.** Any other branch: set `SHOULD_CREATE_WORKTREE=false` and work on the current branch.\n' >>"$copy/.claude/skills/update-gaia/SKILL.md"
  run check_update_commands "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'update: .claude/skills/update-gaia/SKILL.md keeps an in-place arm'
}

@test "red twin: the push-only arm for a non-default branch restored to a publish.md copy fails the update scan" {
  local copy
  copy="$(scratch_copy)"
  run check_update_commands "$copy"
  [ "$status" -eq 0 ]
  printf '\n**If you were already on a non-default branch** at pre-flight, push only.\n' >>"$copy/.claude/skills/update-deps/references/publish.md"
  run check_update_commands "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- 'update: .claude/skills/update-deps/references/publish.md keeps an in-place arm'
}
