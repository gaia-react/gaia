#!/usr/bin/env bats

# The /gaia-wiki nudge: the statusline's slot-7 segment, and the refresher
# (.gaia/scripts/check-updates.sh) that writes `wikiDriftCount` from the
# committed CLI's `wiki state --json` `drift_count`.
#
# Two fixture shapes:
#   - SL: a statusline-only main checkout (no refresher script, so a render
#     never fires a background refresh) fed hand-written cache JSON.
#   - FIX: a real git repository with a bare origin, `wiki/.state.json`, the
#     real refresher and statusline, and a `gaia` wrapper that answers the
#     refresher's non-wiki subcommands with inert stubs and hands `wiki` to the
#     real committed bundle, so drift_count and the land are the shipped code.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/wiki-nudge.bats < /dev/null

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # shellcheck source=.gaia/tests/helpers/path.sh
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v node >/dev/null 2>&1 || skip "node required"

  STATUSLINE_SRC="$REPO_ROOT/.gaia/statusline/gaia-statusline.sh"
  CHECK_UPDATES_SRC="$REPO_ROOT/.gaia/scripts/check-updates.sh"
  MAIN_ROOT_LIB_SRC="$REPO_ROOT/.gaia/scripts/main-root-lib.sh"
  REAL_GAIA="$REPO_ROOT/.gaia/cli/gaia"
  [ -x "$REAL_GAIA" ] || skip "committed gaia bundle missing"

  TMP_HOME=$(mktemp -d -t gaia-wiki-nudge-home-XXXXXX)

  # `Atomics.wait` is how the CLI's merge poll sleeps between `gh pr view`
  # checks; a deferred land would otherwise block for the whole wait budget.
  NO_SLEEP="$BATS_TEST_TMPDIR/no-sleep.cjs"
  printf 'Atomics.wait = () => "ok";\n' > "$NO_SLEEP"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  GH_MERGED_MARKER="$BATS_TEST_TMPDIR/gh-merged"
  ORIGIN_DIR="$BATS_TEST_TMPDIR/origin.git"
  : > "$GH_LOG"
  export GH_LOG GH_MERGED_MARKER ORIGIN_DIR
  write_stub_gh "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

teardown() {
  [ -n "${SL:-}" ] && rm -rf "$SL" || true
  [ -n "${FIX:-}" ] && rm -rf "$FIX" "${FIX}-wt" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  return 0
}

# `gh` stub: `release list` answers gaiaLatest; `pr merge` fast-forwards the
# bare origin's main to the current branch unless MOCK_GH_MERGE=defer (auto-merge
# queued, PR still open); `pr view` reports MERGED only after a merge.
write_stub_gh() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1" in
  release) printf 'v0.0.0\n' ;;
  pr)
    case "$2" in
      create) printf 'https://example.test/pull/1\n' ;;
      merge)
        [ "${MOCK_GH_MERGE:-merge}" = "defer" ] && exit 0
        branch=$(git rev-parse --abbrev-ref HEAD)
        git --git-dir="$ORIGIN_DIR" update-ref refs/heads/main "refs/heads/$branch"
        : > "$GH_MERGED_MARKER"
        ;;
      view)
        if [ -f "$GH_MERGED_MARKER" ]; then printf 'MERGED\n'; else printf 'OPEN\n'; fi
        ;;
    esac
    ;;
  api) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}

# ---------- statusline-only fixture ----------

make_statusline_fixture() {
  SL=$(mktemp -d -t gaia-wiki-nudge-sl-XXXXXX)
  git -C "$SL" init --quiet --initial-branch=main
  git -C "$SL" config user.email "test@example.com"
  git -C "$SL" config user.name "Test"
  git -C "$SL" config commit.gpgsign false
  mkdir -p "$SL/.gaia/statusline" "$SL/.gaia/local/cache/shared"
  cp "$STATUSLINE_SRC" "$SL/.gaia/statusline/gaia-statusline.sh"
  echo "x" > "$SL/README.md"
  git -C "$SL" add -A
  git -C "$SL" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$SL/.gaia/local/setup-state.json"
}

