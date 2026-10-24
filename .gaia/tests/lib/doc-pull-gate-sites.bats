#!/usr/bin/env bats
#
# Doc-pin: the pull gate stands at every fresh start of a command that creates
# a branch, a worktree, a claim or a SPEC id, and nowhere a resume or an exempt
# command runs.
#
#   1. Presence: each gated file calls `gaia_pull_gate "<its command>"` exactly
#      once, and one line of the file names pull-gate.md and the exit code the
#      reader follows it on.
#   2. Order: the gate line comes after the file's own earlier step (its
#      worktree refusal, the interrupted update-worktree check, the claim
#      heading) and before the first creation marker named for that file.
#      A command file whose creation happens in its reference body is ordered
#      against the line that dispatches to that reference.
#   3. Exemptions: no exempt or resume-path file calls the gate.
#
# The files are named in the arrays below, so a file added to the gated set
# without a row here is caught by the reviewer of that change, not by a tree
# walk. Every check takes a root laid out like the repository, so the red twins
# run the same function against a mutated scratch copy.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES='.claude/skills/gaia/references'
  DISPATCH='Read `.claude/skills/gaia/references/'
  REFUSAL='gaia_refuse_if_worktree "'
  # file|command|the earlier step the gate follows|the first creation marker it precedes|exit phrase
  GATED=(
    "$REFERENCES/spec.md|/gaia-spec|### 3. Initial draft|spec-allocator.sh next|exit code"
    "$REFERENCES/plan.md|/gaia-plan|### 0. Pre-flight sweep|plan-allocator.sh next|exit code"
    "$REFERENCES/plan/planner.md|/gaia-plan|**Resume detection (cold-start|**Pre-flight isolation.** The generated|non-zero exit"
    ".claude/commands/gaia-debt.md|/gaia-debt|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-codify.md|/gaia-codify|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-cleanse.md|/gaia-cleanse|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-fitness.md|/gaia-fitness|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-residue.md|/gaia-residue|$REFUSAL|$DISPATCH|exit code"
    ".claude/skills/gaia-wiki/SKILL.md|/gaia-wiki|$REFUSAL|$DISPATCH|exit code"
    ".claude/skills/update-deps/SKILL.md|/update-deps|refs/heads/deps/|## Package layout|exit code"
    "$REFERENCES/work-lifecycle.md|ad-hoc work|## 1. Claim|## 2. Name|exit code"
  )
  # Files that never run the gate, each with its reason.
  UNGATED=(
    # Exempt commands: updating, setup, tooling and release flows.
    ".claude/commands/setup-gaia.md"
    ".claude/commands/gaia-forensics.md"
    ".claude/commands/gaia-release.md"
    ".claude/skills/update-gaia/SKILL.md"
    ".claude/skills/release-notes/SKILL.md"
    "$REFERENCES/forensics.md"
    "frontend/.claude/skills/gaia-react-perf/SKILL.md"
    "wiki/concepts/PR Merge Workflow.md"
    # A residue resume (after /clear, or an owed run) bypasses the slash
    # command and never starts fresh work, so its reference stays ungated.
    "$REFERENCES/residue.md"
  )
}

# first_line <file> <fixed string>: the line number of the first line holding it, or 0.
first_line() {
  local number
  number="$(grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1)"
  printf '%s\n' "${number:-0}"
}

# check_presence <root>
check_presence() {
  local root="$1" row file command earlier later phrase failed=0 calls sentence
  for row in "${GATED[@]}"; do
    IFS='|' read -r file command earlier later phrase <<<"$row"
    if [ ! -f "$root/$file" ]; then
      printf 'presence: %s missing\n' "$file"
      failed=1
      continue
    fi
    calls="$(grep -cF -- "gaia_pull_gate \"$command\"" "$root/$file" || true)"
    if [ "$calls" -ne 1 ]; then
      printf 'presence: %s calls gaia_pull_gate "%s" %s times, expected 1\n' "$file" "$command" "$calls"
      failed=1
      continue
    fi
    sentence="$(grep -F -- 'pull-gate.md' "$root/$file" | grep -F -- "$phrase" || true)"
    if [ -z "$sentence" ]; then
      printf 'presence: %s has no line naming pull-gate.md and "%s"\n' "$file" "$phrase"
      failed=1
    fi
  done
  return "$failed"
}

# check_order <root>
check_order() {
  local root="$1" row file command earlier later phrase failed=0 gate before after
  for row in "${GATED[@]}"; do
    IFS='|' read -r file command earlier later phrase <<<"$row"
    [ -f "$root/$file" ] || { printf 'order: %s missing\n' "$file"; failed=1; continue; }
    gate="$(first_line "$root/$file" "gaia_pull_gate \"$command\"")"
    before="$(first_line "$root/$file" "$earlier")"
    after="$(first_line "$root/$file" "$later")"
    if [ "$gate" -eq 0 ] || [ "$before" -eq 0 ] || [ "$after" -eq 0 ]; then
      printf 'order: %s lacks the gate (%s), its earlier step (%s) or its creation marker (%s)\n' \
        "$file" "$gate" "$before" "$after"
      failed=1
      continue
    fi
    if [ "$before" -ge "$gate" ] || [ "$gate" -ge "$after" ]; then
      printf 'order: %s must hold the earlier step (line %s), the gate (line %s), then the creation marker (line %s)\n' \
        "$file" "$before" "$gate" "$after"
      failed=1
    fi
  done
  return "$failed"
}

