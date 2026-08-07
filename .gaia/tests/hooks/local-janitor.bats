#!/usr/bin/env bats
#
# TST-012's stderr-vs-stdout separation below needs `run --separate-stderr`
# (bats >= 1.5.0); this declaration alters `run` semantics for every test in
# this file, not just the ones that use the separated form.
bats_require_minimum_version 1.5.0
#
# Sweep #1 of local-janitor.sh: the wiki landing's local catch-up.
#
# The wiki landing CLI cuts a throwaway `wiki-sync/<date>-<sha>` branch and
# lands it with `gh pr merge --auto`, which returns before the merge completes.
# The merge gate routinely outlasts the CLI's own bounded wait, so on the
# common path the local branch is not deleted inline and the local base branch
# does not advance either. Sweep #1 covers both, in four steps: an existence
# gate on a local `wiki-sync/*` branch, a bounded and rate-limited
# `git fetch --prune` of origin, a reap of each `[gone]` `wiki-sync/*` branch
# whose work `git cherry` confirms is already represented upstream, and a
# durable `--ff-only` fast-forward of the base branch to `origin/<base>`.
#
# `[gone]` is not read here as proof of a merge: it proves only that the remote
# head ref is absent, which is why the reap carries its own patch-id check and
# the fast-forward rests on `--ff-only` rather than on the reap preceding it.
# A fast-forward the gates decline is a silent skip; one that is attempted and
# fails records a durable obligation and reports one line. This suite covers
# all four steps, both knobs, and every gate.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/local-janitor.sh
  REPO_ROOT_REAL=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${ORIGIN:-}" ] && rm -rf "$ORIGIN"
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  return 0
}

# Stand up a repo with a real bare origin so upstream-track state is faithful.
# Pushes main and points origin/HEAD at it (RT-014): without this, base has no
# upstream and every base-related sweep-#1 arm is an unreachable no-op that
# greens on the skip path regardless of what it is meant to exercise.
make_repo() {
  ORIGIN=$(mktemp -d -t gaia-janitor-origin-XXXXXX)
  # --initial-branch=main: a bare repo initialized without it keeps whatever
  # init.defaultBranch the local git config supplies, which is unset on CI
  # (falls back to "master"). `remote set-head origin -a` below asks the
  # remote for its own HEAD and cannot resolve a branch that was never
  # created, so this pins the name explicitly rather than relying on ambient
  # config -- same hazard make_repo_default_branch documents just below.
  git init -q --bare --initial-branch=main "$ORIGIN"
  REPO=$(mktemp -d -t gaia-janitor-repo-XXXXXX)
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$ORIGIN"
  echo init > "$REPO/f"
  # .gaia/local is gitignored in every real GAIA checkout; committing the same
  # entry here is what makes `git status --porcelain` clean reachable at all
  # once mkdir -p below creates the directory -- load-bearing for the
  # fast-forward's working-tree-clean gate.
  printf '.gaia/local/\n' > "$REPO/.gitignore"
  git -C "$REPO" add f .gitignore
  git -C "$REPO" commit -q -m init
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" remote set-head origin -a
  mkdir -p "$REPO/.gaia/local"
}

# A repo whose default branch is NOT `main`, with origin/HEAD pointing at it
# (UAT-009, consumed by the fast-forward task that lands beside this one).
make_repo_default_branch() {
  local base="$1"
  ORIGIN=$(mktemp -d -t gaia-janitor-origin-XXXXXX)
  # The bare repo's own HEAD symref must already name $base: `remote set-head
  # origin -a` below asks the remote for its own HEAD, and a bare repo
  # initialized without --initial-branch keeps whatever init.defaultBranch
  # the local git config supplies (often "main"), which never gets created
  # here when $base is something else -- "Cannot determine remote HEAD".
  git init -q --bare --initial-branch="$base" "$ORIGIN"
  REPO=$(mktemp -d -t gaia-janitor-repo-XXXXXX)
  git -C "$REPO" init -q --initial-branch="$base"
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$ORIGIN"
  echo init > "$REPO/f"
  printf '.gaia/local/\n' > "$REPO/.gitignore"
  git -C "$REPO" add f .gitignore
  git -C "$REPO" commit -q -m init
  git -C "$REPO" push -q -u origin "$base"
  git -C "$REPO" remote set-head origin -a
  mkdir -p "$REPO/.gaia/local"
}

# A branch whose upstream is [gone]: pushed (tracking ref created), then the
# remote head is deleted and pruned. Mirrors a squash-merged, auto-deleted PR.
make_gone_branch() {
  local br="$1"
  git -C "$REPO" branch "$br"
  git -C "$REPO" push -q -u origin "$br"
  git -C "$REPO" push -q origin --delete "$br"
  git -C "$REPO" fetch -q --prune
}

# A branch whose remote head is deleted but which has NOT been pruned
# locally, so its upstream-track state is not yet [gone]. This is the state a
# real checkout is in right after a wiki landing's PR squash-merges: exactly
# the state sweep #1's own prune-fetch has to resolve.
make_gone_branch_unpruned() {
  local br="$1" clone
  git -C "$REPO" branch "$br"
  git -C "$REPO" push -q -u origin "$br"
  # Delete the remote branch from a SEPARATE clone, not through REPO's own
  # push: `git push origin --delete` updates the pushing repo's OWN
  # remote-tracking ref as part of that same push, so a delete issued from
  # REPO itself would already read [gone] before REPO's own fetch ever runs
  # -- REPO never observes the delay this fixture exists to model. A second
  # clone has no such side channel back to REPO: REPO's own
  # refs/remotes/origin/$br stays exactly as it was (present, live) until
  # REPO's own `git fetch --prune` resolves it, which is the real shape of a
  # checkout that has not yet caught up with a squash-merged PR's
  # auto-deleted branch.
  clone=$(mktemp -d -t gaia-janitor-unpruned-clone-XXXXXX)
  git clone -q "$ORIGIN" "$clone"
  git -C "$clone" push -q origin --delete "$br"
  rm -rf "$clone"
}

# A branch with a live, in-sync upstream (tracking ref still present).
make_live_branch() {
  local br="$1"
  git -C "$REPO" branch "$br"
  git -C "$REPO" push -q -u origin "$br"
}

branch_exists() {
  git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1
}

@test "deletes a merged-and-gone wiki-sync branch" {
  make_repo
  make_gone_branch "wiki-sync/2026-01-01-aaaaaaa"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  ! branch_exists "wiki-sync/2026-01-01-aaaaaaa"
}

@test "keeps a wiki-sync branch whose upstream is still live" {
  make_repo
  make_live_branch "wiki-sync/2026-02-02-bbbbbbb"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "wiki-sync/2026-02-02-bbbbbbb"
}

@test "never deletes the current branch, even when gone" {
  make_repo
  make_gone_branch "wiki-sync/2026-03-03-ccccccc"
  git -C "$REPO" checkout -q "wiki-sync/2026-03-03-ccccccc"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "wiki-sync/2026-03-03-ccccccc"
}

@test "keeps a gone branch outside the wiki-sync/* class" {
  make_repo
  make_gone_branch "feature/some-work"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "feature/some-work"
}

@test "deletes gone wiki-sync while keeping live wiki-sync and gone non-wiki" {
  make_repo
  make_gone_branch "wiki-sync/2026-04-04-ddddddd"
  make_live_branch "wiki-sync/2026-05-05-eeeeeee"
  make_gone_branch "feature/keepme"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "wiki-sync/2026-04-04-ddddddd" && return 1
  branch_exists "wiki-sync/2026-05-05-eeeeeee"
  branch_exists "feature/keepme"
}

@test "runs the branch sweep even when .gaia/local is absent" {
  make_repo
  make_gone_branch "wiki-sync/2026-06-06-fffffff"
  rm -rf "$REPO/.gaia/local"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  ! branch_exists "wiki-sync/2026-06-06-fffffff"
}

@test "no wiki-sync branches: silent no-op, exit 0" {
  make_repo
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  branch_exists "main"
}

# --- Sweep #1's bounded prune-fetch and guarded reap (TST-003: reuse the
# PATH-shim-plus-witness idiom used elsewhere in this file rather than
# inventing a second one) --------------------------------------------------

# PATH-shimmed `git`: appends every invocation's argv to a witness file, then
# passes through to the real binary.
make_argv_witness_shim() {
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  witness="$SHIM_DIR/witness"
  : > "$witness"
  local real_git
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
echo "\$*" >> "$witness"
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}

# PATH-shimmed `git` whose fetch arm hangs for $1 seconds (default 60); every
# other call passes through to the real binary.
make_hanging_fetch_shim() {
  local sleep_secs="${1:-60}"
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  local real_git
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
case "\$*" in
  *fetch*) sleep $sleep_secs; exit 0 ;;
esac
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}

# PATH-shimmed `git` whose fetch arm backgrounds a long-sleeping grandchild
# and records both its own pid and the grandchild's into a witness file, so a
# test can assert BOTH are gone after the hook's kill path runs. Every other
# call passes through to the real binary.
make_hanging_fetch_pid_witness_shim() {
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  witness="$SHIM_DIR/pids"
  : > "$witness"
  local real_git
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
case "\$*" in
  *fetch*)
    sleep 3600 &
    child=\$!
    echo "\$\$ \$child" >> "$witness"
    wait
    exit 0
    ;;
