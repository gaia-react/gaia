#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/token-tally-review.sh (SPEC-032 FC-3/FC-4).
#
# This hook is a thin trigger: it cheap-gates on a Code Audit Team member's
# sidecar (any name on the .gaia/audit-ci.yml roster) actually existing, resolves SPEC/PLAN association, and invokes
# `token-tally.sh --action review` by a path rooted at its own on-disk
# location, never by a PATH lookup and never against the working directory. The
# real trigger -> row -> dedup effect is owned by task-integration-e2e; this
# suite proves the INVOCATION (arg capture via a recording stub, DP-004),
# the cheap negative gate, the Bash/Stop payload dispatch, and the
# never-blocks contract.
#
# Every test drives a COPY of the hook staged inside a tmp git repo, never the
# real one, so no test row is ever appended to the real
# .gaia/local/telemetry/cost.jsonl and no test ever shells out to the real
# token-tally.sh (a recording stub stands in beside the staged copy). Running
# the real hook with cwd set to the tmp repo would not achieve that: the hook
# roots what it loads and runs at itself, so it would reach the real tree
# whatever the working directory says.

setup() {
  # Isolate pricing from the developer's real rate table and the network.
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.claude/hooks/token-tally-review.sh"
  LIBRARY_SOURCE="$REPO_ROOT/.claude/hooks/lib/gaia-active-plan.sh"
  LIBRARY_MAIN_ROOT_SOURCE="$REPO_ROOT/.gaia/scripts/main-root-lib.sh"
  VERB_ARMING_SOURCE="$REPO_ROOT/.claude/hooks/lib/verb-arming.sh"
  VERB_ARMING_WALK_SOURCE="$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh"
  REPO_SCOPE_SOURCE="$REPO_ROOT/.claude/hooks/lib/repo-scope.sh"
  AUDIT_SCOPE_SOURCE="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${PROOT:-}" ] && rm -rf "$PROOT"
  return 0
}

# Scaffolds a tmp git repo with the built lib + a RECORDING stub standing in
# for .gaia/scripts/token-tally.sh at its real repo-relative path. The stub
# dumps its argv (one per line) to $CALLS_FILE and exits 0; it never touches
# a real ledger, so this suite proves the invocation's flags, not the tally's
# internal effect (that is task-integration-e2e's job). Sets $REPO and
# $CALLS_FILE.
build_repo() {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  cp "$LIBRARY_SOURCE" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$LIBRARY_MAIN_ROOT_SOURCE" "$REPO/.gaia/scripts/main-root-lib.sh"
  cp "$VERB_ARMING_SOURCE" "$REPO/.claude/hooks/lib/verb-arming.sh"
  cp "$VERB_ARMING_WALK_SOURCE" "$REPO/.claude/hooks/lib/verb-arming-walk.sh"
  cp "$REPO_SCOPE_SOURCE" "$REPO/.claude/hooks/lib/repo-scope.sh"
  cp "$AUDIT_SCOPE_SOURCE" "$REPO/.claude/hooks/lib/audit-scope.sh"

  # A two-member roster: the default member plus one claimant, so the gate's
  # roster read is exercised on a member that is not the default.
  cat > "$REPO/.gaia/audit-ci.yml" <<'ROSTER'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    default: true
  - name: code-audit-github-workflows
    globs:
      - ".github/workflows/*.yml"
ROSTER

  CALLS_FILE="$REPO/.gaia/local/tally-review-calls.txt"
  mkdir -p "$(dirname "$CALLS_FILE")"
  cat > "$REPO/.gaia/scripts/token-tally.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CALLS_FILE"
exit 0
STUB
  chmod +x "$REPO/.gaia/scripts/token-tally.sh"

  # A copy of the hook, staged at its own repo-relative path inside $REPO. The
  # hook resolves both its shared lib and the tally script off ${BASH_SOURCE[0]}
  # rather than off the working directory, so the staged libs above and the
  # recording stub beside them are in its view only when the hook running is
  # this copy. Driving $HOOK_ABSOLUTE_PATH with cwd set to $REPO would reach the real
  # checkout's lib and its real token-tally.sh instead, which is the whole
  # point of the rooting and would make every invocation assertion below read
  # a stub that was never called.
  STAGED_HOOK="$REPO/.claude/hooks/token-tally-review.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
}

write_running() {
  # write_running <plan_directory> <branch> <started>
  mkdir -p "$1"
  { printf 'branch: %s\n' "$2"; printf 'slug: %s\n' "$(basename "$1")"; printf 'started: %s\n' "$3"; } > "$1/RUNNING"
}

