#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/mentorship-cleanup-sweep.sh (the one-time,
# sentinel-guarded, best-effort destruction of a checkout's mentorship residue).
#
# The sweep deletes real files under $HOME and under a main checkout, so every
# test fixtures BOTH: an isolated sandbox repo root AND an isolated $HOME. The
# script reads $HOME from the environment for exactly this reason. Nothing here
# ever resolves to the machine's real Claude projects directory or the real
# .gaia/local.
#
# The Claude project slug is derived from the MAIN checkout's absolute path, so
# the fixture $HOME's projects directory is named after the sandbox, and the
# sandbox is resolved with `pwd -P`: on macOS `mktemp -d` hands back a path under
# the /var -> /private/var symlink, and git reports the resolved one, so an
# unresolved fixture path would derive a slug the sweep never looks for.
#
# Assertion style note: per .claude/rules/bats-assertions.md, a non-final absence
# assertion is written as a positive match for the BAD case followed by an
# explicit `return 1`, never as a `!`-negation (POSIX `set -e` exempts an
# inverted status, so a `!`-negated non-final line can never fail a test).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../mentorship-cleanup-sweep.sh"
  [ -x "$SCRIPT" ] || skip "mentorship-cleanup-sweep.sh not executable"
  REPO_ROOT_REAL="$( cd "$THIS_DIR/../../.." && pwd )"
  JANITOR="$REPO_ROOT_REAL/.claude/hooks/local-janitor.sh"

  SANDBOX="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")" && pwd -P)"
  MAIN="$SANDBOX/main"
  WT="$SANDBOX/wt"
  FAKE_HOME="$SANDBOX/home"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# make_main: a real git repo (the sweep resolves the main checkout through
# `git rev-parse --git-common-dir`) with an empty .gaia/local, plus the fixture
# $HOME and the Claude project directory the slug names.
make_main() {
  mkdir -p "$MAIN/.gaia/local"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config commit.gpgsign false
  echo init > "$MAIN/f"
  git -C "$MAIN" add f
  git -C "$MAIN" commit -q -m init

  # The CLI's deriveClaudeSlug: every `/` in the main-checkout path becomes `-`.
  SLUG="${MAIN//\//-}"
  PROJECT_DIR="$FAKE_HOME/.claude/projects/$SLUG"
  MEMORY_DIR="$PROJECT_DIR/memory"
  MEMORY_INDEX="$MEMORY_DIR/MEMORY.md"
  SENTINEL="$MAIN/.gaia/local/.mentorship-swept"
  mkdir -p "$PROJECT_DIR"
}

POINTER_LINE='- [Mentorship raw events are off-limits](feedback_mentorship_display.md): never display, summarize, or tail mentorship event files'
SIBLING_LINE='- [Coaching style: recommend-first](coaching-style.md) — lead with a recommendation'

# seed_offrepo_residue: the whole off-repo tree, exactly as an enabled checkout
# leaves it, plus a MEMORY.md carrying the pointer line AND a sibling line.
seed_offrepo_residue() {
  mkdir -p "$PROJECT_DIR/gaia/telemetry/mentorship" "$MEMORY_DIR"
  echo '{"event":"x"}' > "$PROJECT_DIR/gaia/telemetry/mentorship/events-2026-01-01.jsonl"
  echo '# Profile' > "$PROJECT_DIR/gaia/profile.md"
  echo '01JXXXXXXXXXXXXXXXXXXXXXXX' > "$PROJECT_DIR/gaia/install-id.txt"
  echo 'rule body' > "$MEMORY_DIR/feedback_mentorship_display.md"
  printf '%s\n%s\n' "$POINTER_LINE" "$SIBLING_LINE" > "$MEMORY_INDEX"
}

# seed_inrepo_residue: the in-repo opt-in config, the cloud projection stream,
# and the analytics reports, in the MAIN checkout.
seed_inrepo_residue() {
  mkdir -p "$MAIN/.gaia/local/telemetry/cloud" "$MAIN/.gaia/local/telemetry/analytics"
  echo '{"enabled":true}' > "$MAIN/.gaia/local/mentorship.json"
  echo '{"event":"cloud"}' > "$MAIN/.gaia/local/telemetry/cloud/events-2026-01-01.jsonl"
  echo '{"report":1}' > "$MAIN/.gaia/local/telemetry/analytics/report.json"
}