# Render <script> with a payload whose current_dir is <dir>. Sets $output,
# $status, and $plain (ANSI stripped). COLUMNS=400 keeps every nudge Large.
render_statusline() {
  local script="$1" dir="$2" cols="${3:-400}" json
  json=$(jq -n --arg d "$dir" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" COLUMNS="$cols" bash -c "printf '%s' '$json' | bash '$script'"
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
}

render_with_cache() {
  printf '%s' "$1" > "$SL/.gaia/local/cache/shared/update-check.json"
  render_statusline "$SL/.gaia/statusline/gaia-statusline.sh" "$SL"
}

# ---------- repository fixture ----------

# The wrapper answers every subcommand check-updates.sh calls other than
# `wiki` with an inert stub. `wiki` goes to the real bundle unless
# MOCK_WIKI_EXIT (exit non-zero) or MOCK_WIKI_OUT (print that text) is set.
write_gaia_wrapper() {
  cat > "$1" <<EOF
#!/usr/bin/env bash
case "\$1" in
  update-deps)
    out=""
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --emit-updates) out="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "\$out" ] && printf '{"actionable_count":0}' > "\$out"
    exit 0
    ;;
  harden-tally)
    printf '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90}'
    exit 0
    ;;
  residue-tally)
    printf '{"gh_ok":false,"aged_candidate_count":0}'
    exit 0
    ;;
  wiki)
    [ -n "\${MOCK_WIKI_EXIT:-}" ] && exit 1
    if [ -n "\${MOCK_WIKI_OUT+set}" ]; then
      printf '%s' "\$MOCK_WIKI_OUT"
      exit 0
    fi
    exec "$REAL_GAIA" "\$@"
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}

# One non-bookkeeping empty commit.
add_commit() {
  git -C "$FIX" commit --allow-empty --quiet -m "$1"
}

# The four bookkeeping subjects the drift count must not include.
add_bookkeeping_commits() {
  local sha
  sha=$(git -C "$FIX" rev-parse --short HEAD)
  add_commit "wiki: sync through $sha"
  add_commit "wiki: maintenance chain through $sha"
  add_commit "wiki: consolidate through $sha"
  add_commit "wiki: lint through $sha"
}

# Write wiki/.state.json naming <sha> (full) and <at>.
write_state() {
  mkdir -p "$FIX/wiki"
  jq -n --arg sha "$1" --arg at "${2:-2026-01-01T00:00:00Z}" \
    '{last_evaluated_sha: $sha, last_evaluated_at: $at}' > "$FIX/wiki/.state.json"
}

# make_repo [--no-state]: a committed main checkout with a bare origin, the
# real refresher, statusline, and resolver, the gaia wrapper, an inert
# resolve-audit-members.sh, and (unless --no-state) a state file naming the
# initial commit. Leaves HEAD on main with a clean tree.
make_repo() {
  FIX=$(mktemp -d -t gaia-wiki-nudge-fix-XXXXXX)
  git init --quiet --bare "$ORIGIN_DIR"
  git -C "$FIX" init --quiet --initial-branch=main
  git -C "$FIX" config user.email "test@example.com"
  git -C "$FIX" config user.name "Test"
  git -C "$FIX" config commit.gpgsign false
  printf '.gaia/local/\n.claude/commands/\n' >> "$FIX/.git/info/exclude"
  mkdir -p "$FIX/.gaia/scripts" "$FIX/.gaia/statusline" "$FIX/.gaia/cli" "$FIX/.gaia/local/cache/shared" "$FIX/wiki"
  cp "$CHECK_UPDATES_SRC" "$FIX/.gaia/scripts/check-updates.sh"
  cp "$MAIN_ROOT_LIB_SRC" "$FIX/.gaia/scripts/main-root-lib.sh"
  cp "$STATUSLINE_SRC" "$FIX/.gaia/statusline/gaia-statusline.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/.gaia/scripts/resolve-audit-members.sh"
  # Not executable on purpose: the statusline fires its refresher only when
  # `-x`, and a render-spawned background run would race the explicit
  # `refresh` calls that sequence each test (the tests run it via `bash`).
  chmod -x "$FIX/.gaia/scripts/check-updates.sh"
  chmod +x "$FIX/.gaia/scripts/resolve-audit-members.sh"
  write_gaia_wrapper "$FIX/.gaia/cli/gaia"
  printf '1.0.0\n' > "$FIX/.gaia/VERSION"
  printf 'seed\n' > "$FIX/wiki/index.md"
  git -C "$FIX" add -A
  git -C "$FIX" commit --quiet -m "chore: initial"
  if [ "${1:-}" != "--no-state" ]; then
    write_state "$(git -C "$FIX" rev-parse HEAD)"
    git -C "$FIX" add wiki/.state.json
    git -C "$FIX" commit --quiet -m "wiki: sync through $(git -C "$FIX" rev-parse --short HEAD)"
  fi
  git -C "$FIX" remote add origin "$ORIGIN_DIR"
  git -C "$FIX" push --quiet origin main
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$FIX/.gaia/local/setup-state.json"
  FIX=$(cd "$FIX" && pwd -P)
}