esac
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}

# PATH-shimmed `git` that records argv plus the four prompt-suppression
# variables' values into a witness file (one line per invocation), then
# passes through to the real binary.
make_env_witness_shim() {
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  witness="$SHIM_DIR/envlog"
  : > "$witness"
  local real_git
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
printf 'ARGV=%s GIT_TERMINAL_PROMPT=%s GIT_ASKPASS=%s SSH_ASKPASS=%s GIT_SSH_COMMAND=%s\n' \
  "\$*" "\${GIT_TERMINAL_PROMPT:-}" "\${GIT_ASKPASS:-}" "\${SSH_ASKPASS:-}" "\${GIT_SSH_COMMAND:-}" >> "$witness"
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}

@test "sweep 1: no wiki-sync branch makes ZERO fetch calls (positive argv witness)" {
  make_repo
  make_argv_witness_shim
  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c 'fetch' "$witness")" -eq 0 ]
}

@test "sweep 1: a hanging origin is bounded by the ceiling" {
  make_repo
  make_live_branch "wiki-sync/2026-07-07-1111111"
  make_hanging_fetch_shim 60
  cd "$REPO"
  export GAIA_WIKI_FETCH_TIMEOUT_SECONDS=2
  start=$(date +%s)
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  [ "$((end - start))" -lt 10 ]
}

@test "sweep 1: GAIA_WIKI_FETCH_TIMEOUT_SECONDS=0 disables the fetch" {
  make_repo
  make_live_branch "wiki-sync/2026-07-08-2222222"
  make_argv_witness_shim
  cd "$REPO"
  export GAIA_WIKI_FETCH_TIMEOUT_SECONDS=0
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'fetch' "$witness")" -eq 0 ]
}

@test "sweep 1: a mistyped ceiling clamps rather than blowing the budget" {
  make_repo
  make_live_branch "wiki-sync/2026-07-09-3333333"
  make_hanging_fetch_shim 3600
  cd "$REPO"
  # Neutralize the min-interval knob for both sub-cases below: this test's
  # second invocation must actually re-attempt the fetch, not be skipped by
  # the first invocation's own recorded last_fetch_at.
  export GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES=0

  export GAIA_WIKI_FETCH_TIMEOUT_SECONDS=abc
  start=$(date +%s)
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  elapsed=$((end - start))
  [ "$elapsed" -ge 4 ] || return 1
  [ "$elapsed" -lt 10 ] || return 1

  export GAIA_WIKI_FETCH_TIMEOUT_SECONDS=9999
  start=$(date +%s)
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  elapsed=$((end - start))
  [ "$elapsed" -ge 25 ] || return 1
  [ "$elapsed" -lt 45 ] || return 1
}

@test "sweep 1: a zero-padded min-interval still rate-limits the fetch" {
  make_repo
  make_live_branch "wiki-sync/2026-07-11-5555555"
  make_argv_witness_shim
  cd "$REPO"
  # 08 and 09 are the only values the digits-only guard admits and bare
  # arithmetic rejects, as invalid octal. The first run records last_fetch_at;
  # the second is the one that evaluates the interval against it. Read as base
  # 8 that expansion is an error bash handles by unwinding out of every
  # enclosing compound command, so half A is abandoned mid-sweep and no fetch
  # happens either way: neither the exit status nor the fetch count can see it.
  # The diagnostic on stderr is what separates a rate limit that held from a
  # sweep that was abandoned.
  export GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES=08
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ] || return 1
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ] || return 1
  [ "$(grep -c 'fetch' "$witness")" -eq 1 ] || return 1
  case "$output" in *'value too great for base'*) return 1 ;; esac
}

@test "sweep 1: no origin remote skips the fetch outright" {
  make_repo
  make_live_branch "wiki-sync/2026-07-10-4444444"
  git -C "$REPO" remote remove origin
  make_argv_witness_shim
  cd "$REPO"
  start=$(date +%s)
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  [ "$((end - start))" -lt 10 ]
  [ "$(grep -c 'fetch' "$witness")" -eq 0 ]
}

@test "sweep 1: the kill path leaves no descendant and no stale git lock" {
  make_repo
  make_gone_branch_unpruned "wiki-sync/2026-07-11-5555555"
  make_hanging_fetch_pid_witness_shim
  cd "$REPO"
  export GAIA_WIKI_FETCH_TIMEOUT_SECONDS=2
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -s "$witness" ] || return 1
  read -r shim_pid child_pid < "$witness"
  kill -0 "$shim_pid" 2>/dev/null && return 1
  kill -0 "$child_pid" 2>/dev/null && return 1
  [ ! -e "$REPO/.git/FETCH_HEAD.lock" ]
  [ ! -e "$REPO/.git/shallow.lock" ]
  branch_exists "wiki-sync/2026-07-11-5555555"
}

@test "sweep 1: prompt suppression is per-invocation and never leaks" {
  make_repo
  make_live_branch "wiki-sync/2026-07-12-6666666"
  git -C "$REPO" config core.askPass /custom/adopter-askpass
  make_env_witness_shim
  cd "$REPO"
  GIT_SSH_COMMAND="ssh -i /custom/key" PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -s "$witness" ] || return 1

  fetch_line=$(grep 'ARGV=.*fetch' "$witness")
  [ -n "$fetch_line" ] || return 1
  grep -qF -- "GIT_TERMINAL_PROMPT=0" <<<"$fetch_line" || return 1
  grep -qF -- "GIT_ASKPASS=true" <<<"$fetch_line" || return 1
  grep -qF -- "SSH_ASKPASS=true" <<<"$fetch_line" || return 1
  grep -qF -- "BatchMode=yes" <<<"$fetch_line" || return 1
  grep -qF -- "ConnectTimeout=" <<<"$fetch_line" || return 1
  grep -qF -- "-i /custom/key" <<<"$fetch_line" || return 1

  # No LATER invocation carries any of the three boolean suppression
  # variables: they are a per-invocation prefix on the fetch call only, never
  # exported, so every git call after it must see them unset.
  after_fetch=$(sed -n '/ARGV=.*fetch/,$p' "$witness" | tail -n +2)
  if [ -n "$after_fetch" ]; then
    printf '%s\n' "$after_fetch" | grep -qF -- "GIT_TERMINAL_PROMPT=0" && return 1
    printf '%s\n' "$after_fetch" | grep -qF -- "GIT_ASKPASS=true" && return 1
    printf '%s\n' "$after_fetch" | grep -qF -- "SSH_ASKPASS=true" && return 1
  fi

  # The adopter's own git config file is never rewritten; core.askPass= was
  # an inline -c override scoped to the fetch call only.
  [ "$(git -C "$REPO" config core.askPass)" = "/custom/adopter-askpass" ]
}

@test "sweep 1: an unpruned merged-and-gone branch is reaped after the sweep's own fetch" {
  make_repo
  make_gone_branch_unpruned "wiki-sync/2026-07-13-7777777"
  make_argv_witness_shim
  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "wiki-sync/2026-07-13-7777777" && return 1
  [ "$(grep -c 'fetch' "$witness")" -eq 1 ]
}

@test "sweep 1: the reap REFUSES a gone branch carrying commits the remote never had" {
  make_repo
  make_gone_branch_unpruned "wiki-sync/2026-07-14-8888888"
  git -C "$REPO" checkout -q "wiki-sync/2026-07-14-8888888"
  echo more >> "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m more
  git -C "$REPO" checkout -q main
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "wiki-sync/2026-07-14-8888888"
}

@test "sweep 1: repeat fetch attempts are bounded by a minimum interval" {
  make_repo
  make_live_branch "wiki-sync/2026-07-15-9999999"
  make_argv_witness_shim
  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'fetch' "$witness")" -eq 1 ] || return 1

  export GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES=0
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'fetch' "$witness")" -eq 2 ]
}

@test "sweep 1: the WHOLE hook stays inside the SessionStart budget on a hanging remote" {
  make_repo
  make_live_branch "wiki-sync/2026-07-16-aaaaaaa"
  make_hanging_fetch_shim 60
  cd "$REPO"
  start=$(date +%s)
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  elapsed=$((end - start))
  [ "$elapsed" -lt 20 ] || return 1
}

@test "sweep 1: a checkout with no .gaia/local is not recreated by the breadcrumb write" {
  make_repo
  make_gone_branch_unpruned "wiki-sync/2026-07-17-bbbbbbb"
  rm -rf "$REPO/.gaia/local"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -d "$REPO/.gaia/local" ]
}

# --- Half B: the durable-obligation fast-forward, breadcrumb, and refusal ---
# report (UAT-008 to UAT-015, UAT-018, UAT-020). See task-janitor-catchup's
# `### The fast-forward gate chain` and `### The durable-obligation mechanism`.

catchup_state_file() { printf '%s' "$REPO/.gaia/local/cache/shared/wiki-base-catchup.state"; }
catchup_report_file() { printf '%s' "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report"; }

catchup_owed_is_set() {
  local f; f=$(catchup_state_file)
  [ -f "$f" ] && grep -qF -- "catchup_owed=1" "$f"
}

