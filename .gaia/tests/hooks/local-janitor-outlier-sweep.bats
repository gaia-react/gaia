#!/usr/bin/env bats
#
# Sweep #9 of local-janitor.sh: the allowlist-based outlier sweep.
#
# Sweep 9 walks exactly three scope roots (top level of .gaia/local, its
# audit/, its cache/) at maxdepth-1/mindepth-1 and reaps anything NOT on that
# root's protected allowlist once older than GAIA_OUTLIER_RETENTION_DAYS,
# except OS junk which it reaps at any age. Because it deletes unknown files
# by default under a gitignored folder no diff ever surfaces, its safety
# rests on allowlist completeness and disjoint ownership with the existing
# sweeps -- both checked here.
#
# GAIA_JANITOR_SWEEP_ONLY=outliers runs sweep 9 alone (skipping sweeps 2-8 and
# the one-time migration blocks), so every allowlist-survival assertion below
# is attributable to sweep 9 itself, not a sibling sweep. Every such survival
# assertion is paired with a positive control: an off-allowlist sibling in the
# same fixture that the same run must delete, so a no-op or crashed sweep 9
# cannot pass by leaving everything untouched.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; final-line absence uses `[ ! -e ... ]`.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/local-janitor.sh
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# make_repo: a minimal git repo with .gaia/local, sufficient for the janitor's
# `git rev-parse --show-toplevel` resolution. No bare origin: nothing here
# exercises branch upstream-track state.
make_repo() {
  REPO=$(mktemp -d -t gaia-janitor-outlier-repo-XXXXXX)
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  echo init > "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/.gaia/local"
}

# past_ts <seconds>: a `touch -t` stamp for (now - seconds), portable across
# BSD/macOS `date -r <epoch>` and GNU `date -d @<epoch>`.
past_ts() {
  local epoch=$(( $(date +%s) - $1 ))
  date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S
}

# --- UAT-001/UAT-002: age-gated generic reap ---------------------------------

@test "UAT-001: an aged off-allowlist file, dotfile, and non-empty dir at each of the three roots are all deleted" {
  make_repo
  mkdir -p "$REPO/.gaia/local/audit" "$REPO/.gaia/local/cache"

  echo x > "$REPO/.gaia/local/cruft.md"
  echo x > "$REPO/.gaia/local/.stray-config"
  mkdir -p "$REPO/.gaia/local/ca-research"
  echo x > "$REPO/.gaia/local/ca-research/inner.txt"

  echo x > "$REPO/.gaia/local/audit/cruft.md"
  echo x > "$REPO/.gaia/local/audit/.stray"
  mkdir -p "$REPO/.gaia/local/audit/stray-dir"
  echo x > "$REPO/.gaia/local/audit/stray-dir/inner.txt"

  echo x > "$REPO/.gaia/local/cache/cruft.md"
  echo x > "$REPO/.gaia/local/cache/.stray"
  mkdir -p "$REPO/.gaia/local/cache/stray-dir"
  echo x > "$REPO/.gaia/local/cache/stray-dir/inner.txt"

  touch -t 202001010000 \
    "$REPO/.gaia/local/cruft.md" "$REPO/.gaia/local/.stray-config" \
    "$REPO/.gaia/local/ca-research/inner.txt" "$REPO/.gaia/local/ca-research" \
    "$REPO/.gaia/local/audit/cruft.md" "$REPO/.gaia/local/audit/.stray" \
    "$REPO/.gaia/local/audit/stray-dir/inner.txt" "$REPO/.gaia/local/audit/stray-dir" \
    "$REPO/.gaia/local/cache/cruft.md" "$REPO/.gaia/local/cache/.stray" \
    "$REPO/.gaia/local/cache/stray-dir/inner.txt" "$REPO/.gaia/local/cache/stray-dir"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -e "$REPO/.gaia/local/cruft.md" ] && return 1
  [ -e "$REPO/.gaia/local/.stray-config" ] && return 1
  [ -e "$REPO/.gaia/local/ca-research" ] && return 1
  [ -e "$REPO/.gaia/local/audit/cruft.md" ] && return 1
  [ -e "$REPO/.gaia/local/audit/.stray" ] && return 1
  [ -e "$REPO/.gaia/local/audit/stray-dir" ] && return 1
  [ -e "$REPO/.gaia/local/cache/cruft.md" ] && return 1
  [ -e "$REPO/.gaia/local/cache/.stray" ] && return 1
  [ ! -e "$REPO/.gaia/local/cache/stray-dir" ]
}

