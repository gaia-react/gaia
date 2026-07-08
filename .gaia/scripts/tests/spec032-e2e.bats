#!/usr/bin/env bats
#
# Cross-producer + consumer-back-compat conformance harness for SPEC-032
# (audit-phase cost tracking). Phase 1/2 unit-test each piece (the FC-5 lib,
# token-tally.sh's FC-2 nesting and FC-3 review records, the hook's argument
# capture) against hand-authored or stubbed inputs. This suite is the ONE
# place that chains the REAL token-tally.sh, the REAL cost-represented.sh,
# the REAL token-rollup.sh, and the REAL token-tally-review.sh hook (with
# the REAL gaia-active-plan.sh resolver) together, so a field-name / kind /
# nesting drift between any two of them fails loudly here. It also closes
# two seams no Phase-2 unit test exercises: the breadcrumb WRITE path
# (DP-001, every Phase-2 test copies a pre-authored breadcrumb fixture
# instead of calling the real writer) and the resolver-driven association
# path (COV-002, every Phase-2 review test passes --spec-id directly).
#
# Mirrors cost-sidecar-e2e.bats (tally -> cost-represented) and
# token-cost-e2e.bats (tally -> rollup) in shape and non-circular,
# hand-computed-oracle discipline.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that is not the test's last command, so this suite uses `[ ]`, `grep -qF`,
# or an explicit `return 1` for every non-final assertion.
#
# ---------- fixtures reused from task-tally-core (never re-derived) ----------
# fixtures/token-tally/auditreview/projects (session fixtureauditreview0001):
#   main (decoy, outside every window) + two general-purpose adversarial-audit
#   sidecars (agent-aud0001 @10:05:10, agent-aud0002 @10:06:00) + one
#   code-review-audit sidecar (agent-rev0001, 11:00:00-11:02:00) with one
#   nested general-purpose sub-agent (agent-revnest0001 @11:01:00).
#   Hand-computed (identical derivation to token-tally.bats's header, restated
#   here because this suite writes its own breadcrumb rather than copying the
#   checked-in one):
#     audit window [10:05:00Z,10:07:00Z] selects aud0001+aud0002 only:
#       fresh=10+11=21 cwrite=20+21=41 cread=30+31=61 output=40+41=81
#       elapsed = 10:06:00 - 10:05:10 = 50s
#     phase (spec/plan) = main+aud0001+aud0002 (review window excluded):
#       fresh=1+10+11=22 cwrite=2+20+21=43 cread=3+30+31=64 output=4+40+41=85
#       total=214
#     review record (rev-a+rev-b+nest-a): fresh=115 cwrite=220 cread=324
#       output=430 total=1089, duration_seconds=120, review_id "agent-rev0001"
# fixtures/token-tally/projects (session fixturesession0001): the anchor
#   fixture, carries NO code-review-audit sidecar at all (the spurious-guard
#   no-op case).
#
# ---------- fixture authored for this suite ----------
# fixtures/spec032-e2e/elapsed-span/projects (session fixturespec032span0001):
#   built specifically to exercise UAT-004's "elapsed <= sum of individual
#   spans, equal only when back-to-back" clause -- the auditreview fixture's
#   audit sub-agents are each a SINGLE usage line (zero individual span), so
#   their sum S=0 cannot demonstrate the inequality. Two general-purpose
#   sidecars with real, OVERLAPPING internal spans:
#     agent-lensa0001: usage @02:00:00.000Z (fresh=5 cwrite=1 cread=2 out=3)
#       and @02:00:20.000Z (fresh=6 cwrite=1 cread=2 out=3) -> span 20s
#     agent-lensb0001: usage @02:00:10.000Z (fresh=7 cwrite=1 cread=2 out=3)
#       and @02:00:25.000Z (fresh=8 cwrite=1 cread=2 out=3) -> span 15s
#     main: one decoy usage line @01:00:00.000Z (fresh=1 cwrite=1 cread=1 out=1)
#   breadcrumb window [02:00:00Z,02:00:25Z] contains both sidecars fully:
#     audit buckets: fresh=5+6+7+8=26 cwrite=1*4=4 cread=2*4=8 output=3*4=12
#     audit elapsed = max(02:00:25) - min(02:00:00) = 25s
#     S = per-file spans 20+15 = 35s; 25 <= 35, strictly less (the sidecars
#     overlap, they do not run back-to-back)
#     phase total = main(4) + audit(50) = fresh=27 cwrite=5 cread=9 output=13
#       total=54

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TALLY="$SCRIPT_DIR/token-tally.sh"
  ROLLUP="$SCRIPT_DIR/token-rollup.sh"
  GATE="$SCRIPT_DIR/cost-represented.sh"
  AUDIT_LIB="$SCRIPT_DIR/audit-window-lib.sh"
  HELPERS="$REPO_ROOT/.gaia/tests/hooks/helpers"

  FIX_TALLY="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"
  FIX_E2E="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/spec032-e2e" && pwd)"

  AR="$FIX_TALLY/auditreview/projects"
  AR_SESSION="fixtureauditreview0001"
  ANCHOR="$FIX_TALLY/projects"
  ANCHOR_SESSION="fixturesession0001"
  SPAN="$FIX_E2E/elapsed-span/projects"
  SPAN_SESSION="fixturespec032span0001"

  # shellcheck source=.gaia/scripts/audit-window-lib.sh
  source "$AUDIT_LIB"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

