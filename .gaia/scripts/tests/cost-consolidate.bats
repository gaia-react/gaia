#!/usr/bin/env bats
# Tests for the shared cost-consolidate.sh routine (FC-6, archive-consolidate).
#
# Mode `spec` runs against an active .gaia/local/specs/<id>/ folder BEFORE the
# caller moves it to archived/: it splices the SPEC-root and plan-folder
# cost.md sections into one dollars-led cost.md with a grand `## Total`,
# moves SUMMARY.md up, and prunes every plan/plan-N subfolder. Mode
# `plan-total` just appends/refreshes a `## Total` on a spec-less plan's
# Planning+Execution cost.md. Both share the same grand-total arithmetic.
#
# Assertion style note: bare `grep`/`[ ... ]`/`!` are used throughout instead
# of `[[ ... ]]` for any non-terminal assertion, per
# .claude/rules/bats-assertions.md (a false `[[ ... ]]` is silently skipped
# under bash 3.2's `set -e`, which is what macOS's default `/bin/bash`
# resolves to for bats-core).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.specify/extensions/gaia/lib/cost-consolidate.sh"
  [ -x "$SCRIPT" ] || skip "cost-consolidate.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

_consolidate() {
  bash "$SCRIPT" "$@"
}

# seed_spec_folder <spec_id>: SPEC.md, AUDIT.md, a `## SPEC` cost.md ($0.10),
# and plan/ carrying `## Planning` ($0.20) + `## Execution` ($0.30) plus
# SUMMARY.md -- the AC1 fixture shape.
seed_spec_folder() {
  local id="$1" dir="$SANDBOX/.gaia/local/specs/$1"
  mkdir -p "$dir/plan"
  echo "spec body" > "$dir/SPEC.md"
  echo "audit body" > "$dir/AUDIT.md"
  cat > "$dir/cost.md" <<'EOF'
# Cost: SPEC-Z

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 100 |
| Cache write | 10 |
| Cache read | 5 |
| Output | 20 |
| **Total** | 135 |

**Est. cost (USD):** $0.10
EOF
  cat > "$dir/plan/cost.md" <<'EOF'
# Cost: SPEC-Z / spec-z-slug

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 200 |
| Cache write | 20 |
| Cache read | 10 |
| Output | 40 |
| **Total** | 270 |

**Est. cost (USD):** $0.20

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 300 |
| Cache write | 30 |
| Cache read | 15 |
| Output | 60 |
| **Total** | 405 |

**Est. cost (USD):** $0.30
EOF
  echo "plan summary body" > "$dir/plan/SUMMARY.md"
}

# --- 1. Mode spec: flattens the folder, splices all four sections ----------

@test "spec mode: flattens the folder and splices SPEC/Planning/Execution/Total" {
  seed_spec_folder SPEC-Z
  dir="$SANDBOX/.gaia/local/specs/SPEC-Z"

  run _consolidate spec "$SANDBOX" SPEC-Z
  [ "$status" -eq 0 ]

  [ ! -d "$dir/plan" ]
  count="$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$count" -eq 4 ]
  [ -f "$dir/AUDIT.md" ]
  [ -f "$dir/SPEC.md" ]
  [ -f "$dir/SUMMARY.md" ]
  [ -f "$dir/cost.md" ]

  [ "$(cat "$dir/SUMMARY.md")" = "plan summary body" ]

  grep -qx '## SPEC' "$dir/cost.md"
  grep -qx '## Planning' "$dir/cost.md"
  grep -qx '## Execution' "$dir/cost.md"
  grep -qx '## Total' "$dir/cost.md"
}

# --- 2. Grand-total oracle: priced sections sum, bucket table sums ---------

@test "grand total: sums priced sections and shows the summed bucket table" {
  seed_spec_folder SPEC-Z
  dir="$SANDBOX/.gaia/local/specs/SPEC-Z"

  run _consolidate spec "$SANDBOX" SPEC-Z
  [ "$status" -eq 0 ]

  total="$(awk '/^## Total$/{f=1} f' "$dir/cost.md")"
  printf '%s\n' "$total" | grep -qF '**Est. cost (USD):** $0.60'
  printf '%s\n' "$total" | grep -qE '\| Fresh input \| 600 \|'
  printf '%s\n' "$total" | grep -qE '\| Cache write \| 60 \|'
  printf '%s\n' "$total" | grep -qE '\| Cache read \| 30 \|'
  printf '%s\n' "$total" | grep -qE '\| Output \| 120 \|'
  printf '%s\n' "$total" | grep -qE '\| \*\*Total\*\* \| 810 \|'
}

# --- 3. Lower-bound / unavailable propagation, never a fabricated figure ---

