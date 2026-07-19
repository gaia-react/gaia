#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/ledger-title-repair.sh`: the one-off,
# best-effort, idempotent repair of EXISTING specs `intent` / plans `subject`
# ledger rows plus the archived-PLAN `status`/`merged_at` stamp (U2 + U3
# existing-row repair).
#
# Does NOT use helpers/tmp-spec-repo.sh: that shared harness copies a fixed
# lib list that excludes ledger-title-repair.sh, title-normalize.sh, and
# plan-ledger-update.sh, and seeds only the specs ledger. Mirrors the
# self-copy sandbox pattern from `.gaia/scripts/tests/plan-archive.bats` and
# `.gaia/tests/lib/plan-ledger-update.bats`: copy the script under test plus
# every runtime dep it sources into a sibling lib dir so
# ${BASH_SOURCE[0]}-relative sourcing resolves, and seed both ledgers
# explicitly per test.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SRC_LIB="$REPO_ROOT/.specify/extensions/gaia/lib"
  [ -x "$SRC_LIB/ledger-title-repair.sh" ] || skip "ledger-title-repair.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"

  mkdir -p "$SANDBOX/.specify/extensions/gaia/lib"
  for f in ledger-title-repair.sh title-normalize.sh plan-ledger-update.sh \
           ledger-update.sh with-ledger-lock.sh; do
    cp "$SRC_LIB/$f" "$SANDBOX/.specify/extensions/gaia/lib/$f"
    chmod +x "$SANDBOX/.specify/extensions/gaia/lib/$f"
  done

  mkdir -p "$SANDBOX/.gaia/local/specs" "$SANDBOX/.gaia/local/plans"
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
}

_run_repair() {
  bash "$SANDBOX/.specify/extensions/gaia/lib/ledger-title-repair.sh" "$SANDBOX"
}

_specs_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg f "$field" \
    '.specs[] | select(.id == $id) | .[$f] // "null"' \
    "$SANDBOX/.gaia/local/specs/ledger.json"
}

_plans_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg f "$field" \
    '.plans[] | select(.id == $id) | .[$f] // "null"' \
    "$SANDBOX/.gaia/local/plans/ledger.json"
}

# --- 1. Specs intent repair --------------------------------------------------

