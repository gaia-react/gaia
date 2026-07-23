#!/usr/bin/env bats
#
# Sweep #9 of local-janitor.sh: the registry-driven outlier sweep.
#
# Sweep 9 walks exactly three scope roots (top level of .gaia/local, its
# audit/, its cache/) at maxdepth-1/mindepth-1. For every child it asks the
# state registry (.gaia/state-registry.json, through gaia_registry_recognizes
# in .gaia/scripts/state-registry-lib.sh) whether the child is recognized -- a
# live entry or a named residue path. A recognized child is kept, silently.
# An unrecognized child is reported on stderr and left in place: report,
# never reap. OS junk is the one exception, reaped at any age regardless of
# the registry. The registry is the single answer to "may I reap this?",
# replacing the three hardcoded JANITOR_OUTLIER_ALLOW_* allowlists this sweep
# used to consult (now deleted from the source).
#
# GAIA_JANITOR_SWEEP_ONLY=outliers runs sweep 9 alone (skipping sweeps 2-8 and
# the one-time migration blocks), so every assertion below is attributable to
# sweep 9 itself, not a sibling sweep.
#
# Retired from the pre-registry suite, and why: UAT-001/002 (aged-vs-fresh
# off-allowlist reap) asserted the destructive default this conversion
# removes -- an unrecognized child is never reaped now, at any age, so there
# is no "aged" case left to distinguish. UAT-003/004/005/007 built elaborate
# per-zone allowlist enumerations whose only remaining true assertion
# (survival) no longer distinguishes "correctly recognized by the registry"
# from "nothing but OS junk is ever reaped any more" -- surviving is not
# proof of recognition once reaping unrecognized children is gone, so the
# distinguishing signal has to be the stderr report, which those tests never
# checked. UAT-010/010b exercised GAIA_OUTLIER_RETENTION_DAYS floor-clamping,
# a knob this sweep no longer reads (age never gates anything but OS junk).
# UAT-011/011b/011c were the disjoint-owner guard: they grepped sweep-9's own
# allowlist arrays to keep them in sync with sweep 2/5's age-managed globs --
# exactly the "test whose only job is keeping duplicates in sync" class this
# registry conversion exists to dissolve, since sweep 9 has no arrays left to
# drift. Replaced below by REG-001..007, which assert the new report-vs-keep
# behavior directly (including from stderr content, the only thing that still
# distinguishes "recognized" from "merely never reaped").
#
# Kept unchanged: UAT-006 (OS junk), UAT-008/009 family and CG-001 family
# (sweep 2/5's own owner arms, unrelated to sweep 9's array removal),
# UAT-010c/d/e/f (sweep 2/5's own knobs), UAT-011d (renamed REG-004, same
# renders.json behavior), UAT-013 (renamed REG-007, same worktree-safety
# fixture with its outcome flipped from reap to survive), and the
# sweep-count-structure test.
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

# write_registry <gaia_dir>: writes a minimal, schema-shaped
# .gaia/state-registry.json fixture into <gaia_dir> (e.g. "$REPO/.gaia").
# Not the real registry -- a fixture-local stand-in so gaia_registry_path
# (which resolves through the fixture repo's own git root) has a real file to
# read, covering exactly the families this suite exercises: a per-tree
# directory (red-ledger), a shared directory (cache/shared), a shared glob
# family (audit clearance markers), and a residue file (mentorship.json).
write_registry() {
  mkdir -p "$1"
  cat > "$1/state-registry.json" <<'JSON'
{
  "$schema": "./state-registry.schema.json",
  "version": 1,
  "description": "fixture registry for the outlier-sweep suite",
  "entries": [
    {
      "id": "red-ledger",
      "path": "red-ledger/",
      "match": "prefix",
      "kind": "dir",
      "scope": "per-tree",
      "keyed_by": null,
      "why": "fixture",
      "writer": "code",
      "reaped_by": null,
      "source": "fixture"
    },
    {
      "id": "audit-clearance-markers",
      "path": "audit/*.ok|audit/*.refused|audit/*.dispositions.json",
      "match": "glob",
      "kind": "file",
      "scope": "shared",
      "keyed_by": "content digest",
      "why": "fixture",
      "writer": "code",
      "reaped_by": "orphaned audit markers sweep",
      "source": "fixture"
    },
    {
      "id": "cache-shared",
      "path": "cache/shared/",
      "match": "prefix",
      "kind": "dir",
      "scope": "shared",
      "keyed_by": "singleton",
      "why": "fixture",
      "writer": "code",
      "reaped_by": null,
      "source": "fixture"
    }
  ],
  "residue": [
    {
      "id": "mentorship-config",
      "path": "mentorship.json",
      "match": "exact",
      "why": "fixture",
      "writer": "none-residue"
    }
  ]
}
JSON
}

# --- REG-001..007: the registry-driven report-not-delete model -------------

@test "REG-001: registry-recognized entries (a per-tree dir, a residue file, a shared glob family) are kept and never reported" {
  make_repo
  write_registry "$REPO/.gaia"
  local_dir="$REPO/.gaia/local"
  mkdir -p "$local_dir/audit" "$local_dir/red-ledger"
  echo x > "$local_dir/mentorship.json"
  echo '{}' > "$local_dir/audit/deadbeef.ok"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -d "$local_dir/red-ledger" ]
  [ -f "$local_dir/mentorship.json" ]
  [ -f "$local_dir/audit/deadbeef.ok" ]

  grep -qF -- "red-ledger" <<< "$output" && return 1
  grep -qF -- "mentorship.json" <<< "$output" && return 1
  grep -qF -- "deadbeef.ok" <<< "$output" && return 1
  return 0
}