# advance_origin_main [base]: pushes a NEW commit to $ORIGIN's own [base]
# (default main) via a throwaway clone, so REPO's local [base] is left
# strictly BEHIND origin/[base] without ever touching REPO's own working
# tree or history. The new commit writes wiki/.state.json, so a test can
# assert the fast-forward's working-tree content, not just its ref.
advance_origin_main() {
  local base="${1:-main}" clone
  clone=$(mktemp -d -t gaia-janitor-adv-XXXXXX)
  git clone -q "$ORIGIN" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name Test
  git -C "$clone" config commit.gpgsign false
  mkdir -p "$clone/wiki"
  echo '{"advanced":true}' > "$clone/wiki/.state.json"
  git -C "$clone" add wiki/.state.json
  git -C "$clone" commit -q -m "advance $base"
  git -C "$clone" push -q origin "$base"
  rm -rf "$clone"
}

# diverge_base_and_origin [base]: local [base] gets ONE commit never pushed;
# origin's [base] gets a DIFFERENT commit, pushed via a throwaway clone taken
# BEFORE the local commit exists. Neither side is an ancestor of the other --
# genuine divergence, the shape `merge --ff-only` refuses outright.
diverge_base_and_origin() {
  local base="${1:-main}" clone
  echo "local only" >> "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m "local-only change"

  clone=$(mktemp -d -t gaia-janitor-div-XXXXXX)
  git clone -q "$ORIGIN" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name Test
  git -C "$clone" config commit.gpgsign false
  echo "origin only" >> "$clone/f"
  git -C "$clone" add f
  git -C "$clone" commit -q -m "origin-only change"
  git -C "$clone" push -q origin "$base"
  rm -rf "$clone"
}

# seed_catchup_owed: writes catchup_owed=1 directly, bypassing a real reap --
# UAT-012's "no branch present" arm needs the breadcrumb already on file
# BEFORE the session under test ever runs.
seed_catchup_owed() {
  mkdir -p "$REPO/.gaia/local/cache/shared"
  printf 'catchup_owed=1\n' > "$(catchup_state_file)"
}

# make_status_clean_shim: a PATH-shimmed `git` whose `status --porcelain`
# call always reports clean, while every other call (fetch, merge, branch,
# ...) passes through to the real binary. Simulates the TOCTOU window
# between the gate's own status read and the merge attempt: a real
# untracked-collision failure needs a file on disk `git status --porcelain`
# would otherwise show, which would fail the clean-tree gate before the
# merge is ever attempted.
make_status_clean_shim() {
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  local real_git
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
case "\$*" in
  *"status --porcelain"*) exit 0 ;;
esac
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}

@test "sweep 1: fast-forwards base with a checkout-aware --ff-only" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-11-4444441"
  make_argv_witness_shim
  advance_origin_main main
  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse origin/main)" ] || return 1
  [ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] || return 1
  [ "$(cat "$REPO/wiki/.state.json" 2>/dev/null)" = '{"advanced":true}' ] || return 1
  [ "$(grep -c 'fetch' "$witness")" -eq 1 ] || return 1
  grep -qF -- 'pull' "$witness" && return 1
  branch_exists "wiki-sync/2026-08-11-4444441" && return 1
  return 0
}

@test "sweep 1: base resolution honors a non-main default branch" {
  make_repo_default_branch trunk
  make_gone_branch "wiki-sync/2026-08-07-ffff007"
  advance_origin_main trunk
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse trunk)" = "$(git -C "$REPO" rev-parse origin/trunk)" ]
}

@test "sweep 1: base resolution falls back when origin/HEAD is unset" {
  make_repo
  git -C "$REPO" remote set-head origin --delete
  make_gone_branch "wiki-sync/2026-08-08-00000a8"
  advance_origin_main main
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse origin/main)" ]
}

# Reproduces the fail-open the reap's cherry check used to have: with
# origin/HEAD unset AND a non-main default branch, base's fallback ("main")
# never resolves on this remote (origin/main does not exist -- the remote's
# default is trunk). `git cherry` against that unresolvable base fails and
# prints nothing, which `grep -c` alone cannot distinguish from a genuine
# zero-unpushed-commits answer. An unanswerable question must keep the
# branch, per the reap's own comment, not read the failure as "fully
# represented upstream" and delete it.
@test "sweep 1: an unresolvable base keeps a gone wiki-sync branch and its unmerged commit" {
  make_repo_default_branch trunk
  git -C "$REPO" remote set-head origin --delete
  local br="wiki-sync/2026-08-08-b00b00b"
  git -C "$REPO" checkout -qb "$br"
  echo "unmerged wiki work" >> "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m "unmerged wiki-sync work"
  local tip; tip=$(git -C "$REPO" rev-parse "$br")
  git -C "$REPO" push -q -u origin "$br"
  git -C "$REPO" checkout -q trunk
  # Mirrors a squash-merged, auto-deleted PR: the remote head vanishes via a
  # SEPARATE clone (see make_gone_branch_unpruned above for why), so REPO's
  # own upstream-track state still needs the hook's own fetch --prune to
  # resolve to [gone].
  local clone; clone=$(mktemp -d -t gaia-janitor-b00b-clone-XXXXXX)
  git clone -q "$ORIGIN" "$clone"
  git -C "$clone" push -q origin --delete "$br"
  rm -rf "$clone"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "$br" || return 1
  [ "$(git -C "$REPO" rev-parse "$br")" = "$tip" ] || return 1
  return 0
}

@test "sweep 1: an unmerged wiki-sync branch leaves base byte-identical" {
  make_repo
  make_live_branch "wiki-sync/2026-08-01-aaaa001"
  advance_origin_main main
  local before; before=$(git -C "$REPO" rev-parse main)
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$before" ] || return 1
  branch_exists "wiki-sync/2026-08-01-aaaa001"
}

@test "sweep 1: dirty tree skips the fast-forward silently" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-02-cccc002"
  advance_origin_main main
  local before; before=$(git -C "$REPO" rev-parse main)
  echo dirty > "$REPO/dirty.txt"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$before" ] || return 1
  [ -f "$(catchup_report_file)" ] && return 1
  branch_exists "wiki-sync/2026-08-02-cccc002" && return 1
  return 0
}

@test "sweep 1: HEAD off base skips" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-03-cccc003"
  advance_origin_main main
  local before; before=$(git -C "$REPO" rev-parse main)
  git -C "$REPO" checkout -qb feature/off-base
  local checkout_before; checkout_before=$(git -C "$REPO" rev-parse feature/off-base)
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$before" ] || return 1
  # Without the on-base gate, the fast-forward still runs but advances
  # whatever IS checked out (feature/off-base), not main; main alone staying
  # put does not prove the gate held.
  [ "$(git -C "$REPO" rev-parse feature/off-base)" = "$checkout_before" ] || return 1
  [ -f "$(catchup_report_file)" ] && return 1
  return 0
}

@test "sweep 1: detached HEAD skips" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-04-cccc004"
  advance_origin_main main
  local before; before=$(git -C "$REPO" rev-parse main)
  git -C "$REPO" checkout -q --detach main
  local detached_before; detached_before=$(git -C "$REPO" rev-parse HEAD)
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$before" ] || return 1
  # Same hazard the on-base sibling above documents, in its detached form: with
  # the gate gone the fast-forward advances the detached HEAD itself, which
  # leaves the `main` ref untouched, so main alone staying put proves nothing.
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$detached_before" ] || return 1
  [ -f "$(catchup_report_file)" ] && return 1
  return 0
}

@test "sweep 1: a timed-out fetch does not fast-forward on a stale tracking ref" {
  make_repo
  make_live_branch "wiki-sync/2026-08-06-dddd006"
  advance_origin_main main
  # A PRIOR fetch succeeded, so origin/main is genuinely ahead of main. That is
  # what keeps the drain's is-ancestor read from discharging the obligation
  # before the gate under test is ever reached: without this, catchup_owed
  # clears on its own and the arm proves nothing either way.
  git -C "$REPO" fetch -q origin
  seed_catchup_owed
  local before; before=$(git -C "$REPO" rev-parse main)
  make_hanging_fetch_shim 60
  cd "$REPO"
  export GAIA_WIKI_FETCH_TIMEOUT_SECONDS=2
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ] || return 1
  # THIS session's fetch timed out, so nothing it could read is known fresh and
  # the fast-forward is declined even though every other gate passes and the
  # tracking ref happens to be ahead. The obligation survives for a session
  # whose fetch completes.
  [ "$(git -C "$REPO" rev-parse main)" = "$before" ] || return 1
  catchup_owed_is_set || return 1
}

@test "sweep 1: base with no upstream skips" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-05-cccc005"
  advance_origin_main main
  local before; before=$(git -C "$REPO" rev-parse main)
  git -C "$REPO" branch --unset-upstream main
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$before" ] || return 1
  [ -f "$(catchup_report_file)" ] && return 1
  return 0
}

@test "sweep 1: the obligation survives a session that cannot discharge it" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-06-dddd006"
  advance_origin_main main
  cd "$REPO"
  echo dirty > "$REPO/dirty.txt"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" != "$(git -C "$REPO" rev-parse origin/main)" ] || return 1
  catchup_owed_is_set || return 1

  rm -f "$REPO/dirty.txt"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse origin/main)" ] || return 1
  catchup_owed_is_set && return 1
  return 0
}

