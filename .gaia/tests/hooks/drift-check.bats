#!/usr/bin/env bats

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK="$BATS_TEST_DIRNAME/../../../.claude/hooks/wiki-drift-check.sh"
  # Hook is invoked relative to its own repo. Resolve to absolute.
  HOOK_ABS=$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $REPO to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

@test "no state file: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  rm -f wiki/.state.json
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state matches HEAD: silent, marker written" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f .claude/wiki-drift-checked ]
  grep -q "session_id=S1" .claude/wiki-drift-checked
}

@test "5 commits behind: emits reminder, writes marker" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 5)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)  # initial commit
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[wiki state]"* ]]
  [[ "$output" == *"5 commits ahead"* ]]
  [ -f .claude/wiki-drift-checked ]
  grep -q "drift_count=5" .claude/wiki-drift-checked
}

@test "same session_id second prompt: no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 3)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF

  # First call: emits reminder
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ -n "$output" ]

  # Second call same session: no output
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "different session_id: emits again" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 3)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF

  input1=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  bash -c "echo '$input1' | '$HOOK_ABS'" >/dev/null

  input2=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S2)
  invoke_hook "$input2" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[wiki state]"* ]]
  grep -q "session_id=S2" .claude/wiki-drift-checked
}

@test "unreachable state SHA (rebase scenario): silent" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 2)
  cd "$REPO"
  # Use a SHA that doesn't exist in this repo
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing jq input: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  # Need a state file present so we get past the early state-file existence check
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  invoke_hook 'not json' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "only a wiki-sync commit ahead: silent (self-referential, not real drift)" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  base=$(git rev-parse HEAD)
  # A `gaia wiki sync land` bookkeeping commit sitting on top of the recorded SHA.
  echo "synced" >> wiki/index.md
  git add wiki/index.md
  git commit --quiet -m "wiki: sync through ${base:0:7}"
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "drift_count=0" .claude/wiki-drift-checked
}

@test "wiki-sync commit excluded from count, real commits still counted" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 2)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)
  # Two real commits already exist; add a self-referential sync commit on top.
  echo "synced" >> wiki/index.md
  git add wiki/index.md
  git commit --quiet -m "wiki: sync through deadbee"
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 commits ahead"* ]]
  grep -q "drift_count=2" .claude/wiki-drift-checked
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABS" ]
}

# --- Draining the janitor's one-line base-catch-up report ------------------
# .claude/hooks/local-janitor.sh writes at most one line to
# .gaia/local/cache/shared/wiki-base-catchup.report when its own fast-forward
# of the base branch is refused. This hook is the delivery channel: its
# stdout is injected into the conversation, which a SessionStart hook's
# exit-0 stderr is not. The drain sits above every early exit (jq, work-tree,
# wiki/.state.json) so a checkout missing any of those still delivers it.

@test "drains the base-catch-up report to stdout exactly once" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  mkdir -p .gaia/local/cache/shared
  printf '[wiki base] fast-forward of main to origin/main refused (divergence); local base is behind. Resolve by hand; the next qualifying session retries.\n' \
    > .gaia/local/cache/shared/wiki-base-catchup.report
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- '[wiki base] fast-forward of main to origin/main refused' <<<"$output" || return 1
  [ ! -f .gaia/local/cache/shared/wiki-base-catchup.report ] || return 1

  # Read-and-delete: a second prompt in the same session sees nothing left.
  input2=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S2)
  invoke_hook "$input2" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- '[wiki base]' <<<"$output" && return 1
  return 0
}

@test "drains the report even when jq is unavailable" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  mkdir -p .gaia/local/cache/shared
  printf '[wiki base] fast-forward of main to origin/main refused (git error); local base is behind. Resolve by hand; the next qualifying session retries.\n' \
    > .gaia/local/cache/shared/wiki-base-catchup.report

  # `command -v jq` only checks that an executable NAMED jq is on PATH; a shim
  # that fails when run still satisfies it. To genuinely simulate "jq
  # unavailable" the PATH below carries no jq at all -- only symlinks to the
  # handful of external binaries the drain block itself needs (head, rm) plus
  # bash to run the hook.
  nojq_bin=$(mktemp -d -t gaia-drift-nojq-XXXXXX)
  ln -sf "$(command -v bash)" "$nojq_bin/bash"
  ln -sf "$(command -v head)" "$nojq_bin/head"
  ln -sf "$(command -v rm)" "$nojq_bin/rm"

  run bash -c 'PATH="$1" bash "$2" < /dev/null' _ "$nojq_bin" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- '[wiki base] fast-forward of main to origin/main refused' <<<"$output" || return 1
  [ ! -f .gaia/local/cache/shared/wiki-base-catchup.report ] || return 1
  rm -rf "$nojq_bin"
}

@test "no report file is a silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  rm -f .gaia/local/cache/shared/wiki-base-catchup.report
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