@test "grand total: a lower-bound section marks the Total a floor without fabricating a figure" {
  mkdir -p "$SANDBOX/.gaia/local/specs/SPEC-F/plan"
  dir="$SANDBOX/.gaia/local/specs/SPEC-F"
  cat > "$dir/cost.md" <<'EOF'
# Cost: SPEC-F

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 1 |
| **Total** | 4 |

**Est. cost (USD):** $0.05
_Lower bound: unpriced model(s) foo-bar._
EOF
  cat > "$dir/plan/cost.md" <<'EOF'
## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 2 |
| Cache write | 2 |
| Cache read | 2 |
| Output | 2 |
| **Total** | 8 |

_Est. cost (USD): unavailable (rate table unreadable)._

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 3 |
| Cache write | 3 |
| Cache read | 3 |
| Output | 3 |
| **Total** | 12 |

**Est. cost (USD):** $0.15
EOF

  run _consolidate spec "$SANDBOX" SPEC-F
  [ "$status" -eq 0 ]

  total="$(awk '/^## Total$/{f=1} f' "$dir/cost.md")"
  # Only the two priced sections ($0.05 + $0.15) ever contribute; the
  # unpriced Planning section is never guessed at.
  printf '%s\n' "$total" | grep -qF '**Est. cost (USD):** $0.20'
  printf '%s\n' "$total" | grep -qF '_Lower bound: one or more sections are a lower bound or unavailable; the total is a floor._'
}

@test "grand total: no section priced anywhere renders the Total unavailable, never \$0.00" {
  mkdir -p "$SANDBOX/.gaia/local/specs/SPEC-U/plan"
  dir="$SANDBOX/.gaia/local/specs/SPEC-U"
  cat > "$dir/plan/cost.md" <<'EOF'
## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 0 |
| Cache read | 0 |
| Output | 0 |
| **Total** | 1 |

_Est. cost (USD): unavailable (per-model attribution unavailable)._

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 2 |
| Cache write | 0 |
| Cache read | 0 |
| Output | 0 |
| **Total** | 2 |

_Est. cost (USD): unavailable (per-model attribution unavailable)._
EOF

  run _consolidate spec "$SANDBOX" SPEC-U
  [ "$status" -eq 0 ]

  total="$(awk '/^## Total$/{f=1} f' "$dir/cost.md")"
  printf '%s\n' "$total" | grep -qF '_Est. cost (USD): unavailable'
  ! printf '%s\n' "$total" | grep -qF '**Est. cost (USD):**'
}

# --- 4. Re-planned case: consolidate from the plan-N that has Execution ----

@test "re-planned case: consolidates from plan-2 (the one with Execution), prunes both" {
  dir="$SANDBOX/.gaia/local/specs/SPEC-R"
  mkdir -p "$dir/plan" "$dir/plan-2"
  cat > "$dir/plan/cost.md" <<'EOF'
## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 999 |
| Cache write | 0 |
| Cache read | 0 |
| Output | 0 |
| **Total** | 999 |

**Est. cost (USD):** $9.99
EOF
  echo "stale summary" > "$dir/plan/SUMMARY.md"
  cat > "$dir/plan-2/cost.md" <<'EOF'
## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 50 |
| Cache write | 5 |
| Cache read | 2 |
| Output | 10 |
| **Total** | 67 |

**Est. cost (USD):** $0.05

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 70 |
| Cache write | 7 |
| Cache read | 3 |
| Output | 14 |
| **Total** | 94 |

**Est. cost (USD):** $0.15
EOF
  echo "fresh summary" > "$dir/plan-2/SUMMARY.md"

  run _consolidate spec "$SANDBOX" SPEC-R
  [ "$status" -eq 0 ]

  [ ! -d "$dir/plan" ]
  [ ! -d "$dir/plan-2" ]
  [ "$(cat "$dir/SUMMARY.md")" = "fresh summary" ]
  grep -qF '**Est. cost (USD):** $0.05' "$dir/cost.md"
  ! grep -qF '$9.99' "$dir/cost.md"
  grep -qx '## Total' "$dir/cost.md"
  grep -qF '**Est. cost (USD):** $0.20' "$dir/cost.md"
}

# --- 5. Idempotent: a second run over an already-flat folder is a no-op ----

@test "idempotent: a second run over an already-flat folder reproduces the same cost.md" {
  seed_spec_folder SPEC-Z
  dir="$SANDBOX/.gaia/local/specs/SPEC-Z"

  run _consolidate spec "$SANDBOX" SPEC-Z
  [ "$status" -eq 0 ]
  before="$(cat "$dir/cost.md")"

  run _consolidate spec "$SANDBOX" SPEC-Z
  [ "$status" -eq 0 ]
  after="$(cat "$dir/cost.md")"

  [ "$before" = "$after" ]
}

# --- 6. No plan folder at all: skip plan sections, still write SPEC + Total -

@test "no plan folder at all: SPEC section and Total still write; nothing crashes" {
  dir="$SANDBOX/.gaia/local/specs/SPEC-N"
  mkdir -p "$dir"
  cat > "$dir/cost.md" <<'EOF'
# Cost: SPEC-N

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 5 |
| Cache write | 0 |
| Cache read | 0 |
| Output | 0 |
| **Total** | 5 |

**Est. cost (USD):** $0.01
EOF

  run _consolidate spec "$SANDBOX" SPEC-N
  [ "$status" -eq 0 ]

  grep -qx '## SPEC' "$dir/cost.md"
  grep -qx '## Total' "$dir/cost.md"
  ! grep -qx '## Planning' "$dir/cost.md"
  ! grep -qx '## Execution' "$dir/cost.md"
}

