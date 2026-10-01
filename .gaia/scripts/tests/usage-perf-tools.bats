#!/usr/bin/env bats
#
# Smoke tests for the usage-readout perf tools under .gaia/tests/usage-perf/:
# the seeded store generator and the same-run timing script. Wall-clock time is
# never asserted; these prove the tools are reproducible, schema-true, and able
# to report a mismatch.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-perf-tools.bats

# The validator is jq source, not shell: single quotes are the point.
# shellcheck disable=SC2016

PROBES_SCHEMA='
def cats: ["first_merge","repeat_merge","multi_root","inherit","interval","no_spend","unresolvable","lower_bound","cursor_adversarial","wide_root"];
def uat: ["first_merge","repeat_merge","multi_root","inherit","interval","no_spend","unresolvable","lower_bound"];
def need: {first_merge:"merges", repeat_merge:"merges", multi_root:"roots_min", wide_root:"roots_min",
  no_spend:"no_spend", unresolvable:"unresolvable", lower_bound:"lower_bound", cursor_adversarial:"nonzero",
  inherit:"inherit", interval:"interval"};
def ekeys: ["lower_bound","roots_min","no_spend","unresolvable","nonzero","inherit","interval","merges"];
def is_int: type == "number" and . == floor;
def probe_ok:
  .category as $c
  | ((keys | sort) == ["category","expect","key","pr","raw"])
  and (.pr | is_int)
  and (.key == null or (.key | type) == "string")
  and (.raw == null or (.raw | type) == "string")
  and (cats | index($c) != null)
  and (((.expect | keys) - ekeys) == [])
  and (.expect | has(need[$c]))
  and (if $c == "first_merge" then .expect.merges == 1
       elif $c == "repeat_merge" then (.expect.merges | is_int) and .expect.merges >= 2
       elif $c == "multi_root" then (.expect.roots_min | is_int) and .expect.roots_min >= 2
       elif $c == "wide_root" then (.expect.roots_min | is_int) and .expect.roots_min >= 1
       else (.expect[need[$c]] | type) == "boolean" end)
  and (if $c == "unresolvable" then .key == null else .key != null end);
((keys | sort) == ["cut","initiative_roots","probes","typical_pr","widest_pr"])
and (.typical_pr | is_int) and (.widest_pr | is_int)
and (.cut | (keys | sort) == ["c","l","u"] and all(.[]; is_int))
and (.initiative_roots | (keys | sort) == ["issue","research","spec"] and all(.[]; type == "string"))
and (.probes | length >= 20)
and all(.probes[]; probe_ok)
and ((uat - [.probes[].category]) == [])
'

setup_file() {
  SRC="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  GEN="$SRC/.gaia/tests/usage-perf/gen-usage-stores.sh"
  mkdir -p "$BATS_FILE_TMPDIR/a" "$BATS_FILE_TMPDIR/b" "$BATS_FILE_TMPDIR/c"
  "$BASH" "$GEN" 1 "$BATS_FILE_TMPDIR/a" --scale 0.02
  "$BASH" "$GEN" 1 "$BATS_FILE_TMPDIR/b" --scale 0.02
  "$BASH" "$GEN" 1 "$BATS_FILE_TMPDIR/c" --scale 0.02 --seed 7
}

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  GEN="$SRC/.gaia/tests/usage-perf/gen-usage-stores.sh"
  TIMER="$SRC/.gaia/tests/usage-perf/time-usage-readout.sh"
  A="$BATS_FILE_TMPDIR/a"
}

probes_valid() { jq -e "$PROBES_SCHEMA" "$1" >/dev/null; }

@test "generator: equal arguments give byte-identical stores" {
  local f
  for f in usage.jsonl links.jsonl cost.jsonl probes.json; do
    [ -s "$A/$f" ] || { printf 'empty or missing: %s\n' "$f" >&2; return 1; }
    cmp "$A/$f" "$BATS_FILE_TMPDIR/b/$f"
  done
}

@test "generator: every store line is valid JSON" {
  local f
  for f in usage.jsonl links.jsonl cost.jsonl; do
    jq -c . "$A/$f" >/dev/null || { printf 'invalid JSON in %s\n' "$f" >&2; return 1; }
  done
  jq -e . "$A/probes.json" >/dev/null
}

