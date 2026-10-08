#!/usr/bin/env bats

# Tests for the generated per-package Claude settings (SPEC-092 contract C8):
# `gaia packages sync-settings`, `.gaia/scripts/check-settings-drift.sh`, the
# drift and MIG-013 arms of `.githooks/pre-commit`, and the root settings the
# frontend session needs.
#
# Three kinds of case. Reads of the live tree assert the committed shape with jq
# and never run git. Scratch-tree cases copy the code under test into a temp git
# repo, so a mutation never touches this checkout. Failing-state cases drive each
# guard into the state it exists to refuse and assert it refuses.
#
# Git runs the hook directly, so the hook cases do too, with `pnpm` stubbed onto
# PATH. Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  ROOT_SETTINGS="$REPO_ROOT/.claude/settings.json"
  GENERATED="$REPO_ROOT/frontend/.claude/settings.json"
  # shellcheck source=helpers/package-fixture.sh
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  TREE=""
}

teardown() {
  if [ -n "${TREE:-}" ]; then
    rm -rf "$TREE"
  fi
  return 0
}

# build_tree: a scratch git repo carrying the code under test (hook, helper,
# drift script, registry reader, CLI bundle) and the live settings files, with
# the live tree's registry state written as a literal.
build_tree() {
  TREE=$(cd "$(mktemp -d -t settings-drift-XXXXXX)" && pwd -P)
  git -C "$TREE" init --quiet --initial-branch=main
  git -C "$TREE" config user.email "test@example.com"
  git -C "$TREE" config user.name "Test"
  git -C "$TREE" config commit.gpgsign false
  mkdir -p "$TREE/.claude/hooks/lib" "$TREE/.gaia/scripts" "$TREE/.gaia/cli" \
    "$TREE/frontend/.claude" "$TREE/stub-bin"
  cp "$ROOT_SETTINGS" "$TREE/.claude/settings.json"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$TREE/.claude/hooks/lib/"
  cp "$REPO_ROOT/.gaia/scripts/check-settings-drift.sh" "$TREE/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/scripts/precommit-packages.sh" "$TREE/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/cli/gaia" "$TREE/.gaia/cli/gaia"
  cp "$REPO_ROOT/frontend/.claude/settings.json" "$TREE/frontend/.claude/"
  cp "$REPO_ROOT/frontend/.claude/settings.overlay.json" "$TREE/frontend/.claude/"
  write_packages_moved "$TREE"
  printf '#!/bin/sh\nexit 0\n' >"$TREE/stub-bin/pnpm"
  chmod +x "$TREE/stub-bin/pnpm" "$TREE/.gaia/cli/gaia"
  git -C "$TREE" add -A
  git -C "$TREE" commit --quiet -m "baseline"
}

run_drift() {
  run bash "$TREE/.gaia/scripts/check-settings-drift.sh" "$TREE"
}

run_hook() {
  run env PATH="$TREE/stub-bin:$PATH" \
    sh -c 'cd "$1" && "$2"' _ "$TREE" "$REPO_ROOT/.githooks/pre-commit"
}

regenerate() {
  "$TREE/.gaia/cli/gaia" packages sync-settings --repo-root "$TREE" >/dev/null
}

# --- the committed shape ---

@test "root settings carry frontend/ forms of the app-path Edit allows" {
  jq -e '.permissions.allow | index("Edit(frontend/app/**)") != null' "$ROOT_SETTINGS"
  local retired
  for retired in 'Edit(app/**)' 'Edit(test/**)' 'Edit(public/**)' 'Edit(.playwright/**)' 'Edit(.storybook/**)'; do
    jq -e --arg r "$retired" '.permissions.allow | index($r) == null' "$ROOT_SETTINGS"
  done
  local unit
  for unit in agents instructions rules skills; do
    jq -e --arg r "Edit(frontend/.claude/$unit/**)" '.permissions.allow | index($r) != null' "$ROOT_SETTINGS"
  done
}

@test "root settings deny editing the frontend env file and the generated settings, with no .env.* glob" {
  local rule
  for rule in 'Edit(frontend/.env)' 'Edit(frontend/.claude/settings.json)'; do
    jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$ROOT_SETTINGS"
  done
  # A .env.* deny also blocks the tracked, editable .env.example; block-env-write.sh covers it.
  jq -e '.permissions.deny | index("Edit(frontend/.env.*)") == null' "$ROOT_SETTINGS"
}

