#!/usr/bin/env bats

# The extractor's story names against Storybook's own Vitest reporter. A name
# the extractor computes differently from the reporter would key a worthiness
# verdict to a test that no run ever reports, so this runs the real storybook
# project in Chromium over both fixture files and compares.
#
# Needs the frontend workspace and Chromium, and fails rather than skips when
# either is missing: a skipped equality check reads as a pass. Kept apart from
# extract-test-signals-stories.bats so the browser install is owed only to the
# leg that holds this file.

setup_file() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  REPORT="$BATS_FILE_TMPDIR/reporter.json"
  RUN_OUTPUT="$BATS_FILE_TMPDIR/run-output.txt"
  export HOME_ROOT REPORT RUN_OUTPUT
  [ -d "$HOME_ROOT/frontend/node_modules" ] || return 0
  # The run's own exit status is not read: the verdict is the report below, and
  # a no-Chromium run writes one with zero tests next to a launch error.
  pnpm -C "$HOME_ROOT/frontend" exec vitest run --project storybook \
    app/utils/tests/csf-shapes.stories.tsx app/utils/tests/csf-meta-play.stories.tsx \
    --reporter=json --outputFile="$REPORT" < /dev/null > "$RUN_OUTPUT" 2>&1 || true
}

setup() {
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  if [ ! -d "$HOME_ROOT/frontend/node_modules" ]; then
    echo "the frontend workspace is not installed; run pnpm install" >&2
    return 1
  fi
  if ! jq -e '(.numTotalTests // 0) > 0' "$REPORT" >/dev/null 2>&1; then
    echo "the storybook project ran no stories, so Chromium is likely not installed; run pnpm install:browsers" >&2
    head -n 12 "$RUN_OUTPUT" >&2
    return 1
  fi
}

# The reporter's story names for one fixture file.
reporter_names_for() {
  jq -r --arg suffix "$1" '.testResults[] | select(.name | endswith($suffix)) | .assertionResults[] | .fullName' "$REPORT"
}

extractor_names_for() {
  ( cd "$HOME_ROOT" && node "$EXTRACTOR" "frontend/$1" | jq -r '.fullName' )
}

@test "every story the extractor emits for the shapes fixture has the reporter's name, and the render-only story is not emitted" {
  local reporter_names extractor_names story_name
  reporter_names=$(reporter_names_for "app/utils/tests/csf-shapes.stories.tsx")
  extractor_names=$(extractor_names_for "app/utils/tests/csf-shapes.stories.tsx")
  [ -n "$extractor_names" ]

  while IFS= read -r story_name; do
    grep -qxF -- "$story_name" <<<"$reporter_names" || { echo "reporter has no story named: $story_name" >&2; return 1; }
  done <<<"$extractor_names"

  grep -qxF -- "Render Only" <<<"$reporter_names"
  grep -qxF -- "Render Only" <<<"$extractor_names" && return 1
  true
}

@test "every story the reporter runs, bar the render-only one, is emitted by the extractor" {
  local reporter_names extractor_names story_name
  reporter_names=$(reporter_names_for "app/utils/tests/csf-shapes.stories.tsx")
  extractor_names=$(extractor_names_for "app/utils/tests/csf-shapes.stories.tsx")

  while IFS= read -r story_name; do
    [ "$story_name" = "Render Only" ] && continue
    grep -qxF -- "$story_name" <<<"$extractor_names" || { echo "extractor emits nothing for: $story_name" >&2; return 1; }
  done <<<"$reporter_names"
}

@test "the meta-play fixture's inherited-play story has the reporter's name" {
  local reporter_names extractor_names
  reporter_names=$(reporter_names_for "app/utils/tests/csf-meta-play.stories.tsx")
  extractor_names=$(extractor_names_for "app/utils/tests/csf-meta-play.stories.tsx")
  [ -n "$extractor_names" ]
  [ "$reporter_names" = "$extractor_names" ]
}

@test "every fixture story passes in the browser" {
  jq -e '[.testResults[].assertionResults[] | select(.status != "passed")] | length == 0' "$REPORT" >/dev/null
}
