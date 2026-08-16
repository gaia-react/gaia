#!/usr/bin/env bats

# The statusline's right side is a task queue, and each segment names the one
# slash command that discharges it. Two segments naming the same command read
# as two invocations of one command with nothing to tell them apart, and no
# argument selects between them, so a reader cannot act on one without the
# other. The invariant: no command appears in more than one segment of a
# rendered statusline.
#
# It has to be checked against the RENDERED line rather than against the
# source's `segments+=` calls. `/gaia-audit` legitimately occupies two of
# those calls, an if/else over whether a reason is available, and only ever
# renders one of them; a source-level count would red on the very shape that
# is correct.
#
# The fixture mirrors the statusline half of harden-unclassified-segment.bats:
# a MAIN git checkout with setup marked complete and no gaia-init gate file,
# so the right-side indicators are eligible to render, and HOME pointing at an
# empty dir so left-side delegation stays inert.

setup() {
  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)

  MAIN=$(mktemp -d -t gaia-sl-unique-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/local/cache/shared"
  cp "$STATUSLINE_SRC/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"

  TMP_HOME=$(mktemp -d -t gaia-sl-unique-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  return 0
}

# Render MAIN's statusline against a cache that arms every right-side
# indicator at once, which is the only state that can expose a duplicate.
run_saturated_statusline() {
  local json
  cat > "$MAIN/.gaia/local/cache/shared/update-check.json" <<'JSON'
{
  "gaiaHasUpdate": true,
  "gaiaLatest": "9.9.9",
  "outdatedCount": 3,
  "hardenCandidateCount": 2,
  "hardenUnclassifiedCount": 1,
  "auditNudge": true,
  "auditNudgeReason": "stale",
  "serenaLangDrift": ["go"]
}
JSON
  mkdir -p "$MAIN/.gaia/local/debt"
  printf '{"openCount":4}' > "$MAIN/.gaia/local/debt/count.json"
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
}

# Every slash command the rendered line names, one per line, sorted. The
# `Run ` prefix keeps a command named inside a segment's parameter text from
# counting as a segment of its own. `LC_ALL=C` so the order never depends on
# the invoking locale's collation of the hyphen.
rendered_commands() {
  grep -oE 'Run /[a-z][a-z0-9-]*' <<<"$1" | LC_ALL=C sort
}

# The saturated fixture is what gives the uniqueness test below anything to
# check, so pin the exact set it arms rather than a cardinality floor. A floor
# still passes on the survivors when a fixture path drifts out from under one
# segment, and the invariant then goes unexercised over the command that
# dropped out with nothing to say coverage shrank.
@test "the saturated cache arms every right-side segment" {
  run_saturated_statusline
  [ "$status" -eq 0 ]
  expected=$(printf '%s\n' \
    "Run /gaia-audit" \
    "Run /gaia-debt" \
    "Run /gaia-harden" \
    "Run /gaia-serena-sync" \
    "Run /update-deps" \
    "Run /update-gaia")
  [ "$(rendered_commands "$output")" = "$expected" ]
}

@test "no slash command appears in more than one rendered statusline segment" {
  run_saturated_statusline
  [ "$status" -eq 0 ]
  dupes=$(rendered_commands "$output" | uniq -d)
  [ -z "$dupes" ]
}