@test "UAT-002: the same off-allowlist entries, freshly written, all survive" {
  make_repo
  mkdir -p "$REPO/.gaia/local/audit" "$REPO/.gaia/local/cache"

  echo x > "$REPO/.gaia/local/cruft.md"
  echo x > "$REPO/.gaia/local/.stray-config"
  mkdir -p "$REPO/.gaia/local/ca-research"
  echo x > "$REPO/.gaia/local/ca-research/inner.txt"

  echo x > "$REPO/.gaia/local/audit/cruft.md"
  echo x > "$REPO/.gaia/local/audit/.stray"
  mkdir -p "$REPO/.gaia/local/audit/stray-dir"
  echo x > "$REPO/.gaia/local/audit/stray-dir/inner.txt"

  echo x > "$REPO/.gaia/local/cache/cruft.md"
  echo x > "$REPO/.gaia/local/cache/.stray"
  mkdir -p "$REPO/.gaia/local/cache/stray-dir"
  echo x > "$REPO/.gaia/local/cache/stray-dir/inner.txt"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$REPO/.gaia/local/cruft.md" ]
  [ -f "$REPO/.gaia/local/.stray-config" ]
  [ -d "$REPO/.gaia/local/ca-research" ]
  [ -f "$REPO/.gaia/local/audit/cruft.md" ]
  [ -f "$REPO/.gaia/local/audit/.stray" ]
  [ -d "$REPO/.gaia/local/audit/stray-dir" ]
  [ -f "$REPO/.gaia/local/cache/cruft.md" ]
  [ -f "$REPO/.gaia/local/cache/.stray" ]
  [ -d "$REPO/.gaia/local/cache/stray-dir" ]
}

# --- UAT-003/004/005: per-root allowlist survival + positive controls -------

@test "UAT-003: every allowlisted top-level entry survives at ancient age; an off-allowlist control is deleted; drop-zone dirs are kept whole" {
  make_repo
  local_dir="$REPO/.gaia/local"

  for f in maintainer-statusline.sh .patched-statusline.sh .project-id \
           .mentorship-swept setup-state.json declined-updates.json \
           automation.json sandbox.json dep-audit-baseline.json setup-in-progress; do
    echo x > "$local_dir/$f"
    touch -t 202001010000 "$local_dir/$f"
  done

  for d in audit cache debt forensics handoff plans red-ledger specs telemetry \
           worktree-locks harden; do
    mkdir -p "$local_dir/$d"
    touch -t 202001010000 "$local_dir/$d"
  done

  echo x > "$local_dir/cruft-control.md"
  touch -t 202001010000 "$local_dir/cruft-control.md"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  for f in maintainer-statusline.sh .patched-statusline.sh .project-id \
           .mentorship-swept setup-state.json declined-updates.json \
           automation.json sandbox.json dep-audit-baseline.json setup-in-progress; do
    [ -f "$local_dir/$f" ] || return 1
  done
  for d in audit cache debt forensics handoff plans red-ledger specs telemetry \
           worktree-locks harden; do
    [ -d "$local_dir/$d" ] || return 1
  done

  [ ! -e "$local_dir/cruft-control.md" ]
}