@test "sweep 1: the obligation marker cannot accumulate" {
  make_repo
  export GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES=0
  echo dirty > "$REPO/dirty.txt"
  cd "$REPO"
  for n in 1 2 3 4 5; do
    make_gone_branch "wiki-sync/2026-08-2$n-eeee00$n"
    run bash "$HOOK_ABS"
    [ "$status" -eq 0 ]
  done
  local dir; dir="$REPO/.gaia/local/cache/shared"
  [ "$(find "$dir" -maxdepth 1 -name 'wiki-base-catchup.state' | wc -l | tr -d ' ')" -eq 1 ] || return 1
  [ "$(grep -c '^catchup_owed=1$' "$dir/wiki-base-catchup.state")" -eq 1 ] || return 1
  # catchup_owed is drained (unset then reset) by every invocation, which
  # would mask a `wiki_catchup_state_set` regression that appends instead of
  # rewriting: the drain's own correct unset clears the prior line before the
  # broken set appends a new one. last_fetch_at is never unset by anything, so
  # it is the key that actually proves the read-modify-write, not just the
  # AND-list's occurrence count.
  [ "$(grep -c '^last_fetch_at=' "$dir/wiki-base-catchup.state")" -eq 1 ]
}

# wiki_catchup_state_unset's file rewrite is grep-driven: removing a key that
# is the file's ONLY line leaves grep with empty output and a non-zero exit,
# which a naive `grep -v ... >tmp && mv` reads as "the rewrite failed" and
# skips the mv, so the key survives its own deletion. seed_catchup_owed
# produces exactly that single-key file, and base is already caught up with
# origin (make_repo pushes and never advances either side), so the drain-first
# read (a purely local is-ancestor check, no branch or fetch required) unsets
# catchup_owed directly.
@test "sweep 1: a single-key catchup_owed breadcrumb is fully drained once base is caught up" {
  make_repo
  seed_catchup_owed
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  catchup_owed_is_set && return 1
  return 0
}

@test "sweep 1: an owed obligation with NO branch present writes the report and emits nothing" {
  make_repo
  diverge_base_and_origin main
  git -C "$REPO" fetch -q origin
  seed_catchup_owed
  cd "$REPO"
  run --separate-stderr bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || return 1
  [ -z "$stderr" ] || return 1
  local report; report=$(catchup_report_file)
  [ -f "$report" ] || return 1
  grep -qE '^\[wiki base\] fast-forward of main to origin/main refused' "$report"
}

@test "sweep 1: a divergent base is REPORTED, exactly one line, and never blocks" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-12-5555552"
  diverge_base_and_origin main
  local before; before=$(git -C "$REPO" rev-parse main)
  cd "$REPO"
  run --separate-stderr bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$before" ] || return 1
  local report; report=$(catchup_report_file)
  [ -f "$report" ] || return 1
  [ "$(wc -l < "$report" | tr -d ' ')" -eq 1 ] || return 1
  grep -qE '^\[wiki base\] fast-forward of main to origin/main refused' "$report" || return 1
  branch_exists "wiki-sync/2026-08-12-5555552" && return 1
  return 0
}

@test "sweep 1: a non-divergence failure is reported by the same rule" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-13-6666663"
  advance_origin_main main
  mkdir -p "$REPO/wiki"
  echo "collision" > "$REPO/wiki/.state.json"
  make_status_clean_shim
  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run --separate-stderr bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  local report; report=$(catchup_report_file)
  [ -f "$report" ] || return 1
  grep -qF -- "refused (untracked collision)" "$report" || return 1
  # The UAT-011 skip arms above never write a report; this arm's failure is
  # a TRIED-and-failed fast-forward, the only case the report exists for.
  [ "$(wc -l < "$report" | tr -d ' ')" -eq 1 ]
}

@test "sweep 1: a shallow clone degrades without error" {
  make_repo
  local shallow before after br
  br="wiki-sync/2026-08-09-77777a9"
  shallow=$(mktemp -d -t gaia-janitor-shallow-XXXXXX)
  # file://: a bare path clone makes git silently ignore --depth ("--depth is
  # ignored in local clones; use file:// instead"), which would leave this
  # fixture cloning a full repo and the shallow-repository precondition below
  # would never have caught it.
  git clone -q --depth 1 "file://$ORIGIN" "$shallow"
  [ "$(git -C "$shallow" rev-parse --is-shallow-repository)" = "true" ] || return 1
  git -C "$shallow" config user.email test@example.com
  git -C "$shallow" config user.name Test
  git -C "$shallow" config commit.gpgsign false
  git -C "$shallow" remote set-head origin -a
  mkdir -p "$shallow/.gaia/local"
  git -C "$shallow" branch "$br"
  git -C "$shallow" push -q -u origin "$br"
  git -C "$shallow" push -q origin --delete "$br"
  advance_origin_main main
  before=$(git -C "$shallow" rev-parse main)
  cd "$shallow"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || return 1
  after=$(git -C "$shallow" rev-parse main)
  [ "$after" = "$before" ] || return 1
  # --depth 1 implies --single-branch: remote.origin.fetch covers only main,
  # so wiki-sync/*'s upstream is never mapped to a local tracking ref at all
  # -- %(upstream:track) reads empty, not "[gone]", for a ref outside that
  # refspec. The reap loop's own `[ "$track" = "[gone]" ] || continue` gate
  # (line 494, .claude/hooks/local-janitor.sh) then never treats it as a reap
  # candidate, so it survives untouched: the "degrades without error" case
  # for this fixture is skip, not delete.
  git -C "$shallow" rev-parse --verify --quiet "refs/heads/$br" >/dev/null 2>&1 || return 1
  rm -rf "$shallow"
}

@test "sweep 1: two concurrent runs degrade safely" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-10-8888884"
  advance_origin_main main
  local old_main
  old_main=$(git -C "$REPO" rev-parse main)
  cd "$REPO"
  bash "$HOOK_ABS" & local pid1=$!
  bash "$HOOK_ABS" & local pid2=$!
  wait "$pid1"; local s1=$?
  wait "$pid2"; local s2=$?
  [ "$s1" -eq 0 ] || return 1
  [ "$s2" -eq 0 ] || return 1
  [ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] || return 1
  git -C "$REPO" fsck --no-progress >/dev/null 2>&1 || return 1
  local final_main origin_main
  final_main=$(git -C "$REPO" rev-parse main)
  origin_main=$(git -C "$REPO" rev-parse origin/main)
  [ "$final_main" = "$old_main" ] || [ "$final_main" = "$origin_main" ]
}

# --- Migration trigger: ledger-status-migrate.sh runs before the reap sweeps ---
#
# The janitor best-effort runs the one-time ledger-status-migrate.sh right
# after the .gaia/local guard, so a row still on a retired status is on the
# unified vocabulary by the time the reap sweeps read it.

# copy_migrate_deps: mirrors ledger-status-migrate.sh's own repo-relative call
# target inside the fixture repo so the janitor's migration trigger resolves
# for real instead of silently no-op'ing.
copy_migrate_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-status-migrate.sh" \
    "$REPO/.gaia/scripts/ledger-status-migrate.sh"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/with-ledger-lock.sh" \
    "$REPO/.specify/extensions/gaia/lib/with-ledger-lock.sh"
}

@test "migration trigger: a specified/completed fixture row is ready/merged after a janitor run" {
  make_repo
  copy_migrate_deps
  mkdir -p "$REPO/.gaia/local/specs" "$REPO/.gaia/local/plans"
  cat > "$REPO/.gaia/local/specs/ledger.json" <<'EOF'
{"version": 1, "specs": [
  {"id":"SPEC-080","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","status":"specified"}
]}
EOF
  cat > "$REPO/.gaia/local/plans/ledger.json" <<'EOF'
{"version": 1, "plans": [
  {"id":"PLAN-080","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"completed","completed_at":"2026-01-02T00:00:00Z"}
]}
EOF
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.specs[] | select(.id=="SPEC-080") | .status' "$REPO/.gaia/local/specs/ledger.json")" = "ready" ]
  [ "$(jq -r '.plans[] | select(.id=="PLAN-080") | .status' "$REPO/.gaia/local/plans/ledger.json")" = "merged" ]
  [ "$(jq -r '.plans[] | select(.id=="PLAN-080") | .merged_at' "$REPO/.gaia/local/plans/ledger.json")" != "null" ]
}

# --- Sweep #3: completed-but-unswept plan dirs, terminal-ledger + identity gate ---
#
# The janitor delegates the actual delete to plan-archive.sh, so these tests
# copy the real script plus its transitive deps (cost-represented.sh,
# ledger-path-lib.sh, plan-ledger-update.sh, with-ledger-lock.sh) into the
# fixture repo at their real repo-relative paths, exactly as a real checkout
# would have them, rather than re-deriving delete behavior here.

# copy_plan_archive_deps: mirrors plan-archive.sh's own repo-relative call
# targets inside the fixture repo so the janitor's `bash "$root/.gaia/scripts/
# plan-archive.sh" ...` call resolves for real instead of silently failing.
copy_plan_archive_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.gaia/scripts/plan-archive.sh" "$REPO/.gaia/scripts/plan-archive.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/cost-represented.sh" "$REPO/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-path-lib.sh" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/main-root-lib.sh"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/plan-ledger-update.sh" \
    "$REPO/.specify/extensions/gaia/lib/plan-ledger-update.sh"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/with-ledger-lock.sh" \
    "$REPO/.specify/extensions/gaia/lib/with-ledger-lock.sh"
}

