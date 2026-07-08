#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/audit-window-lib.sh (SPEC-032 FC-5, the
# adversarial-audit / code-review-audit window primitive). Sourced, not
# executed: every test sources the lib in setup() and calls its functions
# directly. Fixtures under fixtures/audit-window/ are hand-authored
# $tmp-shaped record files; every expected sum below is HAND-COMPUTED in
# the comment next to it, never derived by running the lib.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that isn't the test's last command, so assertions below use POSIX `[ ]`,
# `grep -q`, or an explicit `return 1`, never a bare mid-test `[[ ]]`.
#
# ---------- fixtures/audit-window/basic.jsonl (AC1) ----------
# 4 records: sidecar A, sidecar B (both in-window), sidecar C (out-of-window,
# decoy values 999 in every field), main (in-window timewise, decoy 999s).
# Window [2026-07-08T01:00:00Z, 2026-07-08T01:05:00Z].
#   A: fresh=10  cwrite=1+2=3   cread=3  output=4   tmin 01:00:10 tmax 01:00:20
#   B: fresh=20  cwrite=2+3=5   cread=6  output=8   tmin 01:01:00 tmax 01:01:30
#   C: OUT OF WINDOW (00:50:00-00:55:00) -> excluded regardless of value
#   main: file_agent "main" -> excluded regardless of window
# expected: count=2 buckets fresh=30 cwrite=8 cread=9 output=12
# expected elapsed_seconds = max(tmax)-min(tmin) over A,B = 01:01:30-01:00:10 = 80s
#
# ---------- fixtures/audit-window/dedup.jsonl (AC2) ----------
# 1 sidecar record, usage array carries the SAME id "dup1" twice: a partial
# line (fresh=1 cwrite=1+1=2 cread=1 output=1) then the final line
# (fresh=100 cwrite=10+20=30 cread=30 output=40). Last-wins dedup: expected
# buckets = the FINAL values only (100/30/30/40), never the naive sum (101/…).
#
# ---------- fixtures/audit-window/overlap.jsonl (AC3) ----------
# 2 sidecars with OVERLAPPING spans: D [03:00:00,03:00:30] (30s span), E
# [03:00:15,03:00:45] (30s span). Combined selected span = max(03:00:45) -
# min(03:00:00) = 45s, strictly LESS than the naive per-file sum 30+30=60s
# (equal only when serial/non-overlapping).
#
# ---------- fixtures/audit-window/boundary.jsonl (AC4b / COV-003) ----------
# Window [2026-07-08T01:00:05Z, 2026-07-08T01:00:59Z] (second precision).
#   F: tmin=01:00:05.123Z (SAME second as window start, fractional) tmax=01:00:10Z
#      -> MUST be included; a raw string compare would sort "05.123Z" before
#      "05Z" (since "." < "Z") and wrongly drop it.
#   G: tmin=01:00:50Z tmax=01:00:59.789Z (SAME second as window end, fractional)
#      -> MUST be included (symmetric case at ended_at).
# expected: count=2 (both F and G included).
#
# ---------- fixtures/audit-window/bymodel.jsonl (AC5) ----------
# 4 sidecars, all in-window: H (claude-opus-4-8, fresh=50 5m=5 1h=10 cread=15
# output=20), I (claude-sonnet-4-6, fresh=5 5m=1 1h=1 cread=1 output=1), K
# (model null, all-zero usage), L (model claude-haiku-4-0, all-zero usage).
# expected buckets (H+I+K+L): fresh=55 cwrite=(5+10)+(1+1)=17 cread=16 output=21
# expected by_model: only H and I survive (K dropped: null model; L dropped:
# zero-sum despite a real model name). Reconciliation: summing by_model's
# fresh/cread/output and (5m+1h) across its two surviving models reproduces
# the 4-key buckets exactly (K/L contribute 0 either way).
#
# ---------- fixtures/audit-window/review.jsonl (AC6/AC7) ----------
# review (code-review-audit, window [04:00:00,04:10:00]), M (sidecar, window
# [04:02:00,04:03:00] -- CONTAINED in review's window), N (sidecar, window
# [04:20:00,04:21:00] -- outside), O (main, window [03:59:00,04:05:00] --
# crosses the review window's start boundary, so NOT a subset, kept).
# expected gaia_review_windows: one entry, review_id "agent-rev0001",
#   started_at 04:00:00Z, ended_at 04:10:00Z.
# expected gaia_exclude_review_windows: drops review and M, keeps N and O.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$SCRIPT_DIR/audit-window-lib.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/audit-window" && pwd)"
  # shellcheck source=.gaia/scripts/audit-window-lib.sh
  source "$LIB"
}

