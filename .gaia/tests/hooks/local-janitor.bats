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

# plant_shadowing_tag: a tag literally named `origin/<base>`, pointed at the
# CURRENT local base tip. git resolves a short `origin/<base>` revspec through
# refs/tags/ before refs/remotes/, so every short spelling in the hook reads
# this tag instead of the remote-tracking ref. Pointing it at the un-advanced
# tip is what makes the difference observable: a fast-forward that reads the
# tag is already there and moves nothing, while one that reads
# refs/remotes/origin/<base> advances. `--verify --quiet` suppresses git's own
# "refname is ambiguous" warning, so nothing diagnoses this anywhere.
plant_shadowing_tag() {
  local base="${1:-main}"
  git -C "$REPO" tag "origin/$base" "refs/heads/$base"
}

@test "sweep 1: a tag named origin/<base> never decides the fast-forward target" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-11-4444442"
  advance_origin_main main
  plant_shadowing_tag main
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  # The remote-tracking ref decides, not the tag. Spelled fully qualified on
  # both sides here so the assertion itself cannot be shadowed by the fixture.
  [ "$(git -C "$REPO" rev-parse refs/heads/main)" \
    = "$(git -C "$REPO" rev-parse refs/remotes/origin/main)" ] || return 1
  # And the tag is still where the fixture put it, so a green above means the
  # hook read past it rather than the fixture having failed to plant it.
  [ "$(git -C "$REPO" rev-parse refs/tags/origin/main)" \
    != "$(git -C "$REPO" rev-parse refs/remotes/origin/main)" ] || return 1
  return 0
}

@test "sweep 1: a tag named origin/<base> never decides base resolution" {
  make_repo
  # A merged-and-gone branch the reap SHOULD delete, so the assertion reds on
  # a base that failed to resolve rather than on one that happened to be safe.
  # The tag makes the short name `origin/main` ambiguous, which is what
  # `symbolic-ref --short` resolves origin/HEAD against: it answers with the
  # longer `remotes/origin/main`, the `origin/` strip below it no longer
  # matches, and every consumer is handed a base that names nothing. The reap
  # then fails closed and keeps a branch it should have taken.
  make_gone_branch "wiki-sync/2026-08-13-6666666"
  plant_shadowing_tag main
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "wiki-sync/2026-08-13-6666666" && return 1
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
  # (.claude/hooks/local-janitor.sh) then never treats it as a reap
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