# write_cost_md <abs_dir> <heading> <fresh> <cwrite> <cread> <output>: writes a
# cost.md with one real, parseable phase section (the shape
# cost-represented.sh's parser expects).
write_cost_md() {
  local dir="$1" heading="$2" fresh="$3" cwrite="$4" cread="$5" output="$6"
  local total=$((fresh + cwrite + cread + output))
  mkdir -p "$dir"
  {
    printf '# Cost\n\n'
    printf '## %s\n\n' "$heading"
    printf '| Bucket | Tokens |\n| --- | --- |\n'
    printf '| Fresh input | %s |\n' "$fresh"
    printf '| Cache write | %s |\n' "$cwrite"
    printf '| Cache read | %s |\n' "$cread"
    printf '| Output | %s |\n' "$output"
    printf '| **Total** | %s |\n\n' "$total"
  } > "$dir/cost.md"
}

# write_cost_json <abs_dir> <fresh> <cwrite> <cread> <output>: writes a
# cost.json sidecar with one execute-phase record, the shape
# cost-represented.sh's sidecar parser expects. A reduced plan folder keeps
# only cost.json (not cost.md), so the terminal PLAN-NNN reduce test uses this.
write_cost_json() {
  local dir="$1" fresh="$2" cwrite="$3" cread="$4" output="$5"
  mkdir -p "$dir"
  jq -cn \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" '
    {execute: {
      kind: "execute",
      session_id: null,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output)
    }}
  ' > "$dir/cost.json"
}

# seed_cost_row <kind> <field> <val> <fresh> <cwrite> <cread> <output>: appends
# one row (token-tally/backfill schema, no session) to the fixture repo's real
# cost ledger, matching where plan-archive.sh's own gaia_resolve_ledger_path
# resolves inside this repo (no --ledger override).
seed_cost_row() {
  local kind="$1" field="$2" val="$3"
  local fresh="$4" cwrite="$5" cread="$6" output="$7"
  local ledger="$REPO/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$ledger")"
  jq -cn \
    --arg kind "$kind" --arg field "$field" --arg val "$val" \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" '
    {
      schema_version: 1, kind: $kind,
      spec_id: null, plan_id: null, plan_slug: null, session_id: null,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output),
      seq: 0, final: true, source: "test"
    } | .[$field] = $val
  ' >> "$ledger"
}

# seed_plans_ledger <plan-row-json>: writes a one-row plans ledger.
seed_plans_ledger() {
  mkdir -p "$REPO/.gaia/local/plans"
  cat > "$REPO/.gaia/local/plans/ledger.json" <<EOF
{"version": 1, "plans": [ $1 ]}
EOF
}

# seed_specs_ledger <spec-row-json>: writes a one-row specs ledger.
seed_specs_ledger() {
  mkdir -p "$REPO/.gaia/local/specs"
  cat > "$REPO/.gaia/local/specs/ledger.json" <<EOF
{"version": 1, "specs": [ $1 ]}
EOF
}

@test "sweep 3: terminal PLAN-NNN + branch-gone + represented -> reduced to SUMMARY.md + cost.json, RUNNING gone" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-050"
  echo "summary" > "$REPO/.gaia/local/plans/PLAN-050/SUMMARY.md"
  printf 'branch: gone-branch-plan-050\n' > "$REPO/.gaia/local/plans/PLAN-050/RUNNING"
  write_cost_json "$REPO/.gaia/local/plans/PLAN-050" 10 1 1 2
  seed_cost_row execute plan_id PLAN-050 10 1 1 2
  seed_plans_ledger '{"id":"PLAN-050","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"merged","merged_at":"2026-01-02T00:00:00Z"}'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-050" ]
  [ -f "$REPO/.gaia/local/plans/PLAN-050/SUMMARY.md" ]
  [ -f "$REPO/.gaia/local/plans/PLAN-050/cost.json" ]
  [ ! -e "$REPO/.gaia/local/plans/PLAN-050/RUNNING" ]
}

@test "sweep 3: non-terminal ledger status -> skipped (branch-gone alone is insufficient)" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-051"
  printf 'branch: gone-branch-plan-051\n' > "$REPO/.gaia/local/plans/PLAN-051/RUNNING"
  write_cost_md "$REPO/.gaia/local/plans/PLAN-051" Execution 5 0 0 1
  seed_cost_row execute plan_id PLAN-051 5 0 0 1
  seed_plans_ledger '{"id":"PLAN-051","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-051" ]
}

@test "sweep 3: ledger-less free-form slug -> skipped (FC-4, no durable identity)" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/plans/my-legacy-slug"
  printf 'branch: gone-branch-legacy\n' > "$REPO/.gaia/local/plans/my-legacy-slug/RUNNING"
  write_cost_md "$REPO/.gaia/local/plans/my-legacy-slug" Execution 3 0 0 0
  seed_cost_row execute plan_slug my-legacy-slug 3 0 0 0
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/my-legacy-slug" ]
}

@test "sweep 3: colocated terminal -> plan/ deleted, parent SPEC folder untouched" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/specs/SPEC-050/plan"
  echo "spec body" > "$REPO/.gaia/local/specs/SPEC-050/SPEC.md"
  echo "# SPEC-050" > "$REPO/.gaia/local/specs/SPEC-050/SUMMARY.md"
  printf 'branch: gone-branch-spec-050\n' > "$REPO/.gaia/local/specs/SPEC-050/plan/RUNNING"
  write_cost_md "$REPO/.gaia/local/specs/SPEC-050/plan" Execution 4 0 0 1
  seed_cost_row execute spec_id SPEC-050 4 0 0 1
  seed_specs_ledger '{"id":"SPEC-050","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"merged","merged_at":"2026-01-02T00:00:00Z"}'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-050/plan" ]
  [ -d "$REPO/.gaia/local/specs/SPEC-050" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-050/SPEC.md" ]
}

# --- Sweep #7: age-reap merged spec-less plan folders past the retention window ---
#
# Merged spec-less plan folders (already reduced to SUMMARY.md + cost.json by
# sweep #3's plan-archive.sh delegation) are reaped only once merged_at ages
# past the retention window (GAIA_SPEC_RETENTION_DAYS, default 30) AND cost is
# fully represented. The janitor delegates both gates to plan-archive-merged.sh,
# so these tests copy the real script plus its transitive deps, symmetric with
# sweep #6's spec-reap suite.

# copy_plan_archive_merged_deps: mirrors plan-archive-merged.sh's own
# repo-relative call targets inside the fixture repo so the janitor's
# `bash "$root/.specify/extensions/gaia/lib/plan-archive-merged.sh" ...` call
# resolves for real instead of silently failing.
copy_plan_archive_merged_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/plan-archive-merged.sh" \
    "$REPO/.specify/extensions/gaia/lib/plan-archive-merged.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/cost-represented.sh" "$REPO/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-path-lib.sh" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/main-root-lib.sh"
}

# copy_plan_archive_abandoned_deps: mirrors plan-archive-abandoned.sh's own
# repo-relative call target inside the fixture repo so the janitor's
# `bash "$root/.specify/extensions/gaia/lib/plan-archive-abandoned.sh" ...`
# call resolves for real instead of silently failing.
copy_plan_archive_abandoned_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/plan-archive-abandoned.sh" \
    "$REPO/.specify/extensions/gaia/lib/plan-archive-abandoned.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/cost-represented.sh" "$REPO/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-path-lib.sh" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/main-root-lib.sh"
}

# days_ago <n>: portable ISO8601 timestamp n days in the past, computed with
# jq (never `date -d`/`date -j`, matching the project's cross-platform epoch
# rule).
days_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

@test "sweep 7: merged spec-less plan folder past the retention window with represented cost is reaped" {
  make_repo
  copy_plan_archive_merged_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-070"
  echo "summary" > "$REPO/.gaia/local/plans/PLAN-070/SUMMARY.md"
  seed_plans_ledger "{\"id\":\"PLAN-070\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 45)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/plans/PLAN-070" ]
}

@test "sweep 7: merged spec-less plan folder within the retention window is kept" {
  make_repo
  copy_plan_archive_merged_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-071"
  echo "summary" > "$REPO/.gaia/local/plans/PLAN-071/SUMMARY.md"
  seed_plans_ledger "{\"id\":\"PLAN-071\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 2)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-071" ]
}

@test "sweep 7: abandoned spec-less plan folder past the retention window with represented cost is reaped" {
  make_repo
  copy_plan_archive_abandoned_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-072"
  echo "draft" > "$REPO/.gaia/local/plans/PLAN-072/PLAN.md"
  seed_plans_ledger "{\"id\":\"PLAN-072\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"abandoned\",\"abandoned_at\":\"$(days_ago 45)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/plans/PLAN-072" ]
}

@test "sweep 7: abandoned spec-less plan folder within the retention window is kept" {
  make_repo
  copy_plan_archive_abandoned_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-073"
  echo "draft" > "$REPO/.gaia/local/plans/PLAN-073/PLAN.md"
  seed_plans_ledger "{\"id\":\"PLAN-073\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"abandoned\",\"abandoned_at\":\"$(days_ago 2)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-073" ]
}