# ---------- 1. gaia_window_subset: in-window sidecars only (AC1) ----------
@test "gaia_window_subset: sums only in-window sidecars, excludes main and out-of-window records" {
  run gaia_window_subset "$FIX/basic.jsonl" "2026-07-08T01:00:00Z" "2026-07-08T01:05:00Z"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(jq -r '.count' <<<"$out")" -eq 2 ]
  [ "$(jq -r '.buckets.fresh_input' <<<"$out")" -eq 30 ]
  [ "$(jq -r '.buckets.cache_write' <<<"$out")" -eq 8 ]
  [ "$(jq -r '.buckets.cache_read' <<<"$out")" -eq 9 ]
  [ "$(jq -r '.buckets.output' <<<"$out")" -eq 12 ]
  [ "$(jq -r '.elapsed_seconds' <<<"$out")" -eq 80 ]
  # decoy values (999) never leak in (final statement: use an explicit `if`
  # so the good case, grep finding nothing, exits 0 and does not itself
  # become the test's failing result -- see .claude/rules/bats-assertions.md)
  if grep -qF '999' <<<"$out"; then
    return 1
  fi
}

# ---------- 2. message-id dedup, last-wins (AC2) ----------
@test "gaia_window_subset: dedupes a repeated message id, last value wins" {
  run gaia_window_subset "$FIX/dedup.jsonl" "2026-07-08T02:00:00Z" "2026-07-08T02:00:10Z"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(jq -r '.count' <<<"$out")" -eq 1 ]
  [ "$(jq -r '.buckets.fresh_input' <<<"$out")" -eq 100 ]
  [ "$(jq -r '.buckets.cache_write' <<<"$out")" -eq 30 ]
  [ "$(jq -r '.buckets.cache_read' <<<"$out")" -eq 30 ]
  [ "$(jq -r '.buckets.output' <<<"$out")" -eq 40 ]
  # a naive undeduped sum (1+100=101) must NOT appear
  [ "$(jq -r '.buckets.fresh_input' <<<"$out")" -ne 101 ]
}

# ---------- 3. elapsed_seconds over overlapping spans (AC3) ----------
@test "gaia_window_subset: elapsed_seconds is the union span, strictly less than the sum of overlapping per-file spans" {
  run gaia_window_subset "$FIX/overlap.jsonl" "2026-07-08T03:00:00Z" "2026-07-08T03:01:00Z"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(jq -r '.count' <<<"$out")" -eq 2 ]
  [ "$(jq -r '.elapsed_seconds' <<<"$out")" -eq 45 ]
  # sum of the two 30s per-file spans is 60; the union span (45) is strictly less
  [ "$(jq -r '.elapsed_seconds' <<<"$out")" -lt 60 ]
}

# ---------- 4. empty window degrades to zero-filled result (AC4) ----------
@test "gaia_window_subset: a window with no sidecar activity returns count 0 and zero buckets" {
  run gaia_window_subset "$FIX/basic.jsonl" "2099-01-01T00:00:00Z" "2099-01-02T00:00:00Z"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(jq -r '.count' <<<"$out")" -eq 0 ]
  [ "$(jq -r '.buckets.fresh_input' <<<"$out")" -eq 0 ]
  [ "$(jq -r '.buckets.cache_write' <<<"$out")" -eq 0 ]
  [ "$(jq -r '.buckets.cache_read' <<<"$out")" -eq 0 ]
  [ "$(jq -r '.buckets.output' <<<"$out")" -eq 0 ]
  [ "$(jq -r '.elapsed_seconds' <<<"$out")" -eq 0 ]
  [ "$(jq -r '.by_model | length' <<<"$out")" -eq 0 ]
}

# ---------- 4b. same-second fractional boundary (COV-003) ----------
@test "gaia_window_subset: includes a sidecar sharing the window's boundary second with fractional precision" {
  run gaia_window_subset "$FIX/boundary.jsonl" "2026-07-08T01:00:05Z" "2026-07-08T01:00:59Z"
  [ "$status" -eq 0 ]
  out="$output"
  # both the start-boundary (tmin .123 into the start second) and the
  # end-boundary (tmax .789 into the end second) sidecars must be counted;
  # a raw string compare would drop both.
  [ "$(jq -r '.count' <<<"$out")" -eq 2 ]
  [ "$(jq -r '.buckets.fresh_input' <<<"$out")" -eq 2 ]
}

