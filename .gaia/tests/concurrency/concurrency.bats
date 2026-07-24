#!/usr/bin/env bats
#
# The INV-7 concurrency meter suite (see README.md, frozen). One @test per
# scenario id; each drives the real GAIA code for its named defect and
# asserts the TARGET (post-fix) isolation property, so it fails today because
# the fix is absent -- not because it is stubbed. `skip` is banned in this
# suite (it reports green, the opposite of red-by-design).
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/concurrency/
#
# Assertion style note: per .claude/rules/bats-assertions.md, a non-final
# absence check uses a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; POSIX `[ ]` throughout.

setup() {
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/lib/concurrency-harness.sh"
}

teardown() {
  gaia_teardown
}

# count_autocommits <dir>: how many consecutive `wiki: auto-commit *` commits
# sit at <dir>'s current HEAD. Used by C5-02's squash-hook check.
count_autocommits() {
  local dir="$1" n=0
  while git -C "$dir" log "HEAD~$n" -1 --format=%s 2>/dev/null | grep -q '^wiki: auto-commit '; do
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Tranche 3 -- CONVERT
# ---------------------------------------------------------------------------

@test "C3-01: janitor spares a live peer tree" {
  MAIN="$(gaia_new_main gaia-c301-main)"
  gaia_copy_real "$MAIN" \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh \
    .gaia/scripts/remove-worktree.sh \
    .gaia/scripts/link-worktree.sh \
    .claude/hooks/local-janitor.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add janitor deps"

  ORIGIN="$(gaia_mk_tmp gaia-c301-origin)"
  git init -q --bare "$ORIGIN"
  git -C "$MAIN" remote add origin "$ORIGIN"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # treeB's branch upstream is pushed then deleted remotely: the same
  # provable-death signal the reaper uses for wiki-sync/* branches. treeB is
  # otherwise LIVE: it carries an active plan RUNNING sentinel, GAIA's own
  # in-progress marker, in its own (gitignored, per-tree) .gaia/local.
  git -C "$B" push -q -u origin treeB
  git -C "$B" push -q origin --delete treeB
  git -C "$B" fetch -q --prune

  mkdir -p "$B/.gaia/local/plans/PLAN-999"
  {
    printf 'branch: treeB\n'
    printf 'status: RUNNING\n'
  } > "$B/.gaia/local/plans/PLAN-999/RUNNING"

  # treeA needs its own .gaia/local present (a real worktree gets one from
  # link-worktree.sh at creation), or the janitor's own local_dir guard exits
  # before ever reaching the worktree-reap sweep.
  gaia_link_worktree "$A"

  run run_in "$A" -- bash "$MAIN/.claude/hooks/local-janitor.sh"
  [ "$status" -eq 0 ]

  # Target: treeB, a live peer (a RUNNING plan in flight), survives a
  # session-start janitor run fired from treeA -- the live_trees set the
  # reaper's own liveness test relies on covers every live worktree, and no
  # live tree's state is swept. Today the reaper's only liveness test is
  # git-level ([gone] upstream + a clean working tree; a RUNNING sentinel is
  # gitignored and invisible to `git status`), so it deletes treeB's whole
  # worktree -- including the RUNNING plan -- out from under the live session.
  [ -d "$B" ] || return 1
  [ -f "$B/.gaia/local/plans/PLAN-999/RUNNING" ]
}

@test "C3-02: write-guard attributes by payload cwd" {
  MAIN="$(gaia_new_main gaia-c302-main)"
  gaia_copy_real "$MAIN" \
    .claude/hooks/block-worktree-path-mismatch.sh \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add write-guard"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # A subagent in worktree B, delivered with B's own payload cwd, edits a file
  # that physically resolves inside worktree A -- a DIFFERENT linked worktree,
  # not main. The payload cwd correctly names B (the true acting tree); the
  # guard's job is to attribute the write by that payload cwd and deny a
  # target naming a different tree.
  json="$(jq -n --arg c "$B" --arg p "$A/README.md" \
    '{tool_name: "Edit", cwd: $c, tool_input: {file_path: $p}}')"
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$MAIN/.claude/hooks/block-worktree-path-mismatch.sh"
  [ "$status" -eq 0 ]

  # Target: denied (payload cwd names B, target resolves to a different real
  # tree, A). Today this hook only ever checks the target against MAIN's root
  # ("Scope, and why it stops there" in its own header) -- a write from one
  # linked worktree into another sibling worktree is explicitly left
  # unguarded, so this is allowed.
  grep -qF -- '"permissionDecision": "deny"' <<< "$output"
}

@test "C3-03: a wrong tree identity is refused, not trusted" {
  MAIN="$(gaia_new_main gaia-c303-main)"
  gaia_copy_real "$MAIN" \
    .claude/hooks/block-worktree-path-mismatch.sh \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add write-guard"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # The REAL acting process sits in treeB (run_in below); the hook payload
  # instead names treeA -- a well-shaped, absolute cwd that resolves to a
  # DIFFERENT real checkout of the same repo, not a garbage/unresolvable
  # value. The write targets treeA's own file (the tree the payload claims).
  json="$(jq -n --arg c "$A" --arg p "$A/README.md" \
    '{tool_name: "Edit", cwd: $c, tool_input: {file_path: $p}}')"
  run run_in "$B" -- bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$MAIN/.claude/hooks/block-worktree-path-mismatch.sh"
  [ "$status" -eq 0 ]

  # Target: a plausible-but-wrong identity claim is refused, or corroborated
  # against where the call really came from -- never silently trusted at face
  # value. Today the guard's only cross-check is "does the payload cwd's own
  # main root match the process cwd's main root", and every worktree of one
  # repo shares the same main root, so a payload naming ANY sibling worktree
  # always passes that check and is trusted outright, with no signal that the
  # real acting process (treeB) differs from the claim (treeA).
  grep -qF -- '"permissionDecision": "deny"' <<< "$output"
}

@test "C3-04: main-anchored ledgers resolve to main from a worktree" {
  MAIN="$(gaia_new_main gaia-c304-main)"
  gaia_copy_real "$MAIN" \
    .specify/extensions/gaia/lib/plan-allocator.sh \
    .specify/extensions/gaia/lib/with-ledger-lock.sh \
    .specify/extensions/gaia/lib/title-normalize.sh \
    .gaia/scripts/ledger-path-lib.sh \
    .gaia/scripts/main-root-lib.sh
  gaia_commit_all "$MAIN" "add plan allocator"

  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # Mirrors the real invocation in .claude/skills/gaia/references/plan.md:
  # ROOT="$(git rev-parse --show-toplevel)"; plan-allocator.sh next "$ROOT".
  root_b="$(run_in "$B" -- git rev-parse --show-toplevel)"
  run bash "$MAIN/.specify/extensions/gaia/lib/plan-allocator.sh" next "$root_b" "feature from B"
  [ "$status" -eq 0 ]

  # Target: the write lands in the main checkout's one ledger, because the
  # resolver -- not $PWD/$ROOT -- supplies the path. Today $ROOT resolves to
  # B's own toplevel (plans/ is not among link-worktree.sh's five shared
  # paths), so the row lands in a forked per-tree copy at
  # B/.gaia/local/plans/ledger.json and main's ledger is never created.
  [ -f "$MAIN/.gaia/local/plans/ledger.json" ]
}

@test "C3-05: the project id is one value per clone" {
  MAIN="$(gaia_new_main gaia-c305-main)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # Drives the real production functions directly (readOrCreateProjectId /
  # resolveStorageRoots) via tsx against the real source: the module resolves
  # through node_modules, not a relative `source`, so a throwaway fixture
  # cannot carry a working copy the way a bash script can.
  storage_dir="$GAIA_REPO_ROOT_REAL/.gaia/cli/src/storage"
  tsx="$GAIA_REPO_ROOT_REAL/.gaia/cli/node_modules/.bin/tsx"

  read_id() {
    local repo_root="$1"
    "$tsx" --eval "
      import {readOrCreateProjectId, resolveStorageRoots} from '$storage_dir/index.ts';
      process.stdout.write(readOrCreateProjectId(resolveStorageRoots({repoRoot: '$repo_root'})));
    "
  }

  main_id="$(read_id "$MAIN")"
  [ -n "$main_id" ]

  # Mirrors the real caller (ping/send.ts's postPing): cwd defaults to
  # process.cwd(), which for a session running in B is B's own directory.
  b_id="$(read_id "$B")"

  # Target: reading .project-id "from" B yields main's id. Today B mints its
  # own separate id (sha256 of B's own root path) -- a second identity for
  # one clone.
  [ "$b_id" = "$main_id" ]
}

# ---------------------------------------------------------------------------
# Tranche 4 -- KEYS
# ---------------------------------------------------------------------------

# Shared by C4-01 / C4-02: a main checkout plus two real linked worktrees with
# link-worktree.sh's real symlinks live, each carrying its own new commit off
# the same base, so both compute the identical BASE_SHA the real documented
# recipe uses (`git merge-base "$BASE_REF" HEAD`, per
# .claude/agents/code-audit-frontend.md). Sets MAIN, A, B, BASE_SHA_A,
# BASE_SHA_B.
setup_c4_base_sha_pair() {
  MAIN="$(gaia_new_main "$1")"
  gaia_copy_real "$MAIN" \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh \
    .gaia/scripts/link-worktree.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add link-worktree deps"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"
  gaia_link_worktree "$A"
  gaia_link_worktree "$B"

  echo a > "$A/a.txt"
  git -C "$A" add a.txt
  git -C "$A" commit -q -m "a work"
  echo b > "$B/b.txt"
  git -C "$B" add b.txt
  git -C "$B" commit -q -m "b work"

  BASE_SHA_A="$(run_in "$A" -- git merge-base main HEAD)"
  BASE_SHA_B="$(run_in "$B" -- git merge-base main HEAD)"
}

@test "C4-01: findings sidecar isolated across worktrees" {
  setup_c4_base_sha_pair gaia-c401-main
  [ "$BASE_SHA_A" = "$BASE_SHA_B" ]

  sidecar_a="$A/.gaia/local/audit/${BASE_SHA_A}.code-audit-frontend.findings.json"
  sidecar_b="$B/.gaia/local/audit/${BASE_SHA_B}.code-audit-frontend.findings.json"

  jq -n '{schema: 1, member: "frontend", tree: "treeA", findings: ["A-only finding"]}' > "$sidecar_a"
  jq -n '{schema: 1, member: "frontend", tree: "treeB", findings: ["B-only finding"]}' > "$sidecar_b"

  # Target: tree A's findings are never overwritten by, nor contain, tree B's
  # (keyed by base-sha plus branch). Today the sidecar path is
  # .gaia/local/audit/${BASE_SHA}.code-audit-frontend.findings.json --
  # base-sha alone -- and audit/ is symlinked to main from every worktree, so
  # both trees' writes land on the SAME physical file and B's write clobbers
  # A's.
  run jq -r '.tree' "$sidecar_a"
  [ "$status" -eq 0 ]
  [ "$output" = "treeA" ]
}

@test "C4-02: rerun ledger isolated across worktrees" {
  setup_c4_base_sha_pair gaia-c402-main
  [ "$BASE_SHA_A" = "$BASE_SHA_B" ]

  ledger_a="$A/.gaia/local/audit/${BASE_SHA_A}.rerun.json"
  ledger_b="$B/.gaia/local/audit/${BASE_SHA_B}.rerun.json"

  jq -n --arg br treeA --arg base "$BASE_SHA_A" '{schema: 1, branch: $br, base_sha: $base, round: 1}' > "$ledger_a"
  jq -n --arg br treeB --arg base "$BASE_SHA_B" '{schema: 1, branch: $br, base_sha: $base, round: 1}' > "$ledger_b"

  # Target: the rerun ledger is partitioned by base-sha plus branch, so one
  # tree's rerun record never overwrites the other's. Today it is base-sha
  # alone (.gaia/local/audit/${BASE_SHA}.rerun.json, shared audit/), so B's
  # write clobbers A's.
  run jq -r '.branch' "$ledger_a"
  [ "$status" -eq 0 ]
  [ "$output" = "treeA" ]
}

@test "C4-03: PR-artifact capture is per branch (simulated)" {
  # Simulated: the GitHub PR/merge round-trip is stood in by a fixture; only
  # the real capture/read library (gh-artifact-lib.sh) is driven for real.
  MAIN="$(gaia_new_main gaia-c403-main)"
  gaia_copy_real "$MAIN" .gaia/scripts/gh-artifact-lib.sh .gaia/scripts/main-root-lib.sh
  gaia_commit_all "$MAIN" "add gh-artifact lib"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # Tree A's session opens PR #100 for its own branch...
  run run_in "$A" -- bash -c '
    . .gaia/scripts/gh-artifact-lib.sh
    cache_dir="$(gaia_gh_artifact_cache_dir)"
    path="$(gaia_gh_artifact_path "$cache_dir")"
    gaia_gh_artifact_write "$path" 100 owner/repo treeA sessA
  '
  [ "$status" -eq 0 ]

  # ...then tree B's session, concurrently, opens PR #200 for ITS branch.
  run run_in "$B" -- bash -c '
    . .gaia/scripts/gh-artifact-lib.sh
    cache_dir="$(gaia_gh_artifact_cache_dir)"
    path="$(gaia_gh_artifact_path "$cache_dir")"
    gaia_gh_artifact_write "$path" 200 owner/repo treeB sessB
  '
  [ "$status" -eq 0 ]

  # Tree A's own reader then asks for its own artifact back.
  run run_in "$A" -- bash -c '
    . .gaia/scripts/gh-artifact-lib.sh
    cache_dir="$(gaia_gh_artifact_cache_dir)"
    path="$(gaia_gh_artifact_path "$cache_dir")"
    gaia_gh_artifact_read "$path" sessA treeA
  '
  [ "$status" -eq 0 ]

  # Target: A's own record is still readable (per-branch keying). Today the
  # cache is one file, resolved to main regardless of which tree calls it
  # ("One file, PR artifacts only ... Last writer wins" per the lib's own
  # header) -- B's later write overwrote A's record entirely, so A's read
  # returns nothing.
  [ -n "$output" ] || return 1
  printf '%s' "$output" | jq -e '.number == 100' >/dev/null
}

@test "C4-04: worthiness ledger is per tree" {
  MAIN="$(gaia_new_main gaia-c404-main)"
  gaia_copy_real "$MAIN" \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh \
    .gaia/scripts/link-worktree.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add link-worktree deps"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"
  gaia_link_worktree "$A"
  gaia_link_worktree "$B"

  mkdir -p "$A/test" "$B/test"
  cat > "$A/test/a.test.ts" <<'JS'
import { test, expect } from 'vitest';
test('a only test', () => {
  expect(1).toBe(1);
});
JS
  cat > "$B/test/b.test.ts" <<'JS'
import { test, expect } from 'vitest';
test('b only test', () => {
  expect(2).toBe(2);
});
JS

  append_script="$GAIA_REPO_ROOT_REAL/.gaia/scripts/audit-ledger/append-worthiness.mjs"
  run run_in "$A" -- node "$append_script" test/a.test.ts "a only test" keep
  [ "$status" -eq 0 ]
  run run_in "$B" -- node "$append_script" test/b.test.ts "b only test" keep
  [ "$status" -eq 0 ]

  # Target: tree B's own ledger holds only B's observation, matching its RED
  # sibling (per-tree), not shared under audit/. Today audit/worthiness.jsonl
  # (registry scope "per-tree") lives under audit/, a directory
  # link-worktree.sh symlinks WHOLESALE into main because other entries under
  # it are scope "shared" -- so the two trees' appends land in the SAME
  # physical file, and B's view contains A's entry too.
  contamination_count="$(grep -c '"a only test"' "$B/.gaia/local/audit/worthiness.jsonl")"
  [ "$contamination_count" -eq 0 ]
}

@test "C4-05: SPEC/plan locks serialize across worktrees" {
  MAIN="$(gaia_new_main gaia-c405-main)"
  gaia_copy_real "$MAIN" \
    .specify/extensions/gaia/lib/plan-allocator.sh \
    .specify/extensions/gaia/lib/with-ledger-lock.sh \
    .specify/extensions/gaia/lib/title-normalize.sh \
    .gaia/scripts/ledger-path-lib.sh \
    .gaia/scripts/main-root-lib.sh
  gaia_commit_all "$MAIN" "add plan allocator"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  root_a="$(run_in "$A" -- git rev-parse --show-toplevel)"
  root_b="$(run_in "$B" -- git rev-parse --show-toplevel)"

  id_a="$(bash "$MAIN/.specify/extensions/gaia/lib/plan-allocator.sh" next "$root_a" "feature A")"
  id_b="$(bash "$MAIN/.specify/extensions/gaia/lib/plan-allocator.sh" next "$root_b" "feature B")"

  # Target: concurrent number allocations never both mint the same id -- the
  # lock (and the ledger it guards) is anchored to main, so the second waits
  # and reads the first's row. Today plan-allocator.sh is handed
  # $ROOT = each tree's own toplevel (see C3-04), so each locks and numbers a
  # SEPARATE, disconnected per-tree ledger, and both mint PLAN-001.
  [ "$id_a" != "$id_b" ]
}

@test "C4-06: per-tree state survives the cutover" {
  MAIN="$(gaia_new_main gaia-c406-main)"
  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  mkdir -p "$A/.gaia/local/red-ledger" "$B/.gaia/local/red-ledger"
  echo '{"tree":"treeA","observation":"red-a"}' > "$A/.gaia/local/red-ledger/observations.jsonl"
  echo '{"tree":"treeB","observation":"red-b"}' > "$B/.gaia/local/red-ledger/observations.jsonl"

  # red-ledger/ is NOT among link-worktree.sh's five shared paths (state
  # registry scope "per-tree"), so it is never symlinked: each tree keeps a
  # genuinely separate, physical copy. This is the regression guard the meter
  # names already-green: it must STAY isolated after the single-symlink
  # cutover -- tree A's observation never resolves into main's one path and
  # never blocks tree B's commit.
  grep -qF 'red-b' "$A/.gaia/local/red-ledger/observations.jsonl" && return 1
  grep -qF 'red-a' "$B/.gaia/local/red-ledger/observations.jsonl" && return 1
  [ ! -e "$MAIN/.gaia/local/red-ledger/observations.jsonl" ]
}

# ---------------------------------------------------------------------------
# Tranche 5 -- SURFACE
# ---------------------------------------------------------------------------

@test "C5-01: statusline renders the worktree's own segment" {
  MAIN="$(gaia_new_main gaia-c501-main)"
  gaia_copy_real "$MAIN" .gaia/statusline/gaia-statusline.sh
  gaia_commit_all "$MAIN" "add statusline"

  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  mkdir -p "$B/.gaia/local/debt"
  jq -n '{schema: 1, openCount: 3, computedAt: 0}' > "$B/.gaia/local/debt/count.json"
  jq -n '{completed_at: "2026-01-01T00:00:00Z"}' > "$B/.gaia/local/setup-state.json"

  home_dir="$(gaia_mk_tmp gaia-c501-home)"
  json="$(jq -n --arg d "$B" '{workspace: {current_dir: $d}}')"
  run env HOME="$home_dir" bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$B/.gaia/statusline/gaia-statusline.sh"
  [ "$status" -eq 0 ]

  # Target: the right side renders B's own segment (e.g. the debt nudge), not
  # blanket-suppressed; no segment shows main's or another tree's state.
  # Today ANY session inside a linked worktree blanket-suppresses the whole
  # right side ("if [ "$is_worktree" -eq 0 ]" gates everything from the debt
  # segment down to setup completion), so the right side is dark regardless
  # of what the (correctly shared) cache holds.
  grep -qF 'gaia-debt' <<< "$output"
}

@test "C5-02: wiki hooks are live in a worktree" {
  MAIN="$(gaia_new_main gaia-c502-main)"
  gaia_copy_real "$MAIN" \
    .claude/hooks/wiki-drift-check.sh \
    .claude/hooks/wiki-commit-nudge.sh \
    .claude/hooks/wiki-session-stop.sh \
    .claude/hooks/wiki-squash-autocommits.sh
  mkdir -p "$MAIN/wiki"
  jq -n --arg sha "$(git -C "$MAIN" rev-parse HEAD)" \
    '{version: 1, last_evaluated_sha: $sha, last_evaluated_at: "2026-01-01T00:00:00Z"}' \
    > "$MAIN/wiki/.state.json"
  gaia_commit_all "$MAIN" "add wiki hooks"

  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # Advance treeB past its recorded last_evaluated_sha so real drift exists,
  # and remember this point as the session-start marker for hook 3 below.
  echo more >> "$B/README.md"
  git -C "$B" add README.md
  git -C "$B" commit -q -m "drift commit"
  session_start_sha="$(git -C "$B" rev-parse HEAD)"

  dead=""

  # 1. wiki-drift-check.sh: real drift exists; a live hook prints the
  # reminder and stamps its own marker.
  json="$(jq -n '{session_id: "S1"}')"
  out="$(run_in "$B" -- bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$MAIN/.claude/hooks/wiki-drift-check.sh")"
  grep -qF '[wiki state]' <<< "$out" || dead="$dead wiki-drift-check"

  # 2. wiki-commit-nudge.sh: fires on a Bash `git commit` PostToolUse call.
  json="$(jq -n --arg c 'git commit -m "x"' '{tool_name: "Bash", tool_input: {command: $c}}')"
  out="$(run_in "$B" -- bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$MAIN/.claude/hooks/wiki-commit-nudge.sh")"
  grep -qF '[wiki nudge]' <<< "$out" || dead="$dead wiki-commit-nudge"

  # 3. wiki-session-stop.sh: a session-start marker recording HEAD before a
  # commit that touched wiki/ was made; a live hook nudges to refresh hot.md.
  git_dir_b="$(run_in "$B" -- git rev-parse --git-dir)"
  echo "$session_start_sha" > "$git_dir_b/claude-session-start"
  echo page > "$B/wiki/page.md"
  git -C "$B" add wiki/page.md
  git -C "$B" commit -q -m "wiki page"
  json="$(jq -n '{session_id: "S1"}')"
  out="$(run_in "$B" -- bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$MAIN/.claude/hooks/wiki-session-stop.sh")"
  grep -qF 'WIKI_CHANGED' <<< "$out" || dead="$dead wiki-session-stop"

  # 4. wiki-squash-autocommits.sh: two consecutive `wiki: auto-commit` commits
  # at HEAD; a live hook squashes them into one.
  echo a1 > "$B/wiki/auto.md"
  git -C "$B" add wiki/auto.md
  git -C "$B" commit -q -m "wiki: auto-commit 1"
  echo a2 >> "$B/wiki/auto.md"
  git -C "$B" add wiki/auto.md
  git -C "$B" commit -q -m "wiki: auto-commit 2"
  before_n="$(count_autocommits "$B")"
  run_in "$B" -- bash "$MAIN/.claude/hooks/wiki-squash-autocommits.sh" >/dev/null 2>&1
  after_n="$(count_autocommits "$B")"
  [ "$before_n" -eq 2 ]
  [ "$after_n" -eq 1 ] || dead="$dead wiki-squash-autocommits"

  # Target: none silently dead -- each either fires correctly or refuses out
  # loud. Today all four exit 0 at their own `[ -d .git ]` guard the instant
  # they see a linked worktree's .git FILE (not a directory), doing none of
  # the above.
  if [ -n "$dead" ]; then
    echo "silently dead in a worktree:$dead" >&2
    return 1
  fi
}

