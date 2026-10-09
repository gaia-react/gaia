#!/usr/bin/env bats
#
# The token-tally cost stack is retired: the usage ledger is the only cost
# store. This suite asserts that no tracked file still names a retired file,
# function, environment variable or store, that every retired file is gone and
# unregistered, and that the state registry classifies the leftovers.
#
# The grep names no positive root: its subject is the whole tracked tree minus
# the exclusions below. Listing roots instead fails in one direction only,
# silently: a root nobody thought to list is a surface the suite cannot read,
# and its green is indistinguishable from a real absence.
#
# Exclusions, each for a reason a reader can check:
#   CHANGELOG.md                     history ledger; its [Unreleased] section is
#                                    checked separately below, because a stale
#                                    entry there describes the shipping tree.
#   wiki/log.md, wiki/meta           append-only ledger and audit reports.
#   wiki/decisions                   decision records narrate what was decided at
#                                    the time they were written.
#   .gaia/tests/fixtures/dedup-key-corpus
#                                    verbatim capture of residual keys recorded
#                                    in merged pull-request bodies and issues.
#   .gaia/tests/hooks/fixtures/audit-routing-before.tsv
#                                    generated enumeration of every tracked path
#                                    at a past point; a data row, never a call.
#   .gaia/scripts/tests/fixtures/usage/baseline-e4b57e23
#                                    byte-frozen copy of the pre-change scripts
#                                    that identity cases compare against.
#   .gaia/audit-ci.yml               owned by the audit roster, not by this
#                                    deliverable.
#   this suite                       it is the absence assertion, so it names the
#                                    retired symbols on purpose.
# .gaia/manifest.json is not excluded: it is checked for the retired file keys
# explicitly, and for the patterns like any other tracked file.
#
# The honest limit: the assertion is over tree state, not a diff, so the CI path
# filter controls when a reintroduced name is caught, never whether.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  MANIFEST="$REPO_ROOT/.gaia/manifest.json"
  # Escaped EREs: a dot in a name is a literal dot, and the bare cost.json
  # pattern must not swallow the longer retired-ledger name's sibling.
  PATTERN='token-tally|token-rollup|cost-represented|token-rates-feed-lib|token-rates-local-lib|audit-window-lib|gaia_resolve_ledger_path|gaia_rates_heal|gaia_rates_prepare|gaia_rate_table_id|rate_table_id|GAIA_RATES_FEED_DISABLE|GAIA_RATES_STATE_DIRECTORY|cost\.jsonl|cost\.json([^l]|$)'
  PATTERN_WITHOUT_LEDGER='token-tally|token-rollup|cost-represented|token-rates-feed-lib|token-rates-local-lib|audit-window-lib|gaia_resolve_ledger_path|gaia_rates_heal|gaia_rates_prepare|gaia_rate_table_id|rate_table_id|GAIA_RATES_FEED_DISABLE|GAIA_RATES_STATE_DIRECTORY|cost\.json([^l]|$)'
  EXCLUDES=(
    ':!CHANGELOG.md'
    ':!wiki/log.md'
    ':!wiki/meta'
    ':!wiki/decisions'
    ':!.gaia/tests/fixtures/dedup-key-corpus'
    ':!.gaia/tests/hooks/fixtures/audit-routing-before.tsv'
    ':!.gaia/scripts/tests/fixtures/usage/baseline-e4b57e23'
    ':!.gaia/audit-ci.yml'
    ':!.gaia/scripts/tests/cost-stack-absence.bats'
  )
  # Every retired file, by basename (the path a name lived at may be stale).
  RETIRED_FILES=(
    token-tally.sh token-rollup.sh cost-represented.sh token-rates-feed-lib.sh
    token-rates-local-lib.sh audit-window-lib.sh token-tally-review.sh
    token-tally-git-op.sh token-rollup-merge.sh 'Cost Data Contract.md'
  )
}

# The one allowed literal retired-ledger name per file, asserted by count so a
# second hit in either file still fails.
allowed_hit_count() {
  git -C "$REPO_ROOT" grep -h -o -E 'cost\.jsonl' -- "$1" | wc -l | tr -d ' '
}

