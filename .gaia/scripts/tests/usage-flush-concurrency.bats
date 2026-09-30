#!/usr/bin/env bats
#
# usage-flush.sh under contention: concurrent flushers and a sweep sharing the
# cost mutex with other telemetry writers (SPEC-087 UAT-010, AUDIT TST-012a,
# COV-006, MIG-002, RT-010).
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-flush-concurrency.bats
#
# Measured cold sweep (maintainer machine, Apple Silicon macOS, jq 1.7.1): one
# --sweep over the real projects root (3.0 GB of transcripts, about 30 days of
# retained history) into a scratch telemetry dir, budget raised to 3600 s.
# Wall time 766 s for 3155 files (about 0.24 s per file). Rows: 4191 segment,
# 625 binding, 3155 cursor; usage.jsonl 3683108 bytes. Per month of history:
# about 8000 rows and 3.7 MB before steady-state cursor rows, which add one
# row per file per commit. At the default 240 s budget a cold backfill of that
# size completes over about four SessionStart sweeps.
#
# Totals are compared by summing kind=="segment" rows with plain jq against the
# scenario's hand-computed golden.json.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPTS/../.." && pwd)"
  FLUSH="$SCRIPTS/usage-flush.sh"
  LIB="$SCRIPTS/usage-lib.sh"
  FIXDIR="$BATS_TEST_DIRNAME/fixtures/usage/flush"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  unset GITHUB_ACTIONS GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_TALLY_PROJECTS_ROOT GAIA_LEDGER_LOCK_TIMEOUT_SECS
  ROOT="$TMP/repo"
  PROJ="$TMP/projects"
  TEL="$ROOT/.gaia/local/telemetry"
  mkdir -p "$ROOT" "$PROJ"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
}

enc() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

install() {
  local src="$FIXDIR/$1/projects" rel out e
  e="$(enc "$ROOT")"
  while IFS= read -r rel; do
    out="$PROJ/${rel#./}"
    out="${out//@MAIN@/$e}"
    mkdir -p "${out%/*}"
    sed -e "s|@ROOT@|$ROOT|g" "$src/$rel" >"$out"
    touch -t 202001010000 "$out"
  done < <(cd "$src" && find . -type f -name '*.jsonl')
}

totals() {
  jq -S -s '[.[] | select(.kind == "segment")]
    | reduce .[] as $s ({}; reduce ($s.by_model | to_entries[]) as $m (.;
        reduce ($m.value | to_entries[]) as $b (.; .[$s.key][$m.key][$b.key] += $b.value)))' "$TEL/usage.jsonl"
}

assert_golden() {
  local want got
  want="$(jq -S . "$FIXDIR/$1/golden.json")"
  got="$(totals)"
  [ "$got" = "$want" ] || { printf 'want:\n%s\ngot:\n%s\n' "$want" "$got" >&2; return 1; }
}

wait_for() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# Every line of <file> is one JSON value (no torn or interleaved append).
assert_lines_parse() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    jq -e . >/dev/null 2>&1 <<<"$line" || { echo "torn line in $1: $line" >&2; return 1; }
  done <"$1"
}

# Every file the cursor cache names has its offset at its current size.
assert_quiescent() {
  local p off size n=0
  while IFS=$'\t' read -r p off; do
    size="$(wc -c <"$p" | tr -d ' ')"
    [ "$off" -eq "$size" ] || { echo "$p: offset $off, size $size" >&2; return 1; }
    n=$((n + 1))
  done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value.offset)"' "$TEL/usage-cursors.json")
  [ "$n" -eq "$1" ] || { echo "cache names $n files, expected $1" >&2; return 1; }
}

# holds_within <stderr file> <bound secs>: rc 0 when at least one hold was
# reported and none exceeds the bound.
holds_within() {
  awk -v b="$2" '/usage-flush: hold [0-9.]+s/ { v = $3; sub(/s$/, "", v); n++; if (v + 0 > b + 0) bad++ }
    END { exit (n > 0 && bad == 0) ? 0 : 1 }' "$1"
}

