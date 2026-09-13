#!/usr/bin/env bash
# 18-residual-store-withheld.sh
#
# TST-018 (SPEC-081): the audit-residual dismissal store
# (.gaia/audit-residual-dismissals.jsonl) records this repository's own
# triage decisions -- assertions about this repository's code that are
# false about an adopter's. It is tracked (so a maintainer's decisions
# survive a fresh clone) but withheld from what GAIA ships, via a
# `.gaia/release-exclude` line, never via `.gitignore` (`.claude/rules/
# gaia-folder.md`: the manifest and the exclude line are the only
# legitimate withhold mechanism).
#
# TWO FACTS DECIDE THE MECHANISM (verified against the harness, plan/
# README.md section 5):
#
#   1. build-staging.sh stages only paths list-tracked-paths.sh reports, so
#      an UNTRACKED store file stages nothing whether or not the exclude
#      line is present -- a scenario that used an untracked fixture file
#      would red-prove nothing (CG-004).
#   2. build-staging.sh derives PROJECT_ROOT from its own dirname's git
#      toplevel, so it cannot be pointed at a copy of one file: it has to
#      run from inside a copy of the repository (DP-008).
#
# Phase 1b deliberately does not commit the store to this repository's own
# working tree, and this scenario may not write the working tree or the
# index (DP-017, COV-013; `.claude/rules/shell-cwd.md`'s sibling rule on
# leaving HEAD alone). One mechanism satisfies all three: a LOCAL CLONE
# (hardlinked, cheap, carries the branch's committed state -- including
# Phase 1b's exclude line and the committed CLI bundles with their exec
# bits, and no untracked tree). Every git write in this scenario targets
# the clone; nothing touches this checkout's working tree or index.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

STORE_REL=".gaia/audit-residual-dismissals.jsonl"
EXCLUDE_REL=".gaia/release-exclude"
FIXTURE_LINE='{"cited_line_text":"line one","class":"lint","date":"2026-09-01T00:00:00Z","disposition":"dismissed","line":1,"path":"app/example.ts","reason":"distribution scenario fixture","schema":"v1","source_pr":1}'

SCRATCH="$(mktemp -d -t gaia-dist-residual-store-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

# --- setup: a local clone, carrying the branch's committed state ----------

git clone --local --quiet "$PROJECT_ROOT" "$SCRATCH/repo" \
  || { fail "local clone of PROJECT_ROOT failed"; exit 1; }

printf '%s\n' "$FIXTURE_LINE" > "$SCRATCH/repo/$STORE_REL"
git -C "$SCRATCH/repo" add -f "$STORE_REL" \
  || { fail "git add -f on the fixture store record failed in the clone"; exit 1; }
git -C "$SCRATCH/repo" -c user.email="dist-scenario@example.invalid" \
  -c user.name="dist-scenario" commit --quiet -m "fixture: add a dismissal-store record" \
  || { fail "committing the fixture store record failed in the clone"; exit 1; }

# --- assertions on the real repository (no write) --------------------------

# git check-ignore exits 1 for a path .gitignore does not match; exits 0
# (with the matching pattern on stdout) for one it does. The store's
# withhold mechanism must be the release-exclude line, never .gitignore.
if git -C "$PROJECT_ROOT" check-ignore -q "$STORE_REL"; then
  fail "$STORE_REL is gitignored; the withhold mechanism must be .gaia/release-exclude, not .gitignore"
  exit 1
fi
pass "$STORE_REL is not gitignored (the real repository)"

# --- assertions on the clone -------------------------------------------

if ! git -C "$SCRATCH/repo" ls-files --error-unmatch "$STORE_REL" >/dev/null 2>&1; then
  fail "the fixture store record is not tracked in the clone after the commit"
  exit 1
fi
log "the fixture store record is tracked in the clone"

if grep -qF "\"$STORE_REL\"" "$SCRATCH/repo/.gaia/manifest.json"; then
  fail "$STORE_REL appears in .gaia/manifest.json; the store must never be manifest-registered"
  exit 1
fi
log "$STORE_REL is absent from .gaia/manifest.json"

# --- build staging (exclude line present) and assert absence --------------

OUT_PRESENT="$SCRATCH/staging-present"
mkdir -p "$OUT_PRESENT"
"$SCRATCH/repo/.gaia/tests/distribution/lib/build-staging.sh" "$OUT_PRESENT" \
  || { fail "build-staging failed with the release-exclude line present"; exit 1; }

if [ -e "$OUT_PRESENT/$STORE_REL" ]; then
  fail "$STORE_REL leaked into the staged tree with the release-exclude line present"
  exit 1
fi
pass "$STORE_REL is tracked, unmanifested, and withheld from the staged tree"

# --- guards-must-fail: prove the scenario can red -------------------------
#
# Remove the exclude line IN THE CLONE, commit that removal, rebuild
# staging from the mutated clone, and confirm the store now leaks. Because
# the store is tracked in the clone (not merely present on disk), removing
# the exclude line genuinely stages it -- this is a real red, not a
# vacuous one over an untracked file build-staging.sh would have skipped
# regardless.
grep -qxF "$STORE_REL" "$SCRATCH/repo/$EXCLUDE_REL" \
  || { fail "$STORE_REL is not present as its own line in $EXCLUDE_REL; nothing to remove for the red-proof"; exit 1; }

grep -vxF "$STORE_REL" "$SCRATCH/repo/$EXCLUDE_REL" > "$SCRATCH/exclude-without-store"
mv "$SCRATCH/exclude-without-store" "$SCRATCH/repo/$EXCLUDE_REL"
git -C "$SCRATCH/repo" add "$EXCLUDE_REL"
git -C "$SCRATCH/repo" -c user.email="dist-scenario@example.invalid" \
  -c user.name="dist-scenario" commit --quiet -m "fixture: remove the residual-store exclude line" \
  || { fail "committing the exclude-line removal failed in the clone"; exit 1; }

OUT_MUTATED="$SCRATCH/staging-mutated"
mkdir -p "$OUT_MUTATED"
"$SCRATCH/repo/.gaia/tests/distribution/lib/build-staging.sh" "$OUT_MUTATED" \
  || { fail "build-staging failed after removing the exclude line (expected to succeed and leak the store)"; exit 1; }

if [ ! -e "$OUT_MUTATED/$STORE_REL" ]; then
  fail "guard-must-fail proof did not red: $STORE_REL is STILL absent from staging after removing its release-exclude line"
  exit 1
fi
log "guard-must-fail proof observed: removing the release-exclude line in the clone stages $STORE_REL (named above)"

pass "the residual-store withhold assertion is real: it reds when the release-exclude line is removed in the clone, and greens with it present"
