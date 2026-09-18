#!/usr/bin/env bats

# Tests for the review-aware `/gaia-harden` nudge: the refresher
# (.gaia/scripts/check-updates.sh) composes `hardenNudgeReason` from
# `harden-tally`'s emitted JSON (README C6 at .gaia/local/specs/SPEC-084/plan),
# and the statusline (.gaia/statusline/gaia-statusline.sh) renders that cached
# reason without ever reading the review snapshot itself.
#
# The statusline half mirrors harden-unclassified-segment.bats: a MAIN git
# checkout with setup marked complete and no gaia-init gate file, so the
# right-side indicators are eligible to render; HOME points at an empty dir so
# left-side delegation stays inert. The refresher half runs a real copy of
# check-updates.sh against an isolated .gaia tree with a mock `gaia` binary
# whose `harden-tally` prints $MOCK_TALLY_JSON verbatim, so each test supplies
# its own C6-shaped JSON, and a stub `gh` so `gaiaLatest` never makes a real
# network call. REFRESH_ROOT also carries `.gaia/local/harden/`, the review
# snapshot's directory, since the race check reads a file there.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # shellcheck source=.gaia/tests/helpers/path.sh
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"

  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  CHECK_UPDATES_SRC=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)/check-updates.sh

  # ---- statusline fixture ----
  MAIN=$(mktemp -d -t gaia-sl-hreason-XXXXXX)
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

  TMP_HOME=$(mktemp -d -t gaia-sl-hreason-home-XXXXXX)

  # ---- refresher fixture ----
  REFRESH_ROOT=$(mktemp -d -t gaia-cu-hreason-XXXXXX)
  mkdir -p "$REFRESH_ROOT/.gaia/scripts" "$REFRESH_ROOT/.gaia/cli" \
    "$REFRESH_ROOT/.gaia/local/cache/shared" "$REFRESH_ROOT/.gaia/local/harden"
  cp "$CHECK_UPDATES_SRC" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  chmod +x "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  write_mock_gaia "$REFRESH_ROOT/.gaia/cli/gaia"

  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  export MOCK_SNAPSHOT_FILE="$REFRESH_ROOT/.gaia/local/harden/reviewed.json"

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  write_stub_gh "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  [ -n "${REFRESH_ROOT:-}" ] && rm -rf "$REFRESH_ROOT" || true
  return 0
}

# A `gaia` binary stub answering the two subcommands check-updates.sh calls:
# `update-deps run --emit-updates <file>` (writes an empty plan) and
# `harden-tally` (prints $MOCK_TALLY_JSON verbatim, so each test supplies its
# own C6-shaped payload). $MOCK_REWRITE_SNAPSHOT_BEFORE / _AFTER, when set,
# write that literal content to $MOCK_SNAPSHOT_FILE before / after printing
# the tally -- the two race-window shapes tests 8 and 9 drive.
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
    if [ -n "${MOCK_REWRITE_SNAPSHOT_BEFORE:-}" ]; then
      printf '%s' "$MOCK_REWRITE_SNAPSHOT_BEFORE" > "$MOCK_SNAPSHOT_FILE"
    fi
    printf '%s' "$MOCK_TALLY_JSON"
    if [ -n "${MOCK_REWRITE_SNAPSHOT_AFTER:-}" ]; then
      printf '%s' "$MOCK_REWRITE_SNAPSHOT_AFTER" > "$MOCK_SNAPSHOT_FILE"
    fi
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

# Runs a fresh refresh: clears the cache first (so the TTL gate's prev-read
# never blocks a second call inside one @test) and, when $2 is given, seeds
# the snapshot file with it first; an omitted $2 leaves no snapshot file.
run_refresher() {
  local tally="$1" snapshot="${2:-}"
  rm -f "$CACHE_FILE"
  if [ -n "$snapshot" ]; then
    printf '%s' "$snapshot" > "$MOCK_SNAPSHOT_FILE"
  else
    rm -f "$MOCK_SNAPSHOT_FILE"
  fi
  run env MOCK_TALLY_JSON="$tally" bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
}

# Same as run_refresher, but returns the resulting hardenNudgeReason on
# stdout instead of leaving $status/$output for the caller to inspect.
harden_reason_for() {
  run_refresher "$1" "$2"
  [ "$status" -eq 0 ] || return 1
  jq -r '.hardenNudgeReason' "$CACHE_FILE"
}

# Render MAIN's statusline with a payload whose current_dir is MAIN.
render_statusline() {
  local json
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
}