@test "generator guard red: another seed gives another usage.jsonl" {
  if cmp -s "$A/usage.jsonl" "$BATS_FILE_TMPDIR/c/usage.jsonl"; then
    printf 'a different seed produced the same usage.jsonl\n' >&2
    return 1
  fi
  true
}

@test "generator: cut offsets are line boundaries and split the final day off" {
  local f s cut size last
  for s in u:usage.jsonl l:links.jsonl c:cost.jsonl; do
    f="${s#*:}"
    cut="$(jq -r --arg k "${s%%:*}" '.cut[$k]' "$A/probes.json")"
    size="$(wc -c <"$A/$f" | tr -d ' ')"
    [ "$cut" -gt 0 ] && [ "$cut" -lt "$size" ] || { printf '%s: cut %s outside (0, %s)\n' "$f" "$cut" "$size" >&2; return 1; }
    last="$(head -c "$cut" "$A/$f" | tail -c 1 | od -An -tx1 | tr -d ' \n')"
    [ "$last" = 0a ] || { printf '%s: cut %s is not after a newline\n' "$f" "$cut" >&2; return 1; }
    # The earliest and latest stamp on each side, so a swapped cut would show.
    [ "$(head -c "$cut" "$A/$f" | jq -r '(.first_ts // .hw_ts // .ts)[0:10]' | sort | tail -n 1)" \
      '<' 2026-09-30 ] || { printf '%s: a prefix row falls on the final day\n' "$f" >&2; return 1; }
    [ "$(tail -c +$((cut + 1)) "$A/$f" | jq -r '(.first_ts // .hw_ts // .ts)[0:10]' | sort | head -n 1)" \
      = 2026-09-30 ] || { printf '%s: a suffix row falls before the final day\n' "$f" >&2; return 1; }
  done
  true
}

@test "probes.json: matches the C9 schema" {
  probes_valid "$A/probes.json"
}

@test "probes.json guard red: an unknown expect key, top-level key, or a missing category fails" {
  local bad="$BATS_TEST_TMPDIR/bad.json"
  jq '.probes[0].expect.bogus = true' "$A/probes.json" >"$bad"
  probes_valid "$bad" && return 1
  jq '.anchors = {}' "$A/probes.json" >"$bad"
  probes_valid "$bad" && return 1
  jq '.probes |= map(select(.category != "inherit"))' "$A/probes.json" >"$bad"
  probes_valid "$bad" && return 1
  jq '.probes[0].category = "made_up"' "$A/probes.json" >"$bad"
  probes_valid "$bad" && return 1
  true
}

@test "timing script: refuses without --baseline-rev and names the flag" {
  run "$BASH" "$TIMER" --stores "$A" --probe 1
  [ "$status" -eq 2 ]
  case "$output" in *--baseline-rev*) ;; *) printf 'flag not named: %s\n' "$output" >&2; return 1 ;; esac
}

@test "timing script: the bash gate passes under bash 5" {
  run "$BASH" "$TIMER" --stores "$A" --probe 1
  case "$output" in *"bash 5 or later"*) printf 'gate refused a bash 5: %s\n' "$output" >&2; return 1 ;; esac
  true
}

@test "timing script guard red: a raised gate threshold refuses with the bash-version message" {
  local copy="$BATS_TEST_TMPDIR/time-usage-readout.sh"
  grep -c -- '-ge 5 \]' "$TIMER" | grep -qx 1
  sed 's/-ge 5 \]/-ge 99 ]/' "$TIMER" >"$copy"
  grep -qF -- '-ge 99 ]' "$copy"
  run "$BASH" "$copy" --baseline-rev HEAD --stores "$A" --probe 1
  [ "$status" -eq 2 ]
  case "$output" in *"bash 5 or later"*) ;; *) printf 'no bash-version message: %s\n' "$output" >&2; return 1 ;; esac
}

@test "timing script: a bash below 5 exits 2 with the bash-version message" {
  local major
  major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')"
  if [ "$major" -ge 5 ]; then
    printf '/bin/bash is bash %s here; the raised-threshold test covers the refusal\n' "$major" >&2
    return 0
  fi
  run /bin/bash "$TIMER" --baseline-rev HEAD --stores "$A" --probe 1
  [ "$status" -eq 2 ]
  case "$output" in *"bash 5 or later"*) ;; *) printf 'no bash-version message: %s\n' "$output" >&2; return 1 ;; esac
}