@test "C5-03: main-only flows refuse out loud from a worktree" {
  # Proxy note (see the return): release/audit/wiki flows are CLI/skill-
  # driven (network, gh, multi-agent orchestration) and impractical to run
  # live in a bats fixture. This drives the real, already-correct predicate
  # (gaia_is_linked_worktree, proven by main-root-lib.sh's own conformance
  # suite) against a real linked worktree, then asserts the fact that decides
  # this scenario: does any main-only entry point actually call it to refuse?
  MAIN="$(gaia_new_main gaia-c503-main)"
  gaia_copy_real "$MAIN" .gaia/scripts/main-root-lib.sh
  gaia_commit_all "$MAIN" "add resolver"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  run run_in "$B" -- bash "$MAIN/.gaia/scripts/main-root-lib.sh" --is-worktree
  [ "$status" -eq 0 ]

  # Target: a main-only flow triggered from a worktree refuses out loud with
  # a named reason, which requires some entry point to actually consult the
  # resolver's own worktree predicate. Today no release/wiki entry point
  # calls it at all (this grep finds nothing), so none can be refusing on it.
  run grep -rl "gaia_is_linked_worktree" \
    "$GAIA_REPO_ROOT_REAL/.gaia/cli/src/wiki" \
    "$GAIA_REPO_ROOT_REAL/.gaia/cli/src/release" \
    "$GAIA_REPO_ROOT_REAL/.claude/commands/gaia-release.md"
  [ "$status" -eq 0 ]
}

