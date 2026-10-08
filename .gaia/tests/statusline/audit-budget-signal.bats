#!/usr/bin/env bats

# The audit nudge's project-drift signal (.gaia/scripts/check-updates.sh): only
# the auto-loaded root CLAUDE.md and the rules files count against a word or
# line budget. A wiki/hot.md note is an ordinary file and never trips it.
#
# The fixture is a real git repository holding a copy of the real refresher and
# main-root-lib.sh, with a `gaia` wrapper that answers every subcommand the
# refresher calls with an inert stub. The assertions read the cache keys the
# statusline reads: auditNudge and auditNudgeReason.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/audit-budget-signal.bats < /dev/null

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEMPORARY_HOME=$(mktemp -d -t gaia-audit-budget-home-XXXXXX)
  REPOSITORY_FIXTURE=$(mktemp -d -t gaia-audit-budget-fix-XXXXXX)

  git -C "$REPOSITORY_FIXTURE" init --quiet --initial-branch=main
  git -C "$REPOSITORY_FIXTURE" config user.email "test@example.com"
  git -C "$REPOSITORY_FIXTURE" config user.name "Test"
  git -C "$REPOSITORY_FIXTURE" config commit.gpgsign false
  printf '.gaia/local/\n' >> "$REPOSITORY_FIXTURE/.git/info/exclude"
  mkdir -p "$REPOSITORY_FIXTURE/.gaia/scripts" "$REPOSITORY_FIXTURE/.gaia/cli" \
    "$REPOSITORY_FIXTURE/.gaia/local/cache/shared" "$REPOSITORY_FIXTURE/.claude/rules" \
    "$REPOSITORY_FIXTURE/wiki"
  cp "$REPO_ROOT/.gaia/scripts/check-updates.sh" "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$REPOSITORY_FIXTURE/.gaia/scripts/main-root-lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$REPOSITORY_FIXTURE/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$REPOSITORY_FIXTURE/.gaia/scripts/resolve-audit-members.sh"
  cat > "$REPOSITORY_FIXTURE/.gaia/cli/gaia" <<'WRAPPER'
#!/usr/bin/env bash
case "$1" in
  update-deps)
    output_path=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --emit-updates) output_path="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$output_path" ] && printf '{"actionable_count":0}' > "$output_path"
    exit 0
    ;;
  harden-tally)
    printf '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90}'
    exit 0
    ;;
  residue-tally)
    printf '{"gh_ok":false,"aged_candidate_count":0}'
    exit 0
    ;;
  wiki)
    printf '{"drift_count":0}'
    exit 0
    ;;
  *) exit 1 ;;
esac
WRAPPER
  chmod +x "$REPOSITORY_FIXTURE/.gaia/cli/gaia"
  printf '1.0.0\n' > "$REPOSITORY_FIXTURE/.gaia/VERSION"
  printf 'seed\n' > "$REPOSITORY_FIXTURE/wiki/index.md"
  printf 'short project instructions\n' > "$REPOSITORY_FIXTURE/CLAUDE.md"
  printf '# Rule\n\nOne short rule.\n' > "$REPOSITORY_FIXTURE/.claude/rules/short.md"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$REPOSITORY_FIXTURE/.gaia/local/setup-state.json"
}

teardown() {
  [ -n "${REPOSITORY_FIXTURE:-}" ] && rm -rf "$REPOSITORY_FIXTURE" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# Write <count> words to <file>.
write_words() {
  local count="$1" file="$2"
  awk -v n="$count" 'BEGIN { for (i = 0; i < n; i++) printf "word "; printf "\n" }' > "$file"
}

commit_fixture() {
  git -C "$REPOSITORY_FIXTURE" add -A
  git -C "$REPOSITORY_FIXTURE" commit --quiet -m "chore: fixture"
}

cache_value() {
  jq -r ".$1" "$REPOSITORY_FIXTURE/.gaia/local/cache/shared/update-check.json"
}

refresh() {
  run env HOME="$TEMPORARY_HOME" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
}

@test "a 300-word wiki/hot.md records no over-budget audit nudge" {
  write_words 300 "$REPOSITORY_FIXTURE/wiki/hot.md"
  commit_fixture
  refresh
  [ "$(cache_value auditNudgeReason)" != "over budget" ]
  [ "$(cache_value auditNudge)" = "false" ]
}

@test "a root CLAUDE.md over the word budget records the over-budget audit nudge" {
  write_words 600 "$REPOSITORY_FIXTURE/CLAUDE.md"
  commit_fixture
  refresh
  [ "$(cache_value auditNudge)" = "true" ]
  [ "$(cache_value auditNudgeReason)" = "over budget" ]
}