# --- Sweep #2: orphaned audit markers --------------------------------------
#
# A marker's filename key is a 64-hex CONTENT DIGEST over exactly the files
# the audited member owns plus the shared gate machinery, not a git tree or
# commit sha, so the key resolves to no git object and no reachability call
# can ever answer "live" for one. Liveness is read off each marker's own JSON
# body instead, through three key-shape-agnostic keep-arms:
#
#   Keep-arm A (live-tree)         the marker's body `.tree` (plain data) is
#     one of the once-computed live_trees (every local branch tip / linked
#     worktree HEAD).
#   Keep-arm B (retention window)  the marker is within
#     GAIA_AUDIT_MARKER_RETENTION_HOURS (default 72) of its own recorded
#     `audited_at`. Applies to both `.ok` and `.refused`.
#   Keep-arm C (open-receipt)      the frontend `<digest>.ok` marker's
#     co-keyed `<digest>.dispositions.json` sidecar still holds a still-open
#     entry (COV-002, its own section below).
#
# A marker is NEW-SCHEME iff its filename stem-before-first-dot is 64-hex AND
# its body's `.digest` equals that stem; only a new-scheme marker is
# keep-eligible at all. Everything else -- an old-scheme (pre-digest) marker,
# a body lacking `.digest`, the deleted `.carried` family, and the
# CI-observability `.progress.log` breadcrumb (never re-keyed as a clearance)
# -- is spent residue and is unconditionally reaped.

# seed_audit_file <name>: drops one raw file into the audit drop-zone.
seed_audit_file() {
  mkdir -p "$REPO/.gaia/local/audit"
  echo '{}' > "$REPO/.gaia/local/audit/$1"
}

# orphan_sha: a real commit whose branch is deleted, so its tree names no
# local branch tip or worktree HEAD -- exactly a squash-merged or abandoned
# branch tip, the NON-live-tree fixture every keep-arm-A-fails test needs.
orphan_sha() {
  git -C "$REPO" checkout -q -b throwaway
  echo orphan > "$REPO/orphan"
  git -C "$REPO" add orphan
  git -C "$REPO" commit -q -m orphan
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q -D throwaway
}

# head_tree: the tree the Code Audit Team's clearance bodies record.
head_tree() {
  git -C "$REPO" rev-parse "HEAD^{tree}"
}

# hours_ago <n>: portable ISO8601 timestamp n hours in the past, computed with
# jq (never `date -d`/`date -j`), matching days_ago's cross-platform epoch
# rule above.
hours_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 3600)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# gen_digest <seed>: a deterministic 64-hex sha256 of <seed>, the new-scheme
# filename-key shape. Distinct seeds across a test's fixtures never collide.
gen_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

# seed_marker <digest> <infix> <ext> <tree> <audited_at_iso>: writes a
# schema-3 clearance body at .gaia/local/audit/<digest>[.<infix>].<ext>.
# <infix> "" is the default member (code-audit-frontend, infix-free
# filename); a non-empty <infix> is a specialist member name. <ext> is
# ok (provenance earned) or refused.
seed_marker() {
  local digest="$1" infix="$2" ext="$3" tree="$4" audited_at="$5"
  local member prov name
  mkdir -p "$REPO/.gaia/local/audit"
  if [ -z "$infix" ]; then
    member="code-audit-frontend"
    name="${digest}.${ext}"
  else
    member="$infix"
    name="${digest}.${infix}.${ext}"
  fi
  case "$ext" in
    ok) prov=earned ;;
    refused) prov=refused ;;
  esac
  jq -cn --arg member "$member" --arg prov "$prov" --arg digest "$digest" \
    --arg tree "$tree" --arg audited_at "$audited_at" \
    --argjson sidecar "$([ "$member" = code-audit-frontend ] && echo true || echo false)" '
    {version: "1.6.1", schema: 3, member: $member, provenance: $prov,
     digest: $digest, tree: $tree, sha: "deadbeef", audited_at: $audited_at,
     sidecar: $sidecar}
  ' > "$REPO/.gaia/local/audit/$name"
}

# seed_sidecar <digest> <findings-json-array>: writes a dispositions sidecar
# at .gaia/local/audit/<digest>.dispositions.json.
seed_sidecar() {
  local digest="$1" findings="$2"
  mkdir -p "$REPO/.gaia/local/audit"
  jq -cn --argjson findings "$findings" '{backend: "github", findings: $findings}' \
    > "$REPO/.gaia/local/audit/${digest}.dispositions.json"
}

@test "sweep 2: UAT-007 an old-scheme <tree>.ok marker is reaped even for HEAD's own tree" {
  make_repo
  tree=$(head_tree)
  seed_audit_file "$tree.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.ok" ]
}

# The regression the digest key still must not reopen: code-audit-frontend
# stamps the GAIA-Audit trailer as an EMPTY commit, which advances HEAD while
# leaving the tree byte-identical. A new-scheme marker's body `.tree` is
# unaffected by that commit, so keep-arm A (live-tree) still finds it live.
@test "sweep 2: keep-arm A: a new-scheme marker survives the trailer stamp's empty commit" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-$tree")
  seed_marker "$digest" "" ok "$tree" "2020-01-01T00:00:00Z"
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  # The empty commit moved HEAD but not the tree.
  [ "$(head_tree)" = "$tree" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
}

@test "sweep 2: keep-arm A: LIVE per-member <digest>.<member>.ok markers are never deleted" {
  make_repo
  tree=$(head_tree)
  fdigest=$(gen_digest "frontend-$tree")
  sdigest=$(gen_digest "shell-$tree")
  ndigest=$(gen_digest "node-$tree")
  seed_marker "$fdigest" "" ok "$tree" "2020-01-01T00:00:00Z"
  seed_marker "$sdigest" "code-audit-maintainer-shell" ok "$tree" "2020-01-01T00:00:00Z"
  seed_marker "$ndigest" "code-audit-maintainer-node" ok "$tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$fdigest.ok" ]
  [ -f "$REPO/.gaia/local/audit/$sdigest.code-audit-maintainer-shell.ok" ]
  [ -f "$REPO/.gaia/local/audit/$ndigest.code-audit-maintainer-node.ok" ]
}

@test "sweep 2: a per-member marker for a non-live tree past the retention window is reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "shell-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "code-audit-maintainer-shell" ok "$dead_tree" "$(hours_ago 2)"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.code-audit-maintainer-shell.ok" ]
}

# The audit drop-zone is symlinked into every linked worktree, so one janitor
# run sweeps the markers of every checkout. A sibling branch's marker must
# outlive a sweep launched from another branch, or the janitor deletes a live
# marker out from under a parallel audit.
@test "sweep 2: UAT-010 keep-arm A: a marker for another local branch's tip is kept" {
  make_repo
  git -C "$REPO" checkout -q -b sibling
  echo sibling > "$REPO/sibling"
  git -C "$REPO" add sibling
  git -C "$REPO" commit -q -m sibling
  sibling_tree=$(head_tree)
  git -C "$REPO" checkout -q main
  digest=$(gen_digest "frontend-$sibling_tree")
  seed_marker "$digest" "" ok "$sibling_tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
}

# The other half of the live-tree set, and the one most likely to regress
# silently: a linked worktree's HEAD. A detached worktree HEAD is named by no
# branch, so the branch-tip scan alone cannot see its tree.
@test "sweep 2: UAT-010 keep-arm A: a marker for a linked worktree's detached HEAD is kept" {
  make_repo
  # A commit reachable from no branch, checked out detached in a linked worktree.
  git -C "$REPO" checkout -q -b throwaway
  echo detached > "$REPO/detached"
  git -C "$REPO" add detached
  git -C "$REPO" commit -q -m detached
  wt_sha=$(git -C "$REPO" rev-parse HEAD)
  wt_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  git -C "$REPO" checkout -q main
  # Inside $REPO so teardown reclaims it with the repo; a path in the shared tmp
  # parent would outlive the test and collide on the next run.
  git -C "$REPO" worktree add -q --detach "$REPO/.linked-wt" "$wt_sha"
  git -C "$REPO" branch -q -D throwaway

  # No branch names that tree now; only the linked worktree's HEAD does.
  run bash -c "git -C '$REPO' for-each-ref --format='%(objectname)' refs/heads/ | while read -r c; do git -C '$REPO' rev-parse \"\${c}^{tree}\"; done"
  grep -qxF "$wt_tree" <<< "$output" && return 1

  digest=$(gen_digest "frontend-$wt_tree")
  seed_marker "$digest" "" ok "$wt_tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
}