@test "1: specs intent repair re-derives an over-bound intent, no longer the defect string, ends in ..." {
  cat > "$SANDBOX/.gaia/local/specs/ledger.json" <<'EOF'
{
  "version": 1,
  "specs": [
    {
      "id": "SPEC-003",
      "allocated_at": "2026-06-04T09:35:37Z",
      "source": "allocated",
      "status": "merged",
      "intent": "GAIA's test-driven workflow already instructs the agent to write a failing",
      "merged_at": "2026-06-04T12:53:33Z"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/specs/archived/SPEC-003"
  cat > "$SANDBOX/.gaia/local/specs/archived/SPEC-003/SPEC.md" <<'EOF'
---
spec_id: SPEC-003
status: archived
intent: |
  GAIA's test-driven workflow already instructs the agent to write a failing
  test first, but that "failing first" claim is self-certified: nothing checks
  the test actually ran and failed before the agent made it pass. This feature
success_criteria:
  - A test written but never executed cannot proceed to GREEN.
---

# SPEC-003
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  defect="GAIA's test-driven workflow already instructs the agent to write a failing"
  new_intent="$(_specs_field SPEC-003 intent)"
  [ "$new_intent" != "$defect" ]
  body="${new_intent%...}"
  [ "$body" != "$new_intent" ]
}

# --- 2. Plans subject repair from source ------------------------------------

@test "2: plans subject repair from SUMMARY.md source, no longer mid-word, no longer the defect string" {
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-001",
      "allocated_at": "2026-07-04T08:49:05Z",
      "source": "allocated",
      "subject": "Reframe /gaia-plan worktree isolation prompt: drop the experimental disclaimer, add a brief plain-la"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/archived/PLAN-001"
  cat > "$SANDBOX/.gaia/local/plans/archived/PLAN-001/SUMMARY.md" <<'EOF'
# PLAN-001 Summary

Reframe `/gaia-plan` worktree isolation prompt. Spec-less one-off plan, single task, single phase.

## Phase 1, reframe worktree isolation prompt

More content here that must not leak into the recovered subject.
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  new_subject="$(_plans_field PLAN-001 subject)"
  grep -qF "plain-la" <<<"$new_subject" && return 1
  [ "$new_subject" != "Reframe /gaia-plan worktree isolation prompt: drop the experimental disclaimer, add a brief plain-la" ]
}

# --- 2b. Plans subject repair skips the Commit: anchor line -----------------

@test "2b: plans subject repair skips a leading Commit: anchor line but still recovers a non-anchor Commit-prefixed prose line" {
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-100",
      "allocated_at": "2026-07-04T08:49:05Z",
      "source": "allocated",
      "subject": "placeholder subject one"
    },
    {
      "id": "PLAN-101",
      "allocated_at": "2026-07-04T08:49:05Z",
      "source": "allocated",
      "subject": "placeholder subject two"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/archived/PLAN-100"
  cat > "$SANDBOX/.gaia/local/plans/archived/PLAN-100/SUMMARY.md" <<'EOF'
## Phase 1, First
Commit: abc1234

Real prose line describing the phase.
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/archived/PLAN-101"
  cat > "$SANDBOX/.gaia/local/plans/archived/PLAN-101/SUMMARY.md" <<'EOF'
## Phase 1, Second
Committed the parser cleanly.

Some other paragraph that must not leak into the recovered subject.
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  subj_anchor="$(_plans_field PLAN-100 subject)"
  [ "$subj_anchor" = "Real prose line describing the phase." ]
  [ "$subj_anchor" != "Commit: abc1234" ]
  grep -qF "abc1234" <<<"$subj_anchor" && return 1

  subj_guard="$(_plans_field PLAN-101 subject)"
  [ "$subj_guard" = "Committed the parser cleanly." ]
}

# --- 2c. Plans subject repair from a consolidated SUMMARY.md H1 -------------

@test "2c: plans subject repair recovers the title from a consolidated SUMMARY.md H1, exact string match" {
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-200",
      "allocated_at": "2026-07-05T00:00:00Z",
      "source": "allocated",
      "subject": "placeholder subject"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/PLAN-200"
  cat > "$SANDBOX/.gaia/local/plans/PLAN-200/SUMMARY.md" <<'EOF'
---
wiki_promote_default: ask
wiki_promote_targets: [decisions]
---
# Add real-time collaboration cursors

Users now see teammates' live cursor positions in the shared canvas.
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  [ "$(_plans_field PLAN-200 subject)" = "Add real-time collaboration cursors" ]
}

# --- 2d. Plans subject repair falls back to PROGRESS.md ---------------------

@test "2d: plans subject repair falls back to PROGRESS.md when no SUMMARY.md is present" {
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-201",
      "allocated_at": "2026-07-05T00:00:00Z",
      "source": "allocated",
      "subject": "placeholder subject"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/PLAN-201"
  cat > "$SANDBOX/.gaia/local/plans/PLAN-201/PROGRESS.md" <<'EOF'
## Phase 1, First
Commit: abc1234

Recovered from the live PROGRESS.md ledger mid-run.
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  [ "$(_plans_field PLAN-201 subject)" = "Recovered from the live PROGRESS.md ledger mid-run." ]
}

# --- 2e. Plans subject repair falls back to README.md -----------------------

@test "2e: plans subject repair falls back to README.md when no SUMMARY.md or PROGRESS.md is present" {
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-202",
      "allocated_at": "2026-07-05T00:00:00Z",
      "source": "allocated",
      "subject": "placeholder subject"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/PLAN-202"
  cat > "$SANDBOX/.gaia/local/plans/PLAN-202/README.md" <<'EOF'
# PLAN-202

Recovered from the README fallback when no ledger file exists yet.
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  [ "$(_plans_field PLAN-202 subject)" = "Recovered from the README fallback when no ledger file exists yet." ]
}

# --- 3. Plans subject repair fallback ---------------------------------------

@test "3: plans subject fallback word-safe-trims the stored value when no source is recoverable" {
  long="This plan subject rambles on for quite a very long while with absolutely no period no exclamation and no question mark anywhere in the whole entire run-on text and it just kept truncat"
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<EOF
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-777",
      "allocated_at": "2026-01-01T00:00:00Z",
      "source": "allocated",
      "subject": "$long"
    }
  ]
}
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  new_subject="$(_plans_field PLAN-777 subject)"
  [ -n "$new_subject" ]
  [ "$new_subject" != "null" ]
  [ "$new_subject" != "$long" ]
  body="${new_subject%...}"
  [ "$body" != "$new_subject" ]
}

# --- 4. Status stamp (derivable) ---------------------------------------------

@test "4: archived PLAN row with a derivable cost.md generated stamp advances to merged with matching merged_at" {
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-002",
      "allocated_at": "2026-01-01T00:00:00Z",
      "source": "allocated",
      "subject": "some plan",
      "status": "allocated"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/archived/PLAN-002"
  cat > "$SANDBOX/.gaia/local/plans/archived/PLAN-002/cost.md" <<'EOF'
# Cost: PLAN-002 / PLAN-002

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 100 |
| Cache write | 10 |
| Cache read | 10 |
| Output | 20 |
| **Total** | 140 |

**Est. cost (USD):** $0.01

Session `abc123` · generated 2026-02-02T02:02:02Z
EOF

  run _run_repair
  [ "$status" -eq 0 ]

  [ "$(_plans_field PLAN-002 status)" = "merged" ]
  [ "$(_plans_field PLAN-002 merged_at)" = "2026-02-02T02:02:02Z" ]
}

# --- 4b. Status stamp (no derivable signal -> no fabrication) ---------------

