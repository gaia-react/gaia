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
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  return 0
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
  branch_exists "wiki-sync/2026-04-04-ddddddd" && return 1
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

# copy_plan_archive_abandoned_deps: mirrors plan-archive-abandoned.sh's own
# repo-relative call target inside the fixture repo so the janitor's
# `bash "$root/.specify/extensions/gaia/lib/plan-archive-abandoned.sh" ...`
# call resolves for real instead of silently failing.
copy_plan_archive_abandoned_deps() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT_REAL/.specify/extensions/gaia/lib/plan-archive-abandoned.sh" \
    "$REPO/.specify/extensions/gaia/lib/plan-archive-abandoned.sh"
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

@test "sweep 7: abandoned spec-less plan folder past the retention window with represented cost is reaped" {
  make_repo
  copy_plan_archive_abandoned_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-072"
  echo "draft" > "$REPO/.gaia/local/plans/PLAN-072/PLAN.md"
  seed_plans_ledger "{\"id\":\"PLAN-072\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"abandoned\",\"abandoned_at\":\"$(days_ago 45)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/plans/PLAN-072" ]
}

@test "sweep 7: abandoned spec-less plan folder within the retention window is kept" {
  make_repo
  copy_plan_archive_abandoned_deps
  mkdir -p "$REPO/.gaia/local/plans/PLAN-073"
  echo "draft" > "$REPO/.gaia/local/plans/PLAN-073/PLAN.md"
  seed_plans_ledger "{\"id\":\"PLAN-073\",\"allocated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"allocated\",\"status\":\"abandoned\",\"abandoned_at\":\"$(days_ago 2)\"}"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/plans/PLAN-073" ]
}

# --- Sweep #2: orphaned audit markers --------------------------------------
#
# A marker's filename key is a 64-hex CONTENT DIGEST over exactly the files
# the audited member owns plus the shared gate machinery, not a git tree or
# commit sha, so the key resolves to no git object and no reachability call
# can ever answer "live" for one. Liveness is read off each marker's own JSON
# body instead, through three key-shape-agnostic keep-arms:
#
#   Keep-arm A (live-tree)         the marker's body `.tree` (plain data) is
#     one of the once-computed live_trees (every local branch tip / linked
#     worktree HEAD).
#   Keep-arm B (retention window)  the marker is within
#     GAIA_AUDIT_MARKER_RETENTION_HOURS (default 72) of its own recorded
#     `audited_at`. Applies to both `.ok` and `.refused`.
#   Keep-arm C (open-receipt)      the frontend `<digest>.ok` marker's
#     co-keyed `<digest>.dispositions.json` sidecar still holds a still-open
#     entry (COV-002, its own section below).
#
# A marker is NEW-SCHEME iff its filename stem-before-first-dot is 64-hex AND
# its body's `.digest` equals that stem; only a new-scheme marker is
# keep-eligible at all. Everything else -- an old-scheme (pre-digest) marker,
# a body lacking `.digest`, the deleted `.carried` family, and the
# CI-observability `.progress.log` breadcrumb (never re-keyed as a clearance)
# -- is spent residue and is unconditionally reaped.

# seed_audit_file <name>: drops one raw file into the audit drop-zone.
seed_audit_file() {
  mkdir -p "$REPO/.gaia/local/audit"
  echo '{}' > "$REPO/.gaia/local/audit/$1"
}

# orphan_sha: a real commit whose branch is deleted, so its tree names no
# local branch tip or worktree HEAD -- exactly a squash-merged or abandoned
# branch tip, the NON-live-tree fixture every keep-arm-A-fails test needs.
orphan_sha() {
  git -C "$REPO" checkout -q -b throwaway
  echo orphan > "$REPO/orphan"
  git -C "$REPO" add orphan
  git -C "$REPO" commit -q -m orphan
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q -D throwaway
}

# head_tree: the tree the Code Audit Team's clearance bodies record.
head_tree() {
  git -C "$REPO" rev-parse "HEAD^{tree}"
}

# hours_ago <n>: portable ISO8601 timestamp n hours in the past, computed with
# jq (never `date -d`/`date -j`), matching days_ago's cross-platform epoch
# rule above.
hours_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 3600)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# gen_digest <seed>: a deterministic 64-hex sha256 of <seed>, the new-scheme
# filename-key shape. Distinct seeds across a test's fixtures never collide.
gen_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

