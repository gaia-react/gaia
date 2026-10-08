#!/usr/bin/env bats

# End-to-end tests for .githooks/pre-push: a real `git push` over a copy of the
# real tracked tree, with the real verification runner and the real
# distribution checks (the staging build with its release-scrub leak check,
# 01-files-present and 03-marker-strip). The stubbed suite beside this one
# owns the hook's ref filtering; this one owns what a maintainer sees when a
# push breaks a distribution check, and that nothing the hook or the runner
# adds reaches an adopter.
#
# The fixture is the working tree as it stands, tracked files plus the
# untracked ones under test, committed as `main` and pushed to a bare
# `origin`, so the code under test is exercised before it is committed. It
# is built once per file and copied per test. Every test pays real staging
# builds, which is why the cases stay few.
#
# The suite's outcome depends on tracked files it does not name (the staged
# tree is every tracked file), so it carries the whole-tree mark.

# bats file_tags=whole-tree

setup_file() {
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  BASE_FIXTURE="$BATS_FILE_TMPDIR/base"
  BASE_ORIGIN="$BATS_FILE_TMPDIR/base-origin.git"
  export BASE_FIXTURE BASE_ORIGIN

  mkdir -p "$BASE_FIXTURE"
  # A path tracked but deleted in the working tree makes rsync exit 23 for
  # that one entry and copy the rest; any other status is a real failure.
  local copy_status=0
  git -C "$SOURCE_ROOT" ls-files -z --cached --others --exclude-standard \
    | rsync -a --from0 --files-from=- "$SOURCE_ROOT/" "$BASE_FIXTURE/" || copy_status=$?
  [ "$copy_status" -eq 0 ] || [ "$copy_status" -eq 23 ]

  # The dispatch gate hook is edited by a sibling task while this suite is
  # written; the committed copy is the stable one.
  git -C "$SOURCE_ROOT" show HEAD:.claude/hooks/audit-loop-bound.sh > "$BASE_FIXTURE/.claude/hooks/audit-loop-bound.sh"

  git init --quiet --initial-branch=main "$BASE_FIXTURE"
  git -C "$BASE_FIXTURE" config user.email "test@example.com"
  git -C "$BASE_FIXTURE" config user.name "Test"
  git -C "$BASE_FIXTURE" config commit.gpgsign false
  git -C "$BASE_FIXTURE" add -A
  git -C "$BASE_FIXTURE" -c core.hooksPath=/dev/null commit --quiet -m "fixture main"

  git init --quiet --bare --initial-branch=main "$BASE_ORIGIN"
  git -C "$BASE_FIXTURE" remote add origin "$BASE_ORIGIN"
  git -C "$BASE_FIXTURE" -c core.hooksPath=/dev/null push --quiet origin main
  git -C "$BASE_FIXTURE" fetch --quiet origin

  # Every test below relies on these two being tracked on the fixture's main.
  [ -n "$(git -C "$BASE_FIXTURE" ls-files -z -- .githooks/pre-push | tr -d '\0')" ]
  [ -n "$(git -C "$BASE_FIXTURE" ls-files -z -- .gaia/tests/verify-harness.sh | tr -d '\0')" ]
}

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  rsync -a "$BASE_FIXTURE/" "$REPO/"
  rsync -a "$BASE_ORIGIN/" "$ORIGIN/"
  git -C "$REPO" remote set-url origin "$ORIGIN"
  # The commits and pushes a test makes to prepare its branches run with hooks
  # disabled; only the push under test goes through the hook.
}

enable_hook() {
  git -C "$REPO" config core.hooksPath .githooks
}

# commit_all <message>
commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" -c core.hooksPath=/dev/null commit --quiet -m "$1"
}

# manifest_path_matching <jq select expression over the path string>
manifest_path_matching() {
  jq -r --arg expression "$1" '.files | keys[] | select(test($expression))' "$REPO/.gaia/manifest.json" | head -n 1
}

# remote_has_branch <branch>
remote_has_branch() {
  git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$1" > /dev/null
}

# push_branch <branch>: sets $output and $status through bats `run`.
push_branch() {
  run git -C "$REPO" push origin "$1"
}