@test "UAT-004: audit/ allowlist entries survive; an off-allowlist control is deleted; the three subtrees are kept whole" {
  make_repo
  audit_dir="$REPO/.gaia/local/audit"
  mkdir -p "$audit_dir"

  echo '{}' > "$audit_dir/deadbeef.ok"
  echo '{}' > "$audit_dir/deadbeef.refused"
  echo x > "$audit_dir/worthiness.jsonl"
  echo x > "$audit_dir/KNOWLEDGE-frontend.md"
  for f in deadbeef.ok deadbeef.refused worthiness.jsonl KNOWLEDGE-frontend.md; do
    touch -t 202001010000 "$audit_dir/$f"
  done

  mkdir -p "$audit_dir/archived" "$audit_dir/security" "$audit_dir/comprehensive"
  touch -t 202001010000 "$audit_dir/archived" "$audit_dir/security" "$audit_dir/comprehensive"

  echo x > "$audit_dir/stray-scratch.md"
  touch -t 202001010000 "$audit_dir/stray-scratch.md"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$audit_dir/deadbeef.ok" ] || return 1
  [ -f "$audit_dir/deadbeef.refused" ] || return 1
  [ -f "$audit_dir/worthiness.jsonl" ] || return 1
  [ -f "$audit_dir/KNOWLEDGE-frontend.md" ] || return 1
  [ -d "$audit_dir/archived" ] || return 1
  [ -d "$audit_dir/security" ] || return 1
  [ -d "$audit_dir/comprehensive" ] || return 1

  [ ! -e "$audit_dir/stray-scratch.md" ]
}

@test "UAT-005: cache/ allowlist entries survive; an off-allowlist control is deleted; a renders.json-holding dir survives despite its arbitrary name" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"

  echo '{}' > "$cache_dir/gate1-abc.json"
  echo x > "$cache_dir/draft-abc.md"
  echo x > "$cache_dir/draft.md"
  echo '{}' > "$cache_dir/spec-session-abc.json"
  echo '{}' > "$cache_dir/spec-chain-abc.json"
  echo '{}' > "$cache_dir/gh-artifact-pr.json"
  echo x > "$cache_dir/version-check.lock"
  echo x > "$cache_dir/v2-update-notes.md"
  for f in gate1-abc.json draft-abc.md draft.md spec-session-abc.json \
           spec-chain-abc.json gh-artifact-pr.json version-check.lock v2-update-notes.md; do
    touch -t 202001010000 "$cache_dir/$f"
  done

  mkdir -p "$cache_dir/audit-SPEC-xyz" "$cache_dir/wiki-promote" "$cache_dir/uat-write" "$cache_dir/shared"
  touch -t 202001010000 "$cache_dir/audit-SPEC-xyz" "$cache_dir/wiki-promote" \
    "$cache_dir/uat-write" "$cache_dir/shared"

  mkdir -p "$cache_dir/whatever-run-id"
  echo '{}' > "$cache_dir/whatever-run-id/renders.json"
  touch -t 202001010000 "$cache_dir/whatever-run-id/renders.json" "$cache_dir/whatever-run-id"

  echo x > "$cache_dir/stray-scratch.json"
  touch -t 202001010000 "$cache_dir/stray-scratch.json"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  for f in gate1-abc.json draft-abc.md draft.md spec-session-abc.json \
           spec-chain-abc.json gh-artifact-pr.json version-check.lock v2-update-notes.md; do
    [ -f "$cache_dir/$f" ] || return 1
  done
  [ -d "$cache_dir/audit-SPEC-xyz" ] || return 1
  [ -d "$cache_dir/wiki-promote" ] || return 1
  [ -d "$cache_dir/uat-write" ] || return 1
  [ -d "$cache_dir/shared" ] || return 1
  [ -d "$cache_dir/whatever-run-id" ] || return 1
  [ -f "$cache_dir/whatever-run-id/renders.json" ] || return 1

  [ ! -e "$cache_dir/stray-scratch.json" ]
}

# --- UAT-006: OS junk, the only age-independent deletion --------------------