# seed_marker <digest> <infix> <ext> <tree> <audited_at_iso>: writes a
# schema-3 clearance body at .gaia/local/audit/<digest>[.<infix>].<ext>.
# <infix> "" is the default member (code-audit-frontend, infix-free
# filename); a non-empty <infix> is a specialist member name. <ext> is
# ok (provenance earned) or refused.
seed_marker() {
  local digest="$1" infix="$2" ext="$3" tree="$4" audited_at="$5"
  local member prov name
  mkdir -p "$REPO/.gaia/local/audit"
  if [ -z "$infix" ]; then
    member="code-audit-frontend"
    name="${digest}.${ext}"
  else
    member="$infix"
    name="${digest}.${infix}.${ext}"
  fi
  case "$ext" in
    ok) prov=earned ;;
    refused) prov=refused ;;
  esac
  jq -cn --arg member "$member" --arg prov "$prov" --arg digest "$digest" \
    --arg tree "$tree" --arg audited_at "$audited_at" \
    --argjson sidecar "$([ "$member" = code-audit-frontend ] && echo true || echo false)" '
    {version: "1.6.1", schema: 3, member: $member, provenance: $prov,
     digest: $digest, tree: $tree, sha: "deadbeef", audited_at: $audited_at,
     sidecar: $sidecar}
  ' > "$REPO/.gaia/local/audit/$name"
}

# seed_sidecar <digest> <findings-json-array>: writes a dispositions sidecar
# at .gaia/local/audit/<digest>.dispositions.json.
seed_sidecar() {
  local digest="$1" findings="$2"
  mkdir -p "$REPO/.gaia/local/audit"
  jq -cn --argjson findings "$findings" '{backend: "github", findings: $findings}' \
    > "$REPO/.gaia/local/audit/${digest}.dispositions.json"
}

@test "sweep 2: UAT-007 an old-scheme <tree>.ok marker is reaped even for HEAD's own tree" {
  make_repo
  tree=$(head_tree)
  seed_audit_file "$tree.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.ok" ]
}

# The regression the digest key still must not reopen: code-audit-frontend
# stamps the GAIA-Audit trailer as an EMPTY commit, which advances HEAD while
# leaving the tree byte-identical. A new-scheme marker's body `.tree` is
# unaffected by that commit, so keep-arm A (live-tree) still finds it live.
@test "sweep 2: keep-arm A: a new-scheme marker survives the trailer stamp's empty commit" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-$tree")
  seed_marker "$digest" "" ok "$tree" "2020-01-01T00:00:00Z"
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  # The empty commit moved HEAD but not the tree.
  [ "$(head_tree)" = "$tree" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
}

@test "sweep 2: keep-arm A: LIVE per-member <digest>.<member>.ok markers are never deleted" {
  make_repo
  tree=$(head_tree)
  fdigest=$(gen_digest "frontend-$tree")
  sdigest=$(gen_digest "shell-$tree")
  ndigest=$(gen_digest "node-$tree")
  seed_marker "$fdigest" "" ok "$tree" "2020-01-01T00:00:00Z"
  seed_marker "$sdigest" "code-audit-maintainer-shell" ok "$tree" "2020-01-01T00:00:00Z"
  seed_marker "$ndigest" "code-audit-maintainer-node" ok "$tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$fdigest.ok" ]
  [ -f "$REPO/.gaia/local/audit/$sdigest.code-audit-maintainer-shell.ok" ]
  [ -f "$REPO/.gaia/local/audit/$ndigest.code-audit-maintainer-node.ok" ]
}

@test "sweep 2: a per-member marker for a non-live tree past the retention window is reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "shell-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "code-audit-maintainer-shell" ok "$dead_tree" "$(hours_ago 2)"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.code-audit-maintainer-shell.ok" ]
}

# The audit drop-zone is symlinked into every linked worktree, so one janitor
# run sweeps the markers of every checkout. A sibling branch's marker must
# outlive a sweep launched from another branch, or the janitor deletes a live
# marker out from under a parallel audit.
@test "sweep 2: UAT-010 keep-arm A: a marker for another local branch's tip is kept" {
  make_repo
  git -C "$REPO" checkout -q -b sibling
  echo sibling > "$REPO/sibling"
  git -C "$REPO" add sibling
  git -C "$REPO" commit -q -m sibling
  sibling_tree=$(head_tree)
  git -C "$REPO" checkout -q main
  digest=$(gen_digest "frontend-$sibling_tree")
  seed_marker "$digest" "" ok "$sibling_tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
}