@test "REG-002: an unrecognized top-level file, dotfile, and directory are left in place and reported on stderr" {
  make_repo
  write_registry "$REPO/.gaia"
  local_dir="$REPO/.gaia/local"

  echo x > "$local_dir/cruft.md"
  echo x > "$local_dir/.stray-config"
  mkdir -p "$local_dir/ca-research"
  echo x > "$local_dir/ca-research/inner.txt"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$local_dir/cruft.md" ]
  [ -f "$local_dir/.stray-config" ]
  [ -d "$local_dir/ca-research" ]
  [ -f "$local_dir/ca-research/inner.txt" ]

  grep -qF -- "$local_dir/cruft.md" <<< "$output" || return 1
  grep -qF -- "$local_dir/.stray-config" <<< "$output" || return 1
  grep -qF -- "$local_dir/ca-research" <<< "$output" || return 1
}

@test "REG-003: an unrecognized audit/ child is left in place and reported; the archived/security/comprehensive subtrees are never descended into" {
  make_repo
  write_registry "$REPO/.gaia"
  local_dir="$REPO/.gaia/local"
  audit_dir="$local_dir/audit"
  mkdir -p "$audit_dir/archived/run1" "$audit_dir/security" "$audit_dir/comprehensive/deep"
  echo x > "$audit_dir/archived/run1/junk.txt"
  echo x > "$audit_dir/security/junk.md"
  echo x > "$audit_dir/comprehensive/deep/junk.txt"
  echo x > "$audit_dir/stray-scratch.md"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$audit_dir/archived/run1/junk.txt" ]
  [ -f "$audit_dir/security/junk.md" ]
  [ -f "$audit_dir/comprehensive/deep/junk.txt" ]
  [ -f "$audit_dir/stray-scratch.md" ]

  grep -qF -- "$audit_dir/stray-scratch.md" <<< "$output"
}

@test "REG-004: an unrecognized cache/ child is left in place and reported; a renders.json-holding dir survives despite its arbitrary name" {
  make_repo
  write_registry "$REPO/.gaia"
  local_dir="$REPO/.gaia/local"
  cache_dir="$local_dir/cache"
  mkdir -p "$cache_dir/whatever-run-id"
  echo '{}' > "$cache_dir/whatever-run-id/renders.json"
  echo x > "$cache_dir/stray-scratch.json"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -d "$cache_dir/whatever-run-id" ]
  [ -f "$cache_dir/whatever-run-id/renders.json" ]
  [ -f "$cache_dir/stray-scratch.json" ]

  grep -qF -- "whatever-run-id" <<< "$output" && return 1
  grep -qF -- "$cache_dir/stray-scratch.json" <<< "$output" || return 1
}

@test "REG-005: the self-managing top-level zone directories are never recursed into, so nested content beneath them survives" {
  make_repo
  local_dir="$REPO/.gaia/local"
  for d in telemetry red-ledger handoff plans specs debt forensics harden worktree-locks; do
    mkdir -p "$local_dir/$d"
    echo x > "$local_dir/$d/junk.txt"
  done

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  for d in telemetry red-ledger handoff plans specs debt forensics harden worktree-locks; do
    [ -f "$local_dir/$d/junk.txt" ] || return 1
  done
}

@test "REG-006: jq unavailable degrades to fail-safe -- recognizes everything, reaps and reports nothing" {
  make_repo
  write_registry "$REPO/.gaia"
  local_dir="$REPO/.gaia/local"
  echo x > "$local_dir/totally-unknown-thing.md"

  nojq_bin="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$nojq_bin"
  ln -sf "$(command -v bash)" "$nojq_bin/bash"
  ln -sf "$(command -v git)" "$nojq_bin/git"
  ln -sf "$(command -v dirname)" "$nojq_bin/dirname"

  cd "$REPO"
  PATH="$nojq_bin" GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  [ -f "$local_dir/totally-unknown-thing.md" ]
  grep -qF -- "unrecognized" <<< "$output" && return 1
  return 0
}

@test "REG-007: from a linked worktree, sweep 9 skips a symlinked audit/ root and leaves the worktree's own off-pattern children in place" {
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

  # An off-pattern file in MAIN's REAL audit/ dir.
  echo x > "$MAIN/.gaia/local/audit/stray-in-main.md"

  # Off-pattern files in the WORKTREE's own real dirs (top level + cache).
  echo x > "$WT/.gaia/local/cruft.md"
  echo x > "$WT/.gaia/local/cache/stray.json"

  cd "$WT"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  # The symlinked scope root was skipped: main's file was never even
  # evaluated from the worktree's run.
  [ -f "$MAIN/.gaia/local/audit/stray-in-main.md" ]

  # The worktree's own real, off-pattern children are left in place too --
  # report, not reap, holds regardless of which checkout is sweeping.
  [ -f "$WT/.gaia/local/cruft.md" ]
  [ -f "$WT/.gaia/local/cache/stray.json" ]
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

# --- UAT-010c..f: floor-clamp / non-numeric fallback on sweep 2/5's knobs ---

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

# --- Sweep-count structure (guards the Phase-2 wiki-conformance dependency) -

@test "the janitor source contains exactly nine numbered section dividers and the header says nine things" {
  run grep -cE '^# --- [0-9]+\. ' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$output" -eq 9 ]

  run grep -qF -- 'exactly nine things:' "$HOOK_ABS"
  [ "$status" -eq 0 ]
}