@test "C5-04: a machine-scoped nudge is not mis-scoped" {
  MAIN="$(gaia_new_main gaia-c504-main)"
  gaia_copy_real "$MAIN" \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh \
    .gaia/scripts/link-worktree.sh \
    .gaia/scripts/debt-count-refresh.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add debt refresher + link-worktree deps"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"
  gaia_link_worktree "$A"
  gaia_link_worktree "$B"

  # debt/ is a state-registry "shared" path, so both A's and B's own copy of
  # the refresher resolve the SAME physical cache through their own symlink.
  jq -n --argjson t "$(date +%s)" '{schema: 1, openCount: 2, computedAt: $t}' \
    > "$MAIN/.gaia/local/debt/count.json"
  computed_before="$(jq -r '.computedAt' "$MAIN/.gaia/local/debt/count.json")"

  # Every open worktree's own statusline tick fires its own instance of this
  # refresher; simulate two such ticks landing back-to-back, one per tree.
  run_in "$A" -- bash .gaia/scripts/debt-count-refresh.sh
  run_in "$B" -- bash .gaia/scripts/debt-count-refresh.sh

  computed_after="$(jq -r '.computedAt' "$MAIN/.gaia/local/debt/count.json")"

  # Target -- and today's already-satisfied result: within the TTL, a tick
  # from EITHER worktree sees the shared cache is fresh and skips
  # recomputing, so the nudge fires once for the machine's TTL window, not
  # once per worktree per tick. A machine-scoped nudge firing from every
  # worktree unconditionally is the mis-scoped defect this guards against.
  [ "$computed_before" = "$computed_after" ]
}