@test "UAT-006: OS junk is deleted at every root despite being freshly written" {
  make_repo
  local_dir="$REPO/.gaia/local"
  mkdir -p "$local_dir/audit" "$local_dir/cache"

  for d in "$local_dir" "$local_dir/audit" "$local_dir/cache"; do
    touch "$d/.DS_Store"
    touch "$d/Thumbs.db"
    touch "$d/._resource"
  done

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -e "$local_dir/.DS_Store" ] && return 1
  [ -e "$local_dir/Thumbs.db" ] && return 1
  [ -e "$local_dir/._resource" ] && return 1
  [ -e "$local_dir/audit/.DS_Store" ] && return 1
  [ -e "$local_dir/audit/Thumbs.db" ] && return 1
  [ -e "$local_dir/audit/._resource" ] && return 1
  [ -e "$local_dir/cache/.DS_Store" ] && return 1
  [ -e "$local_dir/cache/Thumbs.db" ] && return 1
  [ ! -e "$local_dir/cache/._resource" ]
}

# --- UAT-007: never below maxdepth-1, never the ledger / self-managing zones -

@test "UAT-007: nested off-allowlist files below maxdepth-1 and inside never-traverse zones survive; a paired top-level control is deleted" {
  make_repo
  local_dir="$REPO/.gaia/local"
  audit_dir="$local_dir/audit"
  cache_dir="$local_dir/cache"

  mkdir -p "$audit_dir/comprehensive/deep" "$audit_dir/archived/run1" "$audit_dir/security"
  echo x > "$audit_dir/comprehensive/deep/junk.txt"
  echo x > "$audit_dir/archived/run1/junk.txt"
  echo x > "$audit_dir/security/junk.md"

  mkdir -p "$cache_dir/audit-xyz/inner"
  echo x > "$cache_dir/audit-xyz/inner/junk.json"

  for d in telemetry red-ledger handoff plans specs debt forensics; do
    mkdir -p "$local_dir/$d"
    echo x > "$local_dir/$d/junk.txt"
  done

  touch -t 202001010000 \
    "$audit_dir/comprehensive/deep/junk.txt" "$audit_dir/comprehensive/deep" "$audit_dir/comprehensive" \
    "$audit_dir/archived/run1/junk.txt" "$audit_dir/archived/run1" "$audit_dir/archived" \
    "$audit_dir/security/junk.md" "$audit_dir/security" \
    "$cache_dir/audit-xyz/inner/junk.json" "$cache_dir/audit-xyz/inner" "$cache_dir/audit-xyz"
  for d in telemetry red-ledger handoff plans specs debt forensics; do
    touch -t 202001010000 "$local_dir/$d/junk.txt" "$local_dir/$d"
  done

  echo x > "$local_dir/cruft.md"
  touch -t 202001010000 "$local_dir/cruft.md"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$audit_dir/comprehensive/deep/junk.txt" ] || return 1
  [ -f "$audit_dir/archived/run1/junk.txt" ] || return 1
  [ -f "$audit_dir/security/junk.md" ] || return 1
  [ -f "$cache_dir/audit-xyz/inner/junk.json" ] || return 1
  for d in telemetry red-ledger handoff plans specs debt forensics; do
    [ -f "$local_dir/$d/junk.txt" ] || return 1
  done

  [ ! -e "$local_dir/cruft.md" ]
}

# --- UAT-008/009: owner arms, not sweep 9, reap their own patterns ----------

@test "UAT-008: the sweep 2 findings arm reaps an aged audit/*.findings.json and keeps a fresh one" {
  make_repo
  audit_dir="$REPO/.gaia/local/audit"
  mkdir -p "$audit_dir"
  echo '{"member":"code-audit-frontend","findings":[]}' > "$audit_dir/deadbeef.findings.json"
  touch -t 202001010000 "$audit_dir/deadbeef.findings.json"
  echo '{"member":"code-audit-frontend","findings":[]}' > "$audit_dir/beefdead.findings.json"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$audit_dir/deadbeef.findings.json" ] && return 1
  [ -f "$audit_dir/beefdead.findings.json" ]
}