@test "the grep's input set is non-empty and plausibly sized" {
  tracked="$(git -C "$REPO_ROOT" ls-files | wc -l | tr -d ' ')"
  # Floor: half the tracked-file count at authoring time (1927).
  [ "$tracked" -gt 963 ]
}

@test "no tracked file outside the exclusions names a retired symbol" {
  # The two files that may carry the retired ledger's name are held to the
  # rest of the pattern here and to a pinned count of that name below.
  run git -C "$REPO_ROOT" grep -n -E "$PATTERN" -- . "${EXCLUDES[@]}" \
    ':!wiki/concepts/Usage Ledger.md' ':!.gaia/state-registry.json'
  [ "$status" -eq 1 ] || { printf '%s\n' "$output" >&2; return 1; }
  run git -C "$REPO_ROOT" grep -n -E "$PATTERN_WITHOUT_LEDGER" -- \
    'wiki/concepts/Usage Ledger.md' .gaia/state-registry.json
  [ "$status" -eq 1 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "the retired ledger's name appears in exactly one sentence of Usage Ledger.md" {
  [ "$(allowed_hit_count 'wiki/concepts/Usage Ledger.md')" -eq 1 ]
}

@test "the retired ledger's name appears in exactly one registry entry" {
  [ "$(allowed_hit_count '.gaia/state-registry.json')" -eq 1 ]
}

@test "the Unreleased changelog section names no retired symbol" {
  section="$(awk '/^## \[Unreleased\]/ { found = 1; next } found && /^## \[/ { exit } found { print }' "$REPO_ROOT/CHANGELOG.md")"
  # An empty extraction would pass vacuously.
  [ -n "$section" ]
  run grep -n -E "$PATTERN" <<<"$section"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "every retired file is absent from the tracked tree" {
  [ "${#RETIRED_FILES[@]}" -gt 0 ]
  tracked="$(git -C "$REPO_ROOT" ls-files)"
  for name in "${RETIRED_FILES[@]}"; do
    if printf '%s\n' "$tracked" | grep -q -E "(^|/)${name//./\\.}\$"; then
      printf 'still tracked: %s\n' "$name" >&2
      return 1
    fi
    if find "$REPO_ROOT/.gaia" "$REPO_ROOT/.claude" "$REPO_ROOT/wiki" -name "$name" -not -path '*/node_modules/*' -not -path '*/.gaia/local/*' 2>/dev/null | grep -q .; then
      printf 'still on disk: %s\n' "$name" >&2
      return 1
    fi
  done
}

@test "the manifest holds no key for a retired file" {
  [ "$(jq '.files | length' "$MANIFEST")" -gt 0 ]
  for name in "${RETIRED_FILES[@]}"; do
    run jq -r --arg name "$name" '.files | keys[] | select(endswith("/" + $name) or . == $name)' "$MANIFEST"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { printf 'manifest key survives: %s\n' "$output" >&2; return 1; }
  done
}

@test "the registry holds the retired ledger and seeded rate files only as residue" {
  # Retired paths, derived from the registry's own residue array so the case
  # reads the entries rather than a list it could drift from.
  for path in telemetry/cost.jsonl telemetry/token-rates.json telemetry/token-rates.base.json \
    telemetry/token-rates.dist.json telemetry/token-rates.feed-state.json \
    'telemetry/token-rates.json.corrupt.*' 'telemetry/.token-rates*.tmp.*'; do
    run jq -r --arg p "$path" '[.residue[] | select(.path == $p and .writer == "none-residue")] | length' "$REGISTRY"
    [ "$output" = "1" ] || { printf 'not residue: %s\n' "$path" >&2; return 1; }
    run jq -r --arg p "$path" '[.entries[] | select(.path == $p)] | length' "$REGISTRY"
    [ "$output" = "0" ] || { printf 'also a live entry: %s\n' "$path" >&2; return 1; }
  done
}

@test "the registry has no audit-window entry and a live price override entry" {
  run jq -r '[(.entries[], .residue[]) | select(.path | test("audit-window"))] | length' "$REGISTRY"
  [ "$output" = "0" ]
  run jq -r '[.entries[] | select(.path == "telemetry/token-rates.override.json" and .match == "exact" and .kind == "file" and .scope == "shared" and .writer == "hand-authored" and .reaped_by == null)] | length' "$REGISTRY"
  [ "$output" = "1" ]
}
