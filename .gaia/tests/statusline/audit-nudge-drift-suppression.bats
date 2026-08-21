#!/usr/bin/env bats

# Tests for the `project_drift` arm of the statusline audit nudge and the debt
# cache it consults.
#
# `project_drift` is the fourth and lowest-priority `auditNudge` signal. Unlike
# the three above it, it is a live measurement of committed auto-load file sizes
# rather than a debounce keyed to whether an audit ran, so an audit that files an
# over-budget file as tech-debt instead of trimming it leaves the nudge firing
# for a condition already tracked in the other channel.
#
# Two halves:
#   - the refresher (.gaia/scripts/debt-count-refresh.sh) emits `coveredPaths`,
#     the repo-relative paths carrying an open `tech-debt` issue, parsed out of
#     each issue body's `gaia-debt-key` comment;
#   - the checker (.gaia/scripts/check-updates.sh) suppresses `project_drift` for
#     a covered path, records the size it suppressed at, and re-fires when the
#     file grows past that baseline.
#
# The suppression key is shared state (an open issue); the growth baseline is
# machine-local, which is sound because it only ever UN-suppresses. A local
# baseline can add a nudge and can never silence one for anyone else.
#
# Both halves run a real copy of the script under test against an isolated tree,
# with a stub `gh` so nothing reaches the network.

setup() {
  SCRIPTS_SRC=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)
  CHECK_UPDATES_SRC="$SCRIPTS_SRC/check-updates.sh"
  DEBT_REFRESH_SRC="$SCRIPTS_SRC/debt-count-refresh.sh"

  ROOT=$(mktemp -d -t gaia-drift-XXXXXX)
  mkdir -p "$ROOT/.gaia/scripts" "$ROOT/.gaia/cli" \
    "$ROOT/.gaia/local/cache/shared" "$ROOT/.gaia/local/debt" \
    "$ROOT/.claude/rules" "$ROOT/wiki"
  cp "$CHECK_UPDATES_SRC" "$ROOT/.gaia/scripts/check-updates.sh"
  cp "$DEBT_REFRESH_SRC" "$ROOT/.gaia/scripts/debt-count-refresh.sh"
  chmod +x "$ROOT/.gaia/scripts/check-updates.sh" "$ROOT/.gaia/scripts/debt-count-refresh.sh"
  write_mock_gaia "$ROOT/.gaia/cli/gaia"

  # Every budgeted file starts comfortably UNDER budget, so each test opts a
  # single file over and nothing else can fire.
  write_words "$ROOT/CLAUDE.md" 10
  write_words "$ROOT/wiki/hot.md" 10
  write_lines "$ROOT/.claude/rules/quiet.md" 5

  # HOME with no memory dir keeps the memory-delta arm at 0; no audit dir keeps
  # the staleness arm at 0. project_drift is then the only signal that can fire.
  TMP_HOME=$(mktemp -d -t gaia-drift-home-XXXXXX)

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  MOCK_ISSUES="$BATS_TEST_TMPDIR/issues.json"
  printf '[]\n' > "$MOCK_ISSUES"
  write_stub_gh "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"

  CACHE="$ROOT/.gaia/local/cache/shared/update-check.json"
  DEBT_CACHE="$ROOT/.gaia/local/debt/count.json"
}

teardown() {
  [ -n "${ROOT:-}" ] && rm -rf "$ROOT" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  return 0
}

# `gaia` stub answering the one subcommand check-updates.sh needs from it.
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
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}

# `gh` stub: a fixed tag for `release list`, and the fixture issue array for
# `issue list`, so neither script reaches the network.
write_stub_gh() {
  cat > "$1" <<EOF
#!/usr/bin/env bash
case "\$1" in
  release) printf 'v0.0.0\n'; exit 0 ;;
  issue) cat "$MOCK_ISSUES"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}