@test "UAT-008b: an isolation sweep-9-only run reaps neither findings.json (the owner arm, not sweep 9, is the reaper)" {
  make_repo
  audit_dir="$REPO/.gaia/local/audit"
  mkdir -p "$audit_dir"
  echo '{"member":"code-audit-frontend","findings":[]}' > "$audit_dir/deadbeef.findings.json"
  touch -t 202001010000 "$audit_dir/deadbeef.findings.json"
  echo '{"member":"code-audit-frontend","findings":[]}' > "$audit_dir/beefdead.findings.json"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$audit_dir/deadbeef.findings.json" ]
  [ -f "$audit_dir/beefdead.findings.json" ]
}

@test "UAT-009: the sweep 5 gh-artifact arm reaps an aged cache/gh-artifact-pr.json" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{"branch":"x"}' > "$cache_dir/gh-artifact-pr.json"
  touch -t 202001010000 "$cache_dir/gh-artifact-pr.json"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$cache_dir/gh-artifact-pr.json" ]
}

@test "UAT-009b: the sweep 5 gh-artifact arm keeps a fresh cache/gh-artifact-pr.json" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{"branch":"x"}' > "$cache_dir/gh-artifact-pr.json"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$cache_dir/gh-artifact-pr.json" ]
}

@test "UAT-009c: an isolation sweep-9-only run never reaps cache/gh-artifact-pr.json (the owner arm, not sweep 9, is the reaper)" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{"branch":"x"}' > "$cache_dir/gh-artifact-pr.json"
  touch -t 202001010000 "$cache_dir/gh-artifact-pr.json"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$cache_dir/gh-artifact-pr.json" ]
}

# --- CG-001: sweep 5's own age arm reaps the spec-session-*.lock glob -------

@test "CG-001: the sweep 5 age arm reaps an aged spec-session-<id>.lock" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{}' > "$cache_dir/spec-session-SPEC-999.lock"
  touch -t 202001010000 "$cache_dir/spec-session-SPEC-999.lock"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$cache_dir/spec-session-SPEC-999.lock" ]
}

@test "CG-001b: the sweep 5 age arm keeps a fresh spec-session-<id>.lock" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{}' > "$cache_dir/spec-session-SPEC-999.lock"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$cache_dir/spec-session-SPEC-999.lock" ]
}

# --- UAT-010: floor-clamp / non-numeric fallback on every new knob ---------

@test "UAT-010: a non-numeric GAIA_OUTLIER_RETENTION_DAYS falls back to the default 7 (not the floor 2)" {
  make_repo
  local_dir="$REPO/.gaia/local"
  echo x > "$local_dir/cruft.md"
  touch -t "$(past_ts $((3 * 86400)))" "$local_dir/cruft.md"   # 3d old: floor-2 reaps it, default-7 keeps it

  cd "$REPO"
  GAIA_OUTLIER_RETENTION_DAYS=abc GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$local_dir/cruft.md" ]
}

@test "UAT-010b: GAIA_OUTLIER_RETENTION_DAYS=1 clamps up to the floor 2" {
  make_repo
  local_dir="$REPO/.gaia/local"
  echo x > "$local_dir/cruft.md"
  touch -t "$(past_ts $((49 * 3600)))" "$local_dir/cruft.md"   # ~49h old

  cd "$REPO"
  GAIA_OUTLIER_RETENTION_DAYS=1 GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$local_dir/cruft.md" ]
}

@test "UAT-010c: a non-numeric GAIA_AUDIT_FINDINGS_RETENTION_HOURS falls back to the default 72h" {
  make_repo
  audit_dir="$REPO/.gaia/local/audit"
  mkdir -p "$audit_dir"
  echo '{}' > "$audit_dir/deadbeef.findings.json"
  touch -t "$(past_ts $((80 * 3600)))" "$audit_dir/deadbeef.findings.json"   # 80h old > 72h default

  cd "$REPO"
  GAIA_AUDIT_FINDINGS_RETENTION_HOURS=abc run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$audit_dir/deadbeef.findings.json" ]
}

