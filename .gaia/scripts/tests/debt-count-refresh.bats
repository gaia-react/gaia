#!/usr/bin/env bats
# Tests for `.gaia/scripts/debt-count-refresh.sh`, focused on the sentinel
# settle-grace re-arm.
#
# GitHub's issue-list index is eventually consistent, so a recompute fired the
# instant a /gaia-debt PR merges can still count the just-closed issue. If that
# stale read cleared the sentinel, the `Run /gaia-debt` nudge would freeze at the
# pre-merge count until the 6h TTL. The fix keeps a sentinel younger than the
# settle grace armed so a later tick re-reads the now-consistent count first.
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

# stub_gh <count>: a fake `gh` whose `issue list` reports <count> open issues.
stub_gh() {
  cat > "$SANDBOX/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  printf '%s\n' "$1"
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_fail: a fake `gh` whose `issue list` prints nothing (a network/auth
# failure). The refresher then treats the read as failed (recompute_ok=false).
stub_gh_fail() {
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_touching <count>: a fake `gh` whose `issue list` reports <count> open
# issues AND re-arms the sentinel mid-call, standing in for a peer worktree whose
# /gaia-debt PR merges inside this run's network window. `.gaia/local/debt/` is a
# shared-state path symlinked into every worktree, so both runs address one file.
stub_gh_touching() {
  cat > "$SANDBOX/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  : > "$SENTINEL"
  printf '%s\n' "$1"
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_json <json>: a fake `gh` whose `issue list` applies the script's own
# --jq filter (scanned from argv) to <json>, so the real exclusion expression is
# exercised rather than a pre-baked count.
stub_gh_json() {
  cat > "$SANDBOX/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  filter='length'
  prev=""
  for a in "\$@"; do
    if [ "\$prev" = "--jq" ]; then filter="\$a"; fi
    prev="\$a"
  done
  printf '%s' '$1' | jq -r "\$filter"
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# Prepend the stub dir so our `gh` wins over any host `gh`; keep the rest of PATH
# so the real `jq` still resolves.
run_refresh() {
  ( cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" "$SCRIPT" )
}

# past_ts <seconds>: a `touch -t` stamp for (now - seconds), portable across
# BSD/macOS `date -r <epoch>` and GNU `date -d @<epoch>`.
past_ts() {
  local epoch=$(( $(date +%s) - $1 ))
  date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S
}

open_count() { jq -r '.openCount' "$CACHE"; }

# --- 1. Young sentinel + stale (still-high) read: count written, sentinel KEPT -
# The exact race that stuck the nudge: the merge fired the sentinel, the index
# still reports the just-closed issue, so the recompute reads a stale 1. It must
# write that read but keep the sentinel armed so a later tick can correct it.
@test "young sentinel + stale read: writes count but keeps the sentinel armed" {
  stub_gh 1
  : > "$SENTINEL"            # fresh: mtime = now, inside the grace
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "1" ]
  [ -e "$SENTINEL" ]         # NOT cleared: next tick re-reads the settled count
}

# --- 2. Young sentinel + already-correct read: still KEPT (grace is time-based) -
# The grace never inspects the value; it waits out the index-consistency window
# regardless, so even a correct 0 keeps the sentinel until it ages out.
@test "young sentinel + correct read: still keeps the sentinel (time-based grace)" {
  stub_gh 0
  : > "$SENTINEL"
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "0" ]
  [ -e "$SENTINEL" ]
}

# --- 3. Aged sentinel + successful read: count written, sentinel CLEARED --------
# Past the grace the index has settled, so the recompute is trusted and the
# sentinel clears (otherwise it would recompute every tick forever).
@test "aged sentinel past grace: writes count and clears the sentinel" {
  stub_gh 0
  : > "$SENTINEL"
  touch -t "$(past_ts 300)" "$SENTINEL"   # 300s old > 120s grace
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "0" ]
  [ ! -e "$SENTINEL" ]
}

# --- 4. Failed read, no prior cache: zero-seed written, sentinel KEPT -----------
# Guards the untouched backend-absent path: a failed recompute (recompute_ok
# false) seeds openCount 0 but must keep the sentinel so the next tick retries,
# even when the sentinel has already aged past the grace.
@test "failed read with no prior cache: zero-seeds and keeps the sentinel" {
  stub_gh_fail
  : > "$SENTINEL"
  touch -t "$(past_ts 300)" "$SENTINEL"
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "0" ]
  [ -e "$SENTINEL" ]
}

# --- 5. Excludes debt:in-progress from the open count -------------------------
# The core concurrency contract: an open tech-debt issue carrying the claim label
# is subtracted from the count so a peer session's nudge drops. Three issues, one
# claimed, must count 2.
@test "excludes debt:in-progress from the open count" {
  stub_gh_json '[{"number":1,"labels":[{"name":"tech-debt"},{"name":"severity:important"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"severity:suggestion"},{"name":"debt:in-progress"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"severity:critical"}]}]'
  : > "$SENTINEL"
  touch -t "$(past_ts 300)" "$SENTINEL"   # aged past the 120s grace: count trusted & written
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
  touch -t "$(past_ts 300)" "$SENTINEL"   # aged past the 120s grace: count trusted & written
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "2" ]
}

# --- 7. Excludes both claim labels together -----------------------------------
# debt:in-progress and debt:spec-pending are distinct exclusions; both must drop.
# Four issues: plain, in-progress, spec-pending, and one carrying both -> counts 1.
@test "excludes both debt:in-progress and debt:spec-pending" {
  stub_gh_json '[{"number":1,"labels":[{"name":"tech-debt"}]},{"number":2,"labels":[{"name":"tech-debt"},{"name":"debt:in-progress"}]},{"number":3,"labels":[{"name":"tech-debt"},{"name":"debt:spec-pending"}]},{"number":4,"labels":[{"name":"tech-debt"},{"name":"debt:in-progress"},{"name":"debt:spec-pending"}]}]'
  : > "$SENTINEL"
  touch -t "$(past_ts 300)" "$SENTINEL"
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "1" ]
}

# --- 8. Aged sentinel re-armed mid-recompute: the re-arm SURVIVES --------------
# The clear decides on state sampled before the `gh` call. A peer worktree that
# merges inside that window re-touches the sentinel, and its invalidation must
# not be deleted by this run: the count it demands is newer than the one this run
# just wrote.
@test "sentinel re-armed during the recompute: keeps the new sentinel" {
  stub_gh_touching 1
  : > "$SENTINEL"
  touch -t "$(past_ts 300)" "$SENTINEL"   # aged past the grace: the clear is armed
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "1" ]
  [ -e "$SENTINEL" ]                      # the peer's re-arm survives
}

# --- 9. No sentinel at sample time, armed mid-recompute: SURVIVES too ----------
# A TTL/missing-cache recompute samples no sentinel at all, so nothing holds the
# clear back and it fires blind on a sentinel armed during the `gh` call. Here the
# cache is absent (the missing-cache trigger) and the peer arms mid-call.
@test "sentinel armed during a no-sentinel recompute: keeps the new sentinel" {
  stub_gh_touching 2
  [ ! -e "$SENTINEL" ]
  [ ! -e "$CACHE" ]
  run run_refresh
  [ "$status" -eq 0 ]
  [ "$(open_count)" = "2" ]
  [ -e "$SENTINEL" ]
}