write_words() {
  local file="$1" n="$2" i=1
  : > "$file"
  while [ "$i" -le "$n" ]; do printf 'word ' >> "$file"; i=$((i + 1)); done
  printf '\n' >> "$file"
}

write_lines() {
  local file="$1" n="$2" i=1
  : > "$file"
  while [ "$i" -le "$n" ]; do printf 'line\n' >> "$file"; i=$((i + 1)); done
}

# Seed the debt cache with the given repo-relative covered paths.
seed_debt_cache() {
  local paths_json
  paths_json=$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -n --argjson coveredPaths "$paths_json" \
    '{schema: 1, openCount: 1, computedAt: 0, coveredPaths: $coveredPaths}' \
    > "$DEBT_CACHE"
}

# Run the checker against ROOT. Forces past the TTL gate by leaving no prior
# cache, or by whatever `checkedAt` a test wrote.
run_checker() {
  run env HOME="$TMP_HOME" bash "$ROOT/.gaia/scripts/check-updates.sh"
}

nudge() { jq -r '.auditNudge' "$CACHE"; }
nudge_reason() { jq -r '.auditNudgeReason' "$CACHE"; }
baseline_for() { jq -r --arg p "$1" '.auditDriftBaseline[$p] // "none"' "$CACHE"; }

# --- the refresher half: coveredPaths ---

@test "refresher emits coveredPaths parsed from each issue body's dedup key" {
  jq -n '[{number: 1, labels: [{name: "tech-debt"}],
           body: "<!-- gaia-debt-key: v1 class=holistic/unclassified path=CLAUDE.md line=1 -->\nbody text"}]' \
    > "$MOCK_ISSUES"
  run bash "$ROOT/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ]
  [ -f "$DEBT_CACHE" ]
  jq . "$DEBT_CACHE" >/dev/null
  [ "$(jq -r '.coveredPaths | length' "$DEBT_CACHE")" = "1" ]
  [ "$(jq -r '.coveredPaths[0]' "$DEBT_CACHE")" = "CLAUDE.md" ]
}

@test "coveredPaths keeps a claimed issue that openCount deliberately excludes" {
  jq -n '[{number: 1, labels: [{name: "tech-debt"}, {name: "in-progress"}],
           body: "<!-- gaia-debt-key: v1 class=holistic/unclassified path=CLAUDE.md line=1 -->"}]' \
    > "$MOCK_ISSUES"
  run bash "$ROOT/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ]
  # The claim label keeps it out of the nudge count...
  [ "$(jq -r '.openCount' "$DEBT_CACHE")" = "0" ]
  # ...but the issue still covers its path, so suppression must still apply.
  [ "$(jq -r '.coveredPaths[0]' "$DEBT_CACHE")" = "CLAUDE.md" ]
}

@test "coveredPaths survives a dedup-key path containing spaces" {
  jq -n '[{number: 1, labels: [{name: "tech-debt"}],
           body: "<!-- gaia-debt-key: v1 class=holistic/unclassified path=wiki/concepts/PR Merge Workflow.md line=175 -->"}]' \
    > "$MOCK_ISSUES"
  run bash "$ROOT/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coveredPaths[0]' "$DEBT_CACHE")" = "wiki/concepts/PR Merge Workflow.md" ]
}

@test "a body that only mentions the key in prose injects no covered path" {
  # The extraction anchors on the whole `<!-- gaia-debt-key:` opener rather than
  # the bare key name, because a false match here ADDS suppression, and that is
  # the one direction the shared-state argument does not cover.
  jq -n '[{number: 1, labels: [{name: "tech-debt"}],
           body: "prose discussing gaia-debt-key: v1 class=x path=CLAUDE.md line=1 with no comment wrapper"}]' \
    > "$MOCK_ISSUES"
  run bash "$ROOT/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coveredPaths | length' "$DEBT_CACHE")" = "0" ]
}

