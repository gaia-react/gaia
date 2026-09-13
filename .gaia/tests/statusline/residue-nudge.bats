#!/usr/bin/env bats

# Tests for the aged-residue delivery channel: the statusline's
# `/gaia-residue` segment, and the refresher (.gaia/scripts/check-updates.sh)
# that writes `residueCandidateCount` from `residue-tally --count-only`'s
# `aged_candidate_count` / `gh_ok` / `count_approximate` fields.
#
# The statusline half mirrors harden-unclassified-segment.bats: a MAIN git
# checkout with setup marked complete and no gaia-init gate file, so the
# right-side indicators are eligible to render; HOME points at an empty dir
# so left-side delegation stays inert. The refresher half runs a real copy of
# check-updates.sh against an isolated .gaia tree with a mock `gaia` binary
# answering `residue-tally` (and the `update-deps` / `harden-tally`
# subcommands the same refresher also calls), a stub `gh` so `gaiaLatest`
# never makes a real network call, and a logging `git` shim that delegates to
# the real binary while recording every invocation.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # shellcheck source=.gaia/tests/helpers/path.sh
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"

  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  CHECK_UPDATES_SRC=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)/check-updates.sh

  # ---- statusline fixture ----
  MAIN=$(mktemp -d -t gaia-sl-residue-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/local/cache/shared"
  cp "$STATUSLINE_SRC/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"

  TMP_HOME=$(mktemp -d -t gaia-sl-residue-home-XXXXXX)

  # ---- refresher fixture ----
  REFRESH_ROOT=$(mktemp -d -t gaia-cu-residue-XXXXXX)
  mkdir -p "$REFRESH_ROOT/.gaia/scripts" "$REFRESH_ROOT/.gaia/cli" "$REFRESH_ROOT/.gaia/local/cache/shared"
  cp "$CHECK_UPDATES_SRC" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  chmod +x "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"

  RESIDUE_ARGV_LOG="$BATS_TEST_TMPDIR/residue-argv.log"
  : > "$RESIDUE_ARGV_LOG"
  export RESIDUE_ARGV_LOG
  GIT_LOG="$BATS_TEST_TMPDIR/git-invocations.log"
  : > "$GIT_LOG"
  export GIT_LOG

  write_mock_gaia "$REFRESH_ROOT/.gaia/cli/gaia"

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  write_stub_gh "$GH_BIN/gh"
  write_logging_git "$GH_BIN/git"
  export PATH="$GH_BIN:$PATH"
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  [ -n "${REFRESH_ROOT:-}" ] && rm -rf "$REFRESH_ROOT" || true
  return 0
}

# A `gaia` binary stub answering the subcommands check-updates.sh
# calls: `update-deps run --emit-updates <file>` and `harden-tally` (both
# no-op stand-ins, irrelevant to this suite's assertions), and
# `residue-tally` (records its argv to $RESIDUE_ARGV_LOG, then answers per
# $MOCK_RESIDUE_EXIT / $MOCK_RESIDUE_BAD_JSON / $MOCK_RESIDUE_GH_OK /
# $MOCK_RESIDUE_COUNT / $MOCK_RESIDUE_APPROX from the test's environment).
write_mock_gaia() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  update-deps)
    out=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --emit-updates) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$out" ] && printf '{"actionable_count":0}' > "$out"
    exit 0
    ;;
  harden-tally)
    printf '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90}'
    exit 0
    ;;
  residue-tally)
    shift
    if [ -n "${RESIDUE_ARGV_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$RESIDUE_ARGV_LOG"
    fi
    if [ "${MOCK_RESIDUE_EXIT:-0}" != "0" ]; then
      exit 1
    fi
    if [ "${MOCK_RESIDUE_BAD_JSON:-false}" = "true" ]; then
      printf 'not json'
      exit 0
    fi
    printf '{"gh_ok":%s,"aged_candidate_count":%s,"count_approximate":%s}' \
      "${MOCK_RESIDUE_GH_OK:-true}" "${MOCK_RESIDUE_COUNT:-0}" "${MOCK_RESIDUE_APPROX:-true}"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$1"
}

# A `gh` stub answering `gh release list` with a fixed tag so gaiaLatest never
# falls through to a real `curl` network call.
write_stub_gh() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  release) printf 'v0.0.0\n'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}

