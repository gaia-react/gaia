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
  USAGE_LIBRARY="$SCRIPTS/usage-lib.sh"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/usage/flush"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  unset GITHUB_ACTIONS GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_TALLY_PROJECTS_ROOT GAIA_LEDGER_LOCK_TIMEOUT_SECONDS
  ROOT="$TEMPORARY_DIRECTORY/repo"
  PROJECTS_DIRECTORY="$TEMPORARY_DIRECTORY/projects"
  TEL="$ROOT/.gaia/local/telemetry"
  mkdir -p "$ROOT" "$PROJECTS_DIRECTORY"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
}

encode_project_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

install() {
  local source_directory="$FIXTURES_DIRECTORY/$1/projects" relative_path destination_path encoded_root
  encoded_root="$(encode_project_path "$ROOT")"
  while IFS= read -r relative_path; do
    destination_path="$PROJECTS_DIRECTORY/${relative_path#./}"
    destination_path="${destination_path//@MAIN@/$encoded_root}"
    mkdir -p "${destination_path%/*}"
    sed -e "s|@ROOT@|$ROOT|g" "$source_directory/$relative_path" >"$destination_path"
    touch -t 202001010000 "$destination_path"
  done < <(cd "$source_directory" && find . -type f -name '*.jsonl')
}

totals() {
  jq -S -s '[.[] | select(.kind == "segment")]
    | reduce .[] as $segment ({}; reduce ($segment.by_model | to_entries[]) as $model (.;
        reduce ($model.value | to_entries[]) as $bucket (.; .[$segment.key][$model.key][$bucket.key] += $bucket.value)))' "$TEL/usage.jsonl"
}

assert_golden() {
  local want got
  want="$(jq -S . "$FIXTURES_DIRECTORY/$1/golden.json")"
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
  local cursor_path cursor_offset size cursor_count=0
  while IFS=$'\t' read -r cursor_path cursor_offset; do
    size="$(wc -c <"$cursor_path" | tr -d ' ')"
    [ "$cursor_offset" -eq "$size" ] || { echo "$cursor_path: offset $cursor_offset, size $size" >&2; return 1; }
    cursor_count=$((cursor_count + 1))
  done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value.offset)"' "$TEL/usage-cursors.json")
  [ "$cursor_count" -eq "$1" ] || { echo "cache names $cursor_count files, expected $1" >&2; return 1; }
}

# holds_within <stderr file> <bound secs>: rc 0 when at least one hold was
# reported and none exceeds the bound.
holds_within() {
  awk -v bound_seconds="$2" '/usage-flush: hold [0-9.]+s/ { hold_seconds = $3; sub(/s$/, "", hold_seconds); hold_count++; if (hold_seconds + 0 > bound_seconds + 0) bad++ }
    END { exit (hold_count > 0 && bad == 0) ? 0 : 1 }' "$1"
}

