#!/usr/bin/env bats
#
# UAT-006: token-rollup.sh (the cost.jsonl reader) reports figures from
# cost.jsonl only. It never opens a cost.md; this suite proves that
# structurally rather than trusting the omission. It plants a deliberately
# WRONG-numbered cost.md at the exact folder location a real spec's archived
# cost.md would occupy, on disk alongside a seeded cost.jsonl, then runs the
# reader against that cost.jsonl (its only input) and proves the wrong
# numbers never surface: the reader takes no folder/spec-root argument at
# all, so nothing about its invocation could ever reach the decoy file.
#
# Assertion style note: bare `[[ ... ]]` is avoided for any non-terminal
# assertion per .claude/rules/bats-assertions.md (a false `[[ ... ]]` is
# silently skipped under bash 3.2's `set -e`, what macOS's default `/bin/bash`
# resolves to for bats-core).

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-rollup.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-rollup" && pwd)"
}

# committed-rate-smoke.jsonl (SPEC-260) is a hand-verified oracle already used
# by token-rollup.bats: one execute row, buckets 300000/0/0/0, total 300000,
# duration_seconds 60 (1m0s), by_model claude-opus-4-8 fresh_input=200000 +
# claude-sonnet-4-6 fresh_input=100000, pricing to $1.30 against the live
# committed token-rates.json (opus $5/MTok, sonnet $3/MTok seed rates).

@test "UAT-006: token-rollup reports cost.jsonl figures, never a planted wrong-number cost.md" {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  mkdir -p "$SANDBOX/.gaia/local/specs/SPEC-260"
  cat > "$SANDBOX/.gaia/local/specs/SPEC-260/cost.md" <<'EOF'
# Cost: SPEC-260

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 999999 |
| Cache write | 888888 |
| Cache read | 777777 |
| Output | 666666 |
| **Total** | 3332220 |

**Est. cost (USD):** $999.99
EOF

  run bash "$SCRIPT" --spec-id SPEC-260 --ledger "$FIX/committed-rate-smoke.jsonl"
  [ "$status" -eq 0 ]

  # The real cost.jsonl-derived token and dollar figures render.
  grep -qF -- "execute:   300,000   (elapsed 1m0s)" <<<"$output"
  grep -qF -- "Total:     300,000   (elapsed 1m0s)" <<<"$output"
  grep -qE -- 'Fresh input:[[:space:]]+300,000' <<<"$output"
  grep -qF -- 'execute:   $1.30' <<<"$output"
  grep -qF -- 'Total:     $1.30' <<<"$output"

  # None of the planted cost.md's fabricated numbers ever leak into the output.
  if grep -qF -- "999,999" <<<"$output"; then
    echo "leaked planted cost.md fresh-input figure" >&2
    return 1
  fi
  if grep -qF -- "888,888" <<<"$output"; then
    echo "leaked planted cost.md cache-write figure" >&2
    return 1
  fi
  if grep -qF -- "3,332,220" <<<"$output"; then
    echo "leaked planted cost.md total" >&2
    return 1
  fi
  if grep -qF -- '$999.99' <<<"$output"; then
    echo "leaked planted cost.md dollar figure" >&2
    return 1
  fi
}

@test "UAT-006: by_model is recoverable directly from cost.jsonl (token-rollup prints no per-model line)" {
  by_model_opus="$(jq -r '.by_model["claude-opus-4-8"].fresh_input' "$FIX/committed-rate-smoke.jsonl")"
  [ "$by_model_opus" = "200000" ]
  by_model_sonnet="$(jq -r '.by_model["claude-sonnet-4-6"].fresh_input' "$FIX/committed-rate-smoke.jsonl")"
  [ "$by_model_sonnet" = "100000" ]

  # token-rollup itself never prints a per-model breakdown line.
  run bash "$SCRIPT" --spec-id SPEC-260 --ledger "$FIX/committed-rate-smoke.jsonl"
  [ "$status" -eq 0 ]
  if grep -qF -- "claude-opus-4-8" <<<"$output"; then
    echo "unexpected: token-rollup printed a by_model line; it should not" >&2
    return 1
  fi
}