# Fail-safe invariant: keep-arm A only fires when the live-tree set was
# reliably enumerated. When BOTH `git for-each-ref` and `git worktree list`
# fail (a transient git error, lock contention, a broken checkout), the
# marker's tree cannot be proven dead OR alive, so the fail-safe must keep it
# regardless of retention age -- an unprovable tree is not the same as a dead
# one, and treating it as dead here would reap a clearance a parallel audit
# may still need.
@test "sweep 2: live-tree enumeration failure keeps a marker whose tree it could not prove live, even past the retention window (fail-safe, not fail-open)" {
  make_repo
  # A tree no branch tip and no worktree HEAD names, past the retention
  # window, so neither keep-arm A's live-tree match nor keep-arm B's window
  # can keep it and the fail-safe is the only thing left that can. HEAD's own
  # tree is the wrong fixture here: arm A keeps that marker whether the
  # enumeration ran or not, which is exactly the reading a shim that never
  # intercepted anything would also produce.
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 1000)"

  # A PATH-shimmed `git` that fails exactly the two live-tree enumeration
  # calls and passes everything else through to the real binary. Each
  # interception appends to a witness file, so the run proves the shim was
  # the git the janitor resolved rather than assuming PATH put it there.
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  witness="$SHIM_DIR/intercepted"
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
case "\$*" in
  *for-each-ref*refs/heads/*) echo "\$*" >> "$witness"; exit 128 ;;
  *"worktree list"*) echo "\$*" >> "$witness"; exit 128 ;;
esac
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"

  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -s "$witness" ] || return 1
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
}

@test "sweep 2: MIG-005 a sidecar co-keyed with a live marker is kept; an old sha-keyed sidecar is reaped" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-$tree")
  seed_marker "$digest" "" ok "$tree" "2020-01-01T00:00:00Z"
  seed_sidecar "$digest" '[]'
  old_sha=$(git -C "$REPO" rev-parse HEAD)
  seed_audit_file "$old_sha.dispositions.json"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
  [ ! -e "$REPO/.gaia/local/audit/$old_sha.dispositions.json" ]
}

@test "sweep 2: MIG-005 a sidecar is co-reaped with its marker when neither arm A nor B keeps it (no open receipt)" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"waived"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "sweep 2: a bogus-key marker is swept (a non-64-hex key is never new-scheme)" {
  make_repo
  seed_audit_file "notasha.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/notasha.ok" ]
}

# The progress log is never re-keyed to the digest scheme (SPEC `never`): it
# is a CI-observability breadcrumb, not a validity artifact, so nothing keeps
# it alive under the new janitor -- it is always spent residue.
@test "sweep 2: UAT-007 a progress log is always reaped, even for HEAD's own tree" {
  make_repo
  tree=$(head_tree)
  seed_audit_file "$tree.progress.log"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.progress.log" ]
}

@test "sweep 2: a progress log does not survive the trailer stamp's empty commit (never re-keyed as a clearance)" {
  make_repo
  tree=$(head_tree)
  seed_audit_file "$tree.progress.log"
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(head_tree)" = "$tree" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.progress.log" ]
}

@test "sweep 2: a .carried artifact (deleted carry-forward family) is always reaped, even for a live tree" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-$tree")
  seed_audit_file "${digest}.carried"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/${digest}.carried" ]
}

@test "sweep 2: keep-arm B applies to .refused too: a live-tree refusal is kept" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-refused-$tree")
  seed_marker "$digest" "" refused "$tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.refused" ]
}

@test "sweep 2: a refusal for a non-live tree past the retention window is reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-refused-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" refused "$dead_tree" "$(hours_ago 2)"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.refused" ]
}

@test "UAT-018: a window-kept marker (arm B) keeps its co-keyed sidecar; a live-tree marker (arm A) survives regardless of age" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  tree=$(head_tree)

  # A non-live-tree marker inside the 72h window: keep-arm B.
  digest1=$(gen_digest "frontend-$dead_tree")
  seed_marker "$digest1" "" ok "$dead_tree" "$(hours_ago 1)"
  seed_sidecar "$digest1" '[]'

  # A marker whose tree IS a live branch tip, well outside the window:
  # keep-arm A keeps it regardless of age.
  digest2=$(gen_digest "frontend-$tree")
  seed_marker "$digest2" "" ok "$tree" "$(hours_ago 1000)"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$REPO/.gaia/local/audit/$digest1.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest1.dispositions.json" ]
  [ -f "$REPO/.gaia/local/audit/$digest2.ok" ]
}

@test "UAT-019: an out-of-window marker on a non-live tree, with no sidecar, is reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
}

# --- COV-002: the open-receipt keep-arm (decision 2) ------------------------
#
# A still-open out-of-scope disposition receipt must survive a digest
# rotation even after its predecessor marker ages past the retention window,
# so seed-forward always finds a live predecessor sidecar to read. Both
# halves are pinned here: a still-open entry keeps the marker+sidecar pair
# alive past every other arm (arms A and B both deliberately fail in each
# fixture below: a non-live tree, and an out-of-window audited_at); a
# fully-resolved sidecar gets no such exemption and is reaped normally. The
# still-open predicate mirrors task-dispositions' disposition_seed_forward
# byte-for-byte: `.disposition == "filed"` OR (`.disposition == "pending"`
# AND `.pending_reason == "definitive"`).

@test "COV-002: a still-open (filed) receipt keeps its marker+sidecar alive past the window on a non-live tree" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"filed"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: a pending(definitive) receipt also keeps its marker+sidecar alive (same predicate as seed-forward)" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"pending","pending_reason":"definitive"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: a fully-resolved sidecar (waived/diverted/pending-transient) gets no window exemption; both are reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[
    {"key":"k1","disposition":"waived"},
    {"key":"k2","disposition":"diverted"},
    {"key":"k3","disposition":"pending","pending_reason":"transient"}
  ]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: an empty-findings sidecar gets no window exemption; both are reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: the marker exemption is frontend-only, but the sidecar exemption applies regardless of marker family" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "shell-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "code-audit-maintainer-shell" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"filed"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.code-audit-maintainer-shell.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

# --- TST-006: the janitor never recomputes a per-member digest -------------

@test "TST-006 tripwire: the janitor source never references audit_member_digest or the digest CLI" {
  run grep -En "audit_member_digest|audit-member-digest\.sh|audit_digests_all" "$HOOK_ABS"
  [ "$status" -ne 0 ]
}

# --- Sweep #2b: orphaned re-run carry-forward ledgers ----------------------
#
# A ledger is keyed on the incremental BASE sha (the fork point
# `git merge-base "$BASE_REF" HEAD`), NOT a branch tip. A fork point is an
# ancestor of the default branch by construction, so the reachability test the
# markers use always answers "live" for a ledger and can never reap one -- which
# is exactly why the sweep needs its own rule. The ledger dies with the branch it
# records: code-audit-frontend deletes it on a clean pass, so one that outlives
# its branch belongs to a line abandoned before it ever reached clean.

# seed_rerun_ledger <base-sha> <branch> [<body-branch>]: writes the ledger the
# way the audit really names and shapes it now (gaia_audit_key,
# .gaia/scripts/audit-key-lib.sh): the filename is base-sha + branch slug, not
# the bare base sha -- a bare base sha collides across two worktrees cut from
# the same main tip, which is the defect task 4.1 removes. The body's
# `.branch` defaults to the same value (the real writer derives both from one
# `git branch --show-current` call). Pass a third arg to give the body a
# DIFFERENT (or empty) branch than the filename carries, modeling a ledger
# whose body is missing `.branch` under an already validly-keyed filename.
seed_rerun_ledger() {
  mkdir -p "$REPO/.gaia/local/audit"
  local base="$1" filename_branch="$2" body_branch="${3-$2}"
  jq -cn --arg branch "$body_branch" --arg base "$base" '
    {schema: 1, round: 1, base_sha: $base, head_sha: $base,
     remaining: [], fixed_last_round: [], notes: null}
    | if $branch == "" then . else . + {branch: $branch} end
  ' > "$REPO/.gaia/local/audit/${base}.${filename_branch}.rerun.json"
}

@test "sweep 2b: a ledger whose audited branch is gone is swept, even though its base sha is on main" {
  make_repo
  # The real shape: the ledger is keyed on the fork point, which IS reachable
  # from main. Only the recorded branch being gone proves it dead.
  base=$(git -C "$REPO" rev-parse HEAD)
  seed_rerun_ledger "$base" "abandoned-feature"
  cd "$REPO"
  # Guard the premise: this base sha really is reachable from a local branch, so
  # a reachability-based rule would keep it forever.
  [ -n "$(git -C "$REPO" branch --contains "$base")" ]
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$base.abandoned-feature.rerun.json" ]
}

@test "sweep 2b: a ledger whose audited branch still exists is kept" {
  make_repo
  base=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" branch live-feature
  seed_rerun_ledger "$base" "live-feature"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$base.live-feature.rerun.json" ]
}

@test "sweep 2b: a ledger with no recorded branch is kept (fail-safe: death unprovable)" {
  make_repo
  base=$(git -C "$REPO" rev-parse HEAD)
  # A validly-keyed filename (gaia_audit_key never fails open on an
  # undeterminable branch here -- it just never writes at all in that case)
  # whose body nonetheless lacks `.branch`, e.g. a pre-4.1 body shape.
  seed_rerun_ledger "$base" "some-branch" ""
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$base.some-branch.rerun.json" ]
}

@test "sweep 2b: an unparseable ledger is kept (fail-safe: death unprovable)" {
  make_repo
  seed_audit_file "deadbeef.rerun.json"
  printf 'not json at all' > "$REPO/.gaia/local/audit/deadbeef.rerun.json"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/deadbeef.rerun.json" ]
}

# --- Cost budget: fork counts, never wall clock (CG-005, PERF-004) ---------
#
# No keep-arm makes a per-marker git call (the digest key resolves to no git
# object, so the old `cat-file -e` / `branch --contains` reachability calls
# are gone entirely); the per-marker cost is at most ONE jq fork, to read a
# new-scheme body once for arms A and B together. Each test measures a
# BASELINE run against an empty audit dir, then a second run with exactly one
# fixture added, and asserts the DELTA -- isolating that one fixture's own
# contribution from every other sweep's constant cost (the branch scan, the
# live-tree computation, ...), which runs unconditionally either way.

# shim_git_and_jq_counters: puts wrapper `git` and `jq` binaries at the front
# of PATH. Each wrapper appends one line to its own counter file, then execs
# the real binary (resolved via `command -v` BEFORE the shim dir is
# prepended, so the wrapper never calls itself).
shim_git_and_jq_counters() {
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  GIT_COUNTER="$SHIM_DIR/git.count"
  JQ_COUNTER="$SHIM_DIR/jq.count"
  : > "$GIT_COUNTER"
  : > "$JQ_COUNTER"
  local real_git real_jq
  real_git=$(command -v git)
  real_jq=$(command -v jq)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
echo x >> "$GIT_COUNTER"
exec "$real_git" "\$@"
SHIM
  cat > "$SHIM_DIR/jq" <<SHIM
#!/bin/bash
echo x >> "$JQ_COUNTER"
exec "$real_jq" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git" "$SHIM_DIR/jq"
}

git_fork_count() { wc -l < "$GIT_COUNTER" | tr -d ' '; }
jq_fork_count() { wc -l < "$JQ_COUNTER" | tr -d ' '; }

@test "budget: a live-tree-kept marker (keep-arm A) costs ZERO git forks and EXACTLY ONE jq fork" {
  make_repo
  shim_git_and_jq_counters
  tree=$(head_tree)
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_git=$(git_fork_count)
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$tree")
  seed_marker "$digest" "" ok "$tree" "2020-01-01T00:00:00Z"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]

  [ "$(git_fork_count)" -eq "$base_git" ]
  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

@test "budget: a window-kept marker (keep-arm B, non-live tree) costs ZERO git forks and EXACTLY ONE jq fork" {
  make_repo
  shim_git_and_jq_counters
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_git=$(git_fork_count)
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$dead_tree")
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 1)"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]

  [ "$(git_fork_count)" -eq "$base_git" ]
  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

@test "budget: a reaped new-scheme marker (neither arm keeps it) costs ZERO git forks and EXACTLY ONE jq fork" {
  make_repo
  shim_git_and_jq_counters
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_git=$(git_fork_count)
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$dead_tree")
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]

  # No reachability git call exists any more: the digest key resolves to no
  # object, so the old cat-file/branch-contains pair is gone entirely.
  [ "$(git_fork_count)" -eq "$base_git" ]
  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

@test "budget: an old-scheme (non-64-hex) marker triggers ZERO jq forks; the key-shape check fires before the fork" {
  make_repo
  shim_git_and_jq_counters
  tree=$(head_tree)
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_jq=$(jq_fork_count)

  seed_audit_file "$tree.ok"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.ok" ]

  [ "$(jq_fork_count)" -eq "$base_jq" ]
}

@test "budget: a .carried or .progress.log artifact triggers ZERO jq forks; unconditional reap, no read" {
  make_repo
  shim_git_and_jq_counters
  tree=$(head_tree)
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$tree")
  seed_audit_file "${digest}.carried"
  seed_audit_file "${tree}.progress.log"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/${digest}.carried" ]
  [ ! -e "$REPO/.gaia/local/audit/${tree}.progress.log" ]

  [ "$(jq_fork_count)" -eq "$base_jq" ]
}

@test "budget: PERF-004 keep-arm C's open-receipt precompute costs exactly ONE jq fork per sidecar" {
  make_repo
  shim_git_and_jq_counters
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$dead_tree")
  seed_sidecar "$digest" '[{"key":"k1","disposition":"filed"}]'
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]

  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

# --- Sweep #4: the telemetry drop-zone split --------------------------------
#
# The highest-consequence entry in the state registry's drop_zones list.
# `telemetry` is a drop-zone and `telemetry/cloud` is not, and the two halves
# pull in opposite directions:
#
#   telemetry/       holds the token/cost ledger (cost.jsonl). Sweep #4 rmdirs
#                    any empty dir under .gaia/local that is not a drop-zone, so
#                    dropping `telemetry` from the registry would delete the
#                    directory that ledger lives in the moment it is
#                    momentarily empty.
#   telemetry/cloud  is dead. Nothing writes it and nothing reads it, so an empty
#                    one left on disk is exactly what sweep #4 exists to prune.
#
# Two janitor passes, because the guard only bites on the second: the first pass
# sees `telemetry` as non-empty (it still contains `cloud`) and would keep it for
# that reason alone, which proves nothing. Only once `cloud` is gone is
# `telemetry` empty at find time, and the registry's drop_zones list is then the
# sole thing standing between the ledgers' directory and `rmdir`.

# write_registry <gaia_dir>: writes a minimal, schema-shaped
# .gaia/state-registry.json fixture into <gaia_dir> (e.g. "$REPO/.gaia"), with
# empty entries/residue and a drop_zones array covering exactly the
# `telemetry` drop-zone this section's fixtures need, plus `red-ledger` and
# its keyed-child glob row for the keyed-per-tree-dir case below. Not the
# real registry -- a fixture-local stand-in so gaia_registry_path (which
# resolves through the fixture repo's own git root) has a real file to read.
write_registry() {
  mkdir -p "$1"
  cat > "$1/state-registry.json" <<'JSON'
{
  "$schema": "./state-registry.schema.json",
  "version": 1,
  "description": "fixture registry for the sweep-4 empty-dir suite",
  "entries": [],
  "residue": [],
  "drop_zones": [
    { "path": "telemetry", "match": "exact", "why": "fixture" },
    { "path": "red-ledger", "match": "exact", "why": "fixture" },
    { "path": "red-ledger/.tmp", "match": "exact", "why": "fixture" },
    { "path": "red-ledger/*", "match": "glob", "why": "fixture: keyed per-tree child (red-ledger/<tree_key>/) and its own .tmp scratch subdir" }
  ]
}
JSON
}

@test "sweep 4: with a registry present, the telemetry drop-zone survives empty while a non-drop-zone empty dir is rmdir'd" {
  make_repo
  write_registry "$REPO/.gaia"
  mkdir -p "$REPO/.gaia/local/telemetry/cloud"
  cd "$REPO"

  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$REPO/.gaia/local/telemetry/cloud" ] && return 1
  [ -d "$REPO/.gaia/local/telemetry" ]

  # Second pass: telemetry is now empty at find time, so the registry's
  # drop_zones list is the only thing keeping the ledgers' directory alive. A
  # sibling non-drop-zone empty dir, added in the same pass, proves the sweep
  # actually consulted the registry and ran -- not skipped, which would have
  # kept every empty dir, drop-zone or not.
  mkdir -p "$REPO/.gaia/local/stray-empty"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/telemetry" ]
  [ ! -e "$REPO/.gaia/local/stray-empty" ]
}

# Fail-safe invariant: sweep #4 only rmdirs an empty dir when it can read the
# registry's drop_zones list. No registry -> gaia_registry_drop_zones fails ->
# the sweep skips entirely, so a non-drop-zone empty dir survives right
# alongside where a real drop-zone would -- an unreadable registry can never
# classify anything, so nothing gets reaped on its say-so.
@test "sweep 4: an unreadable registry is a fail-safe skip, not a bare rmdir: a non-drop-zone empty dir is kept" {
  make_repo
  mkdir -p "$REPO/.gaia/local/stray-empty"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/stray-empty" ]
}

# Regression rail: `.gaia/local` entries re-keyed under a per-tree subpath
# (red-ledger/<tree_key>/, .gaia/state-registry.json's `keyed_by` for the
# per-tree entries) address themselves one path segment deeper than the bare
# container. Before the drop-zones matcher understood glob rows, only the
# bare `red-ledger` and `red-ledger/.tmp` literals survived; a keyed child
# never exact-matched either and was one empty-dir sweep away from `rmdir`.
# Two independent dirs, two different tree-key-shaped names, prove both
# shapes named in the state registry's red-ledger/* row: the keyed container
# itself, and that container's own atomic-write .tmp scratch subdir.
@test "sweep 4: a keyed per-tree red-ledger dir, and a keyed dir's own .tmp scratch subdir, both survive empty" {
  make_repo
  write_registry "$REPO/.gaia"
  mkdir -p "$REPO/.gaia/local/red-ledger/3f9c2b1a4e5d6f78"
  mkdir -p "$REPO/.gaia/local/red-ledger/71a8c4d92e6b0f35/.tmp"
  cd "$REPO"

  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/red-ledger/3f9c2b1a4e5d6f78" ]
  [ -d "$REPO/.gaia/local/red-ledger/71a8c4d92e6b0f35/.tmp" ]
}

# The janitor's delegation to the one-time cleanup sweep is covered in that
# sweep's own suite (.gaia/scripts/tests/), which drives the real janitor against
# a fixture repo. It lives there rather than here because this file is inside the
# repo-wide term grep for the retired subsystem's vocabulary, and a delegation
# test cannot assert on what it is forbidden to name.