@test "4b: archived PLAN row with no cost.md generated stamp advances to merged with no fabricated merged_at" {
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-003",
      "allocated_at": "2026-01-01T00:00:00Z",
      "source": "allocated",
      "subject": "some other plan",
      "status": "allocated"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/archived/PLAN-003"
  # Deliberately no cost.md at all: nothing to derive a "generated" stamp
  # from. The controlled (non-"now", non-allocated_at) folder mtime below
  # verifies the repair does not silently fall back to it as a signal.
  touch -t 202001010000 "$SANDBOX/.gaia/local/plans/archived/PLAN-003"

  run _run_repair
  [ "$status" -eq 0 ]

  [ "$(_plans_field PLAN-003 status)" = "merged" ]
  merged_at="$(_plans_field PLAN-003 merged_at)"
  [ "$merged_at" = "null" ]
  [ "$merged_at" != "2026-01-01T00:00:00Z" ]
}

# --- 5. Non-canonical safety -------------------------------------------------

@test "5: a specs row with no recoverable SPEC.md source is left byte-identical" {
  cat > "$SANDBOX/.gaia/local/specs/ledger.json" <<'EOF'
{
  "version": 1,
  "specs": [
    {
      "id": "SPEC-999",
      "allocated_at": "2026-01-01T00:00:00Z",
      "source": "allocated",
      "status": "merged",
      "intent": "some intent with no recoverable SPEC.md anywhere on disk",
      "merged_at": "2026-01-02T00:00:00Z"
    }
  ]
}
EOF

  before="$(cat "$SANDBOX/.gaia/local/specs/ledger.json")"
  run _run_repair
  [ "$status" -eq 0 ]
  after="$(cat "$SANDBOX/.gaia/local/specs/ledger.json")"
  [ "$before" = "$after" ]
}

# --- 6. Idempotency -----------------------------------------------------------

@test "6: running the repair twice yields an identical ledger after the second run" {
  cat > "$SANDBOX/.gaia/local/specs/ledger.json" <<'EOF'
{
  "version": 1,
  "specs": [
    {
      "id": "SPEC-003",
      "allocated_at": "2026-06-04T09:35:37Z",
      "source": "allocated",
      "status": "merged",
      "intent": "GAIA's test-driven workflow already instructs the agent to write a failing",
      "merged_at": "2026-06-04T12:53:33Z"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/specs/archived/SPEC-003"
  cat > "$SANDBOX/.gaia/local/specs/archived/SPEC-003/SPEC.md" <<'EOF'
---
spec_id: SPEC-003
status: archived
intent: |
  GAIA's test-driven workflow already instructs the agent to write a failing
  test first, but that "failing first" claim is self-certified: nothing checks
  the test actually ran and failed before the agent made it pass. This feature
success_criteria:
  - A test written but never executed cannot proceed to GREEN.
---

# SPEC-003
EOF

  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-001",
      "allocated_at": "2026-07-04T08:49:05Z",
      "source": "allocated",
      "subject": "Reframe /gaia-plan worktree isolation prompt: drop the experimental disclaimer, add a brief plain-la"
    }
  ]
}
EOF

  mkdir -p "$SANDBOX/.gaia/local/plans/archived/PLAN-001"
  cat > "$SANDBOX/.gaia/local/plans/archived/PLAN-001/SUMMARY.md" <<'EOF'
# PLAN-001 Summary

Reframe `/gaia-plan` worktree isolation prompt. Spec-less one-off plan, single task, single phase.

## Phase 1, reframe worktree isolation prompt

More content here that must not leak into the recovered subject.
EOF
  cat > "$SANDBOX/.gaia/local/plans/archived/PLAN-001/cost.md" <<'EOF'
Session `xyz` · generated 2026-07-04T09:07:28Z
EOF

  run _run_repair
  [ "$status" -eq 0 ]
  specs_after_1="$(cat "$SANDBOX/.gaia/local/specs/ledger.json")"
  plans_after_1="$(cat "$SANDBOX/.gaia/local/plans/ledger.json")"

  run _run_repair
  [ "$status" -eq 0 ]
  specs_after_2="$(cat "$SANDBOX/.gaia/local/specs/ledger.json")"
  plans_after_2="$(cat "$SANDBOX/.gaia/local/plans/ledger.json")"

  [ "$specs_after_1" = "$specs_after_2" ]
  [ "$plans_after_1" = "$plans_after_2" ]
}

# --- 7. Missing ledgers / usage -----------------------------------------------

@test "7: exits 0 even with no ledgers present at all" {
  rm -f "$SANDBOX/.gaia/local/specs/ledger.json" "$SANDBOX/.gaia/local/plans/ledger.json"
  run _run_repair
  [ "$status" -eq 0 ]
}

@test "7b: exits 0 (usage note only) when called with the wrong number of args" {
  run bash "$SANDBOX/.specify/extensions/gaia/lib/ledger-title-repair.sh"
  [ "$status" -eq 0 ]
}