# The other half of the live-tree set, and the one most likely to regress
# silently: a linked worktree's HEAD. A detached worktree HEAD is named by no
# branch, so the branch-tip scan alone cannot see its tree.
@test "sweep 2: UAT-010 keep-arm A: a marker for a linked worktree's detached HEAD is kept" {
  make_repo
  # A commit reachable from no branch, checked out detached in a linked worktree.
  git -C "$REPO" checkout -q -b throwaway
  echo detached > "$REPO/detached"
  git -C "$REPO" add detached
  git -C "$REPO" commit -q -m detached
  wt_sha=$(git -C "$REPO" rev-parse HEAD)
  wt_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  git -C "$REPO" checkout -q main
  # Inside $REPO so teardown reclaims it with the repo; a path in the shared tmp
  # parent would outlive the test and collide on the next run.
  git -C "$REPO" worktree add -q --detach "$REPO/.linked-wt" "$wt_sha"
  git -C "$REPO" branch -q -D throwaway

  # No branch names that tree now; only the linked worktree's HEAD does.
  run bash -c "git -C '$REPO' for-each-ref --format='%(objectname)' refs/heads/ | while read -r c; do git -C '$REPO' rev-parse \"\${c}^{tree}\"; done"
  grep -qxF "$wt_tree" <<< "$output" && return 1

  digest=$(gen_digest "frontend-$wt_tree")
  seed_marker "$digest" "" ok "$wt_tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
}

@test "sweep 2: MIG-005 a sidecar co-keyed with a live marker is kept; an old sha-keyed sidecar is reaped" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-$tree")
  seed_marker "$digest" "" ok "$tree" "2020-01-01T00:00:00Z"
  seed_sidecar "$digest" '[]'
  old_sha=$(git -C "$REPO" rev-parse HEAD)
  seed_audit_file "$old_sha.dispositions.json"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
  [ ! -e "$REPO/.gaia/local/audit/$old_sha.dispositions.json" ]
}

@test "sweep 2: MIG-005 a sidecar is co-reaped with its marker when neither arm A nor B keeps it (no open receipt)" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"waived"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "sweep 2: a bogus-key marker is swept (a non-64-hex key is never new-scheme)" {
  make_repo
  seed_audit_file "notasha.ok"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/notasha.ok" ]
}

# The progress log is never re-keyed to the digest scheme (SPEC `never`): it
# is a CI-observability breadcrumb, not a validity artifact, so nothing keeps
# it alive under the new janitor -- it is always spent residue.
@test "sweep 2: UAT-007 a progress log is always reaped, even for HEAD's own tree" {
  make_repo
  tree=$(head_tree)
  seed_audit_file "$tree.progress.log"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.progress.log" ]
}

@test "sweep 2: a progress log does not survive the trailer stamp's empty commit (never re-keyed as a clearance)" {
  make_repo
  tree=$(head_tree)
  seed_audit_file "$tree.progress.log"
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(head_tree)" = "$tree" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.progress.log" ]
}

@test "sweep 2: a .carried artifact (deleted carry-forward family) is always reaped, even for a live tree" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-$tree")
  seed_audit_file "${digest}.carried"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/${digest}.carried" ]
}

@test "sweep 2: keep-arm B applies to .refused too: a live-tree refusal is kept" {
  make_repo
  tree=$(head_tree)
  digest=$(gen_digest "frontend-refused-$tree")
  seed_marker "$digest" "" refused "$tree" "2020-01-01T00:00:00Z"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.refused" ]
}

@test "sweep 2: a refusal for a non-live tree past the retention window is reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-refused-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" refused "$dead_tree" "$(hours_ago 2)"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.refused" ]
}

@test "UAT-018: a window-kept marker (arm B) keeps its co-keyed sidecar; a live-tree marker (arm A) survives regardless of age" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  tree=$(head_tree)

  # A non-live-tree marker inside the 72h window: keep-arm B.
  digest1=$(gen_digest "frontend-$dead_tree")
  seed_marker "$digest1" "" ok "$dead_tree" "$(hours_ago 1)"
  seed_sidecar "$digest1" '[]'

  # A marker whose tree IS a live branch tip, well outside the window:
  # keep-arm A keeps it regardless of age.
  digest2=$(gen_digest "frontend-$tree")
  seed_marker "$digest2" "" ok "$tree" "$(hours_ago 1000)"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$REPO/.gaia/local/audit/$digest1.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest1.dispositions.json" ]
  [ -f "$REPO/.gaia/local/audit/$digest2.ok" ]
}

