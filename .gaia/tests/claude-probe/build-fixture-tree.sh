#!/usr/bin/env bash
# build-fixture-tree.sh: build a throwaway git repo in the SPEC-092 target
# layout (harness at the root, the app and its frontend-only harness under
# frontend/) for the Claude probe's spike run, without touching this checkout.
#
# Usage: build-fixture-tree.sh <out_dir>
#   <out_dir> must not exist, or must be an empty directory.
#
# Real copies only, never symlinks: claude-mechanics Q6 found a symlinked rule
# whose target sits outside the launch dir is treated as an external import,
# which would make the fixture observe a layout the plan rejected.
#
# frontend/.claude/settings.json is a fixture approximation of the settings
# generator that does not exist yet (plan contract C8): it applies the C8
# re-anchoring transform to the copied root settings with jq. The final probe
# run after plan Phase 11 targets a scratch clone of the finished branch and so
# observes the real generated file instead.
#
# The committed fixture is the plain target layout; the probe instrumentation
# (inject-probe-fixtures.sh) is laid over it afterwards, uncommitted, exactly as
# run-probe.sh lays it over any other target.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_ROOT="$(git -C "$SCRIPT_DIRECTORY" rev-parse --show-toplevel)"

if [ "$#" -ne 1 ]; then
  echo "usage: build-fixture-tree.sh <out_dir>" >&2
  exit 2
fi
for required_tool in git jq; do
  command -v "$required_tool" >/dev/null 2>&1 || { echo "ERROR: $required_tool is required" >&2; exit 2; }
done
OUT_DIRECTORY="$1"
if [ -e "$OUT_DIRECTORY" ]; then
  if [ ! -d "$OUT_DIRECTORY" ] || [ -n "$(ls -A "$OUT_DIRECTORY")" ]; then
    echo "ERROR: $OUT_DIRECTORY exists and is not an empty directory" >&2
    exit 2
  fi
fi
mkdir -p "$OUT_DIRECTORY"
OUT_DIRECTORY="$(cd "$OUT_DIRECTORY" && pwd -P)"

# The frontend-only harness units of plan contract C6 (harness-split.json's
# frontend-only set). Each lives at frontend/.claude/<unit> in the source tree.
frontend_only_units() {
  local unit
  for unit in a11y-fixes eslint-fixes gaia-react-perf new-component new-hook new-route \
    new-service playwright-cli react-code skeleton-loaders tailwind typescript; do
    printf '.claude/skills/%s/\n' "$unit"
  done
  for unit in accessibility api-service design-baseline i18n playwright react-router-docs \
    routes state-pattern storybook tailwind; do
    printf '.claude/rules/%s.md\n' "$unit"
  done
  for unit in add-locale remove-i18n; do
    printf '.claude/instructions/%s.md\n' "$unit"
  done
  for unit in README cn conform form-components react-i18next; do
    printf '.claude/agents/code-audit-frontend/%s.md\n' "$unit"
  done
}

copy_tracked() {
  local relative_path="$1" destination="$2"
  mkdir -p "$(dirname "$OUT_DIRECTORY/$destination")"
  cp -p "$SOURCE_ROOT/$relative_path" "$OUT_DIRECTORY/$destination"
}

# Tracked harness: root CLAUDE.md, .claude/, .gaia/scripts, .githooks, and the
# frontend-only units already tracked under frontend/.claude/ (the source tree
# is the post-move layout, so every path copies to itself), plus .gitignore so the fixture ignores what the real tree ignores (.env,
# .gaia/local, .claude/settings.local.json).
copied_count=0
while IFS= read -r -d '' relative_path; do
  [ -f "$SOURCE_ROOT/$relative_path" ] || continue
  copy_tracked "$relative_path" "$relative_path"
  copied_count=$((copied_count + 1))
done < <(git -C "$SOURCE_ROOT" -c core.quotepath=false ls-files -z -- CLAUDE.md .claude .gaia/scripts .githooks .gitignore frontend/.claude)
if [ "$copied_count" -eq 0 ]; then
  echo "ERROR: no tracked harness files found under $SOURCE_ROOT" >&2
  exit 1
fi