@test "root settings allow the explicit pnpm -C forms and never the blanket ones" {
  local rule
  for rule in 'Bash(pnpm -C frontend typecheck:*)' 'Bash(pnpm -C frontend lint)' \
    'Bash(pnpm -C frontend exec playwright test:*)' 'Bash(pnpm -C .gaia/cli bundle)'; do
    jq -e --arg r "$rule" '.permissions.allow | index($r) != null' "$ROOT_SETTINGS"
  done
  for rule in 'Bash(pnpm -C frontend:*)' 'Bash(pnpm -C frontend exec:*)' 'Bash(pnpm -C .gaia/cli:*)'; do
    jq -e --arg r "$rule" '.permissions.allow | index($r) == null' "$ROOT_SETTINGS"
  done
}

@test "the generated file carries every root PreToolUse hook command verbatim" {
  local command_json count=0
  while IFS= read -r command_json; do
    [ -n "$command_json" ] || continue
    count=$((count + 1))
    jq -e --argjson c "$command_json" '[.hooks.PreToolUse[]?.hooks[]?.command] | index($c) != null' "$GENERATED"
  done < <(jq -c '.hooks.PreToolUse[]?.hooks[]?.command' "$ROOT_SETTINGS")
  [ "$count" -gt 0 ]
  [ "$count" -eq "$(jq '[.hooks.PreToolUse[]?.hooks[]?.command] | length' "$GENERATED")" ]
}

@test "the generated file re-anchors the root denies to the frontend launch dir" {
  local pair root_form anchored
  for pair in 'Edit(.env)|Edit(../.env)' \
    'Edit(frontend/.env)|Edit(../frontend/.env)' \
    'Edit(.gaia/local/audit/*.ok)|Edit(../.gaia/local/audit/*.ok)' \
    'Edit(pnpm-lock.yaml)|Edit(../pnpm-lock.yaml)'; do
    root_form="${pair%%|*}"
    anchored="${pair#*|}"
    jq -e --arg r "$root_form" '.permissions.deny | index($r) != null' "$ROOT_SETTINGS"
    jq -e --arg r "$anchored" '.permissions.deny | index($r) != null' "$GENERATED"
    jq -e --arg r "$root_form" '.permissions.deny | index($r) == null' "$GENERATED"
  done
  jq -e '.sandbox.filesystem.denyRead | index("../.env") != null' "$GENERATED"
  jq -e '.sandbox.filesystem.denyRead | index("**/.env") != null' "$GENERATED"
  jq -e '.permissions.additionalDirectories == [".."]' "$GENERATED"
}

@test "the generated file copies hooks and statusLine byte for byte" {
  [ "$(jq -cS '.hooks' "$ROOT_SETTINGS")" = "$(jq -cS '.hooks' "$GENERATED")" ]
  [ "$(jq -c '.statusLine' "$ROOT_SETTINGS")" = "$(jq -c '.statusLine' "$GENERATED")" ]
}

@test "the committed tree passes the drift check" {
  run bash "$REPO_ROOT/.gaia/scripts/check-settings-drift.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF -- "check-settings-drift: clean" <<<"$output"
}

# --- the drift check can fail ---

@test "a changed root hook command without regenerating is drift naming the generated file" {
  build_tree
  jq '.hooks.PreToolUse[0].hooks[0].command = "other.sh"' "$TREE/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "frontend/.claude/settings.json" <<<"$output"
  git -C "$TREE" add .claude/settings.json
  run_hook
  [ "$status" -ne 0 ]
  grep -qF -- "packages sync-settings" <<<"$output"
  regenerate
  git -C "$TREE" add frontend/.claude/settings.json
  run_drift
  [ "$status" -eq 0 ]
  run_hook
  [ "$status" -eq 0 ]
}

@test "mutating only the overlay is drift" {
  build_tree
  printf '{"permissions":{"allow":["Edit(extra/**)"]}}\n' >"$TREE/frontend/.claude/settings.overlay.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "frontend/.claude/settings.json" <<<"$output"
  git -C "$TREE" add frontend/.claude/settings.overlay.json
  run_hook
  [ "$status" -ne 0 ]
  regenerate
  run_drift
  [ "$status" -eq 0 ]
  jq -e '.permissions.allow | index("Edit(extra/**)") != null' "$TREE/frontend/.claude/settings.json"
}

@test "the presence assertion fails on a dropped deny even when the generator reports clean" {
  build_tree
  # A generator that always agrees with itself: only the independent jq
  # assertion is left to notice the missing entry.
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  jq '.permissions.deny |= map(select(. != "Edit(../.env)"))' "$TREE/frontend/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/frontend/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "frontend/.claude/settings.json is missing" <<<"$output"
  grep -qF -- "Edit(../.env)" <<<"$output"
}