# ---------- shared hook-integration harness (items 5b/10) ----------
write_running() {
  # write_running <plan_dir> <branch> <started>
  mkdir -p "$1"
  { printf 'branch: %s\n' "$2"; printf 'slug: %s\n' "$(basename "$1")"; printf 'started: %s\n' "$3"; } > "$1/RUNNING"
}

write_readme_with_spec() {
  # write_readme_with_spec <plan_dir> <spec_path>
  mkdir -p "$1"
  {
    printf '# Plan\n\n'
    printf '## Source SPEC\n\n'
    printf 'Derived from %s (%s).\n' "$(basename "$(dirname "$2")")" "$2"
  } > "$1/README.md"
}

# Scaffolds a tmp git repo with the REAL producer scripts (never a stub) at
# their real repo-relative paths, so the hook's internal repo-relative
# source/exec calls resolve exactly as they do in production. Sets $REPO.
build_full_repo() {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT/.claude/hooks/token-tally-review.sh" "$REPO/.claude/hooks/token-tally-review.sh"
  chmod +x "$REPO/.claude/hooks/token-tally-review.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-active-plan.sh" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$REPO_ROOT/.gaia/scripts/token-tally.sh" "$REPO/.gaia/scripts/token-tally.sh"
  chmod +x "$REPO/.gaia/scripts/token-tally.sh"
  cp "$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh" "$REPO/.gaia/scripts/token-pricing-lib.sh"
  cp "$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$REPO_ROOT/.gaia/scripts/audit-window-lib.sh" "$REPO/.gaia/scripts/audit-window-lib.sh"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/with-ledger-lock.sh" "$REPO/.specify/extensions/gaia/lib/with-ledger-lock.sh"
}

ledger_path() {
  printf '%s/.gaia/local/telemetry/cost.jsonl' "$REPO"
}