# A scratch main root with the capture hooks registered, as the readout needs
# them to print its figures, and the stores loaded.
harness() {
  H="$BATS_TEST_TMPDIR/h"
  mkdir -p "$H/main/.claude" "$H/tel" "$H/projects"
  git -C "$H/main" init -q
  cat >"$H/main/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF
  cp "$A/usage.jsonl" "$A/links.jsonl" "$A/cost.jsonl" "$H/tel/"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_MEMO_TRACE GAIA_USAGE_MEMO_SEAM
}

@test "generated stores: today's usage.sh pr prints figures for the typical and the widest PR" {
  harness
  local pr
  for pr in "$(jq -r .typical_pr "$A/probes.json")" "$(jq -r .widest_pr "$A/probes.json")"; do
    run "$BASH" "$SRC/.gaia/scripts/usage.sh" pr "$pr" --main-root "$H/main" --telemetry-dir "$H/tel" \
      --rate-table "$SRC/.gaia/scripts/token-rates.json" --projects-root "$H/projects"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qE '^  tokens: [1-9]' || { printf 'no tokens line for pr %s:\n%s\n' "$pr" "$output" >&2; return 1; }
    printf '%s\n' "$output" | grep -qF 'est. cost (USD): $' || { printf 'no cost for pr %s\n' "$pr" >&2; return 1; }
  done
  # The widest PR sits under the wide root, so its readout lists that root.
  printf '%s\n' "$output" | grep -qF '[initiative research:wide-a '
}

# A scratch repository holding a committed copy of the scripts the readout
# needs, so --baseline-rev HEAD is the pre-change tree and the working copy is
# the changed one.
scratch_repo() {
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/.gaia" "$R/.specify/extensions/gaia"
  cp -R "$SRC/.gaia/scripts" "$R/.gaia/scripts"
  rm -rf "$R/.gaia/scripts/tests"
  cp -R "$SRC/.specify/extensions/gaia/lib" "$R/.specify/extensions/gaia/lib"
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" -c user.name=gaia-test -c user.email=gaia-test@example.com -c commit.gpgsign=false commit -q -m scratch
}

@test "timing script: identical=yes on equal trees, identical=no after a one-line output change, degenerate on no figures" {
  scratch_repo
  local pr out
  pr="$(jq -r .typical_pr "$A/probes.json")"
  run "$BASH" "$TIMER" --repo "$R" --baseline-rev HEAD --stores "$A" --probe "$pr" --runs 1 --out-dir "$BATS_TEST_TMPDIR/o1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^pre_median=[0-9.]+ new_median=[0-9.]+ ratio=[0-9.]+ identical=yes$' ||
    { printf 'unexpected result:\n%s\n' "$output" >&2; return 1; }
  grep -qE '^  tokens: ' "$BATS_TEST_TMPDIR/o1/new-1.out"

  grep -c 'window: after' "$R/.gaia/scripts/usage-render-lib.sh" | grep -qx 1
  sed -i.bak 's/window: after/window: AFTER/' "$R/.gaia/scripts/usage-render-lib.sh"
  grep -qF 'window: AFTER' "$R/.gaia/scripts/usage-render-lib.sh"
  run "$BASH" "$TIMER" --repo "$R" --baseline-rev HEAD --stores "$A" --probe "$pr" --runs 1 --mode cold --out-dir "$BATS_TEST_TMPDIR/o2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE ' identical=no$' || { printf 'a changed output read as identical:\n%s\n' "$output" >&2; return 1; }

  run "$BASH" "$TIMER" --repo "$R" --baseline-rev HEAD --stores "$A" --sub "pr 7777777" --runs 1 --out-dir "$BATS_TEST_TMPDIR/o3"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE ' identical=degenerate$' || { printf 'a figure-less output was not degenerate:\n%s\n' "$output" >&2; return 1; }
  out="$BATS_TEST_TMPDIR/o3/pre-1.out"
  grep -qF '(branch unresolved)' "$out"
}
