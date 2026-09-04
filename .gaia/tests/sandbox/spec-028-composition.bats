#!/usr/bin/env bats
# UAT-015: a feature composes with the read-side .env guard without weakening
# it. Both tests assert the guard's content: what the settings file carries, and
# the hooks that back it.
#
# The guard's MECHANISM changed and the invariant did not. Read-side denial no
# longer lives in permissions.deny at all: any Read() rule there arms Claude
# Code's bypass-immune approval breaker, which forces a manual prompt on every
# search and copy command whose target it cannot statically prove safe. The
# obligation moved to two hooks for the tool tier and to
# sandbox.filesystem.denyRead for the subprocess tier that a Read() rule used to
# reach by merging into the sandbox boundary. So the assertions below pin the
# ABSENCE of every Read() rule where they once pinned five present ones, and a
# re-addition reds here.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  SETTINGS="$REPO_ROOT/.claude/settings.json"
}

@test "UAT-015: settings.json keeps the write-side rule, no Read() rule, and no no-op Write rule" {
  [ -f "$SETTINGS" ]
  # Edit(.env) is the entire write-side entry, and no Write(.env) belongs beside
  # it. Claude Code's file permission checks match only Read(path) and
  # Edit(path) rules; Edit covers every file-editing tool (Write, Edit,
  # MultiEdit, NotebookEdit), while a Write(path) rule is accepted and then
  # never matched. The harness warns at startup for each unmatched rule, so
  # adding one buys no enforcement and costs every session a warning.
  grep -qF '"Edit(.env)"' "$SETTINGS"
  # Pin the absence rather than only describing it, so re-adding the rule reds
  # this suite instead of relying on a reader honoring the comment above. Match
  # the rule FORM rather than one literal, because Write(**/.env), Write(.env*)
  # and every other spelling is the same no-op. A bare "Write" rule carries no
  # path, matches the tool everywhere, and warns about nothing, so the open
  # paren is what separates the broken form from the legal one. Written as a
  # positive match ending in an explicit return, per
  # .claude/rules/bats-assertions.md: a `!`-negated grep would never fail here,
  # because set -e exempts an inverted status and this is not the final line.
  grep -qF '"Write(' "$SETTINGS" && return 1

  # No Read() rule of ANY spelling. The form is what matters rather than the
  # five literals this replaced: one rule of any shape arms the breaker, so
  # pinning the five by name would let a sixth spelling back in silently.
  run jq -e '[.permissions.deny[] | select(startswith("Read("))] | length == 0' "$SETTINGS"
  [ "$status" -eq 0 ]

  # The subprocess tier a Read() rule used to reach by merging into the sandbox
  # boundary. Declared directly, so removing the rules did not narrow it.
  #
  # Each dotenv class is pinned twice, once root-anchored and once depth-
  # qualified. A sandbox filesystem path carrying no prefix resolves against the
  # project root, so the bare spellings reach the root dotenv only, while the
  # secret classes beside them are `**`-prefixed and match at any depth. Both
  # hooks decide on the basename and so cover every depth; without the `**`
  # pair the two tiers would disagree about a monorepo dotenv such as
  # `apps/web/.env.local`, which no test would have reported.
  run jq -e '
    .sandbox.filesystem.denyRead as $d
    | ($d | index(".env")) != null
      and ($d | index(".env.*")) != null
      and ($d | index("**/.env")) != null
      and ($d | index("**/.env.*")) != null
      and ($d | index("**/*.key")) != null
      and ($d | index("**/*.pem")) != null
      and ($d | index("**/*credential*")) != null
      and ($d | index("**/secrets/**")) != null
  ' "$SETTINGS"
  [ "$status" -eq 0 ]

  # The committed placeholder stays readable inside that deny, or the boundary
  # is a footgun in the same way the hook would be without its exemption. The
  # exemption is depth-qualified alongside the deny that made it necessary, or a
  # nested `.env.example` is denied where the root one is allowed.
  run jq -e '
    .sandbox.filesystem.allowRead as $a
    | ($a | index(".env.example")) != null
      and ($a | index("**/.env.example")) != null
  ' "$SETTINGS"
  [ "$status" -eq 0 ]

  # A boundary is not an enable. sandbox.enabled belongs only in the gitignored
  # per-machine settings, which manifest-and-enable.bats pins.
  run jq -e '.sandbox | has("enabled") | not' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "UAT-015: the read-side .env guard hook is present and still registered" {
  # The composition invariant is that the guard still stands, not that
  # .claude/settings.json is never edited. Every hook a feature adds or retires
  # edits that file, so an assert-no-diff-against-main guard fails any such
  # feature while catching nothing a content assertion misses. Assert the guard
  # itself: the hook exists, both of its registrations survive, and the two
  # behaviors SPEC-028 added to it are intact.
  local hook="$REPO_ROOT/.claude/hooks/block-env-read.sh"
  local secrets_hook="$REPO_ROOT/.claude/hooks/block-secrets-read.sh"
  local lib="$REPO_ROOT/.claude/hooks/lib/reader-operands.sh"
  local matcher

  [ -f "$hook" ]
  [ -x "$hook" ]
  [ -f "$secrets_hook" ]
  [ -x "$secrets_hook" ]
  [ -f "$lib" ]

  # Registered on every tool surface it guards. Asserted per matcher rather than
  # as a count of registrations: a count says nothing about WHICH surfaces are
  # covered, so dropping one and adding another elsewhere keeps it green, and it
  # goes stale the moment a matcher is added.
  for matcher in Read Grep Bash; do
    run jq -e --arg m "$matcher" '
      .hooks.PreToolUse[] | select(.matcher == $m) | .hooks[]
      | select(.command | endswith("/.claude/hooks/block-env-read.sh\""))
    ' "$SETTINGS"
    [ "$status" -eq 0 ]
    run jq -e --arg m "$matcher" '
      .hooks.PreToolUse[] | select(.matcher == $m) | .hooks[]
      | select(.command | endswith("/.claude/hooks/block-secrets-read.sh\""))
    ' "$SETTINGS"
    [ "$status" -eq 0 ]
  done

  # The variant family (.env.local, .env.production, ...) is the gap the hook
  # closed; the literal Read(.env) rule never matched it.
  grep -qF 'is_dotenv_path' "$hook"

  # The committed placeholder stays readable, or the guard is a footgun.
  grep -qF '.env.example' "$hook"

  # Both hooks deny rather than warn.
  grep -qF 'permissionDecision' "$hook"
  grep -qF 'permissionDecision' "$secrets_hook"

  # The shared grammar is what lets the grep family be guarded at all, and a
  # guard that cannot load it must deny rather than exit non-zero: only exit 2
  # or a structured deny blocks a PreToolUse call, so an exit 1 there would let
  # every read through with a stderr line as the only trace.
  grep -qF 'gaia_reader_operands' "$lib"
  grep -qF 'gaia_reader_operands' "$hook"
  grep -qF 'gaia_reader_operands' "$secrets_hook"
}