# ---------------------------------------------------------------------------
# Tranche 6 -- LIFECYCLE
# ---------------------------------------------------------------------------

@test "C6-01: a name collision deletes no peer" {
  MAIN="$(gaia_new_main gaia-c601-main)"
  gaia_copy_real "$MAIN" \
    .gaia/scripts/create-worktree.sh \
    .gaia/scripts/link-worktree.sh \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh \
    .specify/extensions/gaia/lib/with-ledger-lock.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add create-worktree + deps"

  json="$(jq -n '{name: "debt/collide"}')"
  run run_in "$MAIN" -- bash -c 'printf %s "$1" | bash .gaia/scripts/create-worktree.sh' _ "$json"
  [ "$status" -eq 0 ]
  # The hook's own diagnostics (link-worktree.sh's "linked: ..." lines) go to
  # stderr, which `run` merges into $output alongside the hook's one stdout
  # line (the worktree path); the path is always the LAST line.
  wt1="$(tail -n1 <<< "$output")"
  [ -d "$wt1" ]

  # The peer worktree now holds real, valuable, uncommitted work.
  echo irreplaceable > "$wt1/uncommitted.txt"

  # A second session asks to create a worktree of the SAME name: the
  # collision. Its own outcome (refuse / disambiguate) is not asserted here,
  # only that it never deletes the existing peer to resolve itself -- the
  # trial answered by trying it, not assumed.
  run run_in "$MAIN" -- bash -c 'printf %s "$1" | bash .gaia/scripts/create-worktree.sh' _ "$json"

  # Target: the original peer, and its uncommitted work, survive the
  # collision.
  [ -d "$wt1" ]
  [ -f "$wt1/uncommitted.txt" ]
}