# =====================================================================
# 1 + 1b. Adversarial-audit nesting via the REAL breadcrumb WRITER (DP-001,
# UAT-001, UAT-002)
# =====================================================================
@test "1+1b: gaia_audit_window_write produces the FC-1 spec breadcrumb, and the real spec tally nests audit.adversarial from it" {
  CACHE="$BATS_TEST_TMPDIR/cache-1"
  mkdir -p "$CACHE"
  OUTDIR="$BATS_TEST_TMPDIR/out-1"
  LEDGER="$BATS_TEST_TMPDIR/ledger-1.jsonl"

  # The producer-side seam under test: the SAME function spec.md step 7
  # sources and calls, never a hand-authored breadcrumb file.
  bc_path="$CACHE/audit-window-SPEC-032.json"
  run gaia_audit_window_write "$bc_path" "$AR_SESSION" \
    "2026-08-01T10:05:00Z" "2026-08-01T10:07:00Z" '["FG","TST","COV","RT"]' "standard"
  [ "$status" -eq 0 ]

  # FC-1 path + shape: session_id, started_at, ended_at, lenses, intensity.
  [ -f "$bc_path" ]
  [ "$(jq -r '.session_id' "$bc_path")" = "$AR_SESSION" ]
  [ "$(jq -r '.started_at' "$bc_path")" = "2026-08-01T10:05:00Z" ]
  [ "$(jq -r '.ended_at' "$bc_path")" = "2026-08-01T10:07:00Z" ]
  [ "$(jq -c '.lenses' "$bc_path")" = '["FG","TST","COV","RT"]' ]
  [ "$(jq -r '.intensity' "$bc_path")" = "standard" ]

  # Feed THAT written file into the real spec tally.
  run bash "$TALLY" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTDIR" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  led() { jq -r "$1" "$LEDGER"; }
  [ "$(led '.audit.adversarial.buckets.fresh_input')" -eq 21 ]
  [ "$(led '.audit.adversarial.buckets.cache_write')" -eq 41 ]
  [ "$(led '.audit.adversarial.buckets.cache_read')" -eq 61 ]
  [ "$(led '.audit.adversarial.buckets.output')" -eq 81 ]
  [ "$(led '.audit.adversarial.elapsed_seconds')" -eq 50 ]
  [ "$(led '.audit.adversarial.dollars')" = "null" ]
  [ "$(led '.audit.adversarial.intensity')" = "standard" ]
  [ "$(led '.audit.adversarial.lenses | sort | join(",")')" = "COV,FG,RT,TST" ]

  # Identical on the cost.jsonl row AND the cost.json sidecar's .spec value.
  ledger_audit="$(jq -c '.audit' "$LEDGER")"
  sidecar_audit="$(jq -c '.spec.audit' "$OUTDIR/cost.json")"
  [ "$ledger_audit" = "$sidecar_audit" ]

  # The tally consumed (deleted) the breadcrumb it just read.
  [ ! -f "$bc_path" ]
}

@test "1b: plan-form breadcrumb write omits intensity and is namespaced by the SPEC id, never audit-window-plan.json (DP-002/CG-001)" {
  CACHE="$BATS_TEST_TMPDIR/cache-1b"
  mkdir -p "$CACHE"
  OUTDIR="$BATS_TEST_TMPDIR/out-1b"
  LEDGER="$BATS_TEST_TMPDIR/ledger-1b.jsonl"

  # Empty 6th arg (no intensity) -- the plan-audit form.
  bc_path="$CACHE/audit-window-SPEC-032-plan.json"
  run gaia_audit_window_write "$bc_path" "$AR_SESSION" \
    "2026-08-01T10:05:00Z" "2026-08-01T10:07:00Z" '["DP","CG","COV"]' ""
  [ "$status" -eq 0 ]
  [ -f "$bc_path" ]
  jq -e 'has("intensity")' >/dev/null 2>&1 "$bc_path" && return 1
  # Namespaced by the SPEC id, never the plan-dir basename literal "plan".
  [ ! -e "$CACHE/audit-window-plan.json" ]

  run bash "$TALLY" --action plan --spec-id SPEC-032 --plan-slug spec-032-e2e \
    --out-dir "$OUTDIR" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  led() { jq -r "$1" "$LEDGER"; }
  # UAT-005: plan shape carries buckets/dollars/elapsed_seconds/lenses, no intensity.
  [ "$(led '.audit.adversarial.buckets.fresh_input')" -eq 21 ]
  [ "$(led '.audit.adversarial.buckets.output')" -eq 81 ]
  [ "$(led '.audit.adversarial.elapsed_seconds')" -eq 50 ]
  [ "$(led '.audit.adversarial.lenses | sort | join(",")')" = "CG,COV,DP" ]
  run jq -e '.audit.adversarial | has("intensity")' "$LEDGER"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]

  # Phase total unaffected (item 2/UAT-003 restated for the plan form).
  [ "$(led '.buckets.fresh_input')" -eq 22 ]
  [ "$(led '.total')" -eq 214 ]
}

