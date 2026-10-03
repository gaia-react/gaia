#!/usr/bin/env bats

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/wiki-session-stop.sh"
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $REPO to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Stage a fixture repo whose session started at its current HEAD and then
# committed one change to PATH_TO_COMMIT. Sets REPO and START.
stage_session_commit() {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO" || return 1
  START=$(git rev-parse HEAD)
  echo "$START" > "$(git rev-parse --git-dir)/claude-session-start"
  echo "note" >> "$1"
  git add "$1"
  git commit --quiet -m "feat: touch $1"
}

# --- uncommitted wiki/ edits: helpers ---

# start_session DIR STOP_HOOK: run the start hook that sits beside STOP_HOOK, so
# the baselines come from the code under test rather than a hand-written
# marker, and a mutated library is seen by both hooks.
start_session() {
  (cd "$1" && bash "$(dirname "$2")/wiki-session-start.sh" < /dev/null > /dev/null 2>&1)
}

# stop_output DIR HOOK: everything HOOK writes (stdout and stderr) when run from DIR.
stop_output() {
  (cd "$1" && bash "$2" < /dev/null 2>&1) || true
}

# Fixture with a clean wiki/ and a frontend/ subdirectory to run from.
new_fixture() {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  mkdir -p "$REPO/frontend"
}

# install_mutated_hook NAME: copy the real Stop and start hooks and their library into a
# scratch tree under $BATS_TEST_TMPDIR and echo the scratch hooks directory.
# The caller edits the copy; the real files are never touched.
install_mutated_hook() {
  local scratch="$BATS_TEST_TMPDIR/$1/.claude/hooks"
  mkdir -p "$scratch/lib"
  cp "$HOOK_ABSOLUTE_PATH" "$scratch/wiki-session-stop.sh"
  cp "$HOOKS_SOURCE_DIRECTORY/wiki-session-start.sh" "$scratch/wiki-session-start.sh"
  cp "$HOOKS_SOURCE_DIRECTORY/lib/wiki-dirty-fingerprint.sh" "$scratch/lib/wiki-dirty-fingerprint.sh"
  echo "$scratch"
}

# The assertion bodies below take the Stop hook under test as an argument so
# the same body judges the real hook and a mutated copy. Every line ends in
# `|| return 1`: the mutation cases run them inside `run`, where a bare
# failing line would not abort the function.

# assert_modified_page_fires_once SUBDIRECTORY HOOK
assert_modified_page_fires_once() {
  new_fixture
  start_session "$REPO" "$2" || return 1
  echo "edit" >> "$REPO/wiki/index.md"
  local first second
  first=$(stop_output "$REPO/$1" "$2")
  grep -qF -- 'WIKI_CHANGED' <<<"$first" || return 1
  second=$(stop_output "$REPO/$1" "$2")
  [ -z "$second" ] || return 1
}

# assert_new_page_fires_once SUBDIRECTORY HOOK
assert_new_page_fires_once() {
  new_fixture
  start_session "$REPO" "$2" || return 1
  echo "# new" > "$REPO/wiki/new-page.md"
  local first second
  first=$(stop_output "$REPO/$1" "$2")
  grep -qF -- 'WIKI_CHANGED' <<<"$first" || return 1
  second=$(stop_output "$REPO/$1" "$2")
  [ -z "$second" ] || return 1
}

# assert_excluded_path_silent RELATIVE_PATH HOOK
assert_excluded_path_silent() {
  new_fixture
  start_session "$REPO" "$2" || return 1
  mkdir -p "$(dirname "$REPO/$1")" || return 1
  echo "churn" > "$REPO/$1"
  local result
  result=$(stop_output "$REPO" "$2")
  [ -z "$result" ] || return 1
}

# assert_further_edit_fires_once HOOK
assert_further_edit_fires_once() {
  new_fixture
  echo "dirty before start" >> "$REPO/wiki/index.md"
  start_session "$REPO" "$1" || return 1
  echo "dirtier during session" >> "$REPO/wiki/index.md"
  local first second
  first=$(stop_output "$REPO" "$1")
  grep -qF -- 'WIKI_CHANGED' <<<"$first" || return 1
  second=$(stop_output "$REPO" "$1")
  [ -z "$second" ] || return 1
}

