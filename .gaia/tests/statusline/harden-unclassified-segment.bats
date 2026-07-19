#!/usr/bin/env bats

# Tests for the classless-recurrence delivery channels of the policy-memory
# loop: the statusline's `hardenUnclassifiedCount` segment, the refresher
# (.gaia/scripts/check-updates.sh) that writes that field from `harden-tally`'s
# `unclassified` object, and the doc-grep coverage confirming:
#   - harden.md presents the unclassified signal (UAT-008, review-grep half;
#     the deterministic candidates[]-exclusion half is task-tally-core's Vitest)
#   - check-updates.sh dropped the stale "at error/warning severity" phrasing
#     (directive #6; this file is swept in Phase 2, so Phase 1's doc-grep,
#     `.gaia/tests/prose-audit/spec051-countability-prose.bats`, never touches it)
#
# The statusline half mirrors statusline-worktree.bats: a MAIN git checkout
# with setup marked complete and no gaia-init gate file, so the right-side
# indicators are eligible to render; HOME points at an empty dir so left-side
# delegation stays inert. The refresher half runs a real copy of
# check-updates.sh against an isolated .gaia tree with a mock `gaia` binary
# answering `harden-tally`, and a stub `gh` so `gaiaLatest` never makes a real
# network call.

setup() {
  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  CHECK_UPDATES_SRC=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)/check-updates.sh
  HARDEN_MD=$(cd "$BATS_TEST_DIRNAME/../../../.claude/skills/gaia/references" && pwd)/harden.md

  # ---- statusline fixture ----
  MAIN=$(mktemp -d -t gaia-sl-harden-XXXXXX)
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

  TMP_HOME=$(mktemp -d -t gaia-sl-harden-home-XXXXXX)

  # ---- refresher fixture ----
  REFRESH_ROOT=$(mktemp -d -t gaia-cu-harden-XXXXXX)
  mkdir -p "$REFRESH_ROOT/.gaia/scripts" "$REFRESH_ROOT/.gaia/cli" "$REFRESH_ROOT/.gaia/local/cache/shared"
  cp "$CHECK_UPDATES_SRC" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  chmod +x "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  write_mock_gaia "$REFRESH_ROOT/.gaia/cli/gaia"

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
# `harden-tally` (emits candidate_count 0 plus an `unclassified` object shaped
# by $MOCK_GH_OK / $MOCK_UNCLASSIFIED_COUNT from the test's environment).
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
    if [ "${MOCK_GH_OK:-true}" = "false" ]; then
      printf '{"candidate_count":0,"unclassified":null,"gh_ok":false,"window_days":90}'
    else
      printf '{"candidate_count":0,"unclassified":{"distinct_pr_count":%s,"pr_numbers":[401,405,409],"area_tags":["app/routes"],"severity_max":"suggestion"},"gh_ok":true,"window_days":90}' "${MOCK_UNCLASSIFIED_COUNT:-3}"
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

# Run MAIN's statusline with a payload whose current_dir is MAIN and a cache
# fixture holding the given hardenCandidateCount / hardenUnclassifiedCount.
run_statusline_with_cache() {
  local candidate="$1" unclassified="$2" json
  printf '{"hardenCandidateCount":%s,"hardenUnclassifiedCount":%s}' "$candidate" "$unclassified" \
    > "$MAIN/.gaia/local/cache/shared/update-check.json"
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
}

@test "statusline renders the unclassified segment when hardenUnclassifiedCount > 0" {
  run_statusline_with_cache 0 3
  [ "$status" -eq 0 ]
  grep -qF -- "Run /gaia-harden (3 unclassified recurring)" <<<"$output"
}

@test "statusline renders no harden segment when both counts are 0" {
  run_statusline_with_cache 0 0
  [ "$status" -eq 0 ]
  grep -qF -- "gaia-harden" <<<"$output" && return 1
  return 0
}

@test "refresher writes a valid hardenUnclassifiedCount field on a fresh run" {
  run env MOCK_GH_OK=true MOCK_UNCLASSIFIED_COUNT=3 bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  [ -f "$CACHE_FILE" ]
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.hardenUnclassifiedCount' "$CACHE_FILE")" = "3" ]
}

@test "refresher preserves the previous hardenUnclassifiedCount when gh_ok is false" {
  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  printf '{"checkedAt":0,"hardenCandidateCount":0,"hardenUnclassifiedCount":5}' > "$CACHE_FILE"
  run env MOCK_GH_OK=false bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  jq . "$CACHE_FILE" >/dev/null
  [ "$(jq -r '.hardenUnclassifiedCount' "$CACHE_FILE")" = "5" ]
}

# --- doc-grep: harden.md presents the unclassified signal (UAT-008, review half) ---

@test "harden.md binds the top-level unclassified field alongside the candidate fields" {
  grep -Fq "bind the top-level \`unclassified\` field" "$HARDEN_MD"
}

@test "harden.md presents the unclassified signal in its own seed-a-class-or-investigate section" {
  grep -Fq "## Unclassified recurrence signal (seed-a-class-or-investigate)" "$HARDEN_MD"
}

@test "harden.md states the unclassified signal is excluded from the draftable candidate set" {
  grep -Fq "It is NEVER placed in the draftable candidate set." "$HARDEN_MD"
}

# --- doc-grep: directive-#6 sweep of check-updates.sh (swept in Phase 2) ---

@test "check-updates.sh drops the stale 'at error/warning severity' phrasing" {
  grep -Fq "at error/warning severity" "$CHECK_UPDATES_SRC" && return 1
  return 0
}