# =====================================================================
# 2. UAT-003: subset invariant, phase totals unaffected, no double-count
# =====================================================================
@test "2: audit buckets are a strict subset, phase total/buckets are IDENTICAL with vs without the nesting, one row only" {
  # Without any breadcrumb (empty cache dir).
  NOBC_CACHE="$BATS_TEST_TMPDIR/nobc-cache"
  mkdir -p "$NOBC_CACHE"
  LEDGER_A="$BATS_TEST_TMPDIR/ledger-a.jsonl"
  run bash "$TALLY" --action spec --spec-id SPEC-032 \
    --out-dir "$BATS_TEST_TMPDIR/out-a" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER_A" --cache-dir "$NOBC_CACHE"
  [ "$status" -eq 0 ]

  # With a freshly written breadcrumb.
  WBC_CACHE="$BATS_TEST_TMPDIR/wbc-cache"
  mkdir -p "$WBC_CACHE"
  run gaia_audit_window_write "$WBC_CACHE/audit-window-SPEC-032.json" "$AR_SESSION" \
    "2026-08-01T10:05:00Z" "2026-08-01T10:07:00Z" '["FG","TST","COV","RT"]' "standard"
  [ "$status" -eq 0 ]
  LEDGER_B="$BATS_TEST_TMPDIR/ledger-b.jsonl"
  run bash "$TALLY" --action spec --spec-id SPEC-032 \
    --out-dir "$BATS_TEST_TMPDIR/out-b" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER_B" --cache-dir "$WBC_CACHE"
  [ "$status" -eq 0 ]

  # The presence of the nesting changes nothing about the phase record itself.
  [ "$(jq -c '.buckets' "$LEDGER_A")" = "$(jq -c '.buckets' "$LEDGER_B")" ]
  [ "$(jq -r '.total' "$LEDGER_A")" = "$(jq -r '.total' "$LEDGER_B")" ]
  [ "$(jq -r '.total' "$LEDGER_B")" -eq 214 ]

  run jq -e 'has("audit")' "$LEDGER_A"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]

  # Subset: every audit bucket <= the phase bucket.
  led() { jq -r "$1" "$LEDGER_B"; }
  [ "$(led '.audit.adversarial.buckets.fresh_input <= .buckets.fresh_input')" = "true" ]
  [ "$(led '.audit.adversarial.buckets.cache_write <= .buckets.cache_write')" = "true" ]
  [ "$(led '.audit.adversarial.buckets.cache_read <= .buckets.cache_read')" = "true" ]
  [ "$(led '.audit.adversarial.buckets.output <= .buckets.output')" = "true" ]

  # No second row re-counts the audit spend: exactly one line, and no row on
  # the ledger carries the audit subset's own total (204) as its OWN total.
  [ "$(wc -l < "$LEDGER_B" | tr -d ' ')" -eq 1 ]
  audit_total=$(( $(led '.audit.adversarial.buckets.fresh_input') + $(led '.audit.adversarial.buckets.cache_write') + $(led '.audit.adversarial.buckets.cache_read') + $(led '.audit.adversarial.buckets.output') ))
  [ "$audit_total" -eq 204 ]
  run jq -e --argjson at "$audit_total" '[inputs | select(.total == $at)] | length' "$LEDGER_B"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# =====================================================================
# 3. UAT-004: elapsed_seconds is the union span, <= sum of individual spans
# =====================================================================
@test "3: elapsed_seconds equals the union span of overlapping sub-agents, strictly less than the sum of their individual spans" {
  CACHE="$BATS_TEST_TMPDIR/cache-3"
  mkdir -p "$CACHE"
  run gaia_audit_window_write "$CACHE/audit-window-SPEC-SPAN.json" "$SPAN_SESSION" \
    "2026-09-01T02:00:00Z" "2026-09-01T02:00:25Z" '["FG"]' "standard"
  [ "$status" -eq 0 ]

  OUTDIR="$BATS_TEST_TMPDIR/out-3"
  LEDGER="$BATS_TEST_TMPDIR/ledger-3.jsonl"
  run bash "$TALLY" --action spec --spec-id SPEC-SPAN \
    --out-dir "$OUTDIR" --session-id "$SPAN_SESSION" \
    --projects-root "$SPAN" --ledger "$LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  led() { jq -r "$1" "$LEDGER"; }
  # Hand-computed: max(02:00:25) - min(02:00:00) = 25s.
  [ "$(led '.audit.adversarial.elapsed_seconds')" -eq 25 ]
  [ "$(led '.audit.adversarial.buckets.fresh_input')" -eq 26 ]
  [ "$(led '.audit.adversarial.buckets.cache_write')" -eq 4 ]
  [ "$(led '.audit.adversarial.buckets.cache_read')" -eq 8 ]
  [ "$(led '.audit.adversarial.buckets.output')" -eq 12 ]

  # Sum of the two sub-agents' own spans: lensa 20s + lensb 15s = 35s. The
  # union span (25s) is <= that sum, strictly less because the two sub-agents
  # OVERLAP rather than running strictly back-to-back.
  s=35
  elapsed="$(led '.audit.adversarial.elapsed_seconds')"
  [ "$elapsed" -le "$s" ]
  [ "$elapsed" -lt "$s" ]

  # Phase total unaffected: main(4) + audit(50) = 54.
  [ "$(led '.total')" -eq 54 ]
}