@test "refresher emits an empty coveredPaths rather than omitting the field" {
  printf '[]\n' > "$MOCK_ISSUES"
  run bash "$ROOT/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coveredPaths | type' "$DEBT_CACHE")" = "array" ]
  [ "$(jq -r '.coveredPaths | length' "$DEBT_CACHE")" = "0" ]
}

# --- the checker half: suppression ---

@test "project_drift fires when an over-budget file has no covering issue" {
  write_words "$ROOT/CLAUDE.md" 500
  run_checker
  [ "$status" -eq 0 ]
  [ "$(nudge)" = "true" ]
  [ "$(nudge_reason)" = "over budget" ]
}

@test "project_drift is suppressed when the over-budget file has a covering issue" {
  write_words "$ROOT/CLAUDE.md" 500
  seed_debt_cache "CLAUDE.md"
  run_checker
  [ "$status" -eq 0 ]
  [ "$(nudge)" = "false" ]
  [ "$(nudge_reason)" = "" ]
}

@test "suppression records the size it suppressed at as the growth baseline" {
  write_words "$ROOT/CLAUDE.md" 500
  seed_debt_cache "CLAUDE.md"
  run_checker
  [ "$status" -eq 0 ]
  [ "$(baseline_for 'CLAUDE.md')" = "500" ]
}

@test "growth past the recorded baseline re-fires the nudge" {
  write_words "$ROOT/CLAUDE.md" 500
  seed_debt_cache "CLAUDE.md"
  run_checker
  [ "$(nudge)" = "false" ]

  # Grow the file and force past the TTL gate so the next run recomputes.
  write_words "$ROOT/CLAUDE.md" 900
  jq '.checkedAt = 0' "$CACHE" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
  run_checker
  [ "$status" -eq 0 ]
  [ "$(nudge)" = "true" ]
  [ "$(nudge_reason)" = "over budget" ]
  # The baseline must NOT advance to the grown size, or the nudge would fire
  # once and then go quiet while the file is still unfixed.
  [ "$(baseline_for 'CLAUDE.md')" = "500" ]
}

@test "a drifting rule file does not stop the scan before a later covered file is baselined" {
  # The rule loop must not exit early. Glob order is alphabetical, so an early
  # exit on the first drifting file leaves the covered file after it unmeasured,
  # and its baseline is then taken only once the earlier file is fixed, at
  # whatever size it had grown to by then.
  write_lines "$ROOT/.claude/rules/aaa-uncovered.md" 250
  write_lines "$ROOT/.claude/rules/zzz-covered.md" 300
  seed_debt_cache ".claude/rules/zzz-covered.md"
  run_checker
  [ "$status" -eq 0 ]
  [ "$(nudge)" = "true" ]
  [ "$(nudge_reason)" = "over budget" ]
  [ "$(baseline_for '.claude/rules/zzz-covered.md')" = "300" ]
}

@test "the baseline is dropped once the covering issue closes" {
  write_words "$ROOT/CLAUDE.md" 500
  seed_debt_cache "CLAUDE.md"
  run_checker
  [ "$(baseline_for 'CLAUDE.md')" = "500" ]

  # Issue closed: the path leaves coveredPaths. The stale baseline must not
  # linger, or a later re-filing would inherit a baseline nobody measured.
  seed_debt_cache
  jq '.checkedAt = 0' "$CACHE" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
  run_checker
  [ "$status" -eq 0 ]
  [ "$(nudge)" = "true" ]
  [ "$(baseline_for 'CLAUDE.md')" = "none" ]
}

@test "an absent debt cache suppresses nothing" {
  write_words "$ROOT/CLAUDE.md" 500
  rm -f "$DEBT_CACHE"
  run_checker
  [ "$status" -eq 0 ]
  [ "$(nudge)" = "true" ]
}

@test "a covered path that is under budget neither fires nor records a baseline" {
  seed_debt_cache "CLAUDE.md"
  run_checker
  [ "$status" -eq 0 ]
  [ "$(nudge)" = "false" ]
  [ "$(baseline_for 'CLAUDE.md')" = "none" ]
}
