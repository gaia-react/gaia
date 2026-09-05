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
  GAIA_DIR_REAL=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
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

# copy_shipped_registry <gaia_dir>: the repo's OWN .gaia/state-registry.json,
# copied into <gaia_dir> instead of the fixture stand-in above. Used by the
# one test whose subject is the shipped self-managing zones themselves: the
# stand-in deliberately models four families and nothing else, so seven of
# those eight zones read as unrecognized under it and an assertion about them
# would be asserting the stand-in's gaps rather than the sweep's behavior.
copy_shipped_registry() {
  mkdir -p "$1"
  cp "$GAIA_DIR_REAL/state-registry.json" "$1/state-registry.json"
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
  copy_shipped_registry "$REPO/.gaia"
  local_dir="$REPO/.gaia/local"
  for d in telemetry red-ledger handoff plans specs debt forensics harden; do
    mkdir -p "$local_dir/$d"
    echo x > "$local_dir/$d/junk.txt"
  done

  # The control, and the reason it is here: survival alone is satisfied by a
  # sweep that never ran, and silence alone is satisfied by a sweep whose
  # registry probe failed (an unusable registry skips every child before it is
  # ever classified). An unrecognized top-level file the sweep MUST report
  # separates a run that walked the zone roots and consulted the registry from
  # one that did neither.
  echo x > "$local_dir/off-pattern-control.md"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  grep -qF -- "$local_dir/off-pattern-control.md" <<< "$output" || return 1

  for d in telemetry red-ledger handoff plans specs debt forensics harden; do
    [ -f "$local_dir/$d/junk.txt" ] || return 1
    # One prefix match covers both halves of the claim: the zone directory
    # itself is registry-recognized, so it is kept silently, and nothing
    # BENEATH it is reported either, because the walk stops at the top-level
    # child. A report about either would carry this path as a prefix.
    grep -qF -- "$local_dir/$d" <<< "$output" && return 1
  done
  return 0
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

@test "REG-007: from a linked worktree, sweep 9 skips the symlinked .gaia/local root itself but still walks a real audit/ one hop beneath it" {
  make_repo
  write_registry "$REPO/.gaia"
  MAIN="$REPO"
  mkdir -p "$MAIN/.gaia/local/audit"

  WT="$MAIN/.claude/worktrees/wt1"
  mkdir -p "$MAIN/.claude/worktrees"
  git -C "$MAIN" worktree add -q -b wt1-branch "$WT"
  # The cutover shape: .gaia/local is ONE symlink to main's, not a real
  # directory holding individually-symlinked entries (today's pre-cutover
  # shape, which this suite no longer models -- see REG-005's sibling top-
  # level dirs for that era's fixture, kept only where it still applies).
  # There is no separate worktree-local .gaia/local left to construct a
  # "worktree's own real off-pattern child" in: a write through the
  # worktree's own path physically lands in MAIN's real .gaia/local, as
  # cruft.md below demonstrates.
  mkdir -p "$WT/.gaia"
  ln -s "$MAIN/.gaia/local" "$WT/.gaia/local"

  # An off-pattern file in MAIN's real audit/ dir, one hop beneath the single
  # top-level symlink -- once that hop is resolved, audit/ is itself a real
  # directory, not a symlink, so it is not skipped.
  echo x > "$MAIN/.gaia/local/audit/stray-in-main.md"

  # Written through the WORKTREE's own path; physically MAIN's file (see
  # above).
  echo x > "$WT/.gaia/local/cruft.md"

  cd "$WT"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  # The top-level scope root IS the symlink itself now, so it is skipped
  # entirely and never reported on, even though the file behind it is real
  # and physically present (never reaped either -- sweep 9 never deletes a
  # non-junk child, skipped or not).
  [ -f "$MAIN/.gaia/local/cruft.md" ]
  grep -qF -- "cruft.md" <<< "$output" && return 1

  # audit/'s unrecognized child is still reported from this SAME
  # worktree-invoked run, proving only the top-level symlink itself is
  # special, not every path that happens to resolve through it.
  [ -f "$MAIN/.gaia/local/audit/stray-in-main.md" ]
  grep -qF -- "$WT/.gaia/local/audit/stray-in-main.md" <<< "$output" || return 1
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

@test "UAT-008c: the sweep 2 findings arm reaps an aged audit/*.scope.json and keeps a fresh one" {
  # The scope-resolution carry (.gaia/scripts/audit-scope-digest.sh) shares
  # the findings-arm's knob and its `find` clause: same lifetime, per round
  # per member, keyed by the audit key.
  make_repo
  audit_dir="$REPO/.gaia/local/audit"
  mkdir -p "$audit_dir"
  echo '{"schema":1,"member":"code-audit-frontend","scope_digest":"deadbeef"}' > "$audit_dir/deadbeef.code-audit-frontend.scope.json"
  touch -t 202001010000 "$audit_dir/deadbeef.code-audit-frontend.scope.json"
  echo '{"schema":1,"member":"code-audit-frontend","scope_digest":"beefdead"}' > "$audit_dir/beefdead.code-audit-frontend.scope.json"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$audit_dir/deadbeef.code-audit-frontend.scope.json" ] && return 1
  [ -f "$audit_dir/beefdead.code-audit-frontend.scope.json" ]
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

@test "UAT-009: the sweep 5 gh-artifact arm reaps an aged cache/gh-artifact-pr.<branch-slug>.json" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  # A percent-encoded slug (branch "feat/x"), not a bare word: the reap glob
  # has to keep matching once gaia_key_slug has encoded a "/" into the name.
  echo '{"branch":"feat/x"}' > "$cache_dir/gh-artifact-pr.feat%2Fx.json"
  touch -t 202001010000 "$cache_dir/gh-artifact-pr.feat%2Fx.json"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$cache_dir/gh-artifact-pr.feat%2Fx.json" ]
}

@test "UAT-009b: the sweep 5 gh-artifact arm keeps a fresh cache/gh-artifact-pr.<branch-slug>.json" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{"branch":"treeA"}' > "$cache_dir/gh-artifact-pr.treeA.json"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$cache_dir/gh-artifact-pr.treeA.json" ]
}

@test "UAT-009c: an isolation sweep-9-only run never reaps cache/gh-artifact-pr.<branch-slug>.json (the owner arm, not sweep 9, is the reaper)" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{"branch":"treeA"}' > "$cache_dir/gh-artifact-pr.treeA.json"
  touch -t 202001010000 "$cache_dir/gh-artifact-pr.treeA.json"

  cd "$REPO"
  GAIA_JANITOR_SWEEP_ONLY=outliers run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$cache_dir/gh-artifact-pr.treeA.json" ]
}