# ---------- 5. by_model grouping + reconciliation (AC5) ----------
@test "gaia_window_subset: by_model collapses 5m/1h, drops null-model and zero-sum entries, reconciles to buckets" {
  run gaia_window_subset "$FIX/bymodel.jsonl" "2026-07-08T05:00:00Z" "2026-07-08T05:10:00Z"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(jq -r '.count' <<<"$out")" -eq 4 ]
  [ "$(jq -r '.buckets.fresh_input' <<<"$out")" -eq 55 ]
  [ "$(jq -r '.buckets.cache_write' <<<"$out")" -eq 17 ]
  [ "$(jq -r '.buckets.cache_read' <<<"$out")" -eq 16 ]
  [ "$(jq -r '.buckets.output' <<<"$out")" -eq 21 ]
  # only 2 models survive: the null-model and zero-sum entries are dropped
  [ "$(jq -r '.by_model | length' <<<"$out")" -eq 2 ]
  jq -e '.by_model | has("claude-opus-4-8")' >/dev/null 2>&1 <<<"$out" || return 1
  jq -e '.by_model | has("claude-sonnet-4-6")' >/dev/null 2>&1 <<<"$out" || return 1
  jq -e '.by_model | has("claude-haiku-4-0") | not' >/dev/null 2>&1 <<<"$out" || return 1
  [ "$(jq -r '.by_model."claude-opus-4-8".fresh_input' <<<"$out")" -eq 50 ]
  [ "$(jq -r '.by_model."claude-opus-4-8".cache_write_5m' <<<"$out")" -eq 5 ]
  [ "$(jq -r '.by_model."claude-opus-4-8".cache_write_1h' <<<"$out")" -eq 10 ]
  [ "$(jq -r '.by_model."claude-sonnet-4-6".fresh_input' <<<"$out")" -eq 5 ]
  # reconciliation: sum of per-model fresh/cache_write(5m+1h)/cread/output
  # across by_model reproduces the 4-key buckets exactly.
  recon_fresh="$(jq -r '[.by_model[].fresh_input] | add' <<<"$out")"
  recon_cwrite="$(jq -r '[.by_model[] | (.cache_write_5m + .cache_write_1h)] | add' <<<"$out")"
  recon_cread="$(jq -r '[.by_model[].cache_read] | add' <<<"$out")"
  recon_output="$(jq -r '[.by_model[].output] | add' <<<"$out")"
  [ "$recon_fresh" -eq "$(jq -r '.buckets.fresh_input' <<<"$out")" ]
  [ "$recon_cwrite" -eq "$(jq -r '.buckets.cache_write' <<<"$out")" ]
  [ "$recon_cread" -eq "$(jq -r '.buckets.cache_read' <<<"$out")" ]
  [ "$recon_output" -eq "$(jq -r '.buckets.output' <<<"$out")" ]
}