# add_drift <n>: n non-bookkeeping commits, with the four bookkeeping subjects
# interleaved so a count that failed to filter them would overshoot.
add_drift() {
  local n="$1" i
  for ((i = 1; i <= n; i++)); do
    add_commit "feat: change $i"
    [ "$i" -eq 3 ] && add_bookkeeping_commits
  done
  return 0
}

# Run the refresher in <dir> (default FIX) against a stale cache.
refresh() {
  local dir="${1:-$FIX}" cache="$FIX/.gaia/local/cache/shared/update-check.json"
  if [ -f "$cache" ]; then
    jq '.checkedAt = 0' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
  fi
  run env HOME="$TMP_HOME" bash "$dir/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
}

cached_wiki_count() {
  jq -r '.wikiDriftCount' "$FIX/.gaia/local/cache/shared/update-check.json"
}

cli_drift_count() {
  (cd "${1:-$FIX}" && "$REAL_GAIA" wiki state --json | jq -r '.drift_count')
}

render_fix() {
  render_statusline "$FIX/.gaia/statusline/gaia-statusline.sh" "${1:-$FIX}"
}

# Fails (return 1) when the render names the wiki nudge.
assert_no_wiki_nudge() {
  grep -qF -- "/gaia-wiki" <<<"$plain" && return 1
  grep -qF -- "🧠" <<<"$plain" && return 1
  return 0
}

assert_wiki_nudge() {
  grep -qF -- "Run /gaia-wiki ($1 commits behind)" <<<"$plain"
}

# The icon form only exists at a width too narrow for any text form: with the
# 11-column left side, 24 columns leaves the lone nudge room for `🧠<count>`
# and nothing wider.
render_fix_narrow() {
  render_statusline "$FIX/.gaia/statusline/gaia-statusline.sh" "$FIX" 24
}

assert_wiki_icon() {
  grep -qF -- "🧠$1" <<<"$plain"
}

# Run the real CLI's `wiki sync land` in <dir>, with sleeps disabled.
run_land() {
  local dir="$1"
  shift
  run env HOME="$TMP_HOME" NODE_OPTIONS="--require $NO_SLEEP" \
    bash -c "cd '$dir' && '$REAL_GAIA' wiki sync land $*"
}

# Stage the change a sync makes: state advanced to the current HEAD.
stage_state_advance() {
  local dir="$1"
  jq -n --arg sha "$(git -C "$dir" rev-parse HEAD)" \
    '{last_evaluated_sha: $sha, last_evaluated_at: "2026-02-01T00:00:00Z"}' > "$dir/wiki/.state.json"
}

# ---------- UAT-005: the count and the threshold ----------

@test "19 non-bookkeeping commits behind: wikiDriftCount is 19 and no nudge renders" {
  make_repo
  add_drift 19
  [ "$(git -C "$FIX" log --format=%s | grep -c '^wiki: ')" -ge 5 ]
  refresh
  [ "$(cached_wiki_count)" = "19" ]
  render_fix
  assert_no_wiki_nudge
}

@test "20 non-bookkeeping commits behind: the nudge renders and the CLI agrees" {
  make_repo
  add_drift 20
  refresh
  [ "$(cached_wiki_count)" = "20" ]
  [ "$(cli_drift_count)" = "20" ]
  render_fix
  assert_wiki_nudge 20
  render_fix_narrow
  assert_wiki_icon 20
}

@test "the cached count is a number even when the nudge is not showing" {
  make_repo
  refresh
  jq -e '.wikiDriftCount | type == "number"' "$FIX/.gaia/local/cache/shared/update-check.json" >/dev/null
  [ "$(cached_wiki_count)" = "0" ]
}

# ---------- render-only threshold ----------