@test "UAT-009d: the sweep 5 gh-artifact arm's widened glob reaps BOTH a per-branch keyed name and the pre-4.2 unkeyed name when aged" {
  make_repo
  cache_dir="$REPO/.gaia/local/cache"
  mkdir -p "$cache_dir"
  echo '{"branch":"x"}' > "$cache_dir/gh-artifact-pr.json"
  touch -t 202001010000 "$cache_dir/gh-artifact-pr.json"
  echo '{"branch":"treeA"}' > "$cache_dir/gh-artifact-pr.treeA.json"
  touch -t 202001010000 "$cache_dir/gh-artifact-pr.treeA.json"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$cache_dir/gh-artifact-pr.json" ]
  [ ! -e "$cache_dir/gh-artifact-pr.treeA.json" ]
}

# --- MAIN-CACHE: the two main-only cache globs, swept at MAIN's cache when --
# --- invoked from a linked worktree, never the invoking tree's own -----------
# gh-artifact-pr-cache and spec-chain-guard are both registry main-only
# (.gaia/state-registry.json): their real writers (gh-artifact-lib.sh,
# block-spec-plan-chain.sh) always resolve main's root before writing, so a
# worktree-invoked sweep has to target main's cache too. Before this fix, the
# sweep read $cache_dir off the INVOKING tree's own root, so a worktree-run
# janitor cleaned an empty worktree-local cache and never main's real one --
# live today, independent of the .gaia/local symlink cutover.

@test "MAIN-CACHE-01: the sweep 5 gh-artifact arm reaps an aged cache/gh-artifact-pr.*.json at MAIN's cache when invoked from a linked worktree" {
  make_repo
  MAIN="$REPO"
  mkdir -p "$MAIN/.gaia/local/cache"
  echo '{"branch":"treeA"}' > "$MAIN/.gaia/local/cache/gh-artifact-pr.treeA.json"
  touch -t 202001010000 "$MAIN/.gaia/local/cache/gh-artifact-pr.treeA.json"

  WT="$MAIN/.claude/worktrees/wt-cache1"
  mkdir -p "$MAIN/.claude/worktrees"
  git -C "$MAIN" worktree add -q -b wt-cache1-branch "$WT"
  mkdir -p "$WT/.gaia/local/cache"

  cd "$WT"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$MAIN/.gaia/local/cache/gh-artifact-pr.treeA.json" ]
}