@test "UAT-019: an out-of-window marker on a non-live tree, with no sidecar, is reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
}

# --- COV-002: the open-receipt keep-arm (decision 2) ------------------------
#
# A still-open out-of-scope disposition receipt must survive a digest
# rotation even after its predecessor marker ages past the retention window,
# so seed-forward always finds a live predecessor sidecar to read. Both
# halves are pinned here: a still-open entry keeps the marker+sidecar pair
# alive past every other arm (arms A and B both deliberately fail in each
# fixture below: a non-live tree, and an out-of-window audited_at); a
# fully-resolved sidecar gets no such exemption and is reaped normally. The
# still-open predicate mirrors task-dispositions' disposition_seed_forward
# byte-for-byte: `.disposition == "filed"` OR (`.disposition == "pending"`
# AND `.pending_reason == "definitive"`).

@test "COV-002: a still-open (filed) receipt keeps its marker+sidecar alive past the window on a non-live tree" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"filed"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: a pending(definitive) receipt also keeps its marker+sidecar alive (same predicate as seed-forward)" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"pending","pending_reason":"definitive"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: a fully-resolved sidecar (waived/diverted/pending-transient) gets no window exemption; both are reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[
    {"key":"k1","disposition":"waived"},
    {"key":"k2","disposition":"diverted"},
    {"key":"k3","disposition":"pending","pending_reason":"transient"}
  ]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: an empty-findings sidecar gets no window exemption; both are reaped" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "frontend-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

@test "COV-002: the marker exemption is frontend-only, but the sidecar exemption applies regardless of marker family" {
  make_repo
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  digest=$(gen_digest "shell-$dead_tree")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  seed_marker "$digest" "code-audit-maintainer-shell" ok "$dead_tree" "$(hours_ago 2)"
  seed_sidecar "$digest" '[{"key":"k1","disposition":"filed"}]'
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.code-audit-maintainer-shell.ok" ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]
}

# --- TST-006: the janitor never recomputes a per-member digest -------------

@test "TST-006 tripwire: the janitor source never references audit_member_digest or the digest CLI" {
  run grep -En "audit_member_digest|audit-member-digest\.sh|audit_digests_all" "$HOOK_ABS"
  [ "$status" -ne 0 ]
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

# --- Cost budget: fork counts, never wall clock (CG-005, PERF-004) ---------
#
# No keep-arm makes a per-marker git call (the digest key resolves to no git
# object, so the old `cat-file -e` / `branch --contains` reachability calls
# are gone entirely); the per-marker cost is at most ONE jq fork, to read a
# new-scheme body once for arms A and B together. Each test measures a
# BASELINE run against an empty audit dir, then a second run with exactly one
# fixture added, and asserts the DELTA -- isolating that one fixture's own
# contribution from every other sweep's constant cost (the branch scan, the
# live-tree computation, ...), which runs unconditionally either way.

# shim_git_and_jq_counters: puts wrapper `git` and `jq` binaries at the front
# of PATH. Each wrapper appends one line to its own counter file, then execs
# the real binary (resolved via `command -v` BEFORE the shim dir is
# prepended, so the wrapper never calls itself).
shim_git_and_jq_counters() {
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  GIT_COUNTER="$SHIM_DIR/git.count"
  JQ_COUNTER="$SHIM_DIR/jq.count"
  : > "$GIT_COUNTER"
  : > "$JQ_COUNTER"
  local real_git real_jq
  real_git=$(command -v git)
  real_jq=$(command -v jq)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
echo x >> "$GIT_COUNTER"
exec "$real_git" "\$@"
SHIM
  cat > "$SHIM_DIR/jq" <<SHIM
#!/bin/bash
echo x >> "$JQ_COUNTER"
exec "$real_jq" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git" "$SHIM_DIR/jq"
}

git_fork_count() { wc -l < "$GIT_COUNTER" | tr -d ' '; }
jq_fork_count() { wc -l < "$JQ_COUNTER" | tr -d ' '; }

@test "budget: a live-tree-kept marker (keep-arm A) costs ZERO git forks and EXACTLY ONE jq fork" {
  make_repo
  shim_git_and_jq_counters
  tree=$(head_tree)
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_git=$(git_fork_count)
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$tree")
  seed_marker "$digest" "" ok "$tree" "2020-01-01T00:00:00Z"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]

  [ "$(git_fork_count)" -eq "$base_git" ]
  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

@test "budget: a window-kept marker (keep-arm B, non-live tree) costs ZERO git forks and EXACTLY ONE jq fork" {
  make_repo
  shim_git_and_jq_counters
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_git=$(git_fork_count)
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$dead_tree")
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 1)"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.ok" ]

  [ "$(git_fork_count)" -eq "$base_git" ]
  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