# A `git` shim that logs every invocation to $GIT_LOG, then delegates to the
# real binary (resolved once, before this shim is on PATH, so `exec` cannot
# recurse into itself). RD-004's guarantee is that the refresher never
# resolves a residual's cited line, and resolution is git-fetch-shaped; this
# shim lets a test prove no `fetch` ever reaches git during the refresh.
write_logging_git() {
  local dest="$1" real_git
  real_git=$(command -v git)
  cat > "$dest" <<EOF
#!/usr/bin/env bash
if [ -n "\${GIT_LOG:-}" ]; then
  printf '%s\n' "\$*" >> "\$GIT_LOG"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$dest"
}

# Write the given cache JSON verbatim, then render MAIN's statusline against
# it with a payload whose current_dir is MAIN.
run_statusline_with_cache() {
  local cache_json="$1" json
  printf '%s' "$cache_json" > "$MAIN/.gaia/local/cache/shared/update-check.json"
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
}

# Render against a scratch copy of the statusline with RESIDUE_NUDGE_THRESHOLD
# lowered to 1, so the noun-agreement branch is exercised at a count (1) that
# sits below the real threshold.
run_statusline_lowered_threshold() {
  local cache_json="$1" lowered="$MAIN/.gaia/statusline/gaia-statusline-lowered.sh" json
  sed 's/RESIDUE_NUDGE_THRESHOLD=5/RESIDUE_NUDGE_THRESHOLD=1/' \
    "$STATUSLINE_SRC/gaia-statusline.sh" > "$lowered"
  chmod +x "$lowered"
  printf '%s' "$cache_json" > "$MAIN/.gaia/local/cache/shared/update-check.json"
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$lowered'"
}

# --- Rendering ---

@test "statusline renders the plural residue segment at 8" {
  run_statusline_with_cache '{"residueCandidateCount":8}'
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-residue (8 aged residuals)" <<<"$output"
}

@test "statusline renders the singular noun at 1, threshold lowered to isolate the noun branch" {
  run_statusline_lowered_threshold '{"residueCandidateCount":1}'
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-residue (1 aged residual)" <<<"$output"
}

@test "the count threshold boundary: 4 renders nothing, 5 renders the segment" {
  run_statusline_with_cache '{"residueCandidateCount":4}'
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-residue" <<<"$output" && return 1

  run_statusline_with_cache '{"residueCandidateCount":5}'
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-residue (5 aged residuals)" <<<"$output"
}

@test "0, an absent field, an empty string, and a non-numeric value each render no segment" {
  for cache in '{"residueCandidateCount":0}' '{}' '{"residueCandidateCount":""}' '{"residueCandidateCount":"abc"}'; do
    run_statusline_with_cache "$cache"
    [ "$status" -eq 0 ]
    grep -qF -- "gaia-residue" <<<"$output" && return 1
  done
  true
}

@test "a missing cache file renders no segment and exits 0" {
  rm -f "$MAIN/.gaia/local/cache/shared/update-check.json"
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-residue" <<<"$output" && return 1
  true
}

@test "a present cache with jq unavailable renders no segment and exits 0" {
  printf '{"residueCandidateCount":8}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" PATH="$(path_shim_without jq)" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-residue" <<<"$output" && return 1
  true
}

@test "the residue segment coexists with harden, audit, and debt without disturbing them" {
  mkdir -p "$MAIN/.gaia/local/debt"
  printf '{"openCount":3}' > "$MAIN/.gaia/local/debt/count.json"
  run_statusline_with_cache '{"hardenCandidateCount":2,"auditNudge":true,"auditNudgeReason":"stale","residueCandidateCount":8}'
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-harden (2 recurring patterns)" <<<"$output"
  grep -qF -- "Run /gaia-audit (stale)" <<<"$output"
  grep -qF -- "Run /gaia-debt (3 issues)" <<<"$output"
  grep -qF -- "Run /gaia-residue (8 aged residuals)" <<<"$output"
}

# --- Refresher ---

@test "refresher writes aged_candidate_count into residueCandidateCount on a fresh run" {
  run env MOCK_RESIDUE_GH_OK=true MOCK_RESIDUE_COUNT=7 bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  [ -f "$CACHE_FILE" ]
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.residueCandidateCount' "$CACHE_FILE")" = "7" ]
}