# Copy the refresher's own written cache into MAIN, then render against it.
render_statusline_against_refresher_cache() {
  cp "$CACHE_FILE" "$MAIN/.gaia/local/cache/shared/update-check.json"
  render_statusline
}

# 1. No snapshot, byte identity (UAT-001) -------------------------------------

@test "no snapshot: byte identity with the old-style cache, plural count (UAT-001)" {
  run_refresher '{"candidate_count":2,"unclassified":{"distinct_pr_count":5,"pr_numbers":[1],"area_tags":[],"severity_max":"info"},"gh_ok":true,"window_days":90,"snapshot_present":false,"snapshot_reviewed_at":null,"triggers":[]}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "2 recurring patterns, 5 unclassified" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-harden (2 recurring patterns, 5 unclassified)" <<<"$output"
  new_segment=$(grep -oE 'Run /gaia-harden \([^)]*\)' <<<"$output")

  printf '{"hardenCandidateCount":2,"hardenUnclassifiedCount":5}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  render_statusline
  [ "$status" -eq 0 ]
  old_segment=$(grep -oE 'Run /gaia-harden \([^)]*\)' <<<"$output")
  [ "$new_segment" = "$old_segment" ]
}

@test "no snapshot: byte identity with the old-style cache, singular count (UAT-001)" {
  run_refresher '{"candidate_count":1,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":false,"snapshot_reviewed_at":null,"triggers":[]}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "1 recurring pattern" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  new_segment=$(grep -oE 'Run /gaia-harden \([^)]*\)' <<<"$output")
  [ "$new_segment" = "Run /gaia-harden (1 recurring pattern)" ]

  printf '{"hardenCandidateCount":1,"hardenUnclassifiedCount":0}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  render_statusline
  [ "$status" -eq 0 ]
  old_segment=$(grep -oE 'Run /gaia-harden \([^)]*\)' <<<"$output")
  [ "$new_segment" = "$old_segment" ]
}

# 2. Pre-SPEC tally shape ------------------------------------------------------

@test "a tally with no snapshot_present key at all composes today's text" {
  run_refresher '{"candidate_count":3,"unclassified":null,"gh_ok":true,"window_days":90}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "3 recurring patterns" ]
}

# 3. Snapshot present, no triggers (UAT-003) -----------------------------------

@test "snapshot present with no triggers composes an empty reason (UAT-003)" {
  run_refresher \
    '{"candidate_count":2,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[]}' \
    '{"reviewed_at":"T"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-harden" <<<"$output" && return 1
  true
}

# 4. Exact trigger texts -------------------------------------------------------

@test "exact trigger texts, joined in the fixed order" {
  local snap='{"reviewed_at":"T"}'

  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"new_class","finding_class":"holistic/a"}]}' "$snap")" = "1 new pattern" ]
  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"new_class","finding_class":"holistic/a"},{"type":"new_class","finding_class":"holistic/b"}]}' "$snap")" = "2 new patterns" ]
  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"rising_class","finding_class":"holistic/overclaimed-guarantee"}]}' "$snap")" = "overclaimed-guarantee rising" ]
  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"rising_class","finding_class":"holistic/swallowed-error"}]}' "$snap")" = "swallowed-error rising" ]
  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"rising_unclassified"}]}' "$snap")" = "unclassified rising" ]
  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"schema_change"}]}' "$snap")" = "tally changed" ]
  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"rising_class","finding_class":"A"}]}' "$snap")" = "A rising" ]

  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"new_class","finding_class":"C"},{"type":"rising_class","finding_class":"holistic/drifting-duplicate"}]}' "$snap")" = "1 new pattern, drifting-duplicate rising" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-harden (1 new pattern, drifting-duplicate rising)" <<<"$output"
  [ "$(grep -oF -- "Run /gaia-harden" <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]

  [ "$(harden_reason_for '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"schema_change"},{"type":"new_class","finding_class":"C"},{"type":"rising_class","finding_class":"a"},{"type":"rising_unclassified"}]}' "$snap")" = "tally changed, 1 new pattern, a rising, unclassified rising" ]
}

# 5. Positive control (directive 13) ------------------------------------------

@test "positive control: a hand-written cache with hardenNudgeReason renders it" {
  printf '{"hardenNudgeReason":"1 new pattern"}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  render_statusline
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-harden (1 new pattern)" <<<"$output"
}

# 6. Reason key governs when present -------------------------------------------