@test "budget: a reaped new-scheme marker (neither arm keeps it) costs ZERO git forks and EXACTLY ONE jq fork" {
  make_repo
  shim_git_and_jq_counters
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  export GAIA_AUDIT_MARKER_RETENTION_HOURS=1
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_git=$(git_fork_count)
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$dead_tree")
  seed_marker "$digest" "" ok "$dead_tree" "$(hours_ago 2)"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$digest.ok" ]

  # No reachability git call exists any more: the digest key resolves to no
  # object, so the old cat-file/branch-contains pair is gone entirely.
  [ "$(git_fork_count)" -eq "$base_git" ]
  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

@test "budget: an old-scheme (non-64-hex) marker triggers ZERO jq forks; the key-shape check fires before the fork" {
  make_repo
  shim_git_and_jq_counters
  tree=$(head_tree)
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_jq=$(jq_fork_count)

  seed_audit_file "$tree.ok"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/$tree.ok" ]

  [ "$(jq_fork_count)" -eq "$base_jq" ]
}

@test "budget: a .carried or .progress.log artifact triggers ZERO jq forks; unconditional reap, no read" {
  make_repo
  shim_git_and_jq_counters
  tree=$(head_tree)
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$tree")
  seed_audit_file "${digest}.carried"
  seed_audit_file "${tree}.progress.log"
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/audit/${digest}.carried" ]
  [ ! -e "$REPO/.gaia/local/audit/${tree}.progress.log" ]

  [ "$(jq_fork_count)" -eq "$base_jq" ]
}

@test "budget: PERF-004 keep-arm C's open-receipt precompute costs exactly ONE jq fork per sidecar" {
  make_repo
  shim_git_and_jq_counters
  dead=$(orphan_sha)
  dead_tree=$(git -C "$REPO" rev-parse "${dead}^{tree}")
  mkdir -p "$REPO/.gaia/local/audit"
  cd "$REPO"

  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  base_jq=$(jq_fork_count)

  digest=$(gen_digest "frontend-$dead_tree")
  seed_sidecar "$digest" '[{"key":"k1","disposition":"filed"}]'
  : > "$GIT_COUNTER"; : > "$JQ_COUNTER"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/audit/$digest.dispositions.json" ]

  [ "$(jq_fork_count)" -eq "$((base_jq + 1))" ]
}

# --- Sweep #4: the telemetry drop-zone split --------------------------------
#
# The highest-consequence line in is_drop_zone. `telemetry` is a drop-zone and
# `telemetry/cloud` is not, and the two halves pull in opposite directions:
#
#   telemetry/       holds the token/cost ledger (cost.jsonl). Sweep #4 rmdirs
#                    any empty dir under .gaia/local that is not a drop-zone, so
#                    dropping `telemetry` from the arm would delete the directory
#                    that ledger lives in the moment it is momentarily empty.
#   telemetry/cloud  is dead. Nothing writes it and nothing reads it, so an empty
#                    one left on disk is exactly what sweep #4 exists to prune.
#
# Two janitor passes, because the guard only bites on the second: the first pass
# sees `telemetry` as non-empty (it still contains `cloud`) and would keep it for
# that reason alone, which proves nothing. Only once `cloud` is gone is
# `telemetry` empty at find time, and the drop-zone arm is then the sole thing
# standing between the ledgers' directory and `rmdir`.

@test "sweep 4: an empty telemetry/cloud is rmdir'd; the telemetry drop-zone survives even when empty" {
  make_repo
  mkdir -p "$REPO/.gaia/local/telemetry/cloud"
  cd "$REPO"

  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$REPO/.gaia/local/telemetry/cloud" ] && return 1
  [ -d "$REPO/.gaia/local/telemetry" ]

  # Second pass, with telemetry now empty at find time: the drop-zone arm is the
  # only thing keeping the ledgers' directory alive.
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/telemetry" ]
}

# The janitor's delegation to the one-time cleanup sweep is covered in that
# sweep's own suite (.gaia/scripts/tests/), which drives the real janitor against
# a fixture repo. It lives there rather than here because this file is inside the
# repo-wide term grep for the retired subsystem's vocabulary, and a delegation
# test cannot assert on what it is forbidden to name.
