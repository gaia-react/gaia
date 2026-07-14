#!/usr/bin/env bats
# UAT-015: a feature composes with SPEC-028's read-side .env guard without
# weakening it. Both tests assert the guard's content: the deny entries the
# settings file carries, and the hook that backs them.

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

@test "UAT-015: the read-side .env guard hook is present and still registered" {
  # The composition invariant is that the guard still stands, not that
  # .claude/settings.json is never edited. Every hook a feature adds or retires
  # edits that file, so an assert-no-diff-against-main guard fails any such
  # feature while catching nothing a content assertion misses. Assert the guard
  # itself: the hook exists, both of its registrations survive, and the two
  # behaviors SPEC-028 added to it are intact.
  local hook="$REPO_ROOT/.claude/hooks/block-env-read.sh"

  [ -f "$hook" ]
  [ -x "$hook" ]

  # Registered on both tool surfaces it guards (Read and Bash).
  [ "$(grep -cF '.claude/hooks/block-env-read.sh' "$SETTINGS")" -eq 2 ]

  # The variant family (.env.local, .env.production, ...) is the gap SPEC-028
  # closed; Read(.env) alone never matched it.
  grep -qF 'is_dotenv_path' "$hook"

  # The committed placeholder stays readable, or the guard is a footgun.
  grep -qF '.env.example' "$hook"

  # It denies rather than warns.
  grep -qF 'permissionDecision' "$hook"
}