# seed_survivors: the load-bearing state that shares telemetry/ with the
# streams above and must outlive the sweep byte-for-byte, plus the orphaned
# coaching marker in the symlinked shared cache, which the sweep now reaps.
seed_survivors() {
  mkdir -p "$MAIN/.gaia/local/telemetry" "$MAIN/.gaia/local/cache/shared"
  echo '{"kind":"execute","total":11110}' > "$MAIN/.gaia/local/telemetry/cost.jsonl"
  echo '{"event":"spec_closed"}' > "$MAIN/.gaia/local/telemetry/spec-pacing.jsonl"
  echo 'active' > "$MAIN/.gaia/local/cache/shared/coaching-active.txt"
}

run_sweep() {
  env HOME="$FAKE_HOME" bash "$SCRIPT" "${1:-$MAIN}"
}

# file_list: every path under both fixture roots, minus git's own internals.
file_list() {
  find "$MAIN" "$FAKE_HOME" -name '.git' -prune -o -print | sort
}

# tree_digest: file_list plus a content checksum of every file, so a snapshot
# comparison catches a rewrite as well as an add or a delete.
tree_digest() {
  {
    file_list
    find "$MAIN" "$FAKE_HOME" -name '.git' -prune -o -type f -exec cksum {} +
  } | sort
}

# --- 1. The full residue is destroyed ---------------------------------------

@test "every enumerated residue is destroyed; the sibling MEMORY.md line survives" {
  make_main
  seed_offrepo_residue
  seed_inrepo_residue

  run run_sweep
  [ "$status" -eq 0 ]

  # Off-repo: the whole gaia/ subtree (event store, profile, install id).
  [ -e "$PROJECT_DIR/gaia" ] && return 1
  # Off-repo: the auto-loaded display-rule memory file.
  [ -e "$MEMORY_DIR/feedback_mentorship_display.md" ] && return 1
  # In-repo: the opt-in config, the cloud stream, the analytics reports.
  [ -e "$MAIN/.gaia/local/mentorship.json" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/cloud" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/analytics" ] && return 1

  # MEMORY.md keeps its sibling line and loses only the pointer.
  [ -f "$MEMORY_INDEX" ]
  grep -qxF -- "$POINTER_LINE" "$MEMORY_INDEX" && return 1
  grep -qxF -- "$SIBLING_LINE" "$MEMORY_INDEX"
}

# --- 2. The survivors sharing telemetry/ are untouched -----------------------

@test "cost.jsonl, spec-pacing.jsonl and telemetry/ survive intact; coaching-active.txt is reaped" {
  make_main
  seed_offrepo_residue
  seed_inrepo_residue
  seed_survivors

  local cost pacing
  cost="$(cksum < "$MAIN/.gaia/local/telemetry/cost.jsonl")"
  pacing="$(cksum < "$MAIN/.gaia/local/telemetry/spec-pacing.jsonl")"

  run run_sweep
  [ "$status" -eq 0 ]

  # The directory whose two children just died is itself load-bearing.
  [ -d "$MAIN/.gaia/local/telemetry" ]
  [ -e "$MAIN/.gaia/local/telemetry/cloud" ] && return 1

  [ "$(cksum < "$MAIN/.gaia/local/telemetry/cost.jsonl")" = "$cost" ]
  [ "$(cksum < "$MAIN/.gaia/local/telemetry/spec-pacing.jsonl")" = "$pacing" ]
  # Orphaned residue: reaped now, unlike the load-bearing streams above. Final
  # line of the test, so its own exit status is the test result; the `[ ! -e ]`
  # form (not the earlier `&& return 1` pattern) is what actually fails here.
  [ ! -e "$MAIN/.gaia/local/cache/shared/coaching-active.txt" ]
}

# --- 3. MEMORY.md is unlinked when the pointer was its only line -------------