@test "the presence assertion fails on a dropped hook command and a dropped additionalDirectories" {
  build_tree
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  jq 'del(.hooks.PreToolUse[0].hooks[0]) | del(.permissions.additionalDirectories)' "$TREE/frontend/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/frontend/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "PreToolUse hook command" <<<"$output"
  grep -qF -- 'additionalDirectories entry ".."' <<<"$output"
}

# set_handler_if <settings file> <hook index> <if rule>: set one PreToolUse handler's if.
set_handler_if() {
  jq --argjson i "$2" --arg r "$3" '.hooks.PreToolUse[0].hooks[$i]["if"] = $r' "$1" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$1"
}

@test "the presence assertion fails on a generated handler that dropped the root's if" {
  build_tree
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "frontend/.claude/settings.json is missing" <<<"$output"
  grep -qF -- "$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$TREE/.claude/settings.json")" <<<"$output"
  grep -qF -- '"Bash(git *)"' <<<"$output"
}

@test "the presence assertion fails on a generated handler whose if was rewritten" {
  build_tree
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  set_handler_if "$TREE/frontend/.claude/settings.json" 0 'Bash(gh *)'
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "frontend/.claude/settings.json is missing" <<<"$output"
  grep -qF -- "$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$TREE/.claude/settings.json")" <<<"$output"
  grep -qF -- '"Bash(git *)"' <<<"$output"
}

@test "the presence assertion fails when one of two same-command handlers is missing from the generated file" {
  build_tree
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  # The generated file carries the handler with the first rule only; the root
  # also carries a copy of it with a second rule.
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  set_handler_if "$TREE/frontend/.claude/settings.json" 0 'Bash(git *)'
  jq '.hooks.PreToolUse[0].hooks += [.hooks.PreToolUse[0].hooks[0] | .["if"] = "Bash(gh pr merge *)"]' \
    "$TREE/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "frontend/.claude/settings.json is missing" <<<"$output"
  grep -qF -- "$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$TREE/.claude/settings.json")" <<<"$output"
  grep -qF -- '"Bash(gh pr merge *)"' <<<"$output"
  grep -qF -- '"Bash(git *)"' <<<"$output" && return 1
  true
}

@test "the presence assertion passes when root and generated agree on command and if" {
  build_tree
  printf '#!/bin/sh\nexit 0\n' >"$TREE/.gaia/cli/gaia"
  set_handler_if "$TREE/.claude/settings.json" 0 'Bash(git *)'
  set_handler_if "$TREE/frontend/.claude/settings.json" 0 'Bash(git *)'
  run_drift
  [ "$status" -eq 0 ]
  grep -qF -- "check-settings-drift: clean" <<<"$output"
}

# deny_guards_with_if <settings file>: prints "<event> <script>" for every deny guard
# handler that carries an if. The filter is best-effort and the guards' verb arming
# is fail-closed, so none may carry one.
deny_guards_with_if() {
  jq -r '.hooks | to_entries[] | .key as $event | .value[] | .hooks[]
    | select(.["if"]) | (.command | capture("hooks/(?<name>[^\"]+)").name) as $name
    | select($name | test("^(block-.*|pr-merge-audit-check|worthiness-presence-check|red-verify-commit-check)\\.sh$"))
    | "\($event) \($name)"' "$1"
}

@test "no deny guard handler in the root or generated settings carries an if" {
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | test("hooks/block-"))] | length' "$ROOT_SETTINGS")" -gt 0 ]
  [ -z "$(deny_guards_with_if "$ROOT_SETTINGS")" ]
  [ -z "$(deny_guards_with_if "$GENERATED")" ]
}

@test "the deny-guard if check reports a deny guard handler given an if" {
  build_tree
  jq '(.hooks.PreToolUse[].hooks[] | select(.command | test("hooks/block-no-verify.sh"))) |= . + {"if": "Bash(git *)"}' \
    "$TREE/.claude/settings.json" >"$TREE/changed.json"
  mv "$TREE/changed.json" "$TREE/.claude/settings.json"
  run deny_guards_with_if "$TREE/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "PreToolUse block-no-verify.sh" ]
}

@test "a missing generated file fails the drift check" {
  build_tree
  rm "$TREE/frontend/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "frontend/.claude/settings.json" <<<"$output"
}

@test "the drift check refuses to run without the CLI bundle" {
  build_tree
  rm "$TREE/.gaia/cli/gaia"
  run_drift
  [ "$status" -eq 2 ]
  grep -qF -- "Next step" <<<"$output"
}

@test "a malformed registry makes the drift check exit 2, never clean" {
  build_tree
  printf '[{"name":"frontend"}]\n' >"$TREE/.gaia/packages.json"
  run_drift
  [ "$status" -eq 2 ]
  grep -qF -- "gaia-packages" <<<"$output"
}