@test "TST-012a: two session flushers, a sweep, and a links append released together: no torn line, golden totals, quiescent cursors" {
  install conc
  local rows="$TEMPORARY_DIRECTORY/link.jsonl" release_file="$TEMPORARY_DIRECTORY/go" flusher_arguments flusher_pid pids=()
  printf '{"schema_version":1,"kind":"edge","child":"pr:7","parent":"branch:fix/c1","source":"link-command","ts":"2026-10-01T00:00:09Z","session_id":null,"sidechain":false}\n' >"$rows"
  for flusher_arguments in "--session s-c1 --finished-main" "--session s-c2 --finished-main" "--sweep"; do
    # shellcheck disable=SC2086  # the flag set is split on purpose
    ( until [ -e "$release_file" ]; do :; done
      bash "$FLUSH" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" $flusher_arguments 2>/dev/null ) 3>&- &
    pids+=("$!")
  done
  ( until [ -e "$release_file" ]; do :; done
    bash -c 'source "$1"; mkdir -p "$2"; gaia_usage_append "$2" links.jsonl "$3"' _ "$USAGE_LIBRARY" "$TEL" "$rows" ) 3>&- &
  pids+=("$!")
  : >"$release_file"
  for flusher_pid in "${pids[@]}"; do wait "$flusher_pid"; done
  run bash "$FLUSH" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" --sweep
  [ "$status" -eq 0 ]
  assert_lines_parse "$TEL/usage.jsonl"
  assert_lines_parse "$TEL/links.jsonl"
  [ "$(wc -l <"$TEL/links.jsonl" | tr -d ' ')" -eq 1 ]
  assert_golden conc
  assert_quiescent 5
}

@test "a parked cold sweep holds no lock; a ledger write and a SPEC allocation land meanwhile, and every commit's hold is within 2 s" {
  install sweep
  local pid started_seconds stderr_file="$TEMPORARY_DIRECTORY/sweep.err"
  GAIA_USAGE_TEST_BARRIER="$TEMPORARY_DIRECTORY/bar" GAIA_USAGE_DEBUG_HOLD=1 \
    bash "$FLUSH" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" --sweep 2>"$stderr_file" 3>&- &
  pid=$!
  wait_for "$TEMPORARY_DIRECTORY/bar.parsed"
  [ -e "$TEL/usage.jsonl" ] && return 1

  started_seconds=$SECONDS
  GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=2 run --separate-stderr bash "$SCRIPTS/usage.sh" link spec:SPEC-001 research:sweep-parent \
    --main-root "$ROOT" --telemetry-dir "$TEL"
  [ "$status" -eq 0 ]
  [ $((SECONDS - started_seconds)) -le 2 ]
  grep -F 'timed out' <<<"$stderr" && return 1
  [ "$(jq -s '[.[] | select(.kind == "edge" and .child == "spec:SPEC-001" and .parent == "research:sweep-parent")] | length' "$TEL/links.jsonl")" -eq 1 ]

  started_seconds=$SECONDS
  GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=2 run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/spec/spec-allocator.sh" next "$ROOT"
  [ "$status" -eq 0 ]
  [ $((SECONDS - started_seconds)) -le 2 ]
  [ "$output" = "SPEC-001" ]

  : >"$TEMPORARY_DIRECTORY/bar"
  wait "$pid"
  holds_within "$stderr_file" 2
  [ "$(grep -c 'usage-flush: hold' "$stderr_file")" -eq 6 ]
  assert_golden sweep
}

@test "COV-006 guard: a scratch copy that sleeps 3 s inside the locked commit breaks the 2 s hold assertion" {
  local scratch_directory="$TEMPORARY_DIRECTORY/scratch" stderr_file="$TEMPORARY_DIRECTORY/mut.err"
  mkdir -p "$scratch_directory/.gaia/scripts" "$scratch_directory/.gaia/scripts/spec"
  cp "$SCRIPTS"/usage-flush.sh "$SCRIPTS"/usage-parse-lib.sh "$SCRIPTS"/usage-lib.sh "$SCRIPTS"/main-root-lib.sh \
    "$SCRIPTS"/branch-name-lib.sh "$SCRIPTS"/ledger-path-lib.sh "$scratch_directory/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/scripts/spec/with-ledger-lock.sh" "$scratch_directory/.gaia/scripts/spec/"
  sed 's/^  commit_started_at="\$(_uf_now)"$/  commit_started_at="$(_uf_now)"; sleep 3/' "$SCRIPTS/usage-flush.sh" >"$scratch_directory/.gaia/scripts/usage-flush.sh"
  cmp -s "$SCRIPTS/usage-flush.sh" "$scratch_directory/.gaia/scripts/usage-flush.sh" && return 1
  install branch
  GAIA_USAGE_DEBUG_HOLD=1 bash "$scratch_directory/.gaia/scripts/usage-flush.sh" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" \
    --session s-branch --finished-main 2>"$stderr_file"
  grep -q 'usage-flush: hold' "$stderr_file"
  run holds_within "$stderr_file" 2
  [ "$status" -ne 0 ]
}