# =====================================================================
# 4. UAT-009 degrade: absent breadcrumb / session_id mismatch omit .audit
# =====================================================================
@test "4: degrade -- absent breadcrumb and a session_id-mismatched breadcrumb both omit .audit while the phase record is still written" {
  # Absent: no breadcrumb file at all for SPEC-032 in this cache dir.
  EMPTY_CACHE="$BATS_TEST_TMPDIR/empty-cache"
  mkdir -p "$EMPTY_CACHE"
  LEDGER_A="$BATS_TEST_TMPDIR/ledger-absent.jsonl"
  run bash "$TALLY" --action spec --spec-id SPEC-032 \
    --out-dir "$BATS_TEST_TMPDIR/out-absent" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER_A" --cache-dir "$EMPTY_CACHE"
  [ "$status" -eq 0 ]
  run jq -e 'has("audit")' "$LEDGER_A"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
  [ "$(jq -r '.total' "$LEDGER_A")" -eq 214 ]

  # Session mismatch: the breadcrumb's session_id differs from the tally's.
  MISMATCH_CACHE="$BATS_TEST_TMPDIR/mismatch-cache"
  mkdir -p "$MISMATCH_CACHE"
  bc_path="$MISMATCH_CACHE/audit-window-SPEC-032.json"
  run gaia_audit_window_write "$bc_path" "some-other-session" \
    "2026-08-01T10:05:00Z" "2026-08-01T10:07:00Z" '["FG","TST","COV","RT"]' "standard"
  [ "$status" -eq 0 ]

  LEDGER_B="$BATS_TEST_TMPDIR/ledger-mismatch.jsonl"
  run bash "$TALLY" --action spec --spec-id SPEC-032 \
    --out-dir "$BATS_TEST_TMPDIR/out-mismatch" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER_B" --cache-dir "$MISMATCH_CACHE"
  [ "$status" -eq 0 ]
  run jq -e 'has("audit")' "$LEDGER_B"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
  [ "$(jq -r '.total' "$LEDGER_B")" -eq 214 ]
  # The mismatched breadcrumb is still consumed (read once, then removed).
  [ ! -f "$bc_path" ]
}

# =====================================================================
# 5/6/7/10. Review records: resolver association (UAT-008), counted once
# (UAT-006), ad-hoc (UAT-007), counted-once across triggers, spurious guard
# =====================================================================
@test "5: --action review with no association is ad-hoc (null/null), not partial, and never surfaces under any feature's rollup (UAT-007/UAT-010)" {
  LEDGER="$BATS_TEST_TMPDIR/ledger-adhoc.jsonl"
  run bash "$TALLY" --action review \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.spec_id' "$LEDGER")" = "null" ]
  [ "$(jq -r '.plan_id' "$LEDGER")" = "null" ]
  [ "$(jq -r '.source' "$LEDGER")" = "code-review-audit" ]
  [ "$(jq -r '.partial' "$LEDGER")" = "false" ]

  # A null/null review row carries no spec_id/plan_id, so it matches no
  # feature's rollup filter: the ledger has only a "review" kind row, so the
  # rollup finds nothing at all for any feature key.
  run bash "$ROLLUP" --spec-id SPEC-032 --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  assert_contains "no ledger records found"
}