@test "TST-012a: two session flushers, a sweep, and a links append released together: no torn line, golden totals, quiescent cursors" {
  install conc
  local rows="$TMP/link.jsonl" go="$TMP/go" p pids=()
  printf '{"schema_version":1,"kind":"edge","child":"pr:7","parent":"branch:fix/c1","source":"link-command","ts":"2026-10-01T00:00:09Z","session_id":null,"sidechain":false}\n' >"$rows"
  for p in "--session s-c1 --finished-main" "--session s-c2 --finished-main" "--sweep"; do
    # shellcheck disable=SC2086  # the flag set is split on purpose
    ( until [ -e "$go" ]; do :; done
      bash "$FLUSH" --projects-root "$PROJ" --main-root "$ROOT" $p 2>/dev/null ) 3>&- &
    pids+=("$!")
  done
  ( until [ -e "$go" ]; do :; done
    bash -c 'source "$1"; mkdir -p "$2"; gaia_usage_append "$2" links.jsonl "$3"' _ "$LIB" "$TEL" "$rows" ) 3>&- &
  pids+=("$!")
  : >"$go"
  for p in "${pids[@]}"; do wait "$p"; done
  run bash "$FLUSH" --projects-root "$PROJ" --main-root "$ROOT" --sweep
  [ "$status" -eq 0 ]
  assert_lines_parse "$TEL/usage.jsonl"
  assert_lines_parse "$TEL/links.jsonl"
  [ "$(wc -l <"$TEL/links.jsonl" | tr -d ' ')" -eq 1 ]
  assert_golden conc
  assert_quiescent 5
}

@test "COV-006: a parked cold sweep holds no lock; a cost write and a SPEC allocation land meanwhile, and every commit's hold is within 2 s" {
  install sweep
  local pid t0 err="$TMP/sweep.err"
  GAIA_USAGE_TEST_BARRIER="$TMP/bar" GAIA_USAGE_DEBUG_HOLD=1 \
    bash "$FLUSH" --projects-root "$PROJ" --main-root "$ROOT" --sweep 2>"$err" 3>&- &
  pid=$!
  wait_for "$TMP/bar.parsed"
  [ -e "$TEL/usage.jsonl" ] && return 1

  t0=$SECONDS
  GAIA_LEDGER_LOCK_TIMEOUT_SECS=2 run --separate-stderr bash "$SCRIPTS/token-tally.sh" --action command --command gaia-audit \
    --session-id s-sw5 --projects-root "$PROJ" --ledger "$TEL/cost.jsonl"
  [ "$status" -eq 0 ]
  [ $((SECONDS - t0)) -le 2 ]
  grep -F 'timed out' <<<"$stderr" && return 1
  [ "$(jq -s '[.[] | select(.kind == "command" and .command == "gaia-audit")] | length' "$TEL/cost.jsonl")" -eq 1 ]

  t0=$SECONDS
  GAIA_LEDGER_LOCK_TIMEOUT_SECS=2 run --separate-stderr bash "$REPO_ROOT/.specify/extensions/gaia/lib/spec-allocator.sh" next "$ROOT"
  [ "$status" -eq 0 ]
  [ $((SECONDS - t0)) -le 2 ]
  [ "$output" = "SPEC-001" ]

  : >"$TMP/bar"
  wait "$pid"
  holds_within "$err" 2
  [ "$(grep -c 'usage-flush: hold' "$err")" -eq 6 ]
  assert_golden sweep
}

@test "COV-006 guard: a scratch copy that sleeps 3 s inside the locked commit breaks the 2 s hold assertion" {
  local d="$TMP/scratch" err="$TMP/mut.err"
  mkdir -p "$d/.gaia/scripts" "$d/.specify/extensions/gaia/lib"
  cp "$SCRIPTS"/usage-flush.sh "$SCRIPTS"/usage-parse-lib.sh "$SCRIPTS"/usage-lib.sh "$SCRIPTS"/main-root-lib.sh \
    "$SCRIPTS"/branch-name-lib.sh "$SCRIPTS"/ledger-path-lib.sh "$d/.gaia/scripts/"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/with-ledger-lock.sh" "$d/.specify/extensions/gaia/lib/"
  sed 's/^  t0="\$(_uf_now)"$/  t0="$(_uf_now)"; sleep 3/' "$SCRIPTS/usage-flush.sh" >"$d/.gaia/scripts/usage-flush.sh"
  cmp -s "$SCRIPTS/usage-flush.sh" "$d/.gaia/scripts/usage-flush.sh" && return 1
  install branch
  GAIA_USAGE_DEBUG_HOLD=1 bash "$d/.gaia/scripts/usage-flush.sh" --projects-root "$PROJ" --main-root "$ROOT" \
    --session s-branch --finished-main 2>"$err"
  grep -q 'usage-flush: hold' "$err"
  run holds_within "$err" 2
  [ "$status" -ne 0 ]
}