# RD-004's whole guarantee: the refresher never resolves. Invisible without an
# argv assertion, so this pins both halves -- the flag reaches the call, and
# no git fetch happens during the refresh.
@test "the refresher invokes residue-tally with --count-only and never calls git fetch" {
  run env MOCK_RESIDUE_GH_OK=true MOCK_RESIDUE_COUNT=3 bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "--count-only" "$RESIDUE_ARGV_LOG"
  grep -qw "fetch" "$GIT_LOG" && return 1
  true
}

# Proves the argv guard above can fail (guards-must-fail): a mutated refresher
# with --count-only dropped from the call leaves the flag out of the recorded
# argv, which the same assertion the previous test relies on catches.
@test "the --count-only argv guard reds when a mutated refresher drops the flag" {
  : > "$RESIDUE_ARGV_LOG"
  broken="$BATS_TEST_TMPDIR/check-updates-broken.sh"
  sed 's/residue-tally --count-only/residue-tally/' \
    "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" > "$broken"
  chmod +x "$broken"
  run env MOCK_RESIDUE_GH_OK=true MOCK_RESIDUE_COUNT=3 bash "$broken"
  [ "$status" -eq 0 ]
  grep -qF -- "--count-only" "$RESIDUE_ARGV_LOG" && return 1
  true
}

@test "refresher preserves the previous residueCandidateCount when gh_ok is false" {
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  printf '{"checkedAt":0,"residueCandidateCount":6}' > "$CACHE_FILE"
  run env MOCK_RESIDUE_GH_OK=false MOCK_RESIDUE_COUNT=99 bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.residueCandidateCount' "$CACHE_FILE")" = "6" ]
}

@test "refresher writes the count unchanged and never writes count_approximate" {
  run env MOCK_RESIDUE_GH_OK=true MOCK_RESIDUE_COUNT=4 MOCK_RESIDUE_APPROX=true bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.residueCandidateCount' "$CACHE_FILE")" = "4" ]
  jq -e 'has("count_approximate")' "$CACHE_FILE" >/dev/null && return 1
  true
}

@test "refresher preserves the previous count when the stub exits non-zero" {
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  printf '{"checkedAt":0,"residueCandidateCount":6}' > "$CACHE_FILE"
  run env MOCK_RESIDUE_EXIT=1 bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.residueCandidateCount' "$CACHE_FILE")" = "6" ]
}

@test "refresher preserves the previous count when the stub emits unparseable JSON" {
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  printf '{"checkedAt":0,"residueCandidateCount":6}' > "$CACHE_FILE"
  run env MOCK_RESIDUE_BAD_JSON=true bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.residueCandidateCount' "$CACHE_FILE")" = "6" ]
}

@test "refresher preserves the previous count when the gaia binary is absent" {
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  printf '{"checkedAt":0,"residueCandidateCount":6}' > "$CACHE_FILE"
  rm -f "$REFRESH_ROOT/.gaia/cli/gaia"
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.residueCandidateCount' "$CACHE_FILE")" = "6" ]
}

@test "with no prior cache and a failing read, the field is written as 0 rather than omitted" {
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  [ ! -f "$CACHE_FILE" ]
  run env MOCK_RESIDUE_EXIT=1 bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  jq . "$CACHE_FILE" >/dev/null
  jq -e 'has("residueCandidateCount")' "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.residueCandidateCount' "$CACHE_FILE")" = "0" ]
}

@test "the no-jq printf fallback branch writes residueCandidateCount" {
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  run env PATH="$(path_shim_without jq)" bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ]
  grep -qE '"residueCandidateCount":[0-9]+' "$CACHE_FILE"
}

# --- Threshold provenance ---

@test "the count threshold appears exactly once as a named constant" {
  block=$(grep -A 10 'RESIDUE_NUDGE_THRESHOLD=5' "$STATUSLINE_SRC/gaia-statusline.sh")
  [ -n "$block" ]
  [ "$(grep -c 'RESIDUE_NUDGE_THRESHOLD=5' <<<"$block")" -eq 1 ]
  rest=$(grep -v 'RESIDUE_NUDGE_THRESHOLD=5' <<<"$block")
  grep -qE '(^|[^0-9])5([^0-9]|$)' <<<"$rest" && return 1
  true
}
