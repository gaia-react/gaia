#!/usr/bin/env bats
#
# Sweep #1 of local-janitor.sh: merged-and-gone wiki-sync branch cleanup.
#
# The wiki landing CLI cuts a throwaway `wiki-sync/<date>-<sha>` branch and
# lands it with `gh pr merge --auto`, which returns before the merge completes,
# so the local branch is never deleted inline. Once the PR squash-merges the
# remote head branch is deleted and a `git fetch --prune` marks the local
# branch's upstream `[gone]`. The janitor deletes exactly that: a wiki-sync/*
# branch with a `[gone]` upstream, and nothing else.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/local-janitor.sh
  REPO_ROOT_REAL=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${ORIGIN:-}" ] && rm -rf "$ORIGIN"
}

# Stand up a repo with a real bare origin so upstream-track state is faithful.
make_repo() {
  ORIGIN=$(mktemp -d -t gaia-janitor-origin-XXXXXX)
  git init -q --bare "$ORIGIN"
  REPO=$(mktemp -d -t gaia-janitor-repo-XXXXXX)
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$ORIGIN"
  echo init > "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
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
  ! branch_exists "wiki-sync/2026-04-04-ddddddd"
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

# --- Migration trigger: ledger-status-migrate.sh runs before the reap sweeps ---
#
# The janitor best-effort runs the one-time ledger-status-migrate.sh right
# after the .gaia/local guard, so a row still on a retired status is on the
# unified vocabulary by the time the reap sweeps read it.

# copy_migrate_deps: mirrors ledger-status-migrate.sh's own repo-relative call
# target inside the fixture repo so the janitor's migration trigger resolves
# for real instead of silently no-op'ing.
copy_migrate_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-status-migrate.sh" \
    "$REPO/.gaia/scripts/ledger-status-migrate.sh"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/with-ledger-lock.sh" \
    "$REPO/.specify/extensions/gaia/lib/with-ledger-lock.sh"
}

@test "migration trigger: a specified/completed fixture row is ready/merged after a janitor run" {
  make_repo
  copy_migrate_deps
  mkdir -p "$REPO/.gaia/local/specs" "$REPO/.gaia/local/plans"
  cat > "$REPO/.gaia/local/specs/ledger.json" <<'EOF'
{"version": 1, "specs": [
  {"id":"SPEC-080","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","status":"specified"}
]}
EOF
  cat > "$REPO/.gaia/local/plans/ledger.json" <<'EOF'
{"version": 1, "plans": [
  {"id":"PLAN-080","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"completed","completed_at":"2026-01-02T00:00:00Z"}
]}
EOF
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.specs[] | select(.id=="SPEC-080") | .status' "$REPO/.gaia/local/specs/ledger.json")" = "ready" ]
  [ "$(jq -r '.plans[] | select(.id=="PLAN-080") | .status' "$REPO/.gaia/local/plans/ledger.json")" = "merged" ]
  [ "$(jq -r '.plans[] | select(.id=="PLAN-080") | .merged_at' "$REPO/.gaia/local/plans/ledger.json")" != "null" ]
}

# --- Sweep #3: completed-but-unswept plan dirs, terminal-ledger + identity gate ---
#
# The janitor delegates the actual delete to plan-archive.sh, so these tests
# copy the real script plus its transitive deps (cost-represented.sh,
# ledger-path-lib.sh, plan-ledger-update.sh, with-ledger-lock.sh) into the
# fixture repo at their real repo-relative paths, exactly as a real checkout
# would have them, rather than re-deriving delete behavior here.

# copy_plan_archive_deps: mirrors plan-archive.sh's own repo-relative call
# targets inside the fixture repo so the janitor's `bash "$root/.gaia/scripts/
# plan-archive.sh" ...` call resolves for real instead of silently failing.
copy_plan_archive_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.gaia/scripts/plan-archive.sh" "$REPO/.gaia/scripts/plan-archive.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/cost-represented.sh" "$REPO/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-path-lib.sh" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/plan-ledger-update.sh" \
    "$REPO/.specify/extensions/gaia/lib/plan-ledger-update.sh"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/with-ledger-lock.sh" \
    "$REPO/.specify/extensions/gaia/lib/with-ledger-lock.sh"
}

# write_cost_md <abs_dir> <heading> <fresh> <cwrite> <cread> <output>: writes a
# cost.md with one real, parseable phase section (the shape
# cost-represented.sh's parser expects).
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

# write_cost_json <abs_dir> <fresh> <cwrite> <cread> <output>: writes a
# cost.json sidecar with one execute-phase record, the shape
# cost-represented.sh's sidecar parser expects. A reduced plan folder keeps
# only cost.json (not cost.md), so the terminal PLAN-NNN reduce test uses this.
write_cost_json() {
  local dir="$1" fresh="$2" cwrite="$3" cread="$4" output="$5"
  mkdir -p "$dir"
  jq -cn \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" '
    {execute: {
      kind: "execute",
      session_id: null,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output)
    }}
  ' > "$dir/cost.json"
}

