#!/usr/bin/env bats
# UAT-015: this feature composes with SPEC-028's read-side .env guard without
# modifying it. Byte-present deny entries + an untouched-files diff guard.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  SETTINGS="$REPO_ROOT/.claude/settings.json"
}

@test "UAT-015: settings.json deny array still contains all SPEC-028 read-side entries" {
  [ -f "$SETTINGS" ]
  grep -qF '"Read(.env)"' "$SETTINGS"
  grep -qF '"Edit(.env)"' "$SETTINGS"
  grep -qF '"Write(.env)"' "$SETTINGS"
  grep -qF '"Read(**/*.key)"' "$SETTINGS"
  grep -qF '"Read(**/*.pem)"' "$SETTINGS"
  grep -qF '"Read(**/*credential*)"' "$SETTINGS"
  grep -qF '"Read(**/secrets/*)"' "$SETTINGS"
}

@test "UAT-015: this feature's diff vs main touched neither block-env-read.sh nor settings.json" {
  cd "$REPO_ROOT"
  local base changed
  base=$(git merge-base HEAD main)
  changed=$(git diff --name-only "$base" HEAD)

  printf '%s\n' "$changed" | grep -qF '.claude/hooks/block-env-read.sh' && return 1
  printf '%s\n' "$changed" | grep -qF '.claude/settings.json' && return 1
  return 0
}