# --- generation guards (CLI, driven through the real bundle) ---

assert_generation_refused() {
  local before after
  before=$(cksum <"$TREE/frontend/.claude/settings.json")
  run "$TREE/.gaia/cli/gaia" packages sync-settings --repo-root "$TREE"
  [ "$status" -eq 2 ]
  grep -qF -- "settings_generation_failed" <<<"$output"
  after=$(cksum <"$TREE/frontend/.claude/settings.json")
  [ "$before" = "$after" ]
}

@test "an overlay with a hooks key fails generation and writes nothing" {
  build_tree
  printf '{"hooks":{}}\n' >"$TREE/frontend/.claude/settings.overlay.json"
  assert_generation_refused
  grep -qF -- 'overlay key \"hooks\"' <<<"$output"
}

@test "an overlay with a sandbox key fails generation and writes nothing" {
  build_tree
  printf '{"sandbox":{}}\n' >"$TREE/frontend/.claude/settings.overlay.json"
  assert_generation_refused
  grep -qF -- 'overlay key \"sandbox\"' <<<"$output"
}

@test "an overlay allow entry equal to a root deny entry is a removal attempt" {
  build_tree
  printf '{"permissions":{"allow":["Edit(pnpm-lock.yaml)"]}}\n' >"$TREE/frontend/.claude/settings.overlay.json"
  assert_generation_refused
  grep -qF -- "re-open what the root denies" <<<"$output"
}

@test "an overlay rule path with a command substitution fails the charset check" {
  build_tree
  printf '{"permissions":{"allow":["Edit(a$(x))"]}}\n' >"$TREE/frontend/.claude/settings.overlay.json"
  assert_generation_refused
  grep -qF -- "characters outside" <<<"$output"
}

@test "a hostile registry package path fails generation" {
  build_tree
  local hostile
  for hostile in 'front end' 'frontend/../x'; do
    printf '[{"name":"frontend","path":"%s"}]\n' "$hostile" >"$TREE/.gaia/packages.json"
    run "$TREE/.gaia/cli/gaia" packages sync-settings --repo-root "$TREE"
    [ "$status" -eq 2 ]
    grep -qF -- "malformed" <<<"$output"
  done
}

# --- MIG-013: no new files under a retired root path ---

@test "a new root app/ file is refused naming its frontend/ equivalent" {
  build_tree
  mkdir -p "$TREE/app"
  printf 'x\n' >"$TREE/app/x.tsx"
  git -C "$TREE" add app/x.tsx
  run_hook
  [ "$status" -ne 0 ]
  grep -qF -- "app/x.tsx -> frontend/app/x.tsx" <<<"$output"
}

@test "every retired root directory is refused" {
  build_tree
  local directory
  for directory in app test public .playwright .storybook; do
    mkdir -p "$TREE/$directory"
    printf 'x\n' >"$TREE/$directory/new.ts"
    git -C "$TREE" add "$directory/new.ts"
    run_hook
    [ "$status" -ne 0 ]
    grep -qF -- "$directory/new.ts -> frontend/$directory/new.ts" <<<"$output"
    git -C "$TREE" rm --cached --quiet "$directory/new.ts"
  done
}

@test "a new frontend/app file is not refused by the retired-path block" {
  build_tree
  mkdir -p "$TREE/frontend/app"
  printf 'x\n' >"$TREE/frontend/app/x.tsx"
  git -C "$TREE" add frontend/app/x.tsx
  run_hook
  [ "$status" -eq 0 ]
  grep -qF -- "running lint-staged" <<<"$output"
}

@test "the retired-path block stands down while a package is registered at the root" {
  build_tree
  write_packages_today "$TREE"
  rm -rf "$TREE/frontend/gaia.package.json"
  mkdir -p "$TREE/app"
  printf 'x\n' >"$TREE/app/x.tsx"
  git -C "$TREE" add app/x.tsx
  run_hook
  [ "$status" -eq 0 ]
}

@test "a C13-exempt rename staged alone is not refused" {
  build_tree
  mkdir -p "$TREE/frontend/app"
  mkdir -p "$TREE/app"
  printf 'content that is long enough to keep rename detection exact\n' >"$TREE/app/y.ts"
  git -C "$TREE" add app/y.ts
  git -C "$TREE" commit --quiet -m "legacy file"
  git -C "$TREE" mv app/y.ts frontend/app/y.ts
  run_hook
  [ "$status" -eq 0 ]
  grep -qF -- "migration renames staged" <<<"$output"
}
