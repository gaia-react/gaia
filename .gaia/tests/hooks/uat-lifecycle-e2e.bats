#!/usr/bin/env bats
#
# The UAT lifecycle end to end, over a committed fixture SPEC: render the e2e
# UAT into a temporary frontend tree, run it in real Chromium, and drive the
# owning-phase gate, the divergence check and the id scan through the red and
# green states. Also pins that the rendered file is a fixed point of the
# frontend's own `eslint --fix` and typechecks, which only the real frontend
# toolchain can answer.
#
# Needs the frontend workspace and Chromium, and fails rather than skips when
# either is missing: a skipped lifecycle check reads as a pass. Kept in this
# directory so the browser install is owed only to the leg that holds it.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup_file() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAYWRIGHT_BIN="$REPO_ROOT_REAL/frontend/node_modules/.bin/playwright"
  export REPO_ROOT_REAL PLAYWRIGHT_BIN
  if [ ! -x "$PLAYWRIGHT_BIN" ]; then
    echo "Playwright is not installed at $PLAYWRIGHT_BIN; run pnpm install" >&2
    return 1
  fi
  local chromium_path
  chromium_path=$(cd "$REPO_ROOT_REAL/frontend" && node -e "process.stdout.write(require('@playwright/test').chromium.executablePath())" < /dev/null 2>/dev/null) || chromium_path=''
  if [ -z "$chromium_path" ] || [ ! -e "$chromium_path" ]; then
    echo "Chromium is not installed for Playwright (looked for '$chromium_path'); run pnpm install:browsers" >&2
    return 1
  fi
}

teardown_file() {
  # No test leaves anything under the real Playwright tree: tracked files only.
  local leftover
  leftover=$(git -C "$REPO_ROOT_REAL" status --porcelain -- frontend/.playwright)
  [ -z "$leftover" ] || { echo "scratch left under frontend/.playwright: $leftover" >&2; return 1; }
}

setup() {
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/uat-lifecycle"
  SPEC_SCRIPTS="$REPO_ROOT_REAL/.gaia/scripts/spec"
  TREE="$BATS_TEST_TMPDIR/tree"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$PLAN/SPEC.md"
  ROUTING="$PLAN/README.md"
  mkdir -p "$TREE/.gaia" "$TREE/frontend/.playwright/e2e" "$PLAN"
  # The renderer writes its ledger beside the routing file, so the fixtures
  # are copied rather than pointed at.
  cp "$FIXTURES/SPEC.md" "$SPEC"
  cp "$FIXTURES/README.md" "$ROUTING"
  # No packages registry: the package library resolves the built-in default
  # frontend/. node_modules is the real one, so no install happens here.
  ln -s "$REPO_ROOT_REAL/frontend/node_modules" "$TREE/frontend/node_modules"
  cat > "$TREE/frontend/playwright.config.ts" <<'CONFIG'
import {defineConfig, devices} from '@playwright/test';

export default defineConfig({
  projects: [{name: 'chromium', use: {...devices['Desktop Chrome']}}],
  testDir: './.playwright/e2e',
});
CONFIG
  SCRATCH_DIR=''
}

teardown() {
  [ -z "$SCRATCH_DIR" ] || rm -rf "$SCRATCH_DIR"
}

# in_tree <command...>: the real scripts, run from the temporary tree's root.
in_tree() {
  ( cd "$TREE" && "$@" )
}

# playwright_report <report-path> <spec-file>: one owned-file run with the JSON
# reporter, run from the temporary frontend package.
playwright_report() {
  ( cd "$TREE/frontend" && PLAYWRIGHT_JSON_OUTPUT_NAME="$1" "$PLAYWRIGHT_BIN" test "$2" --reporter=json < /dev/null > /dev/null 2>&1 )
}

@test "a rendered UAT runs red, the gate refuses it, and once an implementer turns it green the gate, divergence check and id scan pass" {
  local rendered="frontend/.playwright/e2e/fixture-flow/fixture-flow-confirms.spec.ts"
  local red_report="$BATS_TEST_TMPDIR/red.json" green_report="$BATS_TEST_TMPDIR/green.json"

  # 1. Render.
  run in_tree bash "$SPEC_SCRIPTS/uat-write.sh" "$SPEC" --routing "$ROUTING"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.summary.written' <<<"$output")" = "1" ]
  [ "$(jq -r '.details[0].path' <<<"$output")" = "$rendered" ]
  [ "$(find "$TREE/frontend/.playwright/e2e" -type f | wc -l | tr -d ' ')" = "1" ]
  [ -f "$TREE/$rendered" ]

  # 2. Red run. The owned file alone is run, standing in for a whole-suite
  # run, and the spec is an expected failure: exit 0, status `expected`.
  run playwright_report "$red_report" "$TREE/$rendered"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.. | objects | select(has("expectedStatus"))] | length' "$red_report")" = "1" ]
  [ "$(jq -r '[.. | objects | select(has("expectedStatus"))][0] | "\(.expectedStatus) \(.status)"' "$red_report")" = "failed expected" ]

  # 3. The gate refuses the red state, naming the file.
  run in_tree bash "$SPEC_SCRIPTS/uat-gate.sh" "$SPEC" --routing "$ROUTING" --phase 1 --report "$red_report"
  [ "$status" -eq 1 ]
  grep -qF -- "fixture-flow-confirms.spec.ts" <<<"$output" || return 1
  grep -qE -- 'annotation|expected-failure' <<<"$output" || return 1

  # 4. Turn it green the way an implementer would: the annotation goes, the
  # body drives the page, the contract comment is left alone.
  local green_file="$BATS_TEST_TMPDIR/green.spec.ts"
  sed -n '1,/^const outcome = {/p' "$TREE/$rendered" | sed '$d' > "$green_file"
  cat >> "$green_file" <<'GREEN'