@test "the threshold boundary: 19 renders nothing, 20 renders the segment" {
  make_statusline_fixture
  render_with_cache '{"wikiDriftCount":19}'
  [ "$status" -eq 0 ]
  assert_no_wiki_nudge

  render_with_cache '{"wikiDriftCount":20}'
  [ "$status" -eq 0 ]
  assert_wiki_nudge 20
}

@test "0, an absent field, an empty string, and a non-numeric value each render no segment" {
  make_statusline_fixture
  for cache in '{"wikiDriftCount":0}' '{}' '{"wikiDriftCount":""}' '{"wikiDriftCount":"abc"}' '{"wikiDriftCount":-30}'; do
    render_with_cache "$cache"
    [ "$status" -eq 0 ]
    assert_no_wiki_nudge || return 1
  done
  true
}

@test "a missing cache file and an unavailable jq each render no segment" {
  make_statusline_fixture
  rm -f "$SL/.gaia/local/cache/shared/update-check.json"
  render_statusline "$SL/.gaia/statusline/gaia-statusline.sh" "$SL"
  [ "$status" -eq 0 ]
  assert_no_wiki_nudge || return 1

  printf '{"wikiDriftCount":40}' > "$SL/.gaia/local/cache/shared/update-check.json"
  json=$(jq -n --arg d "$SL" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" PATH="$(path_shim_without jq)" bash -c "printf '%s' '$json' | bash '$SL/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-wiki" <<<"$output" && return 1
  true
}

@test "the nudge sits in the lowest-priority slot, after /gaia-residue" {
  make_statusline_fixture
  render_with_cache '{"gaiaHasUpdate":true,"gaiaLatest":"9.9.9","outdatedCount":3,"residueCandidateCount":5,"wikiDriftCount":22}'
  [ "$status" -eq 0 ]
  order=$(grep -oE 'Run /[a-z][a-z0-9-]*' <<<"$plain")
  expected=$(printf '%s\n' "Run /update-gaia" "Run /update-deps" "Run /gaia-residue" "Run /gaia-wiki")
  [ "$order" = "$expected" ]
}

@test "the nudge color is its own: 01;96 appears on the wiki segment and nowhere else" {
  make_statusline_fixture
  render_with_cache '{"gaiaHasUpdate":true,"gaiaLatest":"9.9.9","outdatedCount":3,"residueCandidateCount":5,"wikiDriftCount":22}'
  [ "$status" -eq 0 ]
  grep -qF -- $'\033[01;96mRun /gaia-wiki (22 commits behind)\033[00m' <<<"$output"
  [ "$(grep -oF -- $'\033[01;96m' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the threshold is declared once as a named constant" {
  [ "$(grep -c 'WIKI_NUDGE_THRESHOLD=' "$STATUSLINE_SRC")" -eq 1 ]
  grep -qE '^ *WIKI_NUDGE_THRESHOLD=20$' "$STATUSLINE_SRC"
  grep -qE 'RESIDUE_NUDGE_THRESHOLD=' "$STATUSLINE_SRC"
}

@test "a statusline with the comparison weakened to -gt fails the 20-commit case" {
  make_statusline_fixture
  mutant="$SL/.gaia/statusline/gaia-statusline-mutant.sh"
  # shellcheck disable=SC2016  # the pattern names a literal `$`, not an expansion
  sed 's/-ge "$WIKI_NUDGE_THRESHOLD"/-gt "$WIKI_NUDGE_THRESHOLD"/' "$STATUSLINE_SRC" > "$mutant"
  cmp -s "$STATUSLINE_SRC" "$mutant" && return 1

  printf '%s' '{"wikiDriftCount":20}' > "$SL/.gaia/local/cache/shared/update-check.json"
  render_statusline "$mutant" "$SL"
  [ "$status" -eq 0 ]
  # The real script's 20-commit assertion is `assert_wiki_nudge 20`; the mutant
  # must not satisfy it.
  assert_wiki_nudge 20 && return 1
  true
}

# ---------- suppression ----------

@test "no wiki nudge renders from a linked worktree of the fixture" {
  make_repo
  add_drift 25
  refresh
  [ "$(cached_wiki_count)" = "25" ]
  render_fix
  assert_wiki_nudge 25

  git -C "$FIX" worktree add --quiet "${FIX}-wt" -b feature
  render_fix "${FIX}-wt"
  [ "$status" -eq 0 ]
  assert_no_wiki_nudge
}

@test "no wiki nudge renders while setup-state.json lacks completed_at" {
  make_repo
  add_drift 25
  refresh
  render_fix
  assert_wiki_nudge 25

  printf '{}' > "$FIX/.gaia/local/setup-state.json"
  render_fix
  [ "$status" -eq 0 ]
  grep -qF -- "Run /setup-gaia" <<<"$plain"
  assert_no_wiki_nudge
}

@test "no wiki nudge renders while .claude/commands/gaia-init.md exists" {
  make_repo
  add_drift 25
  refresh
  render_fix
  assert_wiki_nudge 25

  mkdir -p "$FIX/.claude/commands"
  : > "$FIX/.claude/commands/gaia-init.md"
  render_fix
  [ "$status" -eq 0 ]
  assert_no_wiki_nudge
}

# ---------- UAT-006: clearing ----------

@test "advancing the state file to HEAD and invalidating the cache clears the nudge" {
  make_repo
  add_drift 20
  refresh
  render_fix
  assert_wiki_nudge 20

  write_state "$(git -C "$FIX" rev-parse HEAD)"
  git -C "$FIX" add wiki/.state.json
  git -C "$FIX" commit --quiet -m "wiki: sync through $(git -C "$FIX" rev-parse --short HEAD)"
  refresh
  [ "$(cached_wiki_count)" -lt 20 ]
  render_fix
  assert_no_wiki_nudge
}

@test "invalidating the cache without advancing the state file keeps the nudge" {
  make_repo
  add_drift 20
  refresh
  render_fix
  assert_wiki_nudge 20

  refresh
  [ "$(cached_wiki_count)" = "20" ]
  render_fix
  assert_wiki_nudge 20
}

# ---------- UAT-006 through a real land ----------

# Seed the nudge at 20 and stage the state advance a sync makes.
seed_nudge_and_stage_sync() {
  add_drift 20
  refresh
  render_fix
  assert_wiki_nudge 20
  stage_state_advance "$FIX"
}

assert_land_cleared_nudge() {
  local dir="$1" landed_sha="$2"
  [ "$(jq -r '.checkedAt' "$FIX/.gaia/local/cache/shared/update-check.json")" = "0" ]
  refresh
  [ "$(cached_wiki_count)" -lt 20 ]
  render_fix
  assert_no_wiki_nudge || return 1
  render_fix_narrow
  assert_no_wiki_nudge || return 1
  [ "$(jq -r '.last_evaluated_sha' "$dir/wiki/.state.json")" = "$landed_sha" ]
}

@test "a real land on main clears the nudge and fast-forwards the main checkout's state" {
  make_repo
  seed_nudge_and_stage_sync
  landed_sha=$(git -C "$FIX" rev-parse HEAD)
  run_land "$FIX" --branch-aware
  [ "$status" -eq 0 ]
  grep -qF -- "merged PR" <<<"$output"
  grep -qF -- "statuses/" "$GH_LOG"
  git -C "$FIX" log -1 --format=%s | grep -q '^wiki: sync through '
  assert_land_cleared_nudge "$FIX" "$landed_sha"
}

@test "a real land on a feature branch clears the nudge" {
  make_repo
  git -C "$FIX" checkout --quiet -b feature
  seed_nudge_and_stage_sync
  landed_sha=$(git -C "$FIX" rev-parse HEAD)
  run_land "$FIX"
  [ "$status" -eq 0 ]
  grep -qF -- "in-place commit" <<<"$output"
  git -C "$FIX" log -1 --format=%s | grep -q '^wiki: sync through '
  assert_land_cleared_nudge "$FIX" "$landed_sha"
}

@test "a deferred land leaves the nudge showing after the refresher runs" {
  make_repo
  seed_nudge_and_stage_sync
  run env MOCK_GH_MERGE=defer HOME="$TMP_HOME" NODE_OPTIONS="--require $NO_SLEEP" \
    bash -c "cd '$FIX' && '$REAL_GAIA' wiki sync land --branch-aware"
  [ "$status" -eq 0 ]
  grep -qF -- "auto-merge queued" <<<"$output"
  [ "$(jq -r '.checkedAt' "$FIX/.gaia/local/cache/shared/update-check.json")" = "0" ]
  refresh
  [ "$(cached_wiki_count)" = "20" ]
  render_fix
  assert_wiki_nudge 20
}

# A protected-branch land runs where its branch is checked out. `main` cannot be
# checked out in two trees, so the main checkout parks on `holding` and a linked
# worktree takes `main`. The CLI fast-forwards the worktree's `main`, never the
# main checkout, so the refresher's answer, a main-checkout fact, clears only
# once the main checkout itself catches up.
@test "a real land from a linked worktree invalidates the shared cache and clears once the main checkout catches up" {
  make_repo
  add_drift 20
  git -C "$FIX" checkout --quiet -b holding
  git -C "$FIX" worktree add --quiet "${FIX}-wt" main
  refresh
  render_fix
  assert_wiki_nudge 20

  stage_state_advance "${FIX}-wt"
  landed_sha=$(git -C "${FIX}-wt" rev-parse HEAD)
  run_land "${FIX}-wt" --branch-aware
  [ "$status" -eq 0 ]
  [ "$(jq -r '.checkedAt' "$FIX/.gaia/local/cache/shared/update-check.json")" = "0" ]
  [ "$(jq -r '.last_evaluated_sha' "${FIX}-wt/wiki/.state.json")" = "$landed_sha" ]
  # The main checkout's own state file was not the one the land advanced.
  [ "$(jq -r '.last_evaluated_sha' "$FIX/wiki/.state.json")" != "$landed_sha" ]

  refresh
  [ "$(cached_wiki_count)" = "20" ]

  git -C "$FIX" merge --quiet --ff-only main
  [ "$(jq -r '.last_evaluated_sha' "$FIX/wiki/.state.json")" = "$landed_sha" ]
  refresh
  [ "$(cached_wiki_count)" -lt 20 ]
  render_fix
  assert_no_wiki_nudge
}

# ---------- STATE_ROOT, not PROJECT_ROOT ----------

# The refresher copy inside a linked worktree must ask the main checkout. The
# worktree has advanced its own state (drift 0) while main still trails by 25,
# so only a main-rooted query reports 25.
build_trailing_main_and_current_worktree() {
  make_repo
  add_drift 25
  git -C "$FIX" worktree add --quiet "${FIX}-wt" -b feature
  stage_state_advance "${FIX}-wt"
  git -C "${FIX}-wt" add wiki/.state.json
  git -C "${FIX}-wt" commit --quiet -m "wiki: sync through $(git -C "${FIX}-wt" rev-parse --short HEAD)"
  [ "$(cli_drift_count "${FIX}-wt")" = "0" ]
  [ "$(cli_drift_count "$FIX")" = "25" ]
}

@test "a refresher run from a linked worktree reports the main checkout's drift" {
  build_trailing_main_and_current_worktree
  run env HOME="$TMP_HOME" bash "${FIX}-wt/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cached_wiki_count)" = "25" ]
}

@test "a refresher reading wiki state from PROJECT_ROOT fails the linked-worktree case" {
  build_trailing_main_and_current_worktree
  mutant="${FIX}-wt/.gaia/scripts/check-updates-mutant.sh"
  # shellcheck disable=SC2016  # the pattern names a literal `$`, not an expansion
  sed 's/cd "$STATE_ROOT" \&\& "$GAIA_BIN" wiki state/cd "$PROJECT_ROOT" \&\& "$GAIA_BIN" wiki state/' \
    "$CHECK_UPDATES_SRC" > "$mutant"
  cmp -s "$CHECK_UPDATES_SRC" "$mutant" && return 1

  run env HOME="$TMP_HOME" bash "$mutant"
  [ "$status" -eq 0 ]
  [ "$(cached_wiki_count)" != "25" ]
}

# ---------- UAT-013 / UAT-014: every state shape yields a number ----------

assert_count_matches_cli() {
  local expected="$1"
  refresh
  jq -e 'has("wikiDriftCount")' "$FIX/.gaia/local/cache/shared/update-check.json" >/dev/null
  [ "$(cached_wiki_count)" = "$(cli_drift_count)" ]
  [ "$(cached_wiki_count)" = "$expected" ]
}

@test "no state file: the count is the whole history, written as a number" {
  make_repo --no-state
  add_drift 21
  # Initial commit plus 21 changes.
  assert_count_matches_cli 22
  render_fix
  assert_wiki_nudge 22
}

@test "an all-zero last_evaluated_sha counts the whole history, below the threshold here" {
  make_repo --no-state
  write_state 0000000000000000000000000000000000000000
  git -C "$FIX" add wiki/.state.json
  git -C "$FIX" commit --quiet -m "wiki: sync through 0000000"
  add_drift 5
  assert_count_matches_cli 6
  render_fix
  assert_no_wiki_nudge
}

@test "a state file with no last_evaluated_sha counts the whole history" {
  make_repo --no-state
  printf '{}\n' > "$FIX/wiki/.state.json"
  git -C "$FIX" add wiki/.state.json
  git -C "$FIX" commit --quiet -m "wiki: lint through 0000000"
  add_drift 24
  assert_count_matches_cli 25
  render_fix
  assert_wiki_nudge 25
}

@test "an orphaned sha with a resolvable last_evaluated_at counts from the dated base" {
  make_repo --no-state
  # The early history is dated January; the 20 later commits are dated March.
  # The orphaned state's last_evaluated_at falls between, so the recovery base
  # is the last January commit and exactly the later commits count.
  GIT_AUTHOR_DATE="2026-01-15T00:00:00Z" GIT_COMMITTER_DATE="2026-01-15T00:00:00Z" add_commit "feat: early"
  write_state aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2026-02-01T00:00:00Z
  git -C "$FIX" add wiki/.state.json
  GIT_AUTHOR_DATE="2026-01-16T00:00:00Z" GIT_COMMITTER_DATE="2026-01-16T00:00:00Z" \
    git -C "$FIX" commit --quiet -m "wiki: sync through aaaaaaa"
  for i in $(seq 1 20); do
    GIT_AUTHOR_DATE="2026-03-01T00:00:00Z" GIT_COMMITTER_DATE="2026-03-01T00:00:00Z" add_commit "feat: late $i"
  done
  assert_count_matches_cli 20
  render_fix
  assert_wiki_nudge 20
}

# ---------- refresher failure paths ----------

@test "a failing wiki state call keeps the previous cached count" {
  make_repo
  printf '{"checkedAt":0,"wikiDriftCount":30}' > "$FIX/.gaia/local/cache/shared/update-check.json"
  run env MOCK_WIKI_EXIT=1 HOME="$TMP_HOME" bash "$FIX/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cached_wiki_count)" = "30" ]
}

@test "empty output, unparseable output, and a non-integer drift_count each keep the previous count" {
  make_repo
  for out in '' 'not json' '{"drift_count":"many"}' '{"drift_count":-4}' '{"drift_count":null}' '{}'; do
    printf '{"checkedAt":0,"wikiDriftCount":30}' > "$FIX/.gaia/local/cache/shared/update-check.json"
    run env MOCK_WIKI_OUT="$out" HOME="$TMP_HOME" bash "$FIX/.gaia/scripts/check-updates.sh"
    [ "$status" -eq 0 ]
    [ "$(cached_wiki_count)" = "30" ] || return 1
  done
  true
}

@test "an absent gaia binary keeps the previous cached count" {
  make_repo
  printf '{"checkedAt":0,"wikiDriftCount":30}' > "$FIX/.gaia/local/cache/shared/update-check.json"
  rm -f "$FIX/.gaia/cli/gaia"
  run env HOME="$TMP_HOME" bash "$FIX/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cached_wiki_count)" = "30" ]
}

@test "with no prior cache and a failing binary, 0 is written rather than omitted" {
  make_repo
  [ ! -f "$FIX/.gaia/local/cache/shared/update-check.json" ]
  run env MOCK_WIKI_EXIT=1 HOME="$TMP_HOME" bash "$FIX/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  jq -e 'has("wikiDriftCount")' "$FIX/.gaia/local/cache/shared/update-check.json" >/dev/null
  [ "$(cached_wiki_count)" = "0" ]
}

@test "a non-numeric previous cached value is read as 0, never carried" {
  make_repo
  printf '{"checkedAt":0,"wikiDriftCount":"abc"}' > "$FIX/.gaia/local/cache/shared/update-check.json"
  run env MOCK_WIKI_EXIT=1 HOME="$TMP_HOME" bash "$FIX/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cached_wiki_count)" = "0" ]
}

@test "the no-jq printf fallback branch writes a wikiDriftCount key" {
  make_repo
  run env PATH="$(path_shim_without jq)" HOME="$TMP_HOME" bash "$FIX/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  grep -qE '"wikiDriftCount":[0-9]+' "$FIX/.gaia/local/cache/shared/update-check.json"
}
