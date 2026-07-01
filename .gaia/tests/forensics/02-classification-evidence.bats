#!/usr/bin/env bats
# UAT-009: classification decision + evidence cite shape
# UAT-011: other class evidence cite
#
# DETECTOR/SURROGATE TEST (not the shipped skill): exercises an inline surrogate
# of the runbook branch and, where used, the `lib/*.sh` mirrors, never the shipped
# skill body. Real end-to-end guard: integration.md "Local skill end-to-end" diff.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIB="$HERE/lib"

setup() {
  # Source the classifier library (defines classify_description, classify_evidence)
  # shellcheck source=lib/classify.sh
  source "$LIB/classify.sh"
}

# ---------------------------------------------------------------------------
# Classification table; each class matches its signal phrases
# ---------------------------------------------------------------------------

@test "UAT-009: 'init' signal phrase classifies as init" {
  local class
  class="$(classify_description "the init step failed")"
  [[ "$class" == "init" ]]
}

@test "UAT-009: 'scaffold failed' signal phrase classifies as init" {
  local class
  class="$(classify_description "scaffold failed during setup")"
  [[ "$class" == "init" ]]
}

@test "UAT-009: 'update' signal phrase classifies as update" {
  local class
  class="$(classify_description "update conflict in hooks")"
  [[ "$class" == "update" ]]
}

@test "UAT-009: 'merge conflict' signal phrase classifies as update" {
  local class
  class="$(classify_description "there was a merge conflict")"
  [[ "$class" == "update" ]]
}

@test "UAT-009: 'wiki-sync' signal phrase classifies as wiki-sync" {
  local class
  class="$(classify_description "wiki-sync failed to push")"
  [[ "$class" == "wiki-sync" ]]
}

@test "UAT-009: 'sync' signal phrase classifies as wiki-sync" {
  local class
  class="$(classify_description "the sync operation timed out")"
  [[ "$class" == "wiki-sync" ]]
}

@test "UAT-009: 'quality gate' signal phrase classifies as quality-gate" {
  local class
  class="$(classify_description "quality gate failed")"
  [[ "$class" == "quality-gate" ]]
}

@test "UAT-009: 'typecheck' signal phrase classifies as quality-gate" {
  local class
  class="$(classify_description "typecheck errors appeared")"
  [[ "$class" == "quality-gate" ]]
}

@test "UAT-009: 'hook' signal phrase classifies as hook" {
  local class
  class="$(classify_description "the hook misfired")"
  [[ "$class" == "hook" ]]
}

@test "UAT-009: 'PreToolUse' signal phrase classifies as hook" {
  local class
  class="$(classify_description "PreToolUse rejected the call")"
  [[ "$class" == "hook" ]]
}

@test "UAT-009: 'new-component' signal phrase classifies as scaffold" {
  local class
  class="$(classify_description "new-component skill failed")"
  [[ "$class" == "scaffold" ]]
}

@test "UAT-009: 'vite' signal phrase classifies as dev-server" {
  local class
  class="$(classify_description "vite crashed on startup")"
  [[ "$class" == "dev-server" ]]
}

@test "UAT-009: '5173' signal phrase classifies as dev-server" {
  local class
  class="$(classify_description "port 5173 already in use")"
  [[ "$class" == "dev-server" ]]
}

# ---------------------------------------------------------------------------
# Multi-match: first in declared order wins
# ---------------------------------------------------------------------------

@test "UAT-009: multi-match picks first in declared order (init before update)" {
  local class
  class="$(classify_description "init and update both mentioned")"
  [[ "$class" == "init" ]]
}

# ---------------------------------------------------------------------------
# Zero-match: class is other
# ---------------------------------------------------------------------------

@test "UAT-011: no matching signal phrase falls to 'other'" {
  local class
  class="$(classify_description "something went wrong that I cannot describe")"
  [[ "$class" == "other" ]]
}

# ---------------------------------------------------------------------------
# Evidence cite shape
# ---------------------------------------------------------------------------

@test "UAT-009: evidence cite for init contains signal phrase" {
  local evidence
  evidence="$(classify_evidence "init" "the init step failed")"
  [[ "$evidence" == *"init"* ]]
}

@test "UAT-011: evidence cite for other is 'no taxonomy class matched'" {
  local evidence
  evidence="$(classify_evidence "other" "something inexplicable happened")"
  [[ "$evidence" == "no taxonomy class matched" ]]
}

@test "UAT-009: evidence cite for update contains signal phrase" {
  local evidence
  evidence="$(classify_evidence "update" "merge conflict in hooks")"
  [[ "$evidence" == *"merge conflict"* ]]
}