# check_ungated <root>
check_ungated() {
  local root="$1" file failed=0
  for file in "${UNGATED[@]}"; do
    if [ ! -f "$root/$file" ]; then
      printf 'ungated: %s missing\n' "$file"
      failed=1
      continue
    fi
    if grep -qF -- 'gaia_pull_gate' "$root/$file"; then
      printf 'ungated: %s calls gaia_pull_gate\n' "$file"
      failed=1
    fi
  done
  return "$failed"
}

# scratch_copy: copies every file the arrays name into a scratch root, keeping paths.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root" row file
  rm -rf "$copy"
  for row in "${GATED[@]}"; do
    file="${row%%|*}"
    mkdir -p "$copy/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$copy/$file"
  done
  for file in "${UNGATED[@]}"; do
    mkdir -p "$copy/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$copy/$file"
  done
  printf '%s\n' "$copy"
}

# --- the checks on the real tree -----------------------------------------

@test "the gated and ungated sets are non-empty and every named file exists" {
  local row file missing=0
  [ "${#GATED[@]}" -gt 0 ]
  [ "${#UNGATED[@]}" -gt 0 ]
  for row in "${GATED[@]}"; do
    file="${row%%|*}"
    [ -f "$REPO_ROOT/$file" ] || { printf 'missing: %s\n' "$file"; missing=1; }
  done
  for file in "${UNGATED[@]}"; do
    [ -f "$REPO_ROOT/$file" ] || { printf 'missing: %s\n' "$file"; missing=1; }
  done
  [ "$missing" -eq 0 ]
}

# bats test_tags=whole-tree
@test "each gated file calls the gate once and names pull-gate.md with the exit code" {
  run check_presence "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "each gate follows its earlier step and precedes the first creation marker" {
  run check_order "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "no exempt or resume-path file calls the gate" {
  run check_ungated "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# --- red twins: each guard refuses its failing state ----------------------

@test "red twin: a command copy with the gate removed fails the presence check" {
  local copy
  copy="$(scratch_copy)"
  run check_presence "$copy"
  [ "$status" -eq 0 ]
  grep -vF -- 'gaia_pull_gate' "$copy/.claude/commands/gaia-fitness.md" >"$copy/fitness.tmp"
  mv "$copy/fitness.tmp" "$copy/.claude/commands/gaia-fitness.md"
  run check_presence "$copy"
  [ "$status" -ne 0 ]
  grep -qF -- 'presence: .claude/commands/gaia-fitness.md calls gaia_pull_gate' <<<"$output"
}

@test "red twin: a copy whose sentence drops the exit code fails the presence check" {
  local copy
  copy="$(scratch_copy)"
  sed 's#and the exit code#and nothing else#' "$copy/.claude/commands/gaia-debt.md" >"$copy/debt.tmp"
  mv "$copy/debt.tmp" "$copy/.claude/commands/gaia-debt.md"
  run check_presence "$copy"
  [ "$status" -ne 0 ]
  grep -qF -- 'presence: .claude/commands/gaia-debt.md has no line naming pull-gate.md' <<<"$output"
}

@test "red twin: a copy with the gate moved below the creation marker fails the order check" {
  local copy
  copy="$(scratch_copy)"
  run check_order "$copy"
  [ "$status" -eq 0 ]
  grep -vF -- 'gaia_pull_gate "/gaia-codify"' "$copy/.claude/commands/gaia-codify.md" >"$copy/codify.tmp"
  printf 'gaia_pull_gate "/gaia-codify"\n' >>"$copy/codify.tmp"
  mv "$copy/codify.tmp" "$copy/.claude/commands/gaia-codify.md"
  run check_order "$copy"
  [ "$status" -ne 0 ]
  grep -qF -- 'order: .claude/commands/gaia-codify.md must hold' <<<"$output"
}

@test "red twin: an update-deps copy with the gate above the interrupted-worktree check fails the order check" {
  local copy
  copy="$(scratch_copy)"
  grep -vF -- 'gaia_pull_gate "/update-deps"' "$copy/.claude/skills/update-deps/SKILL.md" >"$copy/deps.tmp"
  { printf 'gaia_pull_gate "/update-deps"\n'; cat "$copy/deps.tmp"; } >"$copy/deps.new"
  mv "$copy/deps.new" "$copy/.claude/skills/update-deps/SKILL.md"
  run check_order "$copy"
  [ "$status" -ne 0 ]
  grep -qF -- 'order: .claude/skills/update-deps/SKILL.md must hold' <<<"$output"
}

@test "red twin: an exempt file with a gate added fails the ungated check" {
  local copy
  copy="$(scratch_copy)"
  printf 'gaia_pull_gate "/gaia-release"\n' >>"$copy/.claude/commands/gaia-release.md"
  run check_ungated "$copy"
  [ "$status" -ne 0 ]
  grep -qF -- 'ungated: .claude/commands/gaia-release.md calls gaia_pull_gate' <<<"$output"
}

@test "red twin: the residue reference with a gate added fails the ungated check" {
  local copy
  copy="$(scratch_copy)"
  printf 'gaia_pull_gate "/gaia-residue"\n' >>"$copy/$REFERENCES/residue.md"
  run check_ungated "$copy"
  [ "$status" -ne 0 ]
  grep -qF -- "ungated: $REFERENCES/residue.md calls gaia_pull_gate" <<<"$output"
}
