#!/usr/bin/env bats
#
# Bats suite for .gaia/cli/health/comprehensive/gauge.sh: the deterministic
# pre-flight depth gauge for the Comprehensive Audit phase of /health-audit.
# Exercises baseline resolution, the diff surface + manifest exclusion, the
# path-to-lens classification, the depth-decision precedence, and the
# gauge.json schema against a throwaway git repo seeded with v* tags.
#
# Each test spins up its own tmp git repo (setup/teardown) and runs the gauge
# with cwd inside that repo, so its `git describe` resolves the seeded tag,
# per .claude/rules/shell-cwd.md the gauge script itself never `cd`s; this
# suite's `run_gauge` helper does the cd inside a throwaway subshell.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` for
# equality/status, `grep -qF` for substrings, explicit `return 1` branches.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/cli/health/comprehensive/gauge.sh"
  [ -x "$SCRIPT" ] || skip "gauge.sh not executable"

  TMPROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-gauge-XXXXXX")"
  REPO="$(cd "$TMPROOT_RAW" && pwd -P)"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  git -C "$REPO" init -q
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  mkdir -p "$REPO/.claude"
  echo "seed" > "$REPO/.claude/seed.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "init"

  GAUGE_JSON="$REPO/.gaia/local/audit/comprehensive/gauge.json"
}

teardown() {
  if [ -n "${REPO:-}" ] && [ -d "$REPO" ]; then
    rm -rf "$REPO"
  fi
  if [ -n "${TMPROOT_RAW:-}" ] && [ "$TMPROOT_RAW" != "${REPO:-}" ] && [ -d "$TMPROOT_RAW" ]; then
    rm -rf "$TMPROOT_RAW"
  fi
}

# Runs the gauge with cwd inside the tmp repo so its `git describe`/`git diff`
# resolve against the seeded tags, not this checkout.
run_gauge() {
  run bash -c '
    cd "$1" || exit 1
    script="$2"
    shift 2
    bash "$script" "$@"
  ' _ "$REPO" "$SCRIPT" "$@"
}

commit_file() {
  local rel="$1"
  mkdir -p "$REPO/$(dirname "$rel")"
  echo "change-$$-$RANDOM" >> "$REPO/$rel"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "change $rel"
}

tag_now() {
  git -C "$REPO" tag "$1"
}

# ---------- AC-1 (UAT-001 determinism) ----------

@test "AC-1: two runs against an unchanged tree emit byte-identical depth/lenses" {
  tag_now "v1.0.0"
  commit_file ".claude/feature.md"

  run_gauge
  [ "$status" -eq 0 ]
  first="$(jq -S '{depth,lenses}' "$GAUGE_JSON")"
  depth1="$(jq -r '.depth' "$GAUGE_JSON")"

  run_gauge
  [ "$status" -eq 0 ]
  second="$(jq -S '{depth,lenses}' "$GAUGE_JSON")"

  [ "$first" = "$second" ]
  if [ "$depth1" = "skip" ]; then return 1; fi
}

# ---------- AC-2 (UAT-002 skip) ----------

@test "AC-2: no surface change since tag -> depth=skip, lenses=[], source=diff, rationale has tag" {
  tag_now "v1.0.0"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "skip" ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = "[]" ]
  [ "$(jq -r '.source' "$GAUGE_JSON")" = "diff" ]
  grep -qF "v1.0.0" <<<"$(jq -r '.rationale' "$GAUGE_JSON")"
}

# ---------- AC-3 (UAT-012 scoped subset) ----------

@test "AC-3: only .claude/** (non-health) changed -> depth=scoped, lenses=[FEAT] exactly" {
  tag_now "v1.0.0"
  commit_file ".claude/skills/foo/SKILL.md"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "scoped" ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["FEAT"]' ]
}

# ---------- AC-4 (SELF routing) ----------

@test "AC-4: .claude/commands/health-audit.md change routes to SELF" {
  tag_now "v1.0.0"
  commit_file ".claude/commands/health-audit.md"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["SELF"]' ]
}

@test "AC-4: .gaia/cli/health/** change routes to SELF" {
  tag_now "v1.0.0"
  commit_file ".gaia/cli/health/runbook.md"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["SELF"]' ]
}

# ---------- AC-5 (TIDY routing) ----------

@test "AC-5: .gaia/release-exclude change routes to TIDY" {
  tag_now "v1.0.0"
  commit_file ".gaia/release-exclude"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["TIDY"]' ]
}