# seed_cost_row <kind> <field> <val> <fresh> <cwrite> <cread> <output>: appends
# one row (token-tally/backfill schema, no session) to the fixture repo's real
# cost ledger, matching where plan-archive.sh's own gaia_resolve_ledger_path
# resolves inside this repo (no --ledger override).
seed_cost_row() {
  local kind="$1" field="$2" val="$3"
  local fresh="$4" cwrite="$5" cread="$6" output="$7"
  local ledger="$REPO/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$ledger")"
  jq -cn \
    --arg kind "$kind" --arg field "$field" --arg val "$val" \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" '
    {
      schema_version: 1, kind: $kind,
      spec_id: null, plan_id: null, plan_slug: null, session_id: null,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output),
      seq: 0, final: true, source: "test"
    } | .[$field] = $val
  ' >> "$ledger"
}

# seed_plans_ledger <plan-row-json>: writes a one-row plans ledger.
seed_plans_ledger() {
  mkdir -p "$REPO/.gaia/local/plans"
  cat > "$REPO/.gaia/local/plans/ledger.json" <<EOF
{"version": 1, "plans": [ $1 ]}
EOF
}

# seed_specs_ledger <spec-row-json>: writes a one-row specs ledger.
seed_specs_ledger() {
  mkdir -p "$REPO/.gaia/local/specs"
  cat > "$REPO/.gaia/local/specs/ledger.json" <<EOF
{"version": 1, "specs": [ $1 ]}
EOF
}

@test "sweep 3: terminal PLAN-NNN + branch-gone + represented -> reduced to SUMMARY.md + cost.json, RUNNING gone" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-050"
  echo "summary" > "$REPO/.gaia/local/plans/PLAN-050/SUMMARY.md"
  printf 'branch: gone-branch-plan-050\n' > "$REPO/.gaia/local/plans/PLAN-050/RUNNING"
  write_cost_json "$REPO/.gaia/local/plans/PLAN-050" 10 1 1 2
  seed_cost_row execute plan_id PLAN-050 10 1 1 2
  seed_plans_ledger '{"id":"PLAN-050","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"merged","merged_at":"2026-01-02T00:00:00Z"}'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-050" ]
  [ -f "$REPO/.gaia/local/plans/PLAN-050/SUMMARY.md" ]
  [ -f "$REPO/.gaia/local/plans/PLAN-050/cost.json" ]
  [ ! -e "$REPO/.gaia/local/plans/PLAN-050/RUNNING" ]
}

@test "sweep 3: non-terminal ledger status -> skipped (branch-gone alone is insufficient)" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-051"
  printf 'branch: gone-branch-plan-051\n' > "$REPO/.gaia/local/plans/PLAN-051/RUNNING"
  write_cost_md "$REPO/.gaia/local/plans/PLAN-051" Execution 5 0 0 1
  seed_cost_row execute plan_id PLAN-051 5 0 0 1
  seed_plans_ledger '{"id":"PLAN-051","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-051" ]
}

@test "sweep 3: ledger-less free-form slug -> skipped (FC-4, no durable identity)" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/plans/my-legacy-slug"
  printf 'branch: gone-branch-legacy\n' > "$REPO/.gaia/local/plans/my-legacy-slug/RUNNING"
  write_cost_md "$REPO/.gaia/local/plans/my-legacy-slug" Execution 3 0 0 0
  seed_cost_row execute plan_slug my-legacy-slug 3 0 0 0
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/my-legacy-slug" ]
}