@test "C6-02: provisioning self-heals on re-entry" {
  MAIN="$(gaia_new_main gaia-c602-main)"
  gaia_copy_real "$MAIN" \
    .gaia/scripts/link-worktree.sh \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh
  gaia_copy_registry "$MAIN"
  gaia_commit_all "$MAIN" "add link-worktree deps"

  B="$(gaia_add_worktree "$MAIN" treeB treeB)"
  gaia_link_worktree "$B"
  [ -L "$B/.gaia/local/audit" ]

  # Deliberately break the shared-state symlink: replace it with a plain dir.
  rm -f "$B/.gaia/local/audit"
  mkdir -p "$B/.gaia/local/audit"
  echo orphaned > "$B/.gaia/local/audit/orphan.txt"

  # Re-entry: the next session start re-runs link-worktree.sh.
  gaia_link_worktree "$B"

  # Target: repaired to a correct symlink at main's real audit dir, on the
  # next session start, without manual intervention.
  [ -L "$B/.gaia/local/audit" ] || return 1
  target_real="$(cd "$B/.gaia/local/audit" && pwd -P)"
  main_real="$(cd "$MAIN/.gaia/local/audit" && pwd -P)"
  [ "$target_real" = "$main_real" ]
}

@test "C6-03: generated types are present in a fresh worktree" {
  MAIN="$(gaia_new_main gaia-c603-main)"
  gaia_copy_real "$MAIN" \
    .gaia/scripts/create-worktree.sh \
    .gaia/scripts/link-worktree.sh \
    .gaia/scripts/main-root-lib.sh \
    .gaia/scripts/state-registry-lib.sh \
    .specify/extensions/gaia/lib/with-ledger-lock.sh
  gaia_copy_registry "$MAIN"

  # A stand-in react-router CLI: create-worktree.sh borrows the resolved
  # project root's own installed binary rather than installing one per
  # worktree, so a fixture-local stub at the same borrowed path is a faithful
  # proxy for the real typegen call.
  mkdir -p "$MAIN/node_modules/.bin"
  cat > "$MAIN/node_modules/.bin/react-router" <<'SH'
#!/bin/sh
if [ "$1" = "typegen" ]; then
  mkdir -p .react-router/types
  echo generated > .react-router/types/.stamp
fi
SH
  chmod +x "$MAIN/node_modules/.bin/react-router"
  gaia_commit_all "$MAIN" "add create-worktree + stub CLI"

  json="$(jq -n '{name: "feat/types"}')"
  run run_in "$MAIN" -- bash -c 'printf %s "$1" | bash .gaia/scripts/create-worktree.sh' _ "$json"
  [ "$status" -eq 0 ]
  # See C6-01: the hook's one stdout line (the worktree path) is always last.
  wt="$(tail -n1 <<< "$output")"

  # Target: generated build types are present and current before first use.
  [ -f "$wt/.react-router/types/.stamp" ]
}