@test "UAT-010d: a non-numeric GAIA_CACHE_ARTIFACT_RETENTION_DAYS falls back to the default 2d" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{}' > "$cache_dir/gh-artifact-pr.json"
  touch -t "$(past_ts $((3 * 86400)))" "$cache_dir/gh-artifact-pr.json"   # 3d old > 2d default

  cd "$REPO"
  GAIA_CACHE_ARTIFACT_RETENTION_DAYS=abc run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$cache_dir/gh-artifact-pr.json" ]
}

@test "UAT-010e: GAIA_AUDIT_FINDINGS_RETENTION_HOURS=1 clamps up to the floor 24h" {
  make_repo
  audit_dir="$REPO/.gaia/local/audit"
  mkdir -p "$audit_dir"
  echo '{}' > "$audit_dir/deadbeef.findings.json"
  touch -t "$(past_ts $((90 * 60)))" "$audit_dir/deadbeef.findings.json"   # ~90min old

  cd "$REPO"
  GAIA_AUDIT_FINDINGS_RETENTION_HOURS=1 run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$audit_dir/deadbeef.findings.json" ]
}

@test "UAT-010f: GAIA_CACHE_ARTIFACT_RETENTION_DAYS=0 clamps up to the floor 1d" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{}' > "$cache_dir/gh-artifact-pr.json"
  touch -t "$(past_ts $((30 * 3600)))" "$cache_dir/gh-artifact-pr.json"   # ~30h old

  cd "$REPO"
  GAIA_CACHE_ARTIFACT_RETENTION_DAYS=0 run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$cache_dir/gh-artifact-pr.json" ]
}

# --- UAT-011: disjoint-owner guard -------------------------------------------
#
# Reads what an existing sweep already age-manages, and what sweep 9's
# allowlist protects, straight from source (no hardcoded duplicate list on
# either side of the comparison) and fails if any managed glob is missing
# from the matching allowlist.

# sweep5_globs: every `-name '<glob>'` argument inside the `# --- 5.` block
# (bounded by the next divider), one per line. Covers both original sweep-5
# artifacts and the new gh-artifact arm attached to the same block.
sweep5_globs() {
  sed -n '/^# --- 5\. /,/^# --- 6\. /p' "$HOOK_ABS" \
    | grep -oE -- "-name '[^']+'" \
    | sed -E "s/-name '([^']+)'/\1/"
}

# sweep2_globs: every `"$audit_dir"/*.xxx` glob (the marker for-loop, the 2b
# ledger for-loop) plus every `-name '<glob>'` (the findings arm), inside the
# `# --- 2.` block. One per line.
sweep2_globs() {
  block=$(sed -n '/^# --- 2\. /,/^# --- 3\. /p' "$HOOK_ABS")
  grep -oE -- '"\$audit_dir"/\*\.[A-Za-z]+(\.[A-Za-z]+)?' <<< "$block" | sed -E 's#.*/##'
  grep -oE -- "-name '[^']+'" <<< "$block" | sed -E "s/-name '([^']+)'/\1/"
}

@test "UAT-011: every sweep-5 age-managed cache glob except renders.json is present in JANITOR_OUTLIER_ALLOW_CACHE" {
  cache_array=$(sed -n '/^JANITOR_OUTLIER_ALLOW_CACHE=(/,/^)/p' "$HOOK_ABS")
  [ -n "$cache_array" ]

  found_any=0
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    found_any=1
    [ "$glob" = "renders.json" ] && continue
    grep -qF -- "$glob" <<< "$cache_array" || return 1
  done < <(sweep5_globs)
  [ "$found_any" -eq 1 ]
}