@test "the reason key governs rendering even when its value is empty" {
  printf '{"hardenNudgeReason":"","hardenCandidateCount":4,"hardenUnclassifiedCount":2}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  render_statusline
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-harden" <<<"$output" && return 1
  true
}

# 7. gh_ok false keeps the previous reason -------------------------------------

@test "gh_ok false keeps the previous reason, including an already-empty one (UAT-016)" {
  printf '{"checkedAt":0,"hardenNudgeReason":"1 new pattern"}' > "$CACHE_FILE"
  run env MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":false,"window_days":90}' bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "1 new pattern" ]

  printf '{"checkedAt":0,"hardenNudgeReason":""}' > "$CACHE_FILE"
  run env MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":false,"window_days":90}' bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-harden" <<<"$output" && return 1
  true
}

# 7a. Upgrade window, legacy cache and gh_ok false (AUDIT directive 8) --------

@test "upgrade window: a legacy cache with gh_ok false seeds today's count text" {
  printf '{"checkedAt":0,"hardenCandidateCount":2,"hardenUnclassifiedCount":5}' > "$CACHE_FILE"
  run env MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":false,"window_days":90}' bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "2 recurring patterns, 5 unclassified" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  new_segment=$(grep -oE 'Run /gaia-harden \([^)]*\)' <<<"$output")
  [ "$new_segment" = "Run /gaia-harden (2 recurring patterns, 5 unclassified)" ]

  # Refusal proof: mutate the legacy-seed line the main assertion depends on
  # and confirm the same assertion now fails, so the pass above is not a
  # fallback that always renders counts regardless of this seed.
  # shellcheck disable=SC2016 # single-quoted on purpose: this is the literal
  # source line to grep and sed for, not an expression to expand here.
  anchor='prev_harden_reason=$(harden_count_reason "$prev_harden_count" "$prev_harden_unclassified")'
  count=$(grep -cF -- "$anchor" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh")
  [ "$count" -eq 1 ]
  # The mutated copy has to live beside the original, under
  # .gaia/scripts/: check-updates.sh derives GAIA_DIR/PROJECT_ROOT from its
  # own directory, so running a copy from anywhere else resolves every path
  # (the cache, the mock gaia binary) against the wrong tree.
  broken="$REFRESH_ROOT/.gaia/scripts/check-updates-broken.sh"
  sed "s|${anchor}|prev_harden_reason=\"\"|" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" > "$broken"
  chmod +x "$broken"

  printf '{"checkedAt":0,"hardenCandidateCount":2,"hardenUnclassifiedCount":5}' > "$CACHE_FILE"
  run env MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":false,"window_days":90}' bash "$broken"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-harden" <<<"$output" && return 1
  true
}

# 8. Race: snapshot token changes during the refresh (UAT-022) ----------------

@test "race: the snapshot token changes during the refresh (UAT-022)" {
  printf '{"reviewed_at":"X"}' > "$MOCK_SNAPSHOT_FILE"
  run env \
    MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"X","triggers":[{"type":"new_class","finding_class":"holistic/a"}]}' \
    MOCK_REWRITE_SNAPSHOT_AFTER='{"reviewed_at":"Y"}' \
    bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "" ]
  [ "$(jq -r '.checkedAt' "$CACHE_FILE")" = "0" ]

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-harden" <<<"$output" && return 1
  true
}

# 9. Race: the T0 arm, review lands before the tally read ---------------------

@test "race: the review lands before the tally read (T0 arm)" {
  printf '{"reviewed_at":"X"}' > "$MOCK_SNAPSHOT_FILE"
  printf '{"checkedAt":0,"hardenNudgeReason":"1 new pattern"}' > "$CACHE_FILE"
  run env \
    MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":false,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"Y"}' \
    MOCK_REWRITE_SNAPSHOT_BEFORE='{"reviewed_at":"Y"}' \
    bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "" ]
  [ "$(jq -r '.checkedAt' "$CACHE_FILE")" = "0" ]
}

# 9a. Race: arm (b) alone, the tally's own snapshot read disagrees with the
# file the script re-reads, with the file itself unchanged throughout (C7) ---

