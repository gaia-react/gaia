#!/usr/bin/env bats
#
# Doc-conformance suite for the post-merge cleanup, owned by the shared
# work-lifecycle reference: it pulls the default branch into the main checkout
# only when that checkout is on it, and its worktree arms still run no `git checkout`.
#
# Every check is a function taking a root laid out like the repository, so the
# red twins run the same function against a mutated scratch copy: removing a
# site's pull has to turn that site's check red.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES='.claude/skills/gaia/references'
  RUNBOOK='wiki/concepts/PR Merge Workflow.md'
  PULL='pull --ff-only origin "$default_branch"'
  PULL_PATTERN='pull --ff-only origin "\$default_branch"'
}

# section <file> <heading prefix>: prints the section whose heading line starts
# with the prefix, up to the next heading of the same or a higher level. Lines
# inside a fence are never read as headings, since a `# comment` in a bash
# fence would otherwise end the section early.
section() {
  awk -v want="$2" '
    /^[[:space:]]*```/ { fenced = !fenced }
    !found && !fenced && index($0, want) == 1 {
      found = 1; match($0, /^#+/); level = RLENGTH; print; next
    }
    found && !fenced && /^#+ / { match($0, /^#+/); if (RLENGTH <= level) exit }
    found { print }
  ' "$1"
}

# fence_bodies <info string>: reads text on stdin and prints the lines inside
# every fence opened with exactly that info string, at any indentation.
fence_bodies() {
  awk -v info="$1" '
    !open && $0 ~ ("^[[:space:]]*```" info "$") { open = 1; next }
    open && /^[[:space:]]*```[[:space:]]*$/ { open = 0; next }
    open { print }
  '
}

# scratch_copy: copies every file this suite reads into a scratch root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root" relative
  rm -rf "$copy"
  for relative in \
    "$REFERENCES/work-lifecycle.md" \
    "$RUNBOOK"; do
    mkdir -p "$copy/$(dirname "$relative")"
    cp "$REPO_ROOT/$relative" "$copy/$relative"
  done
  printf '%s\n' "$copy"
}

# --- b. the pull after a merge -------------------------------------------------

worktree_arm_pulls() {
  local path_arm prose
  path_arm="$(section "$1/$REFERENCES/work-lifecycle.md" '### Worktree entered by path or in an earlier session')"
  fence_bodies bash <<<"$path_arm" | grep -qE -- "git( -C ([^ <][^ ]*|<[^>]*>))? $PULL_PATTERN" || return 1
  fence_bodies bash <<<"$path_arm" | grep -qF -- '= "$default_branch" ]' || return 1
  prose="$(section "$1/$REFERENCES/work-lifecycle.md" '## 8. Cleanup')"
  grep -qF -- 'skip the checkout and the pull' <<<"$prose" || return 1
  grep -qF -- 'Never force a pull, and never stash' <<<"$prose"
}

worktree_arm_has_no_checkout() {
  local arm heading
  for heading in '### Worktree entered by name in this session' '### Worktree entered by path or in an earlier session'; do
    arm="$(section "$1/$REFERENCES/work-lifecycle.md" "$heading")"
    [ -n "$(fence_bodies bash <<<"$arm")" ] || return 1
    if fence_bodies bash <<<"$arm" | grep -qE -- 'git( -C ([^ <][^ ]*|<[^>]*>))? (checkout|switch)'; then
      return 1
    fi
  done
}

in_session_removal_pulls() {
  local removal
  removal="$(section "$1/$REFERENCES/work-lifecycle.md" '### Worktree entered by name in this session')"
  grep -qF -- 'rev-parse --abbrev-ref HEAD' <<<"$removal" || return 1
  grep -qF -- "git $PULL" <<<"$removal"
}

main_checkout_paragraph_uses_digest() {
  local paragraph
  paragraph="$(grep -F -- '**Read what the main checkout is holding' "$1/$RUNBOOK")"
  [ -n "$paragraph" ] || return 1
  section "$1/$RUNBOOK" '## Post-merge verification before cleanup' | grep -qF -- 'audit-member-digest.sh --root <root> --member <member>' || return 1
  if section "$1/$RUNBOOK" '## Post-merge verification before cleanup' | grep -qF -- "marker body's \`tree\` field"; then
    return 1
  fi
}

# bats test_tags=whole-tree
@test "the worktree arm pulls the default branch only when the main checkout holds it, and never forces" {
  worktree_arm_pulls "$REPO_ROOT"
}

@test "red twin: a worktree arm without the pull fails" {
  local copy file
  copy="$(scratch_copy)"
  file="$copy/$REFERENCES/work-lifecycle.md"
  grep -vF -- "$PULL" "$file" >"$file.new"
  mv "$file.new" "$file"
  run worktree_arm_pulls "$copy"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the worktree arms' fences still carry no git checkout" {
  worktree_arm_has_no_checkout "$REPO_ROOT"
}

@test "red twin: a git checkout inside a worktree arm's fence fails" {
  local copy file
  copy="$(scratch_copy)"
  file="$copy/$REFERENCES/work-lifecycle.md"
  awk -v pull="git $PULL" 'index($0, pull) { print "  git checkout main" } { print }' "$file" >"$file.new"
  mv "$file.new" "$file"
  run worktree_arm_has_no_checkout "$copy"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the in-session worktree removal reads the main checkout's HEAD and pulls" {
  in_session_removal_pulls "$REPO_ROOT"
}

@test "red twin: an in-session removal without the pull fails" {
  local copy file
  copy="$(scratch_copy)"
  file="$copy/$REFERENCES/work-lifecycle.md"
  grep -vF -- "$PULL" "$file" >"$file.new"
  mv "$file.new" "$file"
  run in_session_removal_pulls "$copy"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the post-merge verification section keys on the member digest, not the marker tree field" {
  main_checkout_paragraph_uses_digest "$REPO_ROOT"
}