@test "6: resolver-driven association (UAT-008) via gaia-active-plan.sh, counted once across the Bash and Stop triggers, phase excludes the review window (UAT-006)" {
  build_full_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/specs/SPEC-810/plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-810/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  # Bash gh-pr-merge trigger: resolves via resolve_active_plan_dir +
  # resolve_feature_key (NOT --spec-id), records the review row for real.
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use "$AR_SESSION" Bash "gh pr merge 1")
  run env GAIA_TALLY_PROJECTS_ROOT="$AR" bash -c "echo '$input' | '$REPO/.claude/hooks/token-tally-review.sh'"
  [ "$status" -eq 0 ]

  LEDGER="$(ledger_path)"
  [ -f "$LEDGER" ]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]
  # UAT-008: the recorded association equals exactly what the resolver
  # returns for this branch/sentinel -- SPEC-810, never a passed --spec-id.
  [ "$(jq -r '.kind' "$LEDGER")" = "review" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "SPEC-810" ]
  [ "$(jq -r '.plan_id' "$LEDGER")" = "null" ]
  [ "$(jq -r '.source' "$LEDGER")" = "code-review-audit" ]
  [ "$(jq -r '.review_id' "$LEDGER")" = "agent-rev0001" ]

  # Stop trigger for the SAME session: dedup by review_id keeps exactly one
  # row (the merge-then-Stop double-fire).
  stop_input=$("$HELPERS/mock-hook-input.sh" stop "$AR_SESSION")
  run env GAIA_TALLY_PROJECTS_ROOT="$AR" bash -c "echo '$stop_input' | '$REPO/.claude/hooks/token-tally-review.sh'"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]

  # UAT-006 (counted once): an execute tally on the SAME session, into the
  # SAME ledger, excludes the review window from the phase buckets -- the
  # review's own spend is not folded into any phase total.
  run bash "$REPO/.gaia/scripts/token-tally.sh" --action execute --spec-id SPEC-810 \
    --plan-slug spec-810-e2e --out-dir "$BATS_TEST_TMPDIR/out-6" \
    --session-id "$AR_SESSION" --projects-root "$AR"
  [ "$status" -eq 0 ]

  exec_row="$(grep '"kind":"execute"' "$LEDGER")"
  [ "$(jq -r '.buckets.fresh_input' <<<"$exec_row")" -eq 22 ]
  [ "$(jq -r '.buckets.cache_write' <<<"$exec_row")" -eq 43 ]
  [ "$(jq -r '.buckets.cache_read' <<<"$exec_row")" -eq 64 ]
  [ "$(jq -r '.buckets.output' <<<"$exec_row")" -eq 85 ]
  [ "$(jq -r '.total' <<<"$exec_row")" -eq 214 ]
  [ "$(jq -r '.total' <<<"$exec_row")" -ne 1303 ]

  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 2 ]
}

@test "10: a session with no code-review-audit run triggers zero rows (spurious guard)" {
  build_full_repo
  cd "$REPO"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use "$ANCHOR_SESSION" Bash "gh pr merge")
  run env GAIA_TALLY_PROJECTS_ROOT="$ANCHOR" bash -c "echo '$input' | '$REPO/.claude/hooks/token-tally-review.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$(ledger_path)" ]

  stop_input=$("$HELPERS/mock-hook-input.sh" stop "$ANCHOR_SESSION")
  run env GAIA_TALLY_PROJECTS_ROOT="$ANCHOR" bash -c "echo '$stop_input' | '$REPO/.claude/hooks/token-tally-review.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$(ledger_path)" ]
}

# =====================================================================
# 9. UAT-010: back-compat -- pre-existing rows untouched, schema_version 1,
# cost-represented and token-rollup unaffected by the new audit/review rows
# =====================================================================
write_legacy_row() {
  # write_legacy_row <ledger> <kind> <spec_id> <session_id> <f> <cw> <cr> <o> <ts>
  local ledger="$1" kind="$2" spec_id="$3" sid="$4" f="$5" cw="$6" cr="$7" o="$8" ts="$9"
  local total=$((f + cw + cr + o))
  jq -nc --arg kind "$kind" --arg spec_id "$spec_id" --arg sid "$sid" \
    --argjson f "$f" --argjson cw "$cw" --argjson cr "$cr" --argjson o "$o" \
    --argjson total "$total" --arg ts "$ts" '
    {
      schema_version: 1, kind: $kind, spec_id: $spec_id, plan_id: null, plan_slug: null,
      session_id: $sid,
      buckets: {fresh_input: $f, cache_write: $cw, cache_read: $cr, output: $o},
      total: $total, dollars: null, rate_table_id: null, partial: false,
      started_at: $ts, ended_at: $ts, duration_seconds: 10, duration_available: true,
      git_branch: null, project: null, seq: 0, final: true, ts: $ts, session_cwd: null
    }' >> "$ledger"
}