@test "sweep 3: colocated terminal -> plan/ deleted, parent SPEC folder untouched" {
  make_repo
  copy_plan_archive_deps
  mkdir -p "$REPO/.gaia/local/specs/SPEC-050/plan"
  echo "spec body" > "$REPO/.gaia/local/specs/SPEC-050/SPEC.md"
  echo "# SPEC-050" > "$REPO/.gaia/local/specs/SPEC-050/SUMMARY.md"
  printf 'branch: gone-branch-spec-050\n' > "$REPO/.gaia/local/specs/SPEC-050/plan/RUNNING"
  write_cost_md "$REPO/.gaia/local/specs/SPEC-050/plan" Execution 4 0 0 1
  seed_cost_row execute spec_id SPEC-050 4 0 0 1
  seed_specs_ledger '{"id":"SPEC-050","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"merged","merged_at":"2026-01-02T00:00:00Z"}'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-050/plan" ]
  [ -d "$REPO/.gaia/local/specs/SPEC-050" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-050/SPEC.md" ]
}

# --- Sweep #7: age-reap merged spec-less plan folders past the retention window ---
#
# Merged spec-less plan folders (already reduced to SUMMARY.md + cost.json by
# sweep #3's plan-archive.sh delegation) are reaped only once merged_at ages
# past the retention window (GAIA_SPEC_RETENTION_DAYS, default 30) AND cost is
# fully represented. The janitor delegates both gates to plan-archive-merged.sh,
# so these tests copy the real script plus its transitive deps, symmetric with
# sweep #6's spec-reap suite.

# copy_plan_archive_merged_deps: mirrors plan-archive-merged.sh's own
# repo-relative call targets inside the fixture repo so the janitor's
# `bash "$root/.specify/extensions/gaia/lib/plan-archive-merged.sh" ...` call
# resolves for real instead of silently failing.
copy_plan_archive_merged_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/plan-archive-merged.sh" \
    "$REPO/.specify/extensions/gaia/lib/plan-archive-merged.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/cost-represented.sh" "$REPO/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/ledger-path-lib.sh" "$REPO/.gaia/scripts/ledger-path-lib.sh"
}

# days_ago <n>: portable ISO8601 timestamp n days in the past, computed with
# jq (never `date -d`/`date -j`, matching the project's cross-platform epoch
# rule).
days_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

@test "sweep 7: merged spec-less plan folder past the retention window with represented cost is reaped" {
  make_repo
  copy_plan_archive_merged_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-070"
  echo "summary" > "$REPO/.gaia/local/plans/PLAN-070/SUMMARY.md"
  seed_plans_ledger "{\"id\":\"PLAN-070\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 45)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/plans/PLAN-070" ]
}

@test "sweep 7: merged spec-less plan folder within the retention window is kept" {
  make_repo
  copy_plan_archive_merged_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-071"
  echo "summary" > "$REPO/.gaia/local/plans/PLAN-071/SUMMARY.md"
  seed_plans_ledger "{\"id\":\"PLAN-071\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"merged\",\"merged_at\":\"$(days_ago 2)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-071" ]
}

# --- Sweep #2: orphaned audit markers --------------------------------------
#
# A marker (<sha>.ok, <sha>.dispositions.json, or the per-member
# <sha>.<member>.ok the Code Audit Team writes) is live only while its <sha> is
# HEAD or reachable from a local branch. The per-member markers matter here: the
# sha-strip must peel the whole suffix, or a live <HEAD>.<member>.ok resolves to
# no commit, reads as dead, and gets deleted out from under the merge gate.

# seed_audit_file <name>: drops one file into the audit drop-zone.
seed_audit_file() {
  mkdir -p "$REPO/.gaia/local/audit"
  echo '{}' > "$REPO/.gaia/local/audit/$1"
}

# orphan_sha: a real commit whose branch is deleted, so it is neither HEAD nor
# reachable from any local branch (reflog-only) -- exactly a squash-merged or
# abandoned branch tip.
orphan_sha() {
  git -C "$REPO" checkout -q -b throwaway
  echo orphan > "$REPO/orphan"
  git -C "$REPO" add orphan
  git -C "$REPO" commit -q -m orphan
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q -D throwaway
}

@test "sweep 2: orphaned .ok / .dispositions.json markers are swept, HEAD's is kept" {
  make_repo
  dead=$(orphan_sha)
  head=$(git -C "$REPO" rev-parse HEAD)
  seed_audit_file "$dead.ok"
  seed_audit_file "$dead.dispositions.json"
  seed_audit_file "$head.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$dead.ok" ]
  [ ! -e "$REPO/.gaia/local/audit/$dead.dispositions.json" ]
  [ -f "$REPO/.gaia/local/audit/$head.ok" ]
}

@test "sweep 2: a LIVE per-member <HEAD>.<member>.ok is never deleted" {
  make_repo
  head=$(git -C "$REPO" rev-parse HEAD)
  seed_audit_file "$head.ok"
  seed_audit_file "$head.code-audit-maintainer-shell.ok"
  seed_audit_file "$head.code-audit-maintainer-node.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$head.ok" ]
  [ -f "$REPO/.gaia/local/audit/$head.code-audit-maintainer-shell.ok" ]
  [ -f "$REPO/.gaia/local/audit/$head.code-audit-maintainer-node.ok" ]
}

@test "sweep 2: an orphaned per-member <sha>.<member>.ok is swept" {
  make_repo
  dead=$(orphan_sha)
  seed_audit_file "$dead.code-audit-maintainer-shell.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$dead.code-audit-maintainer-shell.ok" ]
}

@test "sweep 2: a bogus-sha marker is swept (an unresolvable sha is dead)" {
  make_repo
  seed_audit_file "notasha.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/notasha.ok" ]
}

