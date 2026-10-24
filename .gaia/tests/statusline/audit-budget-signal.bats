#!/usr/bin/env bats

# The cleanse nudge's project-drift signal (.gaia/scripts/check-updates.sh): the
# auto-loaded CLAUDE.md files and the rules files count against a word or line
# budget, judged by the CLI's budget rule. An ordinary wiki page never trips it.
#
# The fixture is a real git repository holding a copy of the real refresher and
# main-root-lib.sh, with a `gaia` wrapper that answers every subcommand the
# refresher calls with an inert stub, except `fitness`, which runs the bundle
# named by GAIA_TEST_FITNESS_BUNDLE (the committed one unless a test swaps it).
# The assertions read the cache keys the statusline reads: cleanseNudge and
# cleanseNudgeReason.
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
  codify-tally)
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
  fitness)
    exec "$GAIA_TEST_FITNESS_BUNDLE" "$@"
    ;;
  *) exit 1 ;;
esac
WRAPPER
  chmod +x "$REPOSITORY_FIXTURE/.gaia/cli/gaia"
  export GAIA_TEST_FITNESS_BUNDLE="$REPO_ROOT/.gaia/cli/gaia"
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
  rm -f "$REPOSITORY_FIXTURE/.gaia/local/cache/shared/update-check.json"
  run env HOME="$TEMPORARY_HOME" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
}

# A nested file under the nested limit but over what the root allows would not
# trip; this one is over the nested limit, the root sits exactly at its limit,
# and a deeper file is committed too.
write_budget_fixture() {
  mkdir -p "$REPOSITORY_FIXTURE/frontend" "$REPOSITORY_FIXTURE/a/b/c"
  write_words 450 "$REPOSITORY_FIXTURE/frontend/CLAUDE.md"
  write_words 500 "$REPOSITORY_FIXTURE/CLAUDE.md"
  write_words 900 "$REPOSITORY_FIXTURE/a/b/c/CLAUDE.md"
}

budget_finding_files() {
  jq -r '[.findings[] | select(.rule_id == "claudemd.budget") | .file] | join(",")' <<<"$1"
}

@test "a nested CLAUDE.md over its tighter budget records the over-budget nudge and one finding" {
  write_budget_fixture
  commit_fixture
  refresh
  [ "$(cache_value cleanseNudge)" = "true" ]
  [ "$(cache_value cleanseNudgeReason)" = "over budget" ]

  run "$GAIA_TEST_FITNESS_BUNDLE" fitness check --json --scope all --only claudemd.budget --root "$REPOSITORY_FIXTURE"
  [ "$(budget_finding_files "$output")" = "frontend/CLAUDE.md" ]
}

@test "a root CLAUDE.md of 501 words records the over-budget nudge" {
  write_words 501 "$REPOSITORY_FIXTURE/CLAUDE.md"
  commit_fixture
  refresh
  [ "$(cache_value cleanseNudge)" = "true" ]
  [ "$(cache_value cleanseNudgeReason)" = "over budget" ]
}

@test "a rule of 201 lines records the over-budget nudge" {
  awk 'BEGIN { for (i = 0; i < 201; i++) print "line" }' > "$REPOSITORY_FIXTURE/.claude/rules/long.md"
  commit_fixture
  refresh
  [ "$(cache_value cleanseNudge)" = "true" ]
  [ "$(cache_value cleanseNudgeReason)" = "over budget" ]
}

@test "every auto-load file within budget records no nudge" {
  mkdir -p "$REPOSITORY_FIXTURE/frontend"
  write_words 400 "$REPOSITORY_FIXTURE/frontend/CLAUDE.md"
  write_words 500 "$REPOSITORY_FIXTURE/CLAUDE.md"
  awk 'BEGIN { for (i = 0; i < 200; i++) print "line" }' > "$REPOSITORY_FIXTURE/.claude/rules/edge.md"
  commit_fixture
  refresh
  [ "$(cache_value cleanseNudge)" = "false" ]
}

@test "a 300-word ordinary wiki page records no over-budget cleanse nudge" {
  write_words 300 "$REPOSITORY_FIXTURE/wiki/notes.md"
  commit_fixture
  refresh
  [ "$(cache_value cleanseNudgeReason)" != "over budget" ]
  [ "$(cache_value cleanseNudge)" = "false" ]
}

