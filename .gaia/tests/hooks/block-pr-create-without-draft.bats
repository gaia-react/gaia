#!/usr/bin/env bats

# Tests for .claude/hooks/block-pr-create-without-draft.sh, the PreToolUse guard
# that denies a `gh pr create` for the project's own repository unless it opens
# a draft. Exit 2 = block, 0 = allow.
#
# The hook is copied into a scratch git repository whose `origin` the test
# controls, so the own-repository decision never depends on the remote of the
# checkout running the suite. Every deny is paired with an allow one spelling
# away, so a hook that blocks everything or nothing fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # shellcheck source=../helpers/hook-registration.sh
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  SCRATCH="$BATS_TEST_TMPDIR/project"
  mkdir -p "$SCRATCH/.claude/hooks"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$SCRATCH/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/block-pr-create-without-draft.sh" "$SCRATCH/.claude/hooks/"
  git -C "$SCRATCH" init -q
  git -C "$SCRATCH" remote add origin 'git@github.com:Acme/Widgets.git'
  HOOK="$SCRATCH/.claude/hooks/block-pr-create-without-draft.sh"
  # A gh stub answers the visibility probe from $BATS_TEST_TMPDIR/visibility
  # and exits 1 (a probe error) while that file is absent, so no test reaches
  # the network.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/gh-calls"
[ -f "$BATS_TEST_TMPDIR/visibility" ] || exit 1
cat "$BATS_TEST_TMPDIR/visibility"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

