#!/usr/bin/env bats
#
# Doc-conformance suite for the mechanics `/gaia-debt`'s playbook hands to
# scripts and hooks instead of prose (.claude/skills/gaia/references/debt.md
# and any sub-reference under .claude/skills/gaia/references/debt/).
#
# The invariants, one per hand-off plus the split's routing:
#   1. the playbook never touches the debt-count sentinel: the PostToolUse hook
#      on `gh issue edit` / `gh issue reopen` refreshes the count after every
#      claim, release, and park, so a touch written into the playbook is a
#      duplicate instruction paid on every run;
#   2. the audit step dispatches `audit-loop-unit` through the merge workflow's
#      audit-loop-unit section and never resolves and spawns members itself;
#   3. the post-merge path waits on `pr-wait-merge.sh` and never confirms the
#      merge with a one-shot `gh pr view --json state`;
#   4. clustering and exclusion come from `debt-backlog.sh`, and a non-zero
#      exit from it stops the run before anything is claimed;
#   5. a sub-reference read is a step a model can skip, so `debt.md` routes to
#      every debt/*.md through a `Read` line, names no sub-reference that does
#      not exist, keeps the sections every entry path shares, and each moved
#      section lives in exactly one sub-reference.
#
# The playbook set is `debt.md` plus every `debt/*.md` that exists, so the
# invariants keep holding when the file is split. DOC_DEBT_PLAYBOOK_DIR points
# the suite at a scratch copy of the references directory; each invariant has a
# red twin that seeds the previously-missed phrasing into such a copy and proves
# the check fails on it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAYBOOK_DIR="${DOC_DEBT_PLAYBOOK_DIR:-$REPO_ROOT/.claude/skills/gaia/references}"
}