write_readme_with_spec() {
  # write_readme_with_spec <plan_directory> <spec_path>
  mkdir -p "$1"
  {
    printf '# Plan\n\n'
    printf '## Source SPEC\n\n'
    printf 'Derived from %s (%s).\n' "$(basename "$(dirname "$2")")" "$2"
  } > "$1/README.md"
}

write_readme_spec_less() {
  mkdir -p "$1"
  printf '# Plan\n\nNo source spec here.\n' > "$1/README.md"
}

# write_review_sidecar <projects_root> <session_id> <agent_type>: fabricates
# the sidecar meta file the cheap gate globs
# (<projects-root>/*/<session_id>/subagents/agent-*.meta.json). Sets $PROOT.
write_review_sidecar() {
  PROOT="$1"
  local session_id="$2" atype="$3" directory
  directory="$PROOT/proj-hash/$session_id/subagents"
  mkdir -p "$directory"
  jq -n --arg t "$atype" '{agentType: $t, description: "review the diff", toolUseId: "toolu_1"}' \
    > "$directory/agent-0001.meta.json"
}

run_hook_bash() {
  # run_hook_bash <command> <session_id> <projects_root>
  local command="$1" session_id="$2" proot="$3" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use "$session_id" Bash "$command")
  run env GAIA_TALLY_PROJECTS_ROOT="$proot" bash -c "echo '$input' | '$STAGED_HOOK'"
}

run_hook_stop() {
  # run_hook_stop <session_id> <projects_root>
  local session_id="$1" proot="$2" input
  input=$("$HELPERS/mock-hook-input.sh" stop "$session_id")
  run env GAIA_TALLY_PROJECTS_ROOT="$proot" bash -c "echo '$input' | '$STAGED_HOOK'"
}

# ---------- 1. Never-blocks contract (acceptance criterion 1) ----------

@test "non-gh-pr-merge Bash payload: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects-unused"
  run_hook_bash "git commit -m x" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "Stop payload with no code-audit-frontend sidecar: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects-empty"
  mkdir -p "$PROOT"
  run_hook_stop "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "empty/garbage payload: exit 0" {
  build_repo
  cd "$REPO"
  invoke_hook 'not-json{{' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "truly empty stdin: exit 0" {
  build_repo
  cd "$REPO"
  invoke_hook '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "missing jq on PATH: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects-unused"
  # Symlink farm of the tools the hook + git need, deliberately WITHOUT jq, so
  # `command -v jq` fails and the hook's earliest guard fires.
  FARM="$(path_allowlist bash git cat mkdir mktemp mv rm cp chmod grep sed printf basename dirname env sh)"
  run env PATH="$FARM" GAIA_TALLY_PROJECTS_ROOT="$PROOT" bash -c "echo 'x' | '$HOOK_ABSOLUTE_PATH'"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

# ---------- 2. Bash gh-pr-merge invocation: arg capture (acceptance 2, DP-004) ----------

@test "gh pr merge with a code-audit-frontend session: invokes the tally with --session-id and no id flag (ad-hoc)" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_bash "gh pr merge 7 --squash" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
  grep -qF -- "--action" "$CALLS_FILE"
  grep -qF -- "review" "$CALLS_FILE"
  grep -qF -- "--session-id" "$CALLS_FILE"
  grep -qF -- "S1" "$CALLS_FILE"
  grep -qF -- "--projects-root" "$CALLS_FILE"
  grep -qF -- "$PROOT" "$CALLS_FILE"
  # Ad-hoc: no active plan folder at all, so neither id flag is passed.
  grep -qF -- "--spec-id" "$CALLS_FILE" && return 1
  ! grep -qF -- "--plan-id" "$CALLS_FILE"
}

@test "gh pr merge with an active SPEC-derived plan: invokes the tally with --spec-id" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"

  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
  grep -qF -- "--spec-id" "$CALLS_FILE"
  grep -qF -- "SPEC-013" "$CALLS_FILE"
  ! grep -qF -- "--plan-id" "$CALLS_FILE"
}

@test "gh pr merge with a SPEC-less active plan: invokes the tally with --plan-id" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/PLAN-003"
  write_readme_spec_less "$plan_directory"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"

  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  grep -qF -- "--plan-id" "$CALLS_FILE"
  grep -qF -- "PLAN-003" "$CALLS_FILE"
  ! grep -qF -- "--spec-id" "$CALLS_FILE"
}