@test "MEMORY.md holding only the pointer line is unlinked, not left empty" {
  make_main
  mkdir -p "$MEMORY_DIR"
  printf '%s\n' "$POINTER_LINE" > "$MEMORY_INDEX"

  run run_sweep
  [ "$status" -eq 0 ]

  [ -e "$MEMORY_INDEX" ] && return 1
  # And no rewrite temp file is left behind in the memory directory.
  [ "$(find "$MEMORY_DIR" -type f | wc -l | tr -d ' ')" = "0" ]
}

# --- 4. The second run is a byte-identical no-op -----------------------------

@test "idempotent: a second run leaves the tree byte-identical and exits 0" {
  make_main
  seed_offrepo_residue
  seed_inrepo_residue
  seed_survivors

  run run_sweep
  [ "$status" -eq 0 ]
  [ -f "$SENTINEL" ]

  local snapshot
  snapshot="$(mktemp "${BATS_TEST_TMPDIR}/snap.XXXXXX")"
  tree_digest > "$snapshot"

  run run_sweep
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  tree_digest | diff "$snapshot" -
}

# --- 5. A never-enabled checkout's run adds only the sentinel; the orphaned --
#        coaching marker is reaped regardless, since it is unconditional like
#        every other entry in the closed deletion set.

@test "no residue at all: only the sentinel is added and the coaching marker is reaped, exit 0, silent" {
  make_main
  seed_survivors

  local before expected
  before="$(mktemp "${BATS_TEST_TMPDIR}/before.XXXXXX")"
  expected="$(mktemp "${BATS_TEST_TMPDIR}/expected.XXXXXX")"
  file_list > "$before"

  run run_sweep
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$SENTINEL" ]
  [ ! -e "$MAIN/.gaia/local/cache/shared/coaching-active.txt" ]

  # The sentinel is the only path the sweep added; the orphaned coaching
  # marker is the only one it removed, unconditionally like every other entry
  # in the closed deletion set.
  grep -vxF -- "$MAIN/.gaia/local/cache/shared/coaching-active.txt" "$before" \
    | cat - <(printf '%s\n' "$SENTINEL") | sort > "$expected"
  file_list | diff "$expected" -
}

# --- 6. A run from inside a linked worktree ---------------------------------
#
# The one case the whole main-checkout derivation exists for. A linked worktree
# symlinks .gaia/local/mentorship.json and .gaia/local/telemetry into the main
# checkout. The sweep must unlink its OWN mentorship.json symlink (never
# following it), reap the main checkout's real files DIRECTLY, and never reach
# the cost ledger through the telemetry symlink.

@test "worktree run: drops its own symlink, reaps the main checkout, never follows telemetry" {
  make_main
  seed_offrepo_residue
  seed_inrepo_residue
  seed_survivors

  git -C "$MAIN" worktree add -q "$WT" -b feature/sweep
  mkdir -p "$WT/.gaia/local"
  ln -s "$MAIN/.gaia/local/mentorship.json" "$WT/.gaia/local/mentorship.json"
  ln -s "$MAIN/.gaia/local/telemetry" "$WT/.gaia/local/telemetry"

  local cost
  cost="$(cksum < "$MAIN/.gaia/local/telemetry/cost.jsonl")"

  # Guard the premise: the links really do resolve into the main checkout.
  [ -L "$WT/.gaia/local/mentorship.json" ]
  [ -f "$WT/.gaia/local/telemetry/cost.jsonl" ]

  run run_sweep "$WT"
  [ "$status" -eq 0 ]

  # The worktree's symlink is unlinked, link and all.
  [ -L "$WT/.gaia/local/mentorship.json" ] && return 1
  [ -e "$WT/.gaia/local/mentorship.json" ] && return 1
  # The main checkout's real file is reaped directly, not through a link.
  [ -e "$MAIN/.gaia/local/mentorship.json" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/cloud" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/analytics" ] && return 1

  # The telemetry symlink is NOT in the deletion set, and the sweep never
  # followed it: the main checkout's cost ledger is byte-identical, and the
  # worktree still resolves through the link to read it.
  [ "$(cksum < "$MAIN/.gaia/local/telemetry/cost.jsonl")" = "$cost" ]
  [ -L "$WT/.gaia/local/telemetry" ]
  [ "$(cksum < "$WT/.gaia/local/telemetry/cost.jsonl")" = "$cost" ]

  # The sentinel is per checkout, so the worktree got its own.
  [ -f "$WT/.gaia/local/.mentorship-swept" ]
}