@test "no session-start marker: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session committed nothing: silent" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  head=$(git rev-parse HEAD)
  git_directory=$(git rev-parse --git-dir)
  echo "$head" > "$git_directory/claude-session-start"
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session committed only non-wiki paths with stale wiki state: silent, no marker" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  start=$(git rev-parse HEAD)
  git_directory=$(git rev-parse --git-dir)
  echo "$start" > "$git_directory/claude-session-start"
  for i in 1 2 3; do
    echo "$i" >> bar.txt
    git add bar.txt
    git commit --quiet -m "feat: $i"
  done
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$start","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f .claude/wiki-safety-checked ] && return 1
  return 0
}

@test "session committed wiki paths: WIKI_CHANGED line" {
  stage_session_commit wiki/index.md
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  grep -qF -- 'WIKI_CHANGED' <<<"$output" || return 1
  grep -qF -- 'wiki/hot.md' <<<"$output" || return 1
  return 0
}

@test "WIKI_CHANGED fires once per session: a second stop is silent" {
  stage_session_commit wiki/index.md
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  grep -qF -- 'WIKI_CHANGED' <<<"$output" || return 1

  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "WIKI_CHANGED fires with no stdin at all" {
  stage_session_commit wiki/index.md
  run bash -c 'bash "$1" < /dev/null' _ "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  grep -qF -- 'WIKI_CHANGED' <<<"$output" || return 1
  return 0
}

@test "malformed stdin: silent exit 0" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  start=$(git rev-parse HEAD)
  git_directory=$(git rev-parse --git-dir)
  echo "$start" > "$git_directory/claude-session-start"
  echo "x" >> qux.txt
  git add qux.txt
  git commit --quiet -m "x"
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$start","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  invoke_hook 'not-json{{' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the hook carries no deferral-library sourcing, end-of-session reminder, or safety marker" {
  deferral_name="gaia""-ci-defer"
  reminder_tag="[wiki end-of""-session]"
  grep -qF -- "$deferral_name" "$HOOK_ABSOLUTE_PATH" && return 1
  grep -qF -- "$reminder_tag" "$HOOK_ABSOLUTE_PATH" && return 1
  grep -qF -- 'wiki-safety-checked' "$HOOK_ABSOLUTE_PATH" && return 1
  return 0
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

# --- uncommitted wiki/ edits ---

@test "tracked wiki page modified and uncommitted: fires once, from the repository root" {
  assert_modified_page_fires_once "" "$HOOK_ABSOLUTE_PATH"
}

@test "tracked wiki page modified and uncommitted: fires once, from frontend/" {
  assert_modified_page_fires_once "frontend" "$HOOK_ABSOLUTE_PATH"
}

@test "new untracked wiki file: fires once, from the repository root" {
  assert_new_page_fires_once "" "$HOOK_ABSOLUTE_PATH"
}

@test "new untracked wiki file: fires once, from frontend/" {
  assert_new_page_fires_once "frontend" "$HOOK_ABSOLUTE_PATH"
}

@test "a non-ASCII untracked wiki page is fingerprinted and a further edit fires again" {
  new_fixture
  start_session "$REPO" "$HOOK_ABSOLUTE_PATH"
  echo "# first" > "$REPO/wiki/café.md"
  first=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  grep -qF -- 'WIKI_CHANGED' <<<"$first" || return 1
  second=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  [ -z "$second" ] || return 1
  echo "further edit" >> "$REPO/wiki/café.md"
  third=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  grep -qF -- 'WIKI_CHANGED' <<<"$third"
}

@test "a wiki page already dirty when the session started stays silent" {
  new_fixture
  echo "dirty before start" >> "$REPO/wiki/index.md"
  echo "# untracked before start" > "$REPO/wiki/draft.md"
  start_session "$REPO" "$HOOK_ABSOLUTE_PATH"
  result=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  [ -z "$result" ]
}

@test "wiki/hot.md churn alone stays silent" {
  assert_excluded_path_silent wiki/hot.md "$HOOK_ABSOLUTE_PATH"
}

@test "wiki/log.md churn alone stays silent" {
  assert_excluded_path_silent wiki/log.md "$HOOK_ABSOLUTE_PATH"
}

@test "wiki/.state.json churn alone stays silent" {
  assert_excluded_path_silent wiki/.state.json "$HOOK_ABSOLUTE_PATH"
}

@test "wiki/.obsidian churn alone stays silent" {
  assert_excluded_path_silent wiki/.obsidian/workspace.json "$HOOK_ABSOLUTE_PATH"
}

@test "a further edit to a page already dirty at start fires once" {
  assert_further_edit_fires_once "$HOOK_ABSOLUTE_PATH"
}

@test "a wiki change committed this session still fires on a clean start" {
  new_fixture
  start_session "$REPO" "$HOOK_ABSOLUTE_PATH"
  echo "committed edit" >> "$REPO/wiki/index.md"
  git -C "$REPO" add wiki/index.md
  git -C "$REPO" commit --quiet -m "docs: wiki edit"
  result=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  grep -qF -- 'WIKI_CHANGED' <<<"$result"
}

@test "an absent baseline seeds silently and a later distinct edit fires once" {
  new_fixture
  start_session "$REPO" "$HOOK_ABSOLUTE_PATH"
  rm "$REPO/.git/claude-session-wiki-dirty"
  echo "edit before the first stop" >> "$REPO/wiki/index.md"
  first=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  [ -z "$first" ]
  [ -s "$REPO/.git/claude-session-wiki-dirty" ]
  echo "a later distinct edit" >> "$REPO/wiki/index.md"
  second=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  grep -qF -- 'WIKI_CHANGED' <<<"$second" || return 1
  third=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  [ -z "$third" ]
}

@test "a change both committed and left dirty prints the reminder exactly once" {
  new_fixture
  start_session "$REPO" "$HOOK_ABSOLUTE_PATH"
  echo "committed edit" >> "$REPO/wiki/index.md"
  git -C "$REPO" add wiki/index.md
  git -C "$REPO" commit --quiet -m "docs: wiki edit"
  echo "# left dirty" > "$REPO/wiki/draft.md"
  result=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  reminder_count=$(grep -cF -- 'WIKI_CHANGED' <<<"$result" || true)
  [ "$reminder_count" -eq 1 ]
}

@test "the dirty check runs when the session marker is missing" {
  new_fixture
  start_session "$REPO" "$HOOK_ABSOLUTE_PATH"
  rm "$REPO/.git/claude-session-start"
  echo "edit" >> "$REPO/wiki/index.md"
  result=$(stop_output "$REPO" "$HOOK_ABSOLUTE_PATH")
  grep -qF -- 'WIKI_CHANGED' <<<"$result"
}

# --- these guards can fail ---
# Each mutated copy re-creates one regression, and the assertion body that
# judges the real hook must go red on it.

@test "guard: a path-only fingerprint fails the further-edit assertion" {
  scratch=$(install_mutated_hook mutation-path-only)
  library="$scratch/lib/wiki-dirty-fingerprint.sh"
  sed -e 's/--no-color --binary --/--no-color --name-only --/' \
    -e 's|hash-object -- "\$root/\$untracked_path"|hash-object -- /dev/null|' \
    "$library" > "$library.mutated"
  mv "$library.mutated" "$library"
  grep -qF -- '--name-only' "$library" || return 1
  run assert_further_edit_fires_once "$scratch/wiki-session-stop.sh"
  [ "$status" -ne 0 ]
}

@test "guard: a fingerprint without the exclusion list fails the excluded-path assertion" {
  scratch=$(install_mutated_hook mutation-no-exclusions)
  library="$scratch/lib/wiki-dirty-fingerprint.sh"
  sed -E "s/ ?':\(exclude\)[^']*'//g" "$library" > "$library.mutated"
  mv "$library.mutated" "$library"
  grep -qF -- '(exclude)' "$library" && return 1
  run assert_excluded_path_silent wiki/hot.md "$scratch/wiki-session-stop.sh"
  [ "$status" -ne 0 ]
}

@test "guard: a cwd-relative wiki gate fails the frontend/ assertion" {
  scratch=$(install_mutated_hook mutation-cwd-gate)
  hook="$scratch/wiki-session-stop.sh"
  sed -e 's|^\[ -d "\$root/wiki" \] \|\| exit 0$|[ -d wiki ] \|\| exit 0|' "$hook" > "$hook.mutated"
  mv "$hook.mutated" "$hook"
  grep -qF -- '[ -d wiki ] || exit 0' "$hook" || return 1
  run assert_modified_page_fires_once "frontend" "$hook"
  [ "$status" -ne 0 ]
  # The same mutation still passes from the repository root, so the red above
  # is the frontend/ cwd and not a broken copy.
  run assert_modified_page_fires_once "" "$hook"
  [ "$status" -eq 0 ]
}