# playbook_files <references-dir>: one path per line, debt.md first.
playbook_files() {
  local dir="$1" file
  [ -f "$dir/debt.md" ] || return 1
  printf '%s\n' "$dir/debt.md"
  for file in "$dir"/debt/*.md; do
    [ -f "$file" ] && printf '%s\n' "$file"
  done
  return 0
}

# extract_section <file> <heading-line-prefix>: the first matching section's
# body, heading included, up to the next heading of the same or shallower
# level. Prints nothing when no heading matches, which fails the non-empty
# assertion each caller opens with.
extract_section() {
  awk -v want="$2" '
    !found && index($0, want) == 1 {
      found = 1
      match($0, /^#+/)
      level = RLENGTH
      print
      next
    }
    found && /^#+ / {
      match($0, /^#+/)
      if (RLENGTH <= level) exit
    }
    found { print }
  ' "$1"
}

# scratch_copy: copies the references directory into the test's tmpdir and
# prints the copy's path.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/references"
  rm -rf "$copy"
  mkdir -p "$copy"
  cp "$PLAYBOOK_DIR/debt.md" "$copy/debt.md"
  if [ -d "$PLAYBOOK_DIR/debt" ]; then
    cp -R "$PLAYBOOK_DIR/debt" "$copy/debt"
  fi
  printf '%s\n' "$copy"
}

# no_sentinel_touch <references-dir>: succeeds when no playbook file instructs
# a sentinel touch; reports each offending file and returns 1 otherwise.
SENTINEL_TOUCH_PATTERN='refresh-requested|touch(ing)? the sentinel|sentinel (is )?touch|debt-count sentinel'
no_sentinel_touch() {
  local files file count status=0
  files="$(playbook_files "$1")" || return 1
  [ -n "$files" ] || return 1
  count=0
  while IFS= read -r file; do
    count=$((count + 1))
    if grep -qiE -- "$SENTINEL_TOUCH_PATTERN" "$file"; then
      printf 'sentinel touch in %s\n' "$file" >&2
      status=1
    fi
  done <<<"$files"
  [ "$count" -ge 1 ] || return 1
  return "$status"
}

# --- 1. the playbook never touches the count sentinel -----------------------

@test "the playbook set is non-empty and contains debt.md" {
  files="$(playbook_files "$PLAYBOOK_DIR")"
  [ -n "$files" ]
  grep -qF -- "$PLAYBOOK_DIR/debt.md" <<<"$files"
}

@test "the playbook never touches the debt-count sentinel" {
  no_sentinel_touch "$PLAYBOOK_DIR"
}

@test "the sentinel check goes red on each phrasing it exists to catch" {
  for phrase in \
    'mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested' \
    'touch the sentinel' \
    'touching the sentinel' \
    'the sentinel touch' \
    'the sentinel is touched' \
    '## Touch the debt-count sentinel'; do
    copy="$(scratch_copy)"
    printf '\n%s\n' "$phrase" >>"$copy/debt.md"
    run no_sentinel_touch "$copy"
    [ "$status" -ne 0 ] || {
      printf 'sentinel check stayed green for: %s\n' "$phrase" >&2
      return 1
    }
  done
}

@test "the sentinel check reads a sub-reference file as well as debt.md" {
  copy="$(scratch_copy)"
  mkdir -p "$copy/debt"
  printf 'touching the sentinel\n' >"$copy/debt/extra.md"
  run no_sentinel_touch "$copy"
  [ "$status" -ne 0 ]
}

# --- 2. the audit step dispatches the unit ----------------------------------

audit_step_dispatches_unit() {
  local section
  section="$(extract_section "$1/debt.md" '## Drive the PR to merge')"
  [ -n "$section" ] || return 1
  grep -qF -- 'audit-loop-unit' <<<"$section" || return 1
  grep -qF -- '## Dispatch the audit loop unit' <<<"$section" || return 1
  grep -qF -- 'resolve-audit-members.sh' <<<"$section" && return 1
  return 0
}

@test "the audit step dispatches the unit and does not spawn members itself" {
  audit_step_dispatches_unit "$PLAYBOOK_DIR"
}

@test "the audit-step check goes red on the member-spawning bullet" {
  copy="$(scratch_copy)"
  # Append inside the section: the marker bullet gains the old spawn clause.
  sed 's|^- \*\*Get a real marker for HEAD\.\*\*.*|& Resolve the spawn set with `bash .gaia/scripts/resolve-audit-members.sh` and run each named member.|' "$copy/debt.md" >"$copy/debt.md.new"
  mv "$copy/debt.md.new" "$copy/debt.md"
  grep -qF -- 'resolve-audit-members.sh' "$copy/debt.md"
  run audit_step_dispatches_unit "$copy"
  [ "$status" -ne 0 ]
}

@test "the audit-step check goes red when the unit is no longer named" {
  copy="$(scratch_copy)"
  sed 's/audit-loop-unit/audit loop/g' "$copy/debt.md" >"$copy/debt.md.new"
  mv "$copy/debt.md.new" "$copy/debt.md"
  run audit_step_dispatches_unit "$copy"
  [ "$status" -ne 0 ]
}

# --- 3. no one-shot merge check ---------------------------------------------

no_one_shot_merge_check() {
  local files file cleanup
  files="$(playbook_files "$1")" || return 1
  while IFS= read -r file; do
    grep -qE -- 'gh pr view <N> --json state' "$file" && return 1
  done <<<"$files"
  cleanup="$(extract_section "$1/debt/worktree-cleanup.md" '### Post-merge worktree cleanup')"
  [ -n "$cleanup" ] || return 1
  grep -qF -- 'pr-wait-merge.sh' <<<"$cleanup" || return 1
  return 0
}

@test "the post-merge path waits on pr-wait-merge.sh and never reads the state once" {
  no_one_shot_merge_check "$PLAYBOOK_DIR"
}

@test "the merge-check guard goes red on the one-shot state read" {
  copy="$(scratch_copy)"
  printf '\n1. Confirm merge via `gh pr view <N> --json state`; require `.state == "MERGED"`.\n' >>"$copy/debt.md"
  run no_one_shot_merge_check "$copy"
  [ "$status" -ne 0 ]
}

@test "the merge-check guard goes red when the worktree cleanup stops naming the wait" {
  copy="$(scratch_copy)"
  sed 's/pr-wait-merge\.sh/the merge wait/g' "$copy/debt/worktree-cleanup.md" >"$copy/debt/worktree-cleanup.md.new"
  mv "$copy/debt/worktree-cleanup.md.new" "$copy/debt/worktree-cleanup.md"
  run no_one_shot_merge_check "$copy"
  [ "$status" -ne 0 ]
}

# --- 4. clustering is the script's ------------------------------------------

backlog_pass_is_scripted() {
  local section
  section="$(extract_section "$1/debt.md" '## Read and order the backlog')"
  [ -n "$section" ] || return 1
  grep -qF -- 'bash .gaia/scripts/debt-backlog.sh' <<<"$section" || return 1
  grep -qF -- 'A non-zero exit stops the run before anything is claimed' <<<"$section" || return 1
  return 0
}

@test "the backlog read names the backlog script and the stop on its non-zero exit" {
  backlog_pass_is_scripted "$PLAYBOOK_DIR"
}

@test "the backlog-script check goes red when the stop is dropped" {
  copy="$(scratch_copy)"
  sed 's/A non-zero exit stops the run before anything is claimed/A non-zero exit is noted/' "$copy/debt.md" >"$copy/debt.md.new"
  mv "$copy/debt.md.new" "$copy/debt.md"
  run backlog_pass_is_scripted "$copy"
  [ "$status" -ne 0 ]
}

# --- 5. the split: every sub-reference is routed and owns its sections -------

ROUTE_PREFIX='Read `.claude/skills/gaia/references/debt/'

# every_sub_reference_routed <references-dir>: succeeds when debt.md holds a
# `Read` line naming each debt/*.md by its repo path. The set comes from the
# directory, and an independent count catches a glob that read fewer files
# than exist; an empty set fails rather than passing vacuously.
every_sub_reference_routed() {
  local dir="$1" file name count=0 expected
  [ -f "$dir/debt.md" ] || return 1
  expected="$(find "$dir/debt" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$expected" -ge 1 ] || return 1
  for file in "$dir"/debt/*.md; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    count=$((count + 1))
    if ! grep -qF -- "${ROUTE_PREFIX}${name}\`" "$dir/debt.md"; then
      printf 'debt/%s has no Read line in debt.md\n' "$name" >&2
      return 1
    fi
  done
  [ "$count" -eq "$expected" ] || return 1
  return 0
}

@test "every sub-reference is routed from debt.md by a Read line" {
  every_sub_reference_routed "$PLAYBOOK_DIR"
}

@test "the routing check goes red when one routing line is deleted" {
  copy="$(scratch_copy)"
  grep -vF -- "${ROUTE_PREFIX}spec-handoff.md\`" "$copy/debt.md" >"$copy/debt.md.new"
  mv "$copy/debt.md.new" "$copy/debt.md"
  run every_sub_reference_routed "$copy"
  [ "$status" -ne 0 ]
}

# no_orphan_route <references-dir>: succeeds when every debt/<name>.md that
# debt.md names, by full repo path or by the short form, exists. A path such
# as `file-tech-debt/SKILL.md` is not a sub-reference, so the match requires
# `debt/` to start a path segment that is not part of a longer name.
no_orphan_route() {
  local dir="$1" names name
  names="$(grep -oE -- '(^|[^A-Za-z0-9_-])debt/[A-Za-z0-9_-]+\.md' "$dir/debt.md" | sed -E 's|^.*debt/||' | sort -u)"
  [ -n "$names" ] || return 1
  while IFS= read -r name; do
    if [ ! -f "$dir/debt/$name" ]; then
      printf 'debt.md names missing debt/%s\n' "$name" >&2
      return 1
    fi
  done <<<"$names"
  return 0
}

@test "every sub-reference debt.md names exists" {
  no_orphan_route "$PLAYBOOK_DIR"
}

@test "the orphan check goes red on a route to a missing file" {
  copy="$(scratch_copy)"
  printf '\n%smissing.md` now and follow it.\n' "$ROUTE_PREFIX" >>"$copy/debt.md"
  run no_orphan_route "$copy"
  [ "$status" -ne 0 ]
}

CORE_HEADINGS=(
  '## Argument parsing'
  '## Read and order the backlog'
  '## Claim the fix unit'
  '## Fix-time security screen'
  '## Fix-time staleness screen'
  '## Fix-time spec screen'
  '## Pre-flight isolation (branch vs worktree)'
  '## Drive the PR to merge'
  '## Cost record (run end)'
  '## Guardrails'
)

# owner<TAB>heading: each heading that moved out of the core, with the one
# sub-reference that owns it. The spec hand-off has no entry: it holds body
# text from a heading that stays in the core.
MOVED_HEADINGS=(
  "named.md	## Validate named numbers"
  "named.md	## Fix a specific issue (direct-number path)"
  "named.md	## Fix a named set (two or more numbers)"
  "recommend.md	## Recommend and present"
  "worktree-cleanup.md	### Post-merge worktree cleanup"
  "worktree-cleanup.md	### Isolation-context detection"
)

# has_heading <file> <heading-prefix>: a line of the file starts with the prefix.
has_heading() {
  awk -v want="$2" 'index($0, want) == 1 { found = 1 } END { exit !found }' "$1"
}

# headings_owned <references-dir>: the core keeps every shared heading, and
# each moved heading appears in its owning sub-reference and in no other file
# of the playbook set.
headings_owned() {
  local dir="$1" heading entry owner files file holders
  for heading in "${CORE_HEADINGS[@]}"; do
    if ! has_heading "$dir/debt.md" "$heading"; then
      printf 'debt.md lost %s\n' "$heading" >&2
      return 1
    fi
  done
  files="$(playbook_files "$dir")" || return 1
  for entry in "${MOVED_HEADINGS[@]}"; do
    owner="${entry%%	*}"
    heading="${entry#*	}"
    holders=""
    while IFS= read -r file; do
      if has_heading "$file" "$heading"; then
        holders="$holders${file#"$dir"/} "
      fi
    done <<<"$files"
    if [ "$holders" != "debt/$owner " ]; then
      printf '%s is held by [%s], expected [debt/%s]\n' "$heading" "$holders" "$owner" >&2
      return 1
    fi
  done
  return 0
}

@test "the core keeps the shared sections and each moved section has one owner" {
  headings_owned "$PLAYBOOK_DIR"
}

@test "the ownership check goes red when a moved heading is duplicated into the core" {
  copy="$(scratch_copy)"
  printf '\n## Recommend and present\n\nstale copy\n' >>"$copy/debt.md"
  run headings_owned "$copy"
  [ "$status" -ne 0 ]
}

@test "the ownership check goes red when the core loses a shared heading" {
  copy="$(scratch_copy)"
  sed 's/^## Claim the fix unit/## Claiming/' "$copy/debt.md" >"$copy/debt.md.new"
  mv "$copy/debt.md.new" "$copy/debt.md"
  run headings_owned "$copy"
  [ "$status" -ne 0 ]
}