@test "UAT-011b: every sweep-2 managed marker family plus *.findings.json is present in JANITOR_OUTLIER_ALLOW_AUDIT" {
  audit_array=$(sed -n '/^JANITOR_OUTLIER_ALLOW_AUDIT=(/,/^)/p' "$HOOK_ABS")
  [ -n "$audit_array" ]

  found_any=0
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    found_any=1
    grep -qF -- "$glob" <<< "$audit_array" || return 1
  done < <(sweep2_globs)
  [ "$found_any" -eq 1 ]
}

@test "UAT-011c: none of the three JANITOR_OUTLIER_ALLOW_* extractions is degenerate-empty" {
  [ -n "$(sed -n '/^JANITOR_OUTLIER_ALLOW_TOPLEVEL=(/,/^)/p' "$HOOK_ABS")" ]
  [ -n "$(sed -n '/^JANITOR_OUTLIER_ALLOW_AUDIT=(/,/^)/p' "$HOOK_ABS")" ]
  [ -n "$(sed -n '/^JANITOR_OUTLIER_ALLOW_CACHE=(/,/^)/p' "$HOOK_ABS")" ]
}

@test "UAT-011d: renders.json disjointness is proven behaviorally -- a cache/ dir holding it survives an isolation run despite an arbitrary name" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir/random-run-42"
  echo '{}' > "$cache_dir/random-run-42/renders.json"
  touch -t 202001010000 "$cache_dir/random-run-42/renders.json" "$cache_dir/random-run-42"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$cache_dir/random-run-42" ]
  [ -f "$cache_dir/random-run-42/renders.json" ]
}

# --- UAT-013: worktree safety -------------------------------------------------

@test "UAT-013: from a linked worktree, sweep 9 skips a symlinked audit/ root but still reaps the worktree's own real dirs" {
  make_repo
  MAIN="$REPO"
  mkdir -p "$MAIN/.gaia/local/audit" "$MAIN/.gaia/local/telemetry" \
    "$MAIN/.gaia/local/debt" "$MAIN/.gaia/local/cache/shared"

  WT="$MAIN/.claude/worktrees/wt1"
  mkdir -p "$MAIN/.claude/worktrees"
  git -C "$MAIN" worktree add -q -b wt1-branch "$WT"
  mkdir -p "$WT/.gaia/local/cache"
  ln -s "$MAIN/.gaia/local/audit" "$WT/.gaia/local/audit"
  ln -s "$MAIN/.gaia/local/telemetry" "$WT/.gaia/local/telemetry"
  ln -s "$MAIN/.gaia/local/debt" "$WT/.gaia/local/debt"
  ln -s "$MAIN/.gaia/local/cache/shared" "$WT/.gaia/local/cache/shared"

  # An aged off-allowlist file in MAIN's REAL audit/ dir.
  echo x > "$MAIN/.gaia/local/audit/stray-in-main.md"
  touch -t 202001010000 "$MAIN/.gaia/local/audit/stray-in-main.md"

  # Aged off-allowlist files in the WORKTREE's own real dirs (top level + cache).
  echo x > "$WT/.gaia/local/cruft.md"
  touch -t 202001010000 "$WT/.gaia/local/cruft.md"
  echo x > "$WT/.gaia/local/cache/stray.json"
  touch -t 202001010000 "$WT/.gaia/local/cache/stray.json"

  cd "$WT"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  # The symlinked scope root was skipped: main's file is untouched.
  [ -f "$MAIN/.gaia/local/audit/stray-in-main.md" ]

  # The worktree's own real dirs were still swept for real.
  [ -e "$WT/.gaia/local/cruft.md" ] && return 1
  [ ! -e "$WT/.gaia/local/cache/stray.json" ]
}

# --- Sweep-count structure (guards the Phase-2 wiki-conformance dependency) -

@test "the janitor source contains exactly nine numbered section dividers and the header says nine things" {
  run grep -cE '^# --- [0-9]+\. ' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$output" -eq 9 ]

  run grep -qF -- 'exactly nine things:' "$HOOK_ABS"
  [ "$status" -eq 0 ]
}
