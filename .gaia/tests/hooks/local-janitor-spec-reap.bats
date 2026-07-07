#!/usr/bin/env bats
#
# Sweep #6 of local-janitor.sh: age-reap merged SPEC folders once merged_at
# has aged past the retention window (GAIA_SPEC_RETENTION_DAYS, default 30)
# AND cost is fully represented. The janitor delegates both gates to
# spec-archive-merged.sh, so these tests copy the real script plus its
# transitive deps (cost-represented.sh, ledger-path-lib.sh) into the fixture
# repo at their real repo-relative paths, exactly as a real checkout would
# have them, rather than re-deriving delete behavior here.
#
# Representation is driven with no-cost folders (auto-represented, nothing to
# lose) and a plain cost.md fixture (the markdown fallback path), so these
# tests stay independent of the sidecar reroute.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]`. This suite uses `[ ... ]` throughout.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/local-janitor.sh
  REPO_ROOT_REAL=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

make_repo() {
  REPO=$(mktemp -d -t gaia-janitor-spec-reap-repo-XXXXXX)
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  echo init > "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/.gaia/local"
}

# copy_archive_deps: mirrors spec-archive-merged.sh's own repo-relative call
# targets inside the fixture repo so the janitor's `bash "$root/.specify/
# extensions/gaia/lib/spec-archive-merged.sh" ...` call resolves for real
# instead of silently failing.
copy_archive_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/spec-archive-merged.sh" \
    "$REPO/.specify/extensions/gaia/lib/spec-archive-merged.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/cost-represented.sh" "$REPO/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-path-lib.sh" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  chmod +x "$REPO/.specify/extensions/gaia/lib/spec-archive-merged.sh"
}

# seed_specs_ledger <spec-row-json>: writes a one-row specs ledger.
seed_specs_ledger() {
  mkdir -p "$REPO/.gaia/local/specs"
  cat > "$REPO/.gaia/local/specs/ledger.json" <<EOF
{"version": 1, "specs": [ $1 ]}
EOF
}

# seed_merged_folder <spec_id>: the foldered SPEC.md shape under an active
# specs/<id>/ dir, no cost.md (automatically represented).
seed_merged_folder() {
  mkdir -p "$REPO/.gaia/local/specs/$1"
  echo "# $1" > "$REPO/.gaia/local/specs/$1/SPEC.md"
}

# write_cost_md <dir> <heading> <fresh> <cwrite> <cread> <output>: one real,
# parseable phase section (the shape cost-represented.sh's parser expects).
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

# days_ago <n>: portable ISO8601 timestamp n days in the past, computed with
# jq (never `date -d`/`date -j`, matching the project's cross-platform epoch
# rule).
days_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

@test "sweep 6: merged folder past the retention window with represented cost is reaped" {
  make_repo
  copy_archive_deps
  seed_merged_folder SPEC-060
  seed_specs_ledger "{\"id\":\"SPEC-060\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 45)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-060" ]
}

@test "sweep 6: merged folder within the retention window is kept" {
  make_repo
  copy_archive_deps
  seed_merged_folder SPEC-061
  seed_specs_ledger "{\"id\":\"SPEC-061\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 2)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/specs/SPEC-061" ]
}

@test "sweep 6: a folder past the window but unrepresented is kept; janitor still exits 0" {
  make_repo
  copy_archive_deps
  seed_merged_folder SPEC-062
  write_cost_md "$REPO/.gaia/local/specs/SPEC-062" SPEC 10 1 1 2
  mkdir -p "$REPO/.gaia/local/telemetry"
  : > "$REPO/.gaia/local/telemetry/cost.jsonl" # no matching row: unrepresented
  seed_specs_ledger "{\"id\":\"SPEC-062\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 45)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/specs/SPEC-062" ]
}

@test "sweep 6: runs alongside the rest of the janitor's sweeps without side effects" {
  make_repo
  copy_archive_deps
  seed_merged_folder SPEC-063
  seed_specs_ledger "{\"id\":\"SPEC-063\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 45)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-063" ]
  # Sweep #4's structural drop-zones are untouched by the sweep-#6 delegation.
  [ -d "$REPO/.gaia/local/specs" ]
}
