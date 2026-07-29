#!/usr/bin/env bats
# UAT-015: a feature composes with SPEC-028's read-side .env guard without
# weakening it. Both tests assert the guard's content: the deny entries the
# settings file carries, and the hook that backs them.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  SETTINGS="$REPO_ROOT/.claude/settings.json"
}

@test "UAT-015: settings.json deny array carries every SPEC-028 entry and no no-op Write rule" {
  [ -f "$SETTINGS" ]
  grep -qF '"Read(.env)"' "$SETTINGS"
  # Edit(.env) is the entire write-side entry, and no Write(.env) belongs beside
  # it. Claude Code's file permission checks match only Read(path) and
  # Edit(path) rules; Edit covers every file-editing tool (Write, Edit,
  # MultiEdit, NotebookEdit), while a Write(path) rule is accepted and then
  # never matched. The harness warns at startup for each unmatched rule, so
  # adding one buys no enforcement and costs every session a warning.
  # .gaia/tests/hooks/block-env-read.bats pins this from the hook side.
  grep -qF '"Edit(.env)"' "$SETTINGS"
  # Pin the absence rather than only describing it, so re-adding the entry reds
  # this suite instead of relying on a reader honoring the comment above. The
  # bad case is written as a positive match ending in an explicit return, per
  # .claude/rules/bats-assertions.md: a `!`-negated grep would never fail here,
  # because set -e exempts an inverted status and this is not the final line.
  grep -qF '"Write(.env)"' "$SETTINGS" && return 1
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