run_hook() {
  local payload
  payload=$(jq -nc --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "${2:-$HOOK}"
}

assert_blocked() {
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
  grep -qF -- 'gh pr create --draft' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the own repository -------------------------------------------------------

@test "a create with no --repo and no --draft is blocked and names the draft form" {
  run_hook 'gh pr create --title "feat: x" --body-file f'
  assert_blocked
}

@test "the same create with --draft is allowed" {
  run_hook 'gh pr create --draft --title "feat: x" --body-file f'
  assert_allowed
}

@test "the same create with -d is allowed" {
  run_hook 'gh pr create -d --title "feat: x" --body-file f'
  assert_allowed
}

@test "--draft=true is allowed and --draft=false is blocked" {
  run_hook 'gh pr create --draft=true --title "feat: x"'
  assert_allowed
  run_hook 'gh pr create --draft=false --title "feat: x"'
  assert_blocked
}

@test "--repo naming the origin repository without --draft is blocked" {
  run_hook 'gh pr create --repo Acme/Widgets --title "feat: x"'
  assert_blocked
}

@test "-R and --repo= naming the origin repository without --draft are blocked" {
  run_hook 'gh pr create -R acme/widgets --title "feat: x"'
  assert_blocked
  run_hook 'gh pr create --repo=ACME/WIDGETS --title "feat: x"'
  assert_blocked
}

@test "a URL spelling of the origin repository is still the own repository" {
  run_hook 'gh pr create --repo https://github.com/acme/widgets.git --title "feat: x"'
  assert_blocked
}

@test "--repo naming the origin repository with --draft is allowed" {
  run_hook 'gh pr create --draft --repo acme/widgets --title "feat: x"'
  assert_allowed
}

# --- a private repository where drafts are refused ----------------------------

@test "a non-draft create on a PRIVATE own repository is allowed, with or without --repo" {
  printf 'PRIVATE\n' >"$BATS_TEST_TMPDIR/visibility"
  run_hook 'gh pr create --title "feat: x" --body-file f'
  assert_allowed
  run_hook 'gh pr create --repo Acme/Widgets --title "feat: x"'
  assert_allowed
  run_hook 'gh pr create --draft --title "feat: x"'
  assert_allowed
}

@test "the probe asks about the origin repository" {
  printf 'PRIVATE\n' >"$BATS_TEST_TMPDIR/visibility"
  run_hook 'gh pr create -R https://github.com/ACME/widgets.git --title "feat: x"'
  assert_allowed
  grep -qF -- 'repo view acme/widgets --json visibility' "$BATS_TEST_TMPDIR/gh-calls"
}

@test "a non-draft create stays blocked on PUBLIC, INTERNAL, an unknown answer and a probe error" {
  local answer
  for answer in PUBLIC INTERNAL private Private ''; do
    printf '%s\n' "$answer" >"$BATS_TEST_TMPDIR/visibility"
    run_hook 'gh pr create --title "feat: x"'
    assert_blocked
  done
  rm -f "$BATS_TEST_TMPDIR/visibility"
  run_hook 'gh pr create --title "feat: x"'
  assert_blocked
  run_hook 'gh pr create --repo acme/widgets --title "feat: x"'
  assert_blocked
}

@test "the deny text names the private-repository exception" {
  run_hook 'gh pr create --title "feat: x"'
  assert_blocked
  grep -qF -- 'On a private repository where GitHub refuses draft pull requests, the non-draft form is allowed.' <<<"$output"
}

# --- another repository -------------------------------------------------------

@test "-R naming another repository without --draft is allowed" {
  run_hook 'gh pr create -R other/repo --title "feat: x" --body-file f'
  assert_allowed
}

@test "--repo naming another repository without --draft is allowed" {
  run_hook 'gh pr create --repo other/repo --title "feat: x" --body-file f'
  assert_allowed
}

@test "the scaffold repository pull request the release command opens is allowed" {
  run_hook 'gh pr create -R gaia-react/create-gaia --base main --head x --title "chore: y" --body-file f'
  assert_allowed
}

@test "a repository that only shares the owner or the name with origin is another repository" {
  run_hook 'gh pr create --repo acme/gadgets --title "feat: x"'
  assert_allowed
  run_hook 'gh pr create --repo other/widgets --title "feat: x"'
  assert_allowed
}

# --- reading the command ------------------------------------------------------

@test "a create after git push && is read" {
  run_hook 'git push -u origin feat/x && gh pr create --title "feat: x" --body-file f'
  assert_blocked
  run_hook 'git push -u origin feat/x && gh pr create --draft --title "feat: x" --body-file f'
  assert_allowed
}

@test "a create on the line after a comment is read" {
  run_hook $'# open the PR\ngh pr create --title "feat: x"'
  assert_blocked
}

@test "a create inside a heredoc body is data, not a command" {
  run_hook $'cat > notes.md <<\'EOF\'\ngh pr create --title "feat: x"\nEOF'
  assert_allowed
}

@test "a quoted mention of the verb is not a command" {
  run_hook "echo 'gh pr create --title \"feat: x\"'"
  assert_allowed
}

@test "a title or body that mentions --draft does not count as the flag" {
  run_hook 'gh pr create --title "feat: --draft" --body "use -d"'
  assert_blocked
}

@test "other gh pr verbs are allowed" {
  run_hook 'gh pr view 12 --json title'
  assert_allowed
  run_hook 'gh pr ready 12'
  assert_allowed
}

@test "a Monitor call stands down" {
  local payload
  payload=$(jq -nc '{tool_name: "Monitor", tool_input: {command: "gh pr create --title \"feat: x\""}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
  assert_allowed
}

# --- the honest limits --------------------------------------------------------

@test "a repository the shell expands is allowed" {
  run_hook 'gh pr create --repo "$TARGET_REPO" --title "feat: x"'
  assert_allowed
}

@test "with an unreadable origin a --repo is allowed and a plain create is still blocked" {
  git -C "$SCRATCH" remote remove origin
  run_hook 'gh pr create --repo acme/widgets --title "feat: x"'
  assert_allowed
  run_hook 'gh pr create --title "feat: x"'
  assert_blocked
}

# --- registration and fail-loud libraries -------------------------------------

@test "the hook is registered on the PreToolUse Bash|Monitor matcher beside the title guard" {
  hook_registered "$REPO_ROOT/.claude/settings.json" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-pr-create-without-draft.sh
  hook_registered "$REPO_ROOT/.claude/settings.json" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-invalid-pr-title.sh
}

@test "lib/hook-payload.sh absent: a payload the hook would deny exits 2 naming the library" {
  rm -f "$SCRATCH/.claude/hooks/lib/hook-payload.sh"
  run_hook 'gh pr create --title "feat: x"'
  [ "$status" -eq 2 ]
  grep -qF 'BLOCKED: block-pr-create-without-draft.sh cannot load lib/hook-payload.sh' <<<"$output"
}
