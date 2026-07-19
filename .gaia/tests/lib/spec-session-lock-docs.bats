#!/usr/bin/env bats
# Doc-grep suite for the session-lock lifecycle documented in
# `.claude/skills/gaia/references/spec.md` (the "Session-lock" operational
# primitive, the step-2 liveness branch, and the four release sites). Pins the
# exact prose so a future edit cannot silently drop a clause: the lock-file
# literal, the reframe copy, the acquire/release-points phrases, the
# not-mtime rule, the fail-open guarantee, the per-exit release anchors, the
# auto-mode wiring, the error-routing clause, and the two guarded-override
# labels plus their warning string.
#
# DOC-002: test 1 is written so a `spec-session-<spec_id>.json`-only match
# cannot satisfy it; it asserts the `.lock` literal specifically.
#
# RT-005 / UAT-001 note: the live-lock prompt's rendered `AskUserQuestion`
# *payload* is not machine-checkable here. These greps pin the prompt copy and
# the option labels/warning text (COV-102); whether an override is actually
# honored end-to-end is a manual/integration check, not a bats assertion, and
# is carried forward as a follow-up rather than asserted below.
#
# Assertion style (`.claude/rules/bats-assertions.md`): non-final substring
# checks use `grep -qF ... && return 1` (bad case) or `grep -qF ... || return 1`
# (good case), never a bare non-final `[[ ]]` or a `!`-negated non-final line.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
}

@test "doc-grep: SPEC_MD exists" {
  [ -f "$SPEC_MD" ]
}

# --- 1. Full lock-file literal (DOC-002: must not be satisfied by .json) ----

@test "doc-grep: the full lock-file literal spec-session-<spec_id>.lock is present" {
  grep -qF -- 'spec-session-<spec_id>.lock' "$SPEC_MD"
}

@test "doc-grep: DOC-002 -- the .lock literal is not merely the pre-existing .json cache reference" {
  # A file that mentions ONLY the .json cache (no .lock literal anywhere) must
  # fail this suite; assert the .lock-specific literal independently of the
  # .json one so a regression that drops .lock but keeps .json is caught.
  grep -qF -- 'spec-session-<spec_id>.json' "$SPEC_MD" || return 1
  grep -qF -- 'spec-session-<spec_id>.lock' "$SPEC_MD" || return 1
  grep -qF -- 'spec-session-${SPEC_ID}.lock' "$SPEC_MD"
}

# --- 2. "open in another session" reframe string ----------------------------

@test "doc-grep: the 'open in another session' reframe string is present" {
  grep -qF -- 'open in another session' "$SPEC_MD"
}

# --- 3. Acquire-points phrase (fresh allocation + resume) -------------------

@test "doc-grep: the acquire-points phrase names fresh allocation and resume of a dormant draft" {
  grep -qF -- 'Fresh allocation (step 3) and resume of a dormant draft (step 2 Resume branch)' "$SPEC_MD"
}

# --- 4. Release-points phrase (DOC-004 two-category distinction) -----------

@test "doc-grep: the release-points phrase names the holder's own graceful exits and the third-party dormant-or-ghost cleanup" {
  grep -qF -- 'holder drops its own lock' "$SPEC_MD" || return 1
  grep -qF -- 'dormant-or-ghost lock it does not own' "$SPEC_MD"
}

# --- 5. Not-mtime / live-process-check rule ---------------------------------

@test "doc-grep: the not-mtime / live-process-check rule phrase is present" {
  grep -qF -- 'live-process check, never by file mtime' "$SPEC_MD"
}

# --- 6. Fail-open / dormant phrase -------------------------------------------

@test "doc-grep: the fail-open guarantee is stated, distinct from a bare dormant verdict" {
  grep -qF -- 'Fail-open guarantee' "$SPEC_MD" || return 1
  grep -qF -- 'still reads dormant' "$SPEC_MD"
}

# --- 7. Per-exit release anchors (TST-004 / COV-101): one @test per site ---

@test "doc-grep: release site (a) canonical save is independently anchored" {
  grep -qF -- 'Release the session lock (canonical save)' "$SPEC_MD"
}

@test "doc-grep: release site (b) the general abandoned-exit primitive is independently anchored" {
  grep -qF -- 'Release the session lock (abandoned exit)' "$SPEC_MD"
}

@test "doc-grep: release site (c) the save-partial escape is independently anchored" {
  grep -qF -- 'Release the session lock (save-partial escape)' "$SPEC_MD"
}

@test "doc-grep: release site (d) the step-2 discard handler is independently anchored" {
  grep -qF -- 'Release the session lock (step-2 discard)' "$SPEC_MD"
}

# --- 8. Auto-mode wiring (TST-009) ------------------------------------------

@test "doc-grep: the acquire-at-allocation prose states it runs in both interactive and auto mode" {
  grep -qF -- 'Both interactive and auto mode acquire at fresh allocation' "$SPEC_MD"
}

# --- 9. Error-routing without surfacing raw error text (TST-007) -----------

@test "doc-grep: the step-2 prose routes a lock error to Start-new-recommended without surfacing raw error text" {
  grep -qF -- 'without surfacing the raw lock-subsystem error text' "$SPEC_MD"
}

# --- 10. Guarded live-lock override labels + warning (COV-102) -------------

@test "doc-grep: the two guarded override labels and their clobber-or-delete warning are pinned" {
  grep -qF -- 'Override: resume SPEC-NNN anyway' "$SPEC_MD" || return 1
  grep -qF -- 'Override: discard SPEC-NNN anyway' "$SPEC_MD" || return 1
  grep -qF -- 'draft is being authored in another session; proceeding may clobber or delete live work' "$SPEC_MD"
}