# ---------- AC-6 (DIST routing) ----------

@test "AC-6: .gaia/scripts/** change routes to DIST" {
  tag_now "v1.0.0"
  commit_file ".gaia/scripts/some-script.sh"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["DIST"]' ]
}

@test "AC-6: .gaia/cli/** (non-health) change routes to DIST" {
  tag_now "v1.0.0"
  commit_file ".gaia/cli/package.json"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["DIST"]' ]
}

# ---------- AC-7 (UAT-003 churn) ----------

@test "AC-7: churn > 150 -> depth=full, source=churn, all four lenses" {
  tag_now "v1.0.0"
  for i in $(seq 1 151); do
    echo "x" > "$REPO/.claude/bulk-$i.md"
  done
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "bulk change"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "full" ]
  [ "$(jq -r '.source' "$GAUGE_JSON")" = "churn" ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["FEAT","DIST","TIDY","SELF"]' ]
  [ "$(jq -r '.churn_files' "$GAUGE_JSON")" -gt 150 ]
}

# ---------- AC-8 (UAT-004 force flag) ----------

@test "AC-8: --comprehensive-full forces full regardless of the diff" {
  tag_now "v1.0.0"
  # no changes since the tag at all

  run_gauge --comprehensive-full
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "full" ]
  [ "$(jq -r '.source' "$GAUGE_JSON")" = "force-flag" ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["FEAT","DIST","TIDY","SELF"]' ]
}

# ---------- AC-9 (major) ----------

@test "AC-9: --major (no force flag) -> depth=full, source=major" {
  tag_now "v1.0.0"
  commit_file ".claude/feature.md"

  run_gauge --major
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "full" ]
  [ "$(jq -r '.source' "$GAUGE_JSON")" = "major" ]
}

# ---------- AC-10 (UAT-014 no tag) ----------

@test "AC-10: no resolvable v* tag -> depth=full, source=no-tag, baseline_tag empty" {
  # repo has commits but no tag at all

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "full" ]
  [ "$(jq -r '.source' "$GAUGE_JSON")" = "no-tag" ]
  [ "$(jq -r '.baseline_tag' "$GAUGE_JSON")" = "" ]
}

# ---------- AC-11 (manifest excluded) ----------

@test "AC-11: a diff touching only .gaia/manifest.json yields depth=skip" {
  tag_now "v1.0.0"
  commit_file ".gaia/manifest.json"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "skip" ]
}

# ---------- AC-12 (schema) ----------

@test "AC-12: gauge.json is valid JSON with exactly the six frozen keys" {
  tag_now "v1.0.0"
  commit_file ".claude/feature.md"

  run_gauge
  [ "$status" -eq 0 ]
  jq . "$GAUGE_JSON" >/dev/null
  keys="$(jq -S -c 'keys' "$GAUGE_JSON")"
  [ "$keys" = '["baseline_tag","churn_files","depth","lenses","rationale","source"]' ]
}

# ---------- Stdout summary contract ----------

@test "stdout summary line matches the gauge.json fields" {
  tag_now "v1.0.0"
  commit_file ".claude/feature.md"

  run_gauge
  [ "$status" -eq 0 ]
  [ "$output" = "depth=scoped lenses=FEAT source=diff" ]
}

# ---------- Multi-lens canonical ordering (determinism crux) ----------

@test "scoped diff hitting all four lenses emits them in canonical FEAT,DIST,TIDY,SELF order" {
  tag_now "v1.0.0"
  # One file per lens, committed in reverse-canonical order to prove the gauge
  # orders by source-order (the scoped_lenses append block), not detection
  # order. This is the only test that exercises 2+ simultaneous lens hits, the
  # exact multi-value case the byte-identical determinism guarantee rests on.
  commit_file ".gaia/cli/health/runbook.md"  # SELF
  commit_file ".gaia/release-exclude"        # TIDY
  commit_file ".gaia/scripts/some-script.sh" # DIST
  commit_file ".claude/skills/foo/SKILL.md"  # FEAT

  run_gauge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.depth' "$GAUGE_JSON")" = "scoped" ]
  [ "$(jq -c '.lenses' "$GAUGE_JSON")" = '["FEAT","DIST","TIDY","SELF"]' ]
  [ "$output" = "depth=scoped lenses=FEAT,DIST,TIDY,SELF source=diff" ]
}