# Rebuilds a bundle from a copy of the whole .gaia/cli/src tree, so a change
# to any source file it does not name can red it.
# bats test_tags=whole-tree
@test "raising the nested budget constant in a rebuilt bundle clears the nudge for the same fixture" {
  local esbuild="$REPO_ROOT/.gaia/cli/node_modules/.bin/esbuild"
  [ -x "$esbuild" ] || skip "esbuild is not installed in .gaia/cli/node_modules"
  local source_copy="$BATS_TEST_TMPDIR/cli-src" mutated_bundle="$BATS_TEST_TMPDIR/gaia-mutated"
  cp -R "$REPO_ROOT/.gaia/cli/src" "$source_copy"
  sed -i.bak 's/^export const NESTED_CLAUDE_MD_WORD_BUDGET = 400;$/export const NESTED_CLAUDE_MD_WORD_BUDGET = 500;/' "$source_copy/fitness/budgets.ts"
  grep -q 'NESTED_CLAUDE_MD_WORD_BUDGET = 500;' "$source_copy/fitness/budgets.ts"

  NODE_PATH="$REPO_ROOT/.gaia/cli/node_modules" "$esbuild" "$source_copy/index.ts" --bundle --platform=node --target=node20 --format=esm \
    --banner:js='import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' \
    --outfile="$BATS_TEST_TMPDIR/gaia-mutated.js" --log-level=error
  printf '#!/usr/bin/env node\n' | cat - "$BATS_TEST_TMPDIR/gaia-mutated.js" > "$mutated_bundle"
  chmod +x "$mutated_bundle"

  write_budget_fixture
  commit_fixture

  # Control: the committed bundle trips on the 450-word nested file.
  refresh
  [ "$(cache_value cleanseNudge)" = "true" ]

  GAIA_TEST_FITNESS_BUNDLE="$mutated_bundle"
  export GAIA_TEST_FITNESS_BUNDLE
  refresh
  [ "$(cache_value cleanseNudge)" = "false" ]
  run "$mutated_bundle" fitness check --json --scope all --only claudemd.budget --root "$REPOSITORY_FIXTURE"
  [ "$(budget_finding_files "$output")" = "" ]
}

# A PATH directory holding a symlink to every executable on the current PATH
# except node, first match per name.
build_path_without_node() {
  local target="$1" directory entry name
  mkdir -p "$target"
  local old_ifs="$IFS"
  IFS=:
  for directory in $PATH; do
    [ -d "$directory" ] || continue
    for entry in "$directory"/*; do
      [ -f "$entry" ] && [ -x "$entry" ] || continue
      name=$(basename "$entry")
      [ "$name" = "node" ] && continue
      [ -e "$target/$name" ] || ln -s "$entry" "$target/$name"
    done
  done
  IFS="$old_ifs"
}

@test "with node absent the budget signal is skipped and the draft-resume signal still fires" {
  local bin_directory="$BATS_TEST_TMPDIR/no-node-bin"
  build_path_without_node "$bin_directory"
  [ ! -e "$bin_directory/node" ]
  write_words 600 "$REPOSITORY_FIXTURE/CLAUDE.md"
  mkdir -p "$REPOSITORY_FIXTURE/.gaia/local/cleanse"
  printf -- '---\nstatus: draft\n---\n\n# Report\n' > "$REPOSITORY_FIXTURE/.gaia/local/cleanse/KNOWLEDGE-2026-01-01-1200.md"
  commit_fixture
  rm -f "$REPOSITORY_FIXTURE/.gaia/local/cache/shared/update-check.json"
  run env HOME="$TEMPORARY_HOME" PATH="$bin_directory" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cache_value cleanseNudgeReason)" = "resume draft" ]
}

@test "with node absent an over-budget CLAUDE.md alone records no nudge" {
  local bin_directory="$BATS_TEST_TMPDIR/no-node-bin"
  build_path_without_node "$bin_directory"
  [ ! -e "$bin_directory/node" ]
  write_words 600 "$REPOSITORY_FIXTURE/CLAUDE.md"
  commit_fixture
  run env HOME="$TEMPORARY_HOME" PATH="$bin_directory" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cache_value cleanseNudge)" = "false" ]
  [ "$(cache_value cleanseNudgeReason)" = "" ]
}