@test "MAIN-CACHE-02: the sweep 5 spec-chain arm reaps an aged cache/spec-chain-*.json at MAIN's cache when invoked from a linked worktree" {
  make_repo
  MAIN="$REPO"
  mkdir -p "$MAIN/.gaia/local/cache"
  echo '{}' > "$MAIN/.gaia/local/cache/spec-chain-sess123.json"
  touch -t 202001010000 "$MAIN/.gaia/local/cache/spec-chain-sess123.json"

  WT="$MAIN/.claude/worktrees/wt-cache2"
  mkdir -p "$MAIN/.claude/worktrees"
  git -C "$MAIN" worktree add -q -b wt-cache2-branch "$WT"
  mkdir -p "$WT/.gaia/local/cache"

  cd "$WT"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$MAIN/.gaia/local/cache/spec-chain-sess123.json" ]
}

@test "MAIN-CACHE-03: the sweep 5 audit-round-cap arm reaps an aged cache/audit-rounds-*.json at MAIN's cache when invoked from a linked worktree, and keeps a fresh one" {
  make_repo
  MAIN="$REPO"
  mkdir -p "$MAIN/.gaia/local/cache"
  echo '{}' > "$MAIN/.gaia/local/cache/audit-rounds-sess-aged.json"
  touch -t 202001010000 "$MAIN/.gaia/local/cache/audit-rounds-sess-aged.json"
  echo '{}' > "$MAIN/.gaia/local/cache/audit-rounds-sess-fresh.json"

  WT="$MAIN/.claude/worktrees/wt-cache3"
  mkdir -p "$MAIN/.claude/worktrees"
  git -C "$MAIN" worktree add -q -b wt-cache3-branch "$WT"
  mkdir -p "$WT/.gaia/local/cache"

  cd "$WT"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$MAIN/.gaia/local/cache/audit-rounds-sess-aged.json" ]
  [ -f "$MAIN/.gaia/local/cache/audit-rounds-sess-fresh.json" ]
}

@test "MAIN-CACHE-04: the sweep 5 audit-round-cap arm reaps an aged atomic-write leftover, which the registry recognizes so sweep 9 never reports it" {
  make_repo
  MAIN="$REPO"
  mkdir -p "$MAIN/.gaia/local/cache"
  echo '{}' > "$MAIN/.gaia/local/cache/audit-rounds-sess-aged.json.AbC123"
  touch -t 202001010000 "$MAIN/.gaia/local/cache/audit-rounds-sess-aged.json.AbC123"
  echo '{}' > "$MAIN/.gaia/local/cache/audit-rounds-sess-fresh.json.XyZ789"

  WT="$MAIN/.claude/worktrees/wt-cache4"
  mkdir -p "$MAIN/.claude/worktrees"
  git -C "$MAIN" worktree add -q -b wt-cache4-branch "$WT"
  mkdir -p "$WT/.gaia/local/cache"

  cd "$WT"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$MAIN/.gaia/local/cache/audit-rounds-sess-aged.json.AbC123" ]
  [ -f "$MAIN/.gaia/local/cache/audit-rounds-sess-fresh.json.XyZ789" ]
  # Recognized by the registry, so the off-pattern outlier sweep stays silent
  # about it. A leftover that is reported but never reaped, or reaped but
  # reported meanwhile, are both the drift this pair exists to pin.
  printf '%s\n' "$output" | grep -qF 'audit-rounds-sess-fresh.json.XyZ789' && {
    echo "sweep 9 reported a registry-recognized atomic-write leftover" >&2
    return 1
  }
  # Explicit, because the absence check above is this test's last statement:
  # with the needle absent, grep's own non-zero status would otherwise become
  # the test's result and fail it in exactly the case it exists to pass.
  true
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
  echo '{}' > "$cache_dir/gh-artifact-pr.treeA.json"
  touch -t "$(past_ts $((3 * 86400)))" "$cache_dir/gh-artifact-pr.treeA.json"   # 3d old > 2d default

  cd "$REPO"
  GAIA_CACHE_ARTIFACT_RETENTION_DAYS=abc run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$cache_dir/gh-artifact-pr.treeA.json" ]
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
  echo '{}' > "$cache_dir/gh-artifact-pr.treeA.json"
  touch -t "$(past_ts $((30 * 3600)))" "$cache_dir/gh-artifact-pr.treeA.json"   # ~30h old

  cd "$REPO"
  GAIA_CACHE_ARTIFACT_RETENTION_DAYS=0 run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$cache_dir/gh-artifact-pr.treeA.json" ]
}

# --- Sweep-count structure (guards the Phase-2 wiki-conformance dependency) -

@test "the janitor source contains exactly nine numbered section dividers and the header says nine things" {
  run grep -cE '^# --- [0-9]+\. ' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$output" -eq 9 ]

  run grep -qF -- 'exactly nine things:' "$HOOK_ABS"
  [ "$status" -eq 0 ]
}
