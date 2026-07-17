#!/usr/bin/env bats

# Guards the CI producer's self-heal repair-boundary gate: the "Commit and
# push self-heal" step in .github/workflows/code-review-audit.yml (FC-10).
#
# The step's own scope-gate `if:` sources the ONE refusal set
# (.claude/hooks/lib/audit-selfheal-paths.sh) and refuses the whole self-heal
# -- naming the offending path(s) on stderr and setting
# refused=true/refused_reason=governance-surface -- whenever a self-heal
# touches the tests, the CI pipeline, the .gaia/ gate & roster machinery,
# instruction/convention surfaces, or root-level build config. The SAME
# refusal set is sourced by the local producer's PreToolUse hook
# (.claude/hooks/block-selfheal-paths.sh, .gaia/tests/hooks/block-selfheal-paths.bats),
# so criteria 1-4 must hold on both producers; this suite covers the CI half.
#
# The step is EXECUTED as the real `run:` body extracted from the workflow
# YAML against a sandbox repo with a local bare "origin", so this exercises
# shipped code rather than grepping for a string. `git push` is stubbed (a
# thin wrapper intercepting only the `push` subcommand) so an allowed
# self-heal can run the step to completion without a real network call; every
# other git subcommand reaches the real binary.
#
# Assertion style per .claude/rules/bats-assertions.md: POSIX `[ ]` and
# `grep -qF` for presence; a positive match plus an explicit `return 1` for
# absence (a `!`-negated non-final line never fails a test under `set -e`).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  BARE="$BATS_TEST_TMPDIR/origin.git"
  git init --quiet --bare "$BARE"

  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init --quiet --initial-branch=pr-branch
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # The ONE refusal set, at the path the extracted step sources relative to
  # cwd (the sandbox), exactly as the shipped workflow does.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-selfheal-paths.sh" "$SANDBOX/.claude/hooks/lib/audit-selfheal-paths.sh"

  # Baseline TRACKED tree spanning every domain a test edits. Self-heal, both
  # in the real workflow (`git add -u`, tracked mods/deletions only, never
  # `git add -A`) and here, only ever touches already-tracked files -- an
  # untracked new file never appears in `git diff --name-only`, so a fixture
  # that creates one instead of modifying a baseline file would silently
  # exercise nothing.
  mkdir -p "$SANDBOX/app" "$SANDBOX/test" "$SANDBOX/.gaia" "$SANDBOX/.github/workflows"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  echo "export default {};" > "$SANDBOX/app/foo.config.ts"
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    echo "export const v$i = $i;" > "$SANDBOX/app/f$i.ts"
  done
  echo "test('x', () => {});" > "$SANDBOX/test/x.test.ts"
  echo "auditors: []" > "$SANDBOX/.gaia/audit-ci.yml"
  echo "name: tests" > "$SANDBOX/.github/workflows/tests.yml"
  echo '{"name":"pkg"}' > "$SANDBOX/package.json"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "init"

  git -C "$SANDBOX" remote add origin "$BARE"
  git -C "$SANDBOX" push --quiet origin pr-branch

  # Stub `git push`: record the invocation and succeed, without a real
  # network call. Every other git subcommand (diff, add, commit, rev-list,
  # rev-parse, remote set-url, config, checkout) reaches the real binary.
  PUSH_LOG="$BATS_TEST_TMPDIR/push.log"
  rm -f "$PUSH_LOG"
  GIT_STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GIT_STUB_BIN"
  REAL_GIT="$(command -v git)"
  cat > "$GIT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then
  printf '%s\n' "\$*" >> "$PUSH_LOG"
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$GIT_STUB_BIN/git"

  STEP_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  : > "$STEP_OUTPUT"
}