# path_without <tool>: a PATH directory holding every command of the current
# PATH except the named one.
path_without() {
  local farm="$BATS_TEST_TMPDIR/farm" path_directory
  rm -rf "$farm"
  mkdir -p "$farm"
  local saved_separator="$IFS"
  IFS=:
  for path_directory in $PATH; do
    IFS="$saved_separator"
    [ -d "$path_directory" ] || continue
    ln -s "$path_directory"/* "$farm"/ 2> /dev/null || true
  done
  IFS="$saved_separator"
  rm -f "${farm:?}/$1"
  printf '%s\n' "$farm"
}

@test "a branch that deletes a manifest-listed file is refused before the ref reaches the remote" {
  enable_hook
  missing_path="$(manifest_path_matching '^wiki/concepts/')"
  [ -n "$missing_path" ]
  git -C "$REPO" checkout --quiet -b feat/missing
  rm "$REPO/$missing_path"
  commit_all "delete a shipped file"

  push_branch feat/missing
  [ "$status" -ne 0 ]
  grep -qF -- "01-files-present" <<<"$output"
  grep -qF -- "$missing_path" <<<"$output"
  grep -qF -- "reproduce: bash .gaia/tests/distribution/01-files-present.sh" <<<"$output"
  if remote_has_branch feat/missing; then return 1; fi
}

@test "a shipped agent file referencing a maintainer-only path is refused by the leak check" {
  enable_hook
  agent_path=".claude/agents/code-audit-frontend.md"
  [ "$(manifest_path_matching "^${agent_path//./\\.}\$")" = "$agent_path" ]
  git -C "$REPO" checkout --quiet -b feat/leak
  printf '\nSee .claude/rules/maintainers/harness-triage-threshold.md for the threshold.\n' >> "$REPO/$agent_path"
  commit_all "reference a maintainer-only rule"

  push_branch feat/leak
  [ "$status" -ne 0 ]
  grep -qE -- '^FAIL  release-scrub leak check' <<<"$output"
  grep -qF -- "excluded-refs" <<<"$output"
  grep -qF -- "$agent_path" <<<"$output"
  grep -qE -- "\[excluded-refs\] ${agent_path//./\\.}:[0-9]+ +\.claude/rules/maintainers" <<<"$output"
  grep -qF -- 'reproduce: bash .gaia/tests/distribution/lib/build-staging.sh "$(mktemp -d)"' <<<"$output"
  if remote_has_branch feat/leak; then return 1; fi
}

@test "a shipped script gaining a runtime dependency on a file that never ships is refused by the leak check" {
  enable_hook
  script_path=".claude/hooks/lib/gaia-packages.sh"
  [ "$(manifest_path_matching "^${script_path//./\\.}\$")" = "$script_path" ]
  git -C "$REPO" checkout --quiet -b feat/runtime-dependency
  printf '\nbash .gaia/scripts/helper-that-never-ships.sh\n' >> "$REPO/$script_path"
  commit_all "depend on a script no manifest entry names"

  push_branch feat/runtime-dependency
  [ "$status" -ne 0 ]
  grep -qE -- '^FAIL  release-scrub leak check' <<<"$output"
  grep -qF -- "runtime-dependency leaks" <<<"$output"
  grep -qF -- "$script_path" <<<"$output"
  grep -qF -- ".gaia/scripts/helper-that-never-ships.sh" <<<"$output"
  grep -qF -- 'reproduce: bash .gaia/tests/distribution/lib/build-staging.sh "$(mktemp -d)"' <<<"$output"
  if remote_has_branch feat/runtime-dependency; then return 1; fi
}

@test "an unbalanced maintainer-only marker is attributed to the leak check and skips the later staging checks" {
  enable_hook
  rule_path=".claude/rules/context-discipline.md"
  [ "$(manifest_path_matching "^${rule_path//./\\.}\$")" = "$rule_path" ]
  git -C "$REPO" checkout --quiet -b feat/marker
  printf '\n<!-- gaia:maintainer-only:start -->\nOnly the start.\n' >> "$REPO/$rule_path"
  commit_all "open a maintainer-only block and never close it"

  push_branch feat/marker
  [ "$status" -ne 0 ]
  grep -qE -- '^FAIL  release-scrub leak check' <<<"$output"
  grep -qF -- "$rule_path" <<<"$output"
  grep -qE -- '^SKIP  03-marker-strip: staging build failed' <<<"$output"
  grep -qF -- 'reproduce: bash .gaia/tests/distribution/lib/build-staging.sh "$(mktemp -d)"' <<<"$output"
  if remote_has_branch feat/marker; then return 1; fi
}

@test "a failure already on main warns that main is red and the push proceeds" {
  missing_path="$(manifest_path_matching '^wiki/concepts/')"
  [ -n "$missing_path" ]
  git -C "$REPO" rm --quiet "$missing_path"
  commit_all "main already lacks a shipped file"
  git -C "$REPO" -c core.hooksPath=/dev/null push --quiet origin main
  git -C "$REPO" fetch --quiet origin
  enable_hook

  git -C "$REPO" checkout --quiet -b feat/unrelated
  printf 'an unrelated change\n' > "$REPO/unrelated-note.txt"
  commit_all "an unrelated change"

  push_branch feat/unrelated
  [ "$status" -eq 0 ]
  grep -qE -- '^PRE-EXISTING  01-files-present' <<<"$output"
  grep -qF -- "main is red" <<<"$output"
  remote_has_branch feat/unrelated
}

@test "a clean push lists only the distribution checks and never starts bats or shellcheck" {
  enable_hook
  git -C "$REPO" checkout --quiet -b feat/clean
  # A whole-tree suite that always fails, and a script shellcheck flags. Both
  # sit under the release-excluded test directory, so staging is unaffected.
  # The mark line is assembled so this file holds no second copy of it.
  {
    printf '#!/usr/bin/env bats\n'
    printf '# bats %s\n' 'file_tags=whole-tree'
    printf '@test "always red" {\n  false\n}\n'
  } > "$REPO/.gaia/tests/lib/zz-broken-whole-tree.bats"
  printf '#!/usr/bin/env bash\necho $1\n' > "$REPO/.gaia/tests/zz-shellcheck-bait.sh"
  commit_all "a broken suite and a shellcheck finding"

  shim="$BATS_TEST_TMPDIR/shim"
  tool_log="$BATS_TEST_TMPDIR/tool.log"
  mkdir -p "$shim"
  : > "$tool_log"
  for tool in bats shellcheck; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nexit 0\n' "$tool" "$tool_log" > "$shim/$tool"
    chmod +x "$shim/$tool"
  done

  run env PATH="$shim:$PATH" git -C "$REPO" push origin feat/clean
  [ "$status" -eq 0 ]
  grep -qE -- '^PASS  01-files-present \([0-9]+s\)' <<<"$output"
  grep -qE -- '^PASS  release-scrub leak check \([0-9]+s\)' <<<"$output"
  grep -qE -- '^PASS  03-marker-strip \([0-9]+s\)' <<<"$output"
  grep -qE -- '(shell-lint|bats whole-tree|bats selected)' <<<"$output" && return 1
  [ ! -s "$tool_log" ]
  remote_has_branch feat/clean
}

@test "without rsync all three distribution checks are skipped, never passed, and the push proceeds" {
  enable_hook
  git -C "$REPO" checkout --quiet -b feat/no-rsync
  printf 'a change\n' > "$REPO/note.txt"
  commit_all "a change"

  run env PATH="$(path_without rsync)" git -C "$REPO" push origin feat/no-rsync
  [ "$status" -eq 0 ]
  grep -qE -- '^WARN  rsync not found: install with brew install rsync' <<<"$output"
  grep -qF -- "CI remains the only check" <<<"$output"
  grep -qE -- '^SKIP  release-scrub leak check: rsync not found' <<<"$output"
  grep -qE -- '^SKIP  01-files-present: rsync not found' <<<"$output"
  grep -qE -- '^SKIP  03-marker-strip: rsync not found' <<<"$output"
  grep -qE -- '^PASS  ' <<<"$output" && return 1
  remote_has_branch feat/no-rsync
}

@test "without jq only 01-files-present is skipped and the other two checks run" {
  enable_hook
  git -C "$REPO" checkout --quiet -b feat/no-jq
  printf 'a change\n' > "$REPO/note.txt"
  commit_all "a change"

  run env PATH="$(path_without jq)" git -C "$REPO" push origin feat/no-jq
  [ "$status" -eq 0 ]
  grep -qE -- '^WARN  jq not found: install with brew install jq' <<<"$output"
  grep -qE -- '^SKIP  01-files-present: jq not found' <<<"$output"
  grep -qE -- '^PASS  release-scrub leak check \([0-9]+s\)' <<<"$output"
  grep -qE -- '^PASS  03-marker-strip \([0-9]+s\)' <<<"$output"
  grep -qE -- '^PASS  01-files-present' <<<"$output" && return 1
  remote_has_branch feat/no-jq
}

@test "nothing the hook or the runner adds ships, and the shipped hooks match the source less their maintainer-only blocks" {
  # The exclusion below is not vacuous: both files are tracked on the fixture.
  [ -n "$(git -C "$REPO" ls-files -z -- .githooks/pre-push | tr -d '\0')" ]
  [ -n "$(git -C "$REPO" ls-files -z -- .gaia/tests/verify-harness.sh | tr -d '\0')" ]

  staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  run bash "$REPO/.gaia/tests/distribution/lib/build-staging.sh" "$staging"
  [ "$status" -eq 0 ]

  [ ! -e "$staging/.githooks/pre-push" ]
  [ ! -e "$staging/.gaia/tests/verify-harness.sh" ]
  [ ! -e "$staging/.gaia/tests/helpers/verify-pass-record.sh" ]
  [ ! -e "$staging/.gaia/tests/whole-tree-mark-guard.sh" ]

  manifest_hooks="$(jq -r '.files | keys[] | select(startswith(".githooks/"))' "$staging/.gaia/manifest.json" | LC_ALL=C sort)"
  staged_hooks="$(cd "$staging" && find .githooks -type f | LC_ALL=C sort)"
  [ -n "$manifest_hooks" ]
  [ "$staged_hooks" = "$manifest_hooks" ]
  # A hook carrying a maintainer-only block ships with exactly that block
  # removed; every other hook ships byte-identical. At least one hook carries
  # a block, so the stripped arm is exercised rather than vacuous.
  stripped_count=0
  while IFS= read -r hook_path; do
    if grep -qF -- '# gaia:maintainer-only:start' "$REPO/$hook_path"; then
      stripped_count=$((stripped_count + 1))
      sed '/^# gaia:maintainer-only:start$/,/^# gaia:maintainer-only:end$/d' "$REPO/$hook_path" > "$BATS_TEST_TMPDIR/expected-hook"
      cmp "$staging/$hook_path" "$BATS_TEST_TMPDIR/expected-hook"
    else
      cmp "$staging/$hook_path" "$REPO/$hook_path"
    fi
  done <<<"$manifest_hooks"
  [ "$stripped_count" -gt 0 ]
}