@test "race: the tally's snapshot read disagrees with the unchanged file (arm b)" {
  # The snapshot file never changes across the run, so arm (a)'s two script
  # reads agree ("X" both times) and cannot fire on its own. harden-tally's
  # reported snapshot_reviewed_at ("Q") disagrees with that file anyway,
  # simulating its own snapshot read landing on a different value than the
  # file the script re-reads before the write.
  printf '{"reviewed_at":"X"}' > "$MOCK_SNAPSHOT_FILE"
  run env \
    MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"Q","triggers":[{"type":"new_class","finding_class":"holistic/a"}]}' \
    bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "" ]
  [ "$(jq -r '.checkedAt' "$CACHE_FILE")" = "0" ]

  # Refusal proof: drop arm (b) from the race check in a scratch copy that
  # lives beside the original (check-updates.sh derives GAIA_DIR/PROJECT_ROOT
  # from its own dirname, so a copy elsewhere resolves every path against the
  # wrong tree) and confirm the same inputs now compose and keep the reason,
  # so the pass above is not a fallback that always clears it.
  search='|| { [ "$snapshot_present" = "true" ] && [ "$snapshot_token_now" != "$snapshot_reviewed_at" ]; }; then'
  # shellcheck disable=SC2016 # single-quoted on purpose: this is the literal
  # replacement line to write, not an expression to expand here.
  neutered_line='; then'
  count=$(grep -cF -- "$search" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh")
  [ "$count" -eq 1 ]
  broken="$REFRESH_ROOT/.gaia/scripts/check-updates-broken.sh"
  awk -v s="$search" -v new="$neutered_line" \
    '{ if (index($0, s) > 0) print new; else print }' \
    "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" > "$broken"
  chmod +x "$broken"

  rm -f "$CACHE_FILE"
  printf '{"reviewed_at":"X"}' > "$MOCK_SNAPSHOT_FILE"
  run env \
    MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"Q","triggers":[{"type":"new_class","finding_class":"holistic/a"}]}' \
    bash "$broken"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "1 new pattern" ]
}

# 10. No race, same inputs: refusal-state control for 8 and 9 -----------------

@test "no race: identical inputs to the race tests, without the rewrite" {
  printf '{"reviewed_at":"X"}' > "$MOCK_SNAPSHOT_FILE"
  run env \
    MOCK_TALLY_JSON='{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"X","triggers":[{"type":"new_class","finding_class":"holistic/a"}]}' \
    bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "1 new pattern" ]
  checked_at=$(jq -r '.checkedAt' "$CACHE_FILE")
  [ "$checked_at" != "0" ]
}

# 11. Malformed snapshot never suppresses (UAT-017) ----------------------------

@test "a malformed or schema-invalid snapshot never suppresses the render (UAT-017)" {
  printf '{"broken":' > "$MOCK_SNAPSHOT_FILE"
  run env MOCK_TALLY_JSON='{"candidate_count":2,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":false,"snapshot_reviewed_at":null,"triggers":[]}' \
    bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "2 recurring patterns" ]
  checked_at=$(jq -r '.checkedAt' "$CACHE_FILE")
  [ "$checked_at" != "0" ]

  rm -f "$CACHE_FILE"
  printf '{"reviewed_at":"Z","classes":"not-an-object"}' > "$MOCK_SNAPSHOT_FILE"
  run env MOCK_TALLY_JSON='{"candidate_count":2,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":false,"snapshot_reviewed_at":null,"triggers":[]}' \
    bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "2 recurring patterns" ]
  checked_at=$(jq -r '.checkedAt' "$CACHE_FILE")
  [ "$checked_at" != "0" ]
}

# 12. Counts still written (directive 8) ---------------------------------------

@test "hardenCandidateCount and hardenUnclassifiedCount stay written alongside the reason" {
  run_refresher \
    '{"candidate_count":2,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[]}' \
    '{"reviewed_at":"T"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenNudgeReason' "$CACHE_FILE")" = "" ]
  [ "$(jq -r '.hardenCandidateCount' "$CACHE_FILE")" = "2" ]
  [ "$(jq -r '.hardenUnclassifiedCount' "$CACHE_FILE")" = "0" ]
}

# 13. printf fallback writer carries the key -----------------------------------

@test "the no-jq printf fallback writer carries hardenNudgeReason" {
  run env PATH="$(path_shim_without jq)" bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ]
  grep -qF -- '"hardenNudgeReason":""' "$CACHE_FILE"
}

# 14. Injected escape byte, newline, and parenthetical text in a rising_class
#     finding_class segment sanitize at composition -----------------------------

