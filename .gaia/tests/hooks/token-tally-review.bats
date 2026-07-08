#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/token-tally-review.sh (SPEC-032 FC-3/FC-4).
#
# This hook is a thin trigger: it cheap-gates on a code-review-audit sidecar
# actually existing, resolves SPEC/PLAN association, and invokes
# `token-tally.sh --action review` by its literal repo-relative path. The
# real trigger -> row -> dedup effect is owned by task-integration-e2e; this
# suite proves the INVOCATION (arg capture via a recording stub, DP-004),
# the cheap negative gate, the Bash/Stop payload dispatch, and the
# never-blocks contract.
#
# Every test runs the hook with cwd = a tmp git repo, never the real repo
# root, so no test row is ever appended to the real
# .gaia/local/telemetry/cost.jsonl and no test ever shells out to the real
# token-tally.sh (a recording stub stands in at the same repo-relative path).

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/token-tally-review.sh"
  LIB_SRC="$REPO_ROOT/.claude/hooks/lib/gaia-active-plan.sh"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${PROOT:-}" ] && rm -rf "$PROOT"
  [ -n "${FARM:-}" ] && rm -rf "$FARM"
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
  cp "$LIB_SRC" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$REPO/.claude/hooks/lib/gaia-active-plan.sh"

  CALLS_FILE="$REPO/.gaia/local/tally-review-calls.txt"
  mkdir -p "$(dirname "$CALLS_FILE")"
  cat > "$REPO/.gaia/scripts/token-tally.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CALLS_FILE"
exit 0
STUB
  chmod +x "$REPO/.gaia/scripts/token-tally.sh"
}

write_running() {
  # write_running <plan_dir> <branch> <started>
  mkdir -p "$1"
  { printf 'branch: %s\n' "$2"; printf 'slug: %s\n' "$(basename "$1")"; printf 'started: %s\n' "$3"; } > "$1/RUNNING"
}

write_readme_with_spec() {
  # write_readme_with_spec <plan_dir> <spec_path>
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
# (<projects-root>/*/<sid>/subagents/agent-*.meta.json). Sets $PROOT.
write_review_sidecar() {
  PROOT="$1"
  local sid="$2" atype="$3" dir
  dir="$PROOT/proj-hash/$sid/subagents"
  mkdir -p "$dir"
  jq -n --arg t "$atype" '{agentType: $t, description: "review the diff", toolUseId: "toolu_1"}' \
    > "$dir/agent-0001.meta.json"
}

run_hook_bash() {
  # run_hook_bash <command> <session_id> <projects_root>
  local cmd="$1" sid="$2" proot="$3" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use "$sid" Bash "$cmd")
  run env GAIA_TALLY_PROJECTS_ROOT="$proot" bash -c "echo '$input' | '$HOOK_ABS'"
}

run_hook_stop() {
  # run_hook_stop <session_id> <projects_root>
  local sid="$1" proot="$2" input
  input=$("$HELPERS/mock-hook-input.sh" stop "$sid")
  run env GAIA_TALLY_PROJECTS_ROOT="$proot" bash -c "echo '$input' | '$HOOK_ABS'"
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

@test "Stop payload with no code-review-audit sidecar: exit 0, tally not invoked" {
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
  run bash -c "echo 'not-json{{' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "truly empty stdin: exit 0" {
  build_repo
  cd "$REPO"
  run bash -c "echo '' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

@test "missing jq on PATH: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects-unused"
  # Symlink farm of the tools the hook + git need, deliberately WITHOUT jq, so
  # `command -v jq` fails and the hook's earliest guard fires.
  FARM="$(mktemp -d -t token-tally-review-nojq-XXXXXX)"
  local t p
  for t in bash git cat mkdir mktemp mv rm cp chmod grep sed printf basename dirname env sh; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$FARM/$t"
  done
  run env PATH="$FARM" GAIA_TALLY_PROJECTS_ROOT="$PROOT" bash -c "echo 'x' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

# ---------- 2. Bash gh-pr-merge invocation: arg capture (acceptance 2, DP-004) ----------

@test "gh pr merge with a code-review-audit session: invokes the tally with --session-id and no id flag (ad-hoc)" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

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
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

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
  plan_dir="$REPO/.gaia/local/plans/PLAN-003"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

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
  plan_dir="$REPO/.gaia/local/specs/SPEC-099/plan"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

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
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

  heredoc_cmd=$'cat <<EOF\nPlease remember to gh pr merge later.\nEOF'
  run_hook_bash "$heredoc_cmd" "S1" "$PROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

# ---------- 3. Cheap negative gate: spurious guard (acceptance criterion 3) ----------

@test "gh pr merge with NO code-review-audit sidecar meta: exit 0, tally not invoked" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  # A sidecar exists, but it is not a code-review-audit run.
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

# ---------- 4. Stop path (acceptance criterion 2, Stop variant) ----------

@test "Stop payload with a code-review-audit session: invokes the tally" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

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
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

  input=$(jq -n --arg sid "S1" '{session_id: $sid, transcript_path: "/tmp/t.jsonl", cwd: ".", hook_event_name: "Stop", stop_hook_active: true}')
  run env GAIA_TALLY_PROJECTS_ROOT="$PROOT" bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS_FILE" ]
}

# ---------- 5. Repo-relative invocation: no PATH-injected stub interception ----------

@test "invokes token-tally.sh by literal repo-relative path, not via PATH lookup" {
  build_repo
  cd "$REPO"
  PROOT="$REPO/projects"
  write_review_sidecar "$PROOT" "S1" "code-review-audit"

  # A PATH-injected stub named token-tally.sh must NOT be the one invoked;
  # the hook calls `bash .gaia/scripts/token-tally.sh` by literal path.
  PATHSTUB="$(mktemp -d -t token-tally-review-pathstub-XXXXXX)"
  cat > "$PATHSTUB/token-tally.sh" <<'EOF'
#!/usr/bin/env bash
echo "WRONG STUB CALLED" >&2
exit 1
EOF
  chmod +x "$PATHSTUB/token-tally.sh"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr merge")
  run env PATH="$PATHSTUB:$PATH" GAIA_TALLY_PROJECTS_ROOT="$PROOT" bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -f "$CALLS_FILE" ]
  rm -rf "$PATHSTUB"
}