# ---------------------------------------------------------------------------
# Step-7 carve-out candidates -- the hard three
# ---------------------------------------------------------------------------

@test "C7-01: Serena answers the acting tree or refuses (simulated)" {
  # Simulated: Serena is a single MCP process for the whole environment; a
  # fixture stands in for it (a plain "active project" pointer file, plus a
  # query stand-in reporting whichever project last activated it), since
  # there is no way to drive the real MCP process from a bats fixture.
  MAIN="$(gaia_new_main gaia-c701-main)"
  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  serena_root="$(gaia_mk_tmp gaia-c701-serena)"
  serena_state="$serena_root/active-project"

  serena_activate() { printf '%s' "$1" > "$serena_state"; }
  serena_query() { cat "$serena_state" 2>/dev/null; }

  # Tree A activates the single shared MCP process/index...
  serena_activate "$A"
  # ...then a symbol query is issued "from" tree B.
  answered_for="$(serena_query)"

  # Target: the query is answered against B's own index, or refuses out
  # loud; it never silently returns a symbol resolved against a different
  # tree. Today the single shared index answers with whichever project last
  # activated it -- A's -- silently, with no refusal and no B-scoped answer.
  [ "$answered_for" = "$B" ]
}

@test "C7-02: tests use the acting tree's dependencies" {
  MAIN="$(gaia_new_main gaia-c702-main)"
  jq -n '{name: "fixture", dependencies: {"left-pad": "1.0.0"}}' > "$MAIN/package.json"
  gaia_commit_all "$MAIN" "add package.json"

  # node_modules is gitignored and never shared/re-installed per worktree in
  # real GAIA; created directly on disk AFTER the commit, so it never becomes
  # a tracked path a worktree would check out (a real worktree never gets one
  # at all).
  mkdir -p "$MAIN/node_modules/left-pad"
  echo '{"name":"left-pad"}' > "$MAIN/node_modules/left-pad/package.json"
  echo "module.exports = 1;" > "$MAIN/node_modules/left-pad/index.js"

  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  # Tree B's branch drops the dependency (a real divergence: its own manifest
  # no longer names left-pad) and never gets its own node_modules -- worktrees
  # are never installed into, matching create-worktree.sh's own borrow-from-
  # main design ("Node's upward node_modules traversal resolves ... the app's
  # own imports from there").
  jq '.dependencies = {}' "$B/package.json" > "$B/package.json.tmp"
  mv "$B/package.json.tmp" "$B/package.json"
  git -C "$B" add package.json
  git -C "$B" commit -q -m "drop left-pad"
  [ ! -e "$B/node_modules" ]

  # Target: resolving left-pad from inside B either finds B's own copy (there
  # is none) or refuses; it never silently resolves against main's, since B's
  # own manifest disagrees with what main has installed.
  run run_in "$B" -- node -e "require.resolve('left-pad')"

  # Today Node's own upward node_modules search walks past B (which has none)
  # straight to main's, resolving silently despite the divergent manifest.
  [ "$status" -ne 0 ]
}

