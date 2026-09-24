#!/usr/bin/env bats
# Tests for `.gaia/scripts/debt-count-refresh.sh`, focused on the openCount
# exclusion filter (in-progress, debt:spec-pending, debt:spec-active).
#
# The script writes under `$PROJECT_ROOT/.gaia/local/debt/`, where PROJECT_ROOT
# derives from the script's own path. Each test runs a COPY inside an isolated
# sandbox so it never touches the real repo cache, with a stub `gh` on PATH.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SRC_SCRIPT="$THIS_DIR/../debt-count-refresh.sh"
  [ -f "$SRC_SCRIPT" ] || skip "debt-count-refresh.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia/scripts" "$SANDBOX/.gaia/local/debt" "$SANDBOX/bin"
  cp "$SRC_SCRIPT" "$SANDBOX/.gaia/scripts/debt-count-refresh.sh"
  chmod +x "$SANDBOX/.gaia/scripts/debt-count-refresh.sh"
  SCRIPT="$SANDBOX/.gaia/scripts/debt-count-refresh.sh"
  DEBT_DIR="$SANDBOX/.gaia/local/debt"
  SENTINEL="$DEBT_DIR/refresh-requested"
  CACHE="$DEBT_DIR/count.json"
}

# write_gh_stub <json> [extra-line]: a fake `gh` that serves <json> from
# `issue list` the way the real one does, which is what lets one stub cover both
# call shapes the refresher uses. Real `gh` applies a `--jq` filter when given
# one and emits the raw `--json` array when not, so the stub scans argv for
# `--jq` and does the same. A stub that answered only one shape would go green
# or red on the shape rather than on the behaviour under test.
# The fixture goes to a sidecar file rather than being spliced into the stub
# between single quotes: one apostrophe in an issue body would otherwise close
# the quote and emit a stub that is a syntax error, which presents as an empty
# read (a gh failure) and reds a test on a stale count instead of on the real
# cause.
write_gh_stub() {
  printf '%s' "$1" > "$SANDBOX/issues.json"
  cat > "$SANDBOX/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  $2
  filter=""
  prev=""
  for a in "\$@"; do
    if [ "\$prev" = "--jq" ]; then filter="\$a"; fi
    prev="\$a"
  done
  if [ -n "\$filter" ]; then
    jq -r "\$filter" "$SANDBOX/issues.json"
  else
    cat "$SANDBOX/issues.json"
  fi
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_json <json>: a fake `gh` serving a hand-written issue array, so the
# real exclusion expression runs against real labels rather than a pre-baked
# count.
stub_gh_json() {
  write_gh_stub "$1"
}

# Prepend the stub dir so our `gh` wins over any host `gh`; keep the rest of PATH
# so the real `jq` still resolves.
run_refresh() {
  ( cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" "$SCRIPT" )
}

open_count() { jq -r '.openCount' "$CACHE"; }

# --- 5. Excludes in-progress from the open count -------------------------
# The core concurrency contract: an open tech-debt issue carrying the claim label
# is subtracted from the count so a peer session's nudge drops. Three issues, one
# claimed, must count 2.
#
# Issue 1 carries an apostrophe in its body on purpose. Filed issue bodies
# routinely do, and it is what pins the stub's fixture handling: splice the
# fixture into the stub between single quotes and the apostrophe closes the
# quote, so the stub becomes a syntax error, reads as a gh failure, and this
# test reds on a stale count rather than on the real cause.
@test "excludes in-progress from the open count" {
  stub_gh_json '[{"number":1,"labels":[{"name":"tech-debt"},{"name":"severity:important"}],"body":"the refresher'"'"'s own count"},{"number":2,"labels":[{"name":"tech-debt"},{"name":"severity:suggestion"},{"name":"in-progress"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"severity:critical"}]}]'
  : > "$SENTINEL"
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "2" ]
}

# --- 6. Excludes debt:spec-pending from the open count ------------------------
# A handed-off (design-first) issue carries debt:spec-pending and is parked out of
# the backlog until its SPEC and implementation land, so it must not inflate the
# nudge. Three issues, one spec-pending, must count 2.
@test "excludes debt:spec-pending from the open count" {
  stub_gh_json '[{"number":1,"labels":[{"name":"tech-debt"},{"name":"severity:important"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"severity:suggestion"},{"name":"debt:spec-pending"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"severity:critical"}]}]'
  : > "$SENTINEL"
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "2" ]
}

# --- 6b. Excludes debt:spec-active from the open count ------------------------
# Once the pipeline starts, the handoff swaps the park label from
# debt:spec-pending to debt:spec-active. The issue is no less parked for having
# started, so the active state must leave the count exactly as the pending one
# does. Three issues, one spec-active, must count 2.
@test "excludes debt:spec-active from the open count" {
  stub_gh_json '[{"number":1,"labels":[{"name":"tech-debt"},{"name":"severity:important"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"severity:suggestion"},{"name":"debt:spec-active"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"severity:critical"}]}]'
  : > "$SENTINEL"
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "2" ]
}

# --- 7. Excludes every claim label together ------------------------------
# in-progress, debt:spec-pending, and debt:spec-active are distinct exclusions;
# all three must drop. Five issues: plain, in-progress, spec-pending,
# spec-active, and one carrying every one of them -> counts 1.
@test "excludes in-progress, debt:spec-pending and debt:spec-active" {
  stub_gh_json '[{"number":1,"labels":[{"name":"tech-debt"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"in-progress"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"debt:spec-pending"}]},{"number":4,"labels":[{"name":"tech-debt"},{"name":"debt:spec-active"}]},{"number":5,"labels":[{"name":"tech-debt"},{"name":"in-progress"},{"name":"debt:spec-pending"},{"name":"debt:spec-active"}]}]'
  : > "$SENTINEL"
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "1" ]
}