# --- Sweep #2b: orphaned re-run carry-forward ledgers ----------------------
#
# A ledger is keyed on the incremental BASE sha (the fork point
# `git merge-base "$BASE_REF" HEAD`), NOT a branch tip. A fork point is an
# ancestor of the default branch by construction, so the reachability test the
# markers use always answers "live" for a ledger and can never reap one -- which
# is exactly why the sweep needs its own rule. The ledger dies with the branch it
# records: code-audit-frontend deletes it on a clean pass, so one that outlives
# its branch belongs to a line abandoned before it ever reached clean.

# seed_rerun_ledger <base-sha> <recorded-branch>: writes the ledger the way the
# audit really names it -- keyed on the base sha, with the audited branch inside.
# Pass an empty branch to write a ledger with no branch recorded.
seed_rerun_ledger() {
  mkdir -p "$REPO/.gaia/local/audit"
  jq -cn --arg branch "$2" --arg base "$1" '
    {schema: 1, round: 1, base_sha: $base, head_sha: $base,
     remaining: [], fixed_last_round: [], notes: null}
    | if $branch == "" then . else . + {branch: $branch} end
  ' > "$REPO/.gaia/local/audit/$1.rerun.json"
}

@test "sweep 2b: a ledger whose audited branch is gone is swept, even though its base sha is on main" {
  make_repo
  # The real shape: the ledger is keyed on the fork point, which IS reachable
  # from main. Only the recorded branch being gone proves it dead.
  base=$(git -C "$REPO" rev-parse HEAD)
  seed_rerun_ledger "$base" "abandoned-feature"
  cd "$REPO"
  # Guard the premise: this base sha really is reachable from a local branch, so
  # a reachability-based rule would keep it forever.
  [ -n "$(git -C "$REPO" branch --contains "$base")" ]
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$base.rerun.json" ]
}

@test "sweep 2b: a ledger whose audited branch still exists is kept" {
  make_repo
  base=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" branch live-feature
  seed_rerun_ledger "$base" "live-feature"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$base.rerun.json" ]
}

@test "sweep 2b: a ledger with no recorded branch is kept (fail-safe: death unprovable)" {
  make_repo
  base=$(git -C "$REPO" rev-parse HEAD)
  seed_rerun_ledger "$base" ""
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$base.rerun.json" ]
}

@test "sweep 2b: an unparseable ledger is kept (fail-safe: death unprovable)" {
  make_repo
  seed_audit_file "deadbeef.rerun.json"
  printf 'not json at all' > "$REPO/.gaia/local/audit/deadbeef.rerun.json"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/deadbeef.rerun.json" ]
}

# --- Sweep #8: stale cloud telemetry events (age-gated) --------------------
#
# telemetry/cloud is a structural drop-zone, so sweep #4 keeps the directory
# alive, but nothing reaps its contents: `gaia mentorship purge` documents that
# it never touches the cloud stream. The janitor owns the retention, age-gated
# on the same 14-day window sweep #5 uses for stale cache artifacts.

# touch_days_ago <n> <file>: back-date a file n days, computed with jq (never
# `date -d`/`date -j`, matching the project's cross-platform epoch rule).
touch_days_ago() {
  touch -t "$(jq -rn --argjson n "$1" '(now - ($n * 86400)) | strftime("%Y%m%d%H%M")')" "$2"
}

# seed_cloud_file <name> <days-old>: drops one back-dated file into the cloud
# telemetry drop-zone.
seed_cloud_file() {
  mkdir -p "$REPO/.gaia/local/telemetry/cloud"
  echo '{}' > "$REPO/.gaia/local/telemetry/cloud/$1"
  touch_days_ago "$2" "$REPO/.gaia/local/telemetry/cloud/$1"
}

@test "sweep 8: a cloud events file past the window is reaped" {
  make_repo
  seed_cloud_file "events-2026-01-01.jsonl" 20
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/telemetry/cloud/events-2026-01-01.jsonl" ]
}

@test "sweep 8: a cloud events file within the window is kept" {
  make_repo
  seed_cloud_file "events-2026-06-01.jsonl" 2
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/telemetry/cloud/events-2026-06-01.jsonl" ]
}

@test "sweep 8: a non-events file in the cloud drop-zone is never touched, however old" {
  make_repo
  seed_cloud_file "config.json" 90
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/telemetry/cloud/config.json" ]
}

@test "sweep 8: the telemetry/cloud drop-zone survives an emptying reap" {
  make_repo
  seed_cloud_file "events-2026-01-02.jsonl" 20
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  # Second pass: the now-empty drop-zone must still not be rmdir'd by sweep #4.
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/telemetry/cloud" ]
}