# ---------- 6. gaia_review_windows (AC6) ----------
@test "gaia_review_windows: one entry per code-review-audit record, empty array when none" {
  run gaia_review_windows "$FIX/review.jsonl"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(jq -r 'length' <<<"$out")" -eq 1 ]
  [ "$(jq -r '.[0].review_id' <<<"$out")" = "agent-rev0001" ]
  [ "$(jq -r '.[0].started_at' <<<"$out")" = "2026-07-08T04:00:00Z" ]
  [ "$(jq -r '.[0].ended_at' <<<"$out")" = "2026-07-08T04:10:00Z" ]

  run gaia_review_windows "$FIX/basic.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ---------- 7. gaia_exclude_review_windows (AC7) ----------
@test "gaia_exclude_review_windows: drops the review record and its contained sidecar, keeps the rest" {
  run gaia_exclude_review_windows "$FIX/review.jsonl"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(wc -l <<<"$out" | tr -d ' ')" -eq 2 ]
  grep -qF '"file_id":"agent-rev0001"' <<<"$out" && return 1
  grep -qF '"file_id":"agent-mmmm0005"' <<<"$out" && return 1
  grep -qF '"file_id":"agent-nnnn0006"' <<<"$out" || return 1
  grep -qF '"file_agent":"main"' <<<"$out" || return 1
}

@test "gaia_exclude_review_windows: byte no-op when no code-review-audit record is present" {
  run gaia_exclude_review_windows "$FIX/basic.jsonl"
  [ "$status" -eq 0 ]
  expected="$(cat "$FIX/basic.jsonl")"
  [ "$output" = "$expected" ]
}

# ---------- 8. gaia_audit_window_read (AC8) ----------
@test "gaia_audit_window_read: valid breadcrumb round-trips, invalid/missing inputs echo nothing" {
  bc="$BATS_TEST_TMPDIR/valid.json"
  printf '{"session_id":"s1","started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:05:00Z","lenses":["FG"]}\n' >"$bc"
  run gaia_audit_window_read "$bc"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.session_id' <<<"$output")" = "s1" ]

  run gaia_audit_window_read "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  arr="$BATS_TEST_TMPDIR/array.json"
  printf '[1,2,3]\n' >"$arr"
  run gaia_audit_window_read "$arr"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  missing="$BATS_TEST_TMPDIR/missing-ended.json"
  printf '{"session_id":"s1","started_at":"2026-01-01T00:00:00Z"}\n' >"$missing"
  run gaia_audit_window_read "$missing"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 9. every function degrades cleanly on malformed/empty input (AC9) ----------
@test "every function exits 0 and degrades cleanly on malformed or empty input" {
  run gaia_window_subset "$FIX/malformed.jsonl" "2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.count' <<<"$output")" -eq 0 ]

  run gaia_window_subset "$FIX/empty.jsonl" "2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.count' <<<"$output")" -eq 0 ]

  run gaia_review_windows "$FIX/malformed.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]

  run gaia_review_windows "$FIX/empty.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]

  run gaia_exclude_review_windows "$FIX/malformed.jsonl"
  [ "$status" -eq 0 ]

  run gaia_exclude_review_windows "$FIX/empty.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run gaia_audit_window_read "$FIX/malformed.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 10. gaia_audit_window_write (DP-001, AC10) ----------
@test "gaia_audit_window_write: writes the FC-1 shape on success, omits intensity for plan audits" {
  bc="$BATS_TEST_TMPDIR/spec-breadcrumb.json"
  run gaia_audit_window_write "$bc" "sess-1" "2026-07-08T01:00:00Z" "2026-07-08T01:05:00Z" '["FG","TST","COV","RT"]' "standard"
  [ "$status" -eq 0 ]
  read_back="$(gaia_audit_window_read "$bc")"
  [ "$(jq -r '.session_id' <<<"$read_back")" = "sess-1" ]
  [ "$(jq -r '.started_at' <<<"$read_back")" = "2026-07-08T01:00:00Z" ]
  [ "$(jq -r '.ended_at' <<<"$read_back")" = "2026-07-08T01:05:00Z" ]
  [ "$(jq -c '.lenses' <<<"$read_back")" = '["FG","TST","COV","RT"]' ]
  [ "$(jq -r '.intensity' <<<"$read_back")" = "standard" ]

  bc2="$BATS_TEST_TMPDIR/plan-breadcrumb.json"
  run gaia_audit_window_write "$bc2" "sess-2" "2026-07-08T02:00:00Z" "2026-07-08T02:05:00Z" '["DP","CG"]' ""
  [ "$status" -eq 0 ]
  jq -e 'has("intensity")' >/dev/null 2>&1 <"$bc2" && return 1
  [ "$(jq -r '.session_id' <"$bc2")" = "sess-2" ]
}

# The breadcrumb writer PROPAGATES failure: it returns non-zero and writes
# nothing when it cannot produce a valid breadcrumb, so a lost breadcrumb is
# detectable and unit-testable instead of silently swallowed behind return 0.
# Callers keep their `|| true`, so a non-zero return still never blocks them.
@test "gaia_audit_window_write: returns non-zero and writes nothing on jq/write failure" {
  # unwritable target (parent dir absent): the printf redirect fails -> non-zero
  run gaia_audit_window_write "$BATS_TEST_TMPDIR/nonexistent-dir/bc.json" "s" "2026-07-08T01:00:00Z" "2026-07-08T01:05:00Z" '[]' ""
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/nonexistent-dir/bc.json" ]

  # malformed lenses arg: jq -n fails -> non-zero, no partial file left behind
  bc3="$BATS_TEST_TMPDIR/bad-lenses.json"
  run gaia_audit_window_write "$bc3" "s" "2026-07-08T01:00:00Z" "2026-07-08T01:05:00Z" "not-json" ""
  [ "$status" -ne 0 ]
  [ ! -e "$bc3" ]

  # empty target path: nothing to write -> non-zero
  run gaia_audit_window_write "" "s" "2026-07-08T01:00:00Z" "2026-07-08T01:05:00Z" '[]' ""
  [ "$status" -ne 0 ]

  # jq unavailable on PATH (the issue's primary reproduction): the `command -v`
  # guard fires, the writer returns non-zero and writes nothing. PATH is
  # restored right after the call so the remaining assertions keep jq.
  bc4="$BATS_TEST_TMPDIR/nojq.json"
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_audit_window_write "$bc4" "s" "2026-07-08T01:00:00Z" "2026-07-08T01:05:00Z" '["FG"]' ""
  PATH="$saved_path"
  [ "$status" -ne 0 ]
  [ ! -e "$bc4" ]
}