# Every C6 unit must be present under frontend/; a unit renamed or deleted at
# the source would otherwise drop out of the fixture without a word.
while IFS= read -r unit; do
  if [ ! -e "$OUT_DIRECTORY/frontend/${unit%/}" ]; then
    echo "ERROR: frontend-only unit $unit was not found in the source tree" >&2
    exit 1
  fi
done < <(frontend_only_units)

write_file() {
  mkdir -p "$(dirname "$OUT_DIRECTORY/$1")"
  printf '%s\n' "$2" >"$OUT_DIRECTORY/$1"
}

write_file frontend/CLAUDE.md "# Frontend (probe fixture)

Stub package CLAUDE.md for the Claude probe fixture tree. React app conventions live in frontend/.claude/."

write_file frontend/app/components/button/index.tsx "export const Button = ({label}: {label: string}) => <button type=\"button\">{label}</button>;"
write_file frontend/app/components/button/tests/index.test.tsx "import {describe, expect, test} from 'vitest';

describe('Button', () => {
  test('exists', () => {
    expect(true).toBe(true);
  });
});"
write_file frontend/.playwright/e2e/hydration.spec.ts "import {expect, test} from '@playwright/test';

test('home hydrates', async ({page}) => {
  await page.goto('/');
  await expect(page.locator('body')).toBeVisible();
});"
write_file pnpm-lock.yaml "lockfileVersion: '9.0'"

# Untracked by .gitignore, exactly as on a real machine.
write_file .env "PROBE=1"
write_file frontend/.env "PROBE=1"
for marker in ok carried refused; do
  write_file ".gaia/local/audit/x.$marker" "PROBE=1"
done

# frontend/.claude/settings.json: the C8 transform for a package at depth 1.
# Path-bearing Edit/Read/Write/MultiEdit/NotebookEdit rules and every
# sandbox.filesystem entry are re-anchored with ../ unless they begin **/, //
# or ~/ (a leading ./ or / is dropped first); Bash, WebFetch and MCP rules,
# hooks and statusLine copy unchanged; permissions.additionalDirectories gets
# "..", which ships only together with the re-anchored denies.
jq '
  def reanchor:
    if test("^(\\*\\*/|//|~/)") then .
    else "../" + (sub("^\\./"; "") | sub("^/"; ""))
    end;
  def rule:
    if test("^(Edit|Read|Write|MultiEdit|NotebookEdit)\\(.*\\)$") then
      capture("^(?<tool>[A-Za-z]+)\\((?<spec>.*)\\)$") | "\(.tool)(\(.spec | reanchor))"
    else . end;
  (if .permissions then
     .permissions |= (
       reduce ("allow", "deny", "ask") as $key (.;
         if has($key) then .[$key] |= map(rule) else . end)
       | .additionalDirectories = [".."])
   else . end)
  | (if .sandbox.filesystem then
       .sandbox.filesystem |= with_entries(.value |= (if type == "array" then map(reanchor) else . end))
     else . end)
' "$OUT_DIRECTORY/.claude/settings.json" >"$OUT_DIRECTORY/frontend/.claude/settings.json"

git -C "$OUT_DIRECTORY" init -q
git -C "$OUT_DIRECTORY" config user.name "Claude Probe Fixture"
git -C "$OUT_DIRECTORY" config user.email "claude-probe@example.invalid"
git -C "$OUT_DIRECTORY" config commit.gpgsign false
git -C "$OUT_DIRECTORY" add -A
git -C "$OUT_DIRECTORY" commit -q -m "Claude probe fixture: SPEC-092 target layout"
# Off main, as a maintainer's working tree would be: GAIA's commit-to-main
# PreToolUse guard denies any commit on main before git runs, which would hide
# pre-commit and the RED gate from the commit rows. run-probe.sh also moves
# any target onto its own probe branch for the commit scenarios.
git -C "$OUT_DIRECTORY" checkout -q -b probe/fixture
# Armed only after the fixture's own commit, which no hook should judge; from
# here on a commit in the fixture runs .githooks/pre-commit directly, as a
# clone's `prepare` would arm it.
git -C "$OUT_DIRECTORY" config core.hooksPath .githooks

bash "$SCRIPT_DIRECTORY/inject-probe-fixtures.sh" "$OUT_DIRECTORY"

printf '%s\n' "$OUT_DIRECTORY"