# --- 7. Missing SPEC folder: fail-open, no crash -----------------------------

@test "missing spec folder: exits 0 with a stderr note and no crash" {
  run _consolidate spec "$SANDBOX" SPEC-GHOST
  [ "$status" -eq 0 ]
  grep -qF 'does not exist' <<<"$output"
}

# --- 8. Mode plan-total: appends a Total, no SPEC section -------------------

@test "plan-total mode: appends a Total to a spec-less Planning+Execution cost.md" {
  cost_md="$SANDBOX/cost.md"
  cat > "$cost_md" <<'EOF'
# Cost: PLAN-009 / bar-slug

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 10 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 2 |
| **Total** | 14 |

**Est. cost (USD):** $0.10

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 20 |
| Cache write | 2 |
| Cache read | 2 |
| Output | 4 |
| **Total** | 28 |

**Est. cost (USD):** $0.20
EOF

  run _consolidate plan-total "$cost_md"
  [ "$status" -eq 0 ]

  grep -qF '# Cost: PLAN-009 / bar-slug' "$cost_md"
  grep -qx '## Total' "$cost_md"
  grep -qF '**Est. cost (USD):** $0.30' "$cost_md"
  ! grep -qx '## SPEC' "$cost_md"
}

# --- 9. Mode plan-total: idempotent re-run replaces, never duplicates ------

@test "plan-total mode: re-running replaces the existing Total instead of duplicating it" {
  cost_md="$SANDBOX/cost.md"
  cat > "$cost_md" <<'EOF'
# Cost: PLAN-010 / baz-slug

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 10 |
| Cache write | 0 |
| Cache read | 0 |
| Output | 0 |
| **Total** | 10 |

**Est. cost (USD):** $0.10

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 20 |
| Cache write | 0 |
| Cache read | 0 |
| Output | 0 |
| **Total** | 20 |

**Est. cost (USD):** $0.20

## Total

**Est. cost (USD):** $99.99

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 1 |
| **Total** | 4 |
EOF

  run _consolidate plan-total "$cost_md"
  [ "$status" -eq 0 ]

  [ "$(grep -c '^## Total$' "$cost_md")" -eq 1 ]
  grep -qF '**Est. cost (USD):** $0.30' "$cost_md"
  ! grep -qF '$99.99' "$cost_md"
}

# --- 10. Mode plan-total: missing file is a fail-open no-op -----------------

@test "plan-total mode: missing cost.md path is a fail-open no-op" {
  run _consolidate plan-total "$SANDBOX/nope.md"
  [ "$status" -eq 0 ]
  grep -qF 'not found' <<<"$output"
}

# --- 11. UAT-004: both archive entry points reach the identical flat shape -

@test "both archive entry points reach the identical flat shape (UAT-004)" {
  DIRECT="$SANDBOX/direct"
  SWEEP="$SANDBOX/sweep"
  mkdir -p "$DIRECT" "$SWEEP"

  # Identical SPEC-Z fixture in both sandboxes.
  SANDBOX="$DIRECT" seed_spec_folder SPEC-Z
  SANDBOX="$SWEEP" seed_spec_folder SPEC-Z

  # A: invoke the routine directly (no move -- that's the caller's job).
  run bash "$SCRIPT" spec "$DIRECT" SPEC-Z
  [ "$status" -eq 0 ]

  # B: exercise the real safety-net sweep end-to-end (ledger + jq-driven
  # merged-row detection, frontmatter stamp, move to archived/). It shells
  # out to a sibling cost-consolidate.sh, so mirror the two files' real
  # sibling layout inside the sweep sandbox.
  lib_dir="$SWEEP/.specify/extensions/gaia/lib"
  mkdir -p "$lib_dir" "$SWEEP/.gaia/local/specs"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/spec-archive-merged.sh" "$lib_dir/"
  cp "$SCRIPT" "$lib_dir/"
  printf '{"specs":[{"id":"SPEC-Z","status":"merged"}]}\n' > "$SWEEP/.gaia/local/specs/ledger.json"

  run bash "$lib_dir/spec-archive-merged.sh" "$SWEEP"
  [ "$status" -eq 0 ]
  [ -d "$SWEEP/.gaia/local/specs/archived/SPEC-Z" ]

  direct_cost="$DIRECT/.gaia/local/specs/SPEC-Z/cost.md"
  swept_cost="$SWEEP/.gaia/local/specs/archived/SPEC-Z/cost.md"
  [ -f "$direct_cost" ]
  [ -f "$swept_cost" ]
  [ "$(cat "$direct_cost")" = "$(cat "$swept_cost")" ]

  direct_summary="$DIRECT/.gaia/local/specs/SPEC-Z/SUMMARY.md"
  swept_summary="$SWEEP/.gaia/local/specs/archived/SPEC-Z/SUMMARY.md"
  [ "$(cat "$direct_summary")" = "$(cat "$swept_summary")" ]

  [ ! -d "$SWEEP/.gaia/local/specs/archived/SPEC-Z/plan" ]
}