@test "C7-03: the wiki state value is not cross-clobbered" {
  MAIN="$(gaia_new_main gaia-c703-main)"
  mkdir -p "$MAIN/wiki"
  jq -n --arg sha "$(git -C "$MAIN" rev-parse HEAD)" \
    '{version: 1, last_evaluated_sha: $sha, last_evaluated_at: "2026-01-01T00:00:00Z"}' \
    > "$MAIN/wiki/.state.json"
  gaia_commit_all "$MAIN" "add wiki state"

  A="$(gaia_add_worktree "$MAIN" treeA treeA)"
  B="$(gaia_add_worktree "$MAIN" treeB treeB)"

  echo "a work" > "$A/a.txt"
  git -C "$A" add a.txt
  git -C "$A" commit -q -m "a work"
  a_sha="$(git -C "$A" rev-parse HEAD)"
  jq --arg sha "$a_sha" '.last_evaluated_sha = $sha' "$A/wiki/.state.json" > "$A/wiki/.state.json.tmp"
  mv "$A/wiki/.state.json.tmp" "$A/wiki/.state.json"
  git -C "$A" add wiki/.state.json
  git -C "$A" commit -q -m "wiki: bump state to a"

  echo "b work" > "$B/b.txt"
  git -C "$B" add b.txt
  git -C "$B" commit -q -m "b work"
  b_sha="$(git -C "$B" rev-parse HEAD)"
  jq --arg sha "$b_sha" '.last_evaluated_sha = $sha' "$B/wiki/.state.json" > "$B/wiki/.state.json.tmp"
  mv "$B/wiki/.state.json.tmp" "$B/wiki/.state.json"
  git -C "$B" add wiki/.state.json
  git -C "$B" commit -q -m "wiki: bump state to b"

  # Tree A's session lands first (mirrors a squash-merged PR).
  git -C "$MAIN" merge -q --no-ff treeA -m "merge A"
  after_a="$(jq -r '.last_evaluated_sha' "$MAIN/wiki/.state.json")"
  [ "$after_a" = "$a_sha" ]

  # Tree B's session, cut from the ORIGINAL base and unaware of A's landing,
  # then attempts to land too.
  run git -C "$MAIN" merge --no-ff treeB -m "merge B"

  # Target -- and today's already-satisfied result on this tracked-file path:
  # git's own three-way merge sees BOTH sides change the same scalar field
  # and refuses the merge outright (a real conflict), rather than silently
  # letting whichever session lands second clobber the other's value with no
  # signal -- never a last-writer-wins race across trees.
  if [ "$status" -eq 0 ]; then
    final_sha="$(jq -r '.last_evaluated_sha' "$MAIN/wiki/.state.json")"
    [ "$final_sha" = "$a_sha" ] && return 1
    [ "$final_sha" = "$b_sha" ] && return 1
    return 1
  fi
  grep -qF 'CONFLICT' <<< "$output"
}