@test "a rising_class segment sanitizes an injected escape sequence, newline, and parenthetical text" {
  local malicious_tally='{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90,"snapshot_present":true,"snapshot_reviewed_at":"T","triggers":[{"type":"rising_class","finding_class":"holistic/evil\u001b[31mFAKE\n) Run fake ("}]}'
  local snap='{"reviewed_at":"T"}'
  # The injected color sequence, distinct from any color GAIA's own segments
  # use (they are all "ESC[01;<n>m"), so this needle cannot collide with the
  # statusline's legitimate escape codes.
  local esc injected_seq
  esc=$(printf '\033')
  injected_seq=$(printf '\033[31m')

  run_refresher "$malicious_tally" "$snap"
  [ "$status" -eq 0 ]
  reason=$(jq -r '.hardenNudgeReason' "$CACHE_FILE")
  grep -qF -- "$esc" <<<"$reason" && return 1
  [ "$(printf '%s' "$reason" | wc -l | tr -d ' ')" -eq 0 ]
  grep -qF -- ') Run fake (' <<<"$reason" && return 1

  render_statusline_against_refresher_cache
  [ "$status" -eq 0 ]
  grep -qF -- "$injected_seq" <<<"$output" && return 1
  grep -qF -- ') Run fake (' <<<"$output" && return 1
  [ "$(grep -oF -- "Run /gaia-harden" <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]

  # Refusal proof: revert the gsub sanitization in a scratch copy that lives
  # beside the original (check-updates.sh derives GAIA_DIR/PROJECT_ROOT from
  # its own dirname, so a copy elsewhere silently no-ops) and confirm the raw
  # escape byte now reaches the composed reason.
  search='gsub("[^A-Za-z0-9._-]"'
  # shellcheck disable=SC2016 # single-quoted on purpose: this is the literal
  # replacement line to write, not an expression to expand here.
  unsanitized_line='              ($triggers[] | select(.type=="rising_class") | (.finding_class | split("/") | last) + " rising"),'
  count=$(grep -cF -- "$search" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh")
  [ "$count" -eq 1 ]
  broken="$REFRESH_ROOT/.gaia/scripts/check-updates-broken.sh"
  awk -v s="$search" -v new="$unsanitized_line" \
    '{ if (index($0, s) > 0) print new; else print }' \
    "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" > "$broken"
  chmod +x "$broken"

  rm -f "$CACHE_FILE"
  printf '%s' "$snap" > "$MOCK_SNAPSHOT_FILE"
  run env MOCK_TALLY_JSON="$malicious_tally" bash "$broken"
  [ "$status" -eq 0 ]
  broken_reason=$(jq -r '.hardenNudgeReason' "$CACHE_FILE")
  grep -qF -- "$esc" <<<"$broken_reason"
}

# 15. A cached reason already carrying control bytes strips them at render ------

@test "the statusline strips control bytes already present in the cached reason" {
  # Only control bytes are this layer's job (mandate: strip control bytes from
  # the cached reason before printing it); an unsanitized printable segment
  # like "FAKE" or stray parentheses is the composition layer's job (test 14),
  # so this fixture carries only a control-byte payload: an injected color
  # escape and a newline.
  local injected_seq
  injected_seq=$(printf '\033[31m')
  printf '%s' '{"hardenNudgeReason":"1 new pattern\u001b[31mFAKE\n more"}' \
    > "$MAIN/.gaia/local/cache/shared/update-check.json"

  render_statusline
  [ "$status" -eq 0 ]
  grep -qF -- "$injected_seq" <<<"$output" && return 1
  [ "${#lines[@]}" -eq 1 ]
  grep -qF -- "Run /gaia-harden (1 new pattern" <<<"$output"
  [ "$(grep -oF -- "Run /gaia-harden" <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]

  # Refusal proof: drop the control-byte stripping in a scratch copy that
  # lives beside the original (gaia-statusline.sh resolves PROJECT_ROOT from
  # its own dirname when no main-root resolver is present, as here, so a copy
  # elsewhere reads the wrong cache and proves nothing) and confirm the raw
  # escape byte now reaches the render.
  search='tr -d'
  # shellcheck disable=SC2016 # single-quoted on purpose: this is the literal
  # replacement line to write, not an expression to expand here.
  broken_line='      harden_reason="${harden_reason_raw#?}"'
  count=$(grep -cF -- "$search" "$MAIN/.gaia/statusline/gaia-statusline.sh")
  [ "$count" -eq 1 ]
  broken="$MAIN/.gaia/statusline/gaia-statusline-broken.sh"
  awk -v s="$search" -v new="$broken_line" \
    '{ if (index($0, s) > 0) print new; else print }' \
    "$MAIN/.gaia/statusline/gaia-statusline.sh" > "$broken"
  chmod +x "$broken"

  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$broken'"
  [ "$status" -eq 0 ]
  grep -qF -- "$injected_seq" <<<"$output"
}
