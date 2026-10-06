#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-init (.claude/commands/gaia-init.md): the
# command asks no CI-intent or wiki-mode question, writes the project settings
# through `gaia init write-project-config`, and its resume step list names the
# same steps, in the same order, as the CLI's STEP_ORDER.
#
# Forbidden tokens that the repo-wide absence guard also forbids are built at
# runtime, so this file never carries the literal. Each absence check is proven
# able to fail: a scratch copy of the command gets the forbidden content
# re-inserted and the check must flag it.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INIT_MD="$REPO_ROOT/.claude/commands/gaia-init.md"
  STATE_TS="$REPO_ROOT/.gaia/cli/src/init/util/state.ts"
  FROZEN_STEPS="strip-branding configure-i18n configure-data-layer rename wire-statusline bootstrap-env write-project-config finalize"
}

# Fixed-string forbidden tokens, one per line. The runtime-built ones are the
# tokens the repo-wide absence guard forbids as literals.
forbidden_tokens() {
  printf '%s\n' \
    "$(printf 'configure%sautomation' -)" \
    "$(printf 'automation%sjson' .)" \
    "$(printf 'docs.gaiareact.com/maintenance/gaia%sci' -)" \
    'Configure CI integrations' \
    'GAIA CI' \
    'default_mode' \
    '--wiki' \
    'CI_CATEGORY' \
    '--ci' \
    'Sets `wiki`' \
    '`ci` / `local` / `off`'
}

# Print each forbidden token found in the file given as $1.
violations() {
  local file="$1" token
  while IFS= read -r token; do
    if grep -qF -- "$token" "$file"; then
      printf '%s\n' "$token"
    fi
  done < <(forbidden_tokens)
}

# Print the resume list names in order, from the `--from-step` sentence.
resume_steps() {
  grep -F -- '--from-step <N>' "$1" |
    grep -oE '[0-9]+=[a-z0-9-]+' |
    sed -E 's/^[0-9]+=//' |
    tr '\n' ' ' | sed 's/ $//'
}

resume_indices() {
  grep -F -- '--from-step <N>' "$1" |
    grep -oE '[0-9]+=[a-z0-9-]+' |
    sed -E 's/=.*$//' |
    tr '\n' ' ' | sed 's/ $//'
}

state_steps() {
  awk '/export const STEP_ORDER = \[/{on=1; next} on && /\] as const/{exit} on{gsub(/[ ,\047]/,""); if ($0 != "") print}' "$STATE_TS" |
    tr '\n' ' ' | sed 's/ $//'
}

@test "gaia-init.md carries none of the CI-question tokens" {
  run violations "$INIT_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the absence check flags every forbidden token re-inserted into a scratch copy" {
  local token scratch
  while IFS= read -r token; do
    scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
    cp "$INIT_MD" "$scratch"
    printf '\n%s\n' "$token" >>"$scratch"
    run violations "$scratch"
    [ "$output" = "$token" ] || {
      printf 'token not flagged: %s (got: %s)\n' "$token" "$output" >&2
      return 1
    }
  done < <(forbidden_tokens)
}

@test "gaia-init.md calls write-project-config with --sandbox-recommended" {
  grep -qF 'gaia init write-project-config' "$INIT_MD"
  grep -qF -- '--sandbox-recommended <true|false>' "$INIT_MD"
}

@test "gaia-init.md keeps the isolation-policy omission rule" {
  grep -qF -- '[--isolation-policy <always-worktree|prefer-worktree|prefer-branch>]' "$INIT_MD"
  grep -qF -- 'omit the flag entirely' "$INIT_MD"
}

@test "the writer check fails when the writer call is removed from a scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF 'gaia init write-project-config' "$INIT_MD" >"$scratch"
  run grep -qF 'gaia init write-project-config' "$scratch"
  [ "$status" -ne 0 ]
}

@test "the resume list names exactly the frozen steps, 1-indexed, in order" {
  [ "$(resume_steps "$INIT_MD")" = "$FROZEN_STEPS" ]
  [ "$(resume_indices "$INIT_MD")" = "1 2 3 4 5 6 7 8" ]
}

@test "the resume list agrees with STEP_ORDER in state.ts" {
  [ "$(state_steps)" = "$(resume_steps "$INIT_MD")" ]
}

@test "the resume check fails on a reordered scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed -E 's/6=bootstrap-env, 7=write-project-config/6=write-project-config, 7=bootstrap-env/' "$INIT_MD" >"$scratch"
  [ "$(resume_steps "$scratch")" != "$FROZEN_STEPS" ]
}

@test "the adoption ping passes no --ci field" {
  grep -qF '.gaia/cli/gaia ping --event init --mode "$MODE" --i18n "$I18N_COUNT" || true' "$INIT_MD"
}

# Print Step 2 (from its heading to the Step 3 heading) of the file given as $1.
step_two() {
  awk '/^## Step 2:/{on=1} /^## Step 3:/{on=0} on' "$1"
}

# Print each data-layer anchor missing from the file given as $1, one per line.
data_layer_gaps() {
  local file="$1" label
  for label in 'camelCase (Recommended)' 'snake_case' 'Not sure' \
    'Add TanStack Query for client-owned data?' 'No (Recommended)'; do
    step_two "$file" | grep -qF -- "$label" || printf 'option: %s\n' "$label"
  done
  grep -qF '| Backend casing            | `camelCase`' "$file" || echo 'safe-default row: casing'
  grep -qF '| TanStack Query            | `No`' "$file" || echo 'safe-default row: query'
  grep -qF '> | Backend casing ' "$file" || echo 'automatic row: casing'
  grep -qF '> | TanStack Query ' "$file" || echo 'automatic row: query'
  grep -qF -- '- Backend casing (Step 2)' "$file" || echo 'automatic bullet: casing'
  grep -qF -- '- TanStack Query (Step 2)' "$file" || echo 'automatic bullet: query'
  grep -qE 'gaia init configure-data-layer --casing <CASING> --query <QUERY>' "$file" ||
    echo 'step 3 line'
  return 0
}

@test "gaia-init.md carries the data-layer questions, tier rows, defaults, and Step 3 call" {
  run data_layer_gaps "$INIT_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the data-layer check flags each anchor deleted from a scratch copy" {
  local pattern scratch
  for pattern in 'camelCase (Recommended)' 'Not sure' 'No (Recommended)' \
    '| Backend casing            | `camelCase`' '| TanStack Query            | `No`' \
    '> | Backend casing ' '> | TanStack Query ' '- Backend casing (Step 2)' \
    '- TanStack Query (Step 2)' 'configure-data-layer --casing'; do
    scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
    grep -vF -- "$pattern" "$INIT_MD" >"$scratch"
    run data_layer_gaps "$scratch"
    [ -n "$output" ] || {
      printf 'deleting %s was not flagged\n' "$pattern" >&2
      return 1
    }
  done
}

@test "Step 2 asks no rendering-mode question" {
  run bash -c "awk '/^## Step 2:/{on=1} /^## Step 3:/{on=0} on' '$INIT_MD' | grep -E 'SSR|SPA|prerender'"
  [ "$status" -ne 0 ]
}

@test "the rendering-mode check fails when a rendering question is added to a scratch Step 2" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed 's/^### Q7, TanStack Query (asked alone)/Pick SSR or SPA.\n&/' "$INIT_MD" >"$scratch"
  run bash -c "awk '/^## Step 2:/{on=1} /^## Step 3:/{on=0} on' '$scratch' | grep -E 'SSR|SPA|prerender'"
  [ "$status" -eq 0 ]
}