@test "running-but-unclassifiable colocated plan recovers the SPEC id from the plan-dir path" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  # Colocated plan dir whose README has no parseable Source SPEC section, so
  # resolve_feature_key's fallback returns the bare basename `plan`.
  plan_directory="$REPO/.gaia/local/specs/SPEC-099/plan"
  write_readme_spec_less "$plan_directory"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"

  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  grep -qF -- "--spec-id" "$CALLS_FILE"
  grep -qF -- "SPEC-099" "$CALLS_FILE"
  ! grep -qF -- "--plan-id" "$CALLS_FILE"
}

@test "gh pr merge mentioned only inside heredoc body prose: not matched" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  heredoc_command=$'cat <<EOF\nPlease remember to gh pr merge later.\nEOF'
  run_hook_bash "$heredoc_command" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

# ---------- Shared arming decision (data proof, bound, tokenizer) ----------

@test "a real gh pr merge heredoc body (cat-to-file) is proven data: no invocation, and the same text without it invokes" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  heredoc_command=$'cat > /tmp/notes.txt <<EOF\ngh pr merge\nEOF'
  run_hook_bash "$heredoc_command" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]

  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
}

@test "the same heredoc-body payload padded past the arming bound does invoke the tally" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  local pad heredoc_command
  pad=$(printf 'x%.0s' $(seq 1 16400))
  heredoc_command=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr merge\nEOF'
  [ "${#heredoc_command}" -gt 16384 ] || return 1

  run_hook_bash "$heredoc_command" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
}

@test "a quoted verb in the first command invokes the tally (tokenizer arm; red before this change)" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_bash 'gh pr "merge" 7' "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
}

@test "a multi-statement command still invokes the tally (no regression)" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_bash "echo start && gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
}

# ---------- 3. Cheap negative gate: spurious guard (acceptance criterion 3) ----------

@test "gh pr merge with NO code-audit-frontend sidecar meta: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  # A sidecar exists, but it is not a code-audit-frontend run.
  write_review_sidecar "$PROOT" "S1" "general-purpose"

  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "gh pr merge with no sidecars at all under the session: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects-nosidecars"
  mkdir -p "$PROOT"
  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "gh pr merge with only a non-default roster member's sidecar: invokes the tally" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-github-workflows"

  run_hook_bash "gh pr merge 7 --squash" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
  grep -qF -- "review" "$CALLS_FILE"
}

@test "gh pr merge with an off-roster code-audit-* sidecar: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  # Shares the members' naming prefix but is not on the roster.
  write_review_sidecar "$PROOT" "S1" "code-audit-not-on-roster"

  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "unreadable roster: the gate falls back to the default member name" {
  build_repo
  cd "$REPO"
  rm -f "$REPO/.gaia/audit-ci.yml"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_bash "gh pr merge" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
}

# ---------- 4. Stop path (acceptance criterion 2, Stop variant) ----------

@test "Stop payload with a code-audit-frontend session: invokes the tally" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  run_hook_stop "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
  grep -qF -- "review" "$CALLS_FILE"
  grep -qF -- "S1" "$CALLS_FILE"
}

@test "Stop payload with stop_hook_active true: exit 0, tally not invoked (loop guard)" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  input=$(jq -n --arg session_id "S1" '{session_id: $session_id, transcript_path: "/tmp/t.jsonl", cwd: ".", hook_event_name: "Stop", stop_hook_active: true}')
  run env GAIA_TALLY_PROJECTS_ROOT="$PROOT" bash -c "echo '$input' | '$STAGED_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

# ---------- 5. Script-rooted invocation: no PATH-injected stub interception ----------

@test "invokes token-tally.sh by a script-rooted path, not via PATH lookup" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-audit-frontend"

  # A PATH-injected stub named token-tally.sh must NOT be the one invoked; the
  # hook names the script by a path derived from its own location.
  PATHSTUB="$(mktemp -d -t token-tally-review-pathstub-XXXXXX)"
  cat > "$PATHSTUB/token-tally.sh" <<'EOF'
#!/usr/bin/env bash
echo "WRONG STUB CALLED" >&2
exit 1
EOF
  chmod +x "$PATHSTUB/token-tally.sh"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr merge")
  run env PATH="$PATHSTUB:$PATH" GAIA_TALLY_PROJECTS_ROOT="$PROOT" bash -c "echo '$input' | '$STAGED_HOOK'"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
  rm -rf "$PATHSTUB"
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}