test('the confirmation is shown', async ({page}) => {
  await page.setContent('<p>Confirmed</p>');
  await expect(page.getByText('Confirmed')).toBeVisible();
});
GREEN
  cp "$green_file" "$TREE/$rendered"
  head -n 1 "$TREE/$rendered" | grep -q '^// gaia-uat-contract sha256:' || return 1
  run playwright_report "$green_report" "$TREE/$rendered"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.. | objects | select(has("expectedStatus"))][0] | "\(.expectedStatus) \(.status)"' "$green_report")" = "passed expected" ]

  # 5. The same gate now passes on the same file, and the two checks it
  # wraps pass on their own.
  run in_tree bash "$SPEC_SCRIPTS/uat-gate.sh" "$SPEC" --routing "$ROUTING" --phase 1 --report "$green_report"
  [ "$status" -eq 0 ]
  run in_tree bash "$SPEC_SCRIPTS/uat-divergence-check.sh" "$SPEC" --routing "$ROUTING" --all
  [ "$status" -eq 0 ]
  run in_tree bash "$SPEC_SCRIPTS/working-doc-id-scan.sh" "$TREE/frontend/.playwright"
  [ "$status" -eq 0 ]

  # 6. The pre-audit form over every e2e row.
  run in_tree bash "$SPEC_SCRIPTS/uat-gate.sh" "$SPEC" --routing "$ROUTING" --all --report "$green_report"
  [ "$status" -eq 0 ]
}

@test "the live Playwright step of the gate passes a green owned spec on a real run" {
  local rendered="frontend/.playwright/e2e/fixture-flow/fixture-flow-confirms.spec.ts"
  run in_tree bash "$SPEC_SCRIPTS/uat-write.sh" "$SPEC" --routing "$ROUTING"
  [ "$status" -eq 0 ]
  sed -n '1,/^const outcome = {/p' "$TREE/$rendered" | sed '$d' > "$BATS_TEST_TMPDIR/green.spec.ts"
  cat >> "$BATS_TEST_TMPDIR/green.spec.ts" <<'GREEN'
test('the confirmation is shown', async ({page}) => {
  await page.setContent('<p>Confirmed</p>');
  await expect(page.getByText('Confirmed')).toBeVisible();
});
GREEN
  cp "$BATS_TEST_TMPDIR/green.spec.ts" "$TREE/$rendered"
  # The gate runs `pnpm -C <package> exec playwright ...`. A real pnpm in the
  # temporary package would run its dependency check against the symlinked
  # node_modules and try to rewrite it, so a shim on PATH forwards that exact
  # call shape to the real Playwright binary; everything else is the gate's own.
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat > "$BATS_TEST_TMPDIR/shim/pnpm" <<'SHIM'
#!/usr/bin/env bash
[ "$1" = "-C" ] && [ "$3" = "exec" ] && [ "$4" = "playwright" ] || { echo "unexpected pnpm call: $*" >&2; exit 64; }
cd "$2" && shift 4 && exec "$PLAYWRIGHT_BIN" "$@" < /dev/null
SHIM
  chmod +x "$BATS_TEST_TMPDIR/shim/pnpm"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH"
  run in_tree bash "$SPEC_SCRIPTS/uat-gate.sh" "$SPEC" --routing "$ROUTING" --phase 1
  echo "$output" >&2
  [ "$status" -eq 0 ]
}

@test "the rendered special-character spec is a fixed point of the frontend's eslint --fix and typechecks" {
  # Rendered into the real frontend, because the lint and TypeScript configs
  # only resolve there. The folder is unique per run so parallel runs never
  # collide, and teardown removes it, also on failure.
  local unique folder rendered_file
  unique=$(basename "$BATS_RUN_TMPDIR" | tr 'A-Z_.' 'a-z--' | tr -c 'a-z0-9\n-' '-')
  folder="lifecycle-scratch-$unique"
  SCRATCH_DIR="$REPO_ROOT_REAL/frontend/.playwright/e2e/$folder"
  sed "s/| fixture-flow |/| $folder |/" "$FIXTURES/README.md" > "$ROUTING"
  grep -qF -- "| $folder |" "$ROUTING" || return 1

  run bash -c "cd '$REPO_ROOT_REAL' && bash '$SPEC_SCRIPTS/uat-write.sh' '$SPEC' --routing '$ROUTING'"
  [ "$status" -eq 0 ]
  rendered_file="$SCRATCH_DIR/fixture-flow-confirms.spec.ts"
  [ -f "$rendered_file" ]
  cp "$rendered_file" "$BATS_TEST_TMPDIR/before.spec.ts"

  # The embedded digest is the digest of the as-rendered body.
  # shellcheck source=.gaia/scripts/spec/uat-lib.sh
  source "$SPEC_SCRIPTS/uat-lib.sh"
  [ "$(uat_lib_embedded_hash "$rendered_file")" = "$(uat_lib_body_hash "$rendered_file")" ]

  run pnpm -C "$REPO_ROOT_REAL/frontend" exec eslint --fix "$rendered_file"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/before.spec.ts" "$rendered_file"
  [ "$(uat_lib_embedded_hash "$rendered_file")" = "$(uat_lib_body_hash "$rendered_file")" ]

  cat > "$SCRATCH_DIR/tsconfig.json" <<'TSCONFIG'
{
  "extends": "../../../tsconfig.json",
  "include": ["./fixture-flow-confirms.spec.ts"]
}
TSCONFIG
  run pnpm -C "$REPO_ROOT_REAL/frontend" exec tsc --noEmit -p "$SCRATCH_DIR/tsconfig.json"
  echo "$output" >&2
  [ "$status" -eq 0 ]
}