@test "9: pre-existing no-audit rows survive untouched, new rows carry schema_version 1, cost-represented and token-rollup stay correct with review + nested-audit rows mixed in" {
  LEDGER="$BATS_TEST_TMPDIR/ledger-backcompat.jsonl"

  # Pre-existing legacy rows (pre-SPEC-032 shape: no `audit` key at all,
  # written by hand because they represent EXISTING ledger content, never
  # produced by the code under test).
  write_legacy_row "$LEDGER" spec SPEC-777 sess-legacy-spec 100 100 200 100 "2026-05-01T00:00:00Z"
  write_legacy_row "$LEDGER" execute SPEC-777 sess-legacy-exec 200 200 200 100 "2026-05-02T00:00:00Z"
  legacy_spec_line="$(sed -n '1p' "$LEDGER")"
  legacy_exec_line="$(sed -n '2p' "$LEDGER")"

  # New row 1: a real nested-audit spec row for a DIFFERENT feature (SPEC-032).
  CACHE="$BATS_TEST_TMPDIR/cache-9"
  mkdir -p "$CACHE"
  run gaia_audit_window_write "$CACHE/audit-window-SPEC-032.json" "$AR_SESSION" \
    "2026-08-01T10:05:00Z" "2026-08-01T10:07:00Z" '["FG","TST","COV","RT"]' "standard"
  [ "$status" -eq 0 ]
  OUTDIR="$BATS_TEST_TMPDIR/out-9"
  run bash "$TALLY" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTDIR" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  # New row 2: a real standalone review row, associated to the same SPEC-032.
  run bash "$TALLY" --action review --spec-id SPEC-032 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # ---- (a) pre-existing rows parse and are unchanged, byte for byte ----
  [ "$(sed -n '1p' "$LEDGER")" = "$legacy_spec_line" ]
  [ "$(sed -n '2p' "$LEDGER")" = "$legacy_exec_line" ]
  [ "$(jq -r 'select(.session_id=="sess-legacy-spec") | .total' "$LEDGER")" -eq 500 ]
  [ "$(jq -r 'select(.session_id=="sess-legacy-exec") | .total' "$LEDGER")" -eq 700 ]

  # ---- (b) every new row carries schema_version 1 ----
  [ "$(jq -r 'select(.session_id=="'"$AR_SESSION"'" and .kind=="spec") | .schema_version' "$LEDGER")" -eq 1 ]
  [ "$(jq -r 'select(.kind=="review") | .schema_version' "$LEDGER")" -eq 1 ]

  # ---- (c) cost_folder_represented: same verdict with vs without .audit,
  # never chokes on a kind:"review" row mixed into the same ledger ----
  # shellcheck source=/dev/null
  . "$GATE"
  run cost_folder_represented "$OUTDIR" spec_id SPEC-032 "$LEDGER"
  [ "$status" -eq 0 ]
  assert_contains "$(printf 'spec\tREPRESENTED')"

  jq 'del(.spec.audit)' "$OUTDIR/cost.json" > "$OUTDIR/cost.json.tmp"
  mv "$OUTDIR/cost.json.tmp" "$OUTDIR/cost.json"
  run jq -e '.spec | has("audit") | not' "$OUTDIR/cost.json"
  [ "$status" -eq 0 ]
  run cost_folder_represented "$OUTDIR" spec_id SPEC-032 "$LEDGER"
  [ "$status" -eq 0 ]
  assert_contains "$(printf 'spec\tREPRESENTED')"

  # ---- (d) token-rollup.sh: SPEC-032's total is the phase total only (214),
  # never inflated by the nested audit subset (204) nor by the review row
  # (1089); the untouched legacy feature (SPEC-777) rolls up correctly too ----
  run bash "$ROLLUP" --spec-id SPEC-032 --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  assert_contains "$(printf '  %-11s%*s' 'spec:' 3 214)"
  if grep -qF '1,089' <<<"$output"; then
    echo "review total leaked into the SPEC-032 rollup" >&2
    return 1
  fi
  if grep -qF '418' <<<"$output"; then
    echo "audit subset was double-counted into the SPEC-032 rollup" >&2
    return 1
  fi

  run bash "$ROLLUP" --spec-id SPEC-777 --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  assert_contains "Cycle cost (SPEC-777)"
  assert_contains "$(printf '  %-11s%*s' 'spec:' 5 500)"
  assert_contains "$(printf '  %-11s%*s' 'execute:' 5 700)"
  assert_contains "$(printf '  %-11s%*s' 'Total:' 5 '1,200')"
}