# --- 6b. The worktree case that PROVES the main-checkout derivation ----------
#
# The test above cannot tell a $main_root-targeted delete from a $repo_root-
# targeted one: the worktree's telemetry symlink resolves into the main checkout,
# so `rm -rf <worktree>/.gaia/local/telemetry/cloud` follows the link and reaps
# the same directory, and both spellings look identical from outside.
#
# A worktree with NO telemetry symlink separates them. A $repo_root-targeted
# delete silently finds nothing and leaves the main checkout's streams alive; only
# a delete resolved through --git-common-dir reaps them. This is the assertion
# that keeps the derivation honest.

@test "worktree without a telemetry symlink still reaps the main checkout's streams" {
  make_main
  seed_inrepo_residue
  seed_survivors

  git -C "$MAIN" worktree add -q "$WT" -b feature/no-link
  mkdir -p "$WT/.gaia/local"
  # Deliberately no symlinks: nothing under the worktree names the streams.
  [ -e "$WT/.gaia/local/telemetry" ] && return 1

  run run_sweep "$WT"
  [ "$status" -eq 0 ]

  [ -e "$MAIN/.gaia/local/mentorship.json" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/cloud" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/analytics" ] && return 1
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
}

# --- 7. An unresolvable $HOME is a safe no-op --------------------------------

@test "empty \$HOME with no Claude projects directory: exit 0, no output, in-repo residue still reaped" {
  make_main
  seed_inrepo_residue
  seed_survivors
  # A $HOME with no .claude/projects/<slug> at all: the off-repo tree cannot be
  # named, so it is skipped. The in-repo deletions stand on their own.
  FAKE_HOME="$SANDBOX/empty-home"
  mkdir -p "$FAKE_HOME"

  run run_sweep
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ -e "$MAIN/.gaia/local/mentorship.json" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/cloud" ] && return 1
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
}

# --- 9. The janitor's delegation --------------------------------------------
#
# The sweep only ever runs because .claude/hooks/local-janitor.sh calls it on
# SessionStart. That delegation is a bare `[ -f "$sweep" ] && bash "$sweep"`, so a
# typo in the path degrades to a silent no-op no adopter would ever notice, and
# the whole cleanup would simply never happen. The wiring gets its own guard.
#
# This test lives here rather than in the janitor's own suite because it has to
# name the artifacts it asserts on, and this file is the one excluded wholesale
# from the repo-wide term grep for the retired subsystem's vocabulary.

@test "the janitor invokes the sweep, and the cost ledger survives the janitor run" {
  make_main
  seed_offrepo_residue
  seed_inrepo_residue
  seed_survivors
  [ -f "$JANITOR" ] || skip "local-janitor.sh not found"

  # The janitor resolves the sweep at its real repo-relative path under the root
  # it derives from git, so the fixture repo needs its own copy there.
  mkdir -p "$MAIN/.gaia/scripts"
  cp "$SCRIPT" "$MAIN/.gaia/scripts/mentorship-cleanup-sweep.sh"
  chmod +x "$MAIN/.gaia/scripts/mentorship-cleanup-sweep.sh"

  cd "$MAIN"
  run env HOME="$FAKE_HOME" bash "$JANITOR"
  [ "$status" -eq 0 ]

  [ -e "$PROJECT_DIR/gaia" ] && return 1
  [ -e "$MAIN/.gaia/local/mentorship.json" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/cloud" ] && return 1
  [ -e "$MAIN/.gaia/local/telemetry/analytics" ] && return 1
  [ -f "$SENTINEL" ]
  # Neither the sweep nor the janitor's empty-dir prune reaches the ledgers.
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
  [ -f "$MAIN/.gaia/local/telemetry/spec-pacing.jsonl" ]
}