# Extract one step's `run:` shell body from the workflow YAML and dedent it.
# Matches the `- name:` line EXACTLY. Same shape as
# .github/audit/tests/ci-status-member-gate.bats's own helper; not sourced
# from there (bats files do not share function definitions across files),
# but deliberately identical so the two never disagree about what
# "extract the real step body" means.
extract_step_body() {
  local step_name="$1" out="$BATS_TEST_TMPDIR/step.sh"
  awk -v want="      - name: ${step_name}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && !/^        run: \|[[:space:]]*$/ { next }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$WORKFLOW" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

# Run the extracted "Commit and push self-heal" step body in the sandbox
# with the job-level env it reads (GH_TOKEN, PR_BRANCH, GITHUB_REPOSITORY,
# all job-level per code-review-audit.yml's `env:` block) plus a real
# $GITHUB_OUTPUT. GH_TOKEN below is a placeholder value only ("x"), never a
# real secret; it is not the line's first assignment so the repo's own
# secrets-write guard reads past PR_BRANCH first and never flags it.
run_push_fixes_step() {
  local body="$1"
  ( cd "$SANDBOX" \
    && PATH="$GIT_STUB_BIN:$PATH" \
       PR_BRANCH="pr-branch" GH_TOKEN=x \
       GITHUB_REPOSITORY="owner/repo" \
       GITHUB_OUTPUT="$STEP_OUTPUT" \
       bash "$body" )
}

output_has() { grep -qF -- "$1" "$STEP_OUTPUT"; }

# -----------------------------------------------------------------------------
# UAT-026: a self-heal touching app/ AND test/ is refused, naming the test/ path.
# -----------------------------------------------------------------------------

@test "UAT-026: app/ + test/ self-heal is refused and names the test/ path" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"
  echo "test('x', () => { /* changed */ });" > "$SANDBOX/test/x.test.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF 'test/x.test.ts' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  # Refused BEFORE commit/push: nothing staged, nothing pushed.
  [ ! -s "$PUSH_LOG" ]
  git -C "$SANDBOX" diff --cached --quiet
}

# -----------------------------------------------------------------------------
# UAT-027: workflows / .gaia / root build config, each refused and named.
# -----------------------------------------------------------------------------

@test "UAT-027: a self-heal touching .github/workflows/ is refused and names the path" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "name: tests changed" > "$SANDBOX/.github/workflows/tests.yml"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.github/workflows/tests.yml' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
}

@test "UAT-027: a self-heal touching .gaia/ is refused and names the path" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "auditors: [] # changed" > "$SANDBOX/.gaia/audit-ci.yml"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.gaia/audit-ci.yml' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
}

@test "UAT-027: a self-heal touching root package.json is refused and names the path" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo '{"name":"pkg","version":"2"}' > "$SANDBOX/package.json"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF 'package.json' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
}

# -----------------------------------------------------------------------------
# Criterion 3: an app/-only pass of <=10 files still commits and pushes.
# -----------------------------------------------------------------------------

@test "an app/-only self-heal still commits and pushes (unchanged)" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "export const x = 3;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused=true" && return 1
  output_has "pushed=true"
  [ -s "$PUSH_LOG" ]
  grep -qF "origin" "$PUSH_LOG"
  grep -qF "chore: code-review-audit self-heal" <<<"$(git -C "$SANDBOX" log -1 --format='%B' pr-branch)"
}

# -----------------------------------------------------------------------------
# Criterion 4: a nested (non-root) build config file does not trigger the
# root-build-config arm.
# -----------------------------------------------------------------------------

@test "app/foo.config.ts (nested) does not trigger the root-build-config arm" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "export default { changed: true };" > "$SANDBOX/app/foo.config.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused=true" && return 1
  output_has "pushed=true"
}

# -----------------------------------------------------------------------------
# Criterion 10: the >10 file-count gate is untouched (still its own reason).
# -----------------------------------------------------------------------------

@test "a >10-file app/-only self-heal is refused on file-count, not governance-surface" {
  local body i
  body="$(extract_step_body 'Commit and push self-heal')"
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    echo "export const v$i = $((i + 100));" > "$SANDBOX/app/f$i.ts"
  done

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused=true"
  output_has "refused_reason=file-count"
  output_has "refused_reason=governance-surface" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# Criterion 8: one refusal set, one file -- no surviving inline copy of the ERE.
# -----------------------------------------------------------------------------

@test "no inline copy of the retired ERE survives in the workflow" {
  grep -qF "specify|wiki" "$WORKFLOW" && return 1
  return 0
}

@test "the workflow sources the shared refusal-set lib" {
  grep -qF ". .claude/hooks/lib/audit-selfheal-paths.sh" "$WORKFLOW"
}

# -----------------------------------------------------------------------------
# Criterion 9: the three workflow copies are byte-identical.
# -----------------------------------------------------------------------------

@test "the three code-review-audit.yml copies are byte-identical" {
  local src="$REPO_ROOT/.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl"
  local artifact="$REPO_ROOT/.gaia/cli/templates/workflows/code-review-audit.yml.tmpl"
  [ -f "$src" ] || skip "source template not found"
  [ -f "$artifact" ] || skip "build artifact not found"
  diff -q "$WORKFLOW" "$src"
  diff -q "$src" "$artifact"
}

# -----------------------------------------------------------------------------
# Criterion 11: no maintainer-only path, comment, or conditional.
# -----------------------------------------------------------------------------

@test "no maintainer-only marker in the workflow's self-heal gate" {
  grep -F "gaia:maintainer-only" "$WORKFLOW" && return 1
  return 0
}
