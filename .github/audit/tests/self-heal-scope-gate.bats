#!/usr/bin/env bats

# Guards the CI producer's self-heal repair-boundary gate: the "Commit and
# push self-heal" step in .github/workflows/code-review-audit.yml (FC-10).
#
# The step's own scope-gate `if:` sources the ONE refusal set
# (.claude/hooks/lib/audit-selfheal-paths.sh) and refuses the whole self-heal
# -- naming the offending path(s) on stderr and setting
# refused=true/refused_reason=governance-surface -- whenever a self-heal
# touches the tests, the CI pipeline and the rest of .github/, the .gaia/ gate
# & roster machinery, instruction/convention surfaces, or root-level build
# config; the set itself is AUDIT_SELFHEAL_REFUSE_ERE, and this summary is only
# a summary of it. The SAME
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
# Assertion style per .claude/rules/bats-assertions.md.

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
  mkdir -p "$SANDBOX/app" "$SANDBOX/test" "$SANDBOX/.gaia" "$SANDBOX/.github/workflows" "$SANDBOX/.github/audit"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  echo "export default {};" > "$SANDBOX/app/foo.config.ts"
  # The test surface that lives INSIDE app/, the member's own repair surface:
  # a suite and a story in the tests/ folder the component convention puts
  # them in, and a suite outside one, which vitest still collects on the
  # suffix. Each is driven by its own test below.
  mkdir -p "$SANDBOX/app/components/Button/tests" "$SANDBOX/app/utils"
  echo "test('button', () => {});" > "$SANDBOX/app/components/Button/tests/index.test.tsx"
  echo "export default {title: 'Button'};" > "$SANDBOX/app/components/Button/tests/index.stories.tsx"
  echo "test('format', () => {});" > "$SANDBOX/app/utils/format.test.ts"
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    echo "export const v$i = $i;" > "$SANDBOX/app/f$i.ts"
  done
  echo "test('x', () => {});" > "$SANDBOX/test/x.test.ts"
  echo "auditors: []" > "$SANDBOX/.gaia/audit-ci.yml"
  echo "name: tests" > "$SANDBOX/.github/workflows/tests.yml"
  echo "echo pending" > "$SANDBOX/.github/audit/gate-pending-members.sh"
  echo '{"name":"pkg"}' > "$SANDBOX/package.json"
  # A governance-surface file the PR itself changes, so claude-code-action's
  # untrusted-PR restore is observable at all: an identical copy on both
  # branches restores to a clean tree and exercises nothing.
  echo '{"settings":"pr-branch copy"}' > "$SANDBOX/.claude/settings.json"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "init"

  git -C "$SANDBOX" remote add origin "$BARE"
  git -C "$SANDBOX" push --quiet origin pr-branch

  # The base branch this PR merges into. The action restores .claude/** from
  # origin/<base ref>, and the step compares against it to tell that restore
  # apart from an agent's own edit, so the ref has to exist and has to carry a
  # different copy.
  git -C "$SANDBOX" checkout --quiet -b base-branch
  echo '{"settings":"base-branch copy"}' > "$SANDBOX/.claude/settings.json"
  git -C "$SANDBOX" commit --quiet -am "base branch settings"
  git -C "$SANDBOX" push --quiet origin base-branch
  git -C "$SANDBOX" checkout --quiet pr-branch

  # A governance-surface file this PR ADDS, so the base branch does not carry
  # it. When the agent deletes one of these, the working-tree blob and the base
  # blob are both empty, which a bare blob compare reads as the action's own
  # restore. Pushed, so the committed half of the gate sees nothing either.
  echo '#!/usr/bin/env bash' > "$SANDBOX/.claude/hooks/pr-added.sh"
  git -C "$SANDBOX" add .claude/hooks/pr-added.sh
  git -C "$SANDBOX" commit --quiet -m "PR adds a governance-surface file"
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
# Matches the `- name:` line EXACTLY.
#
# Several other bats files carry a near-identical copy of this helper. None of
# them share it (bats files do not define functions across files), so they are
# kept in agreement about what "extract the real step body" means by hand. The
# live set is DECLARED, in the roster this check owns and enforces:
#
#   .gaia/scripts/check-step-body-extractor-roster.sh
#
# Read that file for the membership criterion and the family. Do not re-derive
# the set with a `git grep` for the `run: |` detector: a copy is free to spell
# that detector any way awk accepts, so the literal decays silently, which is
# exactly how the recipe this replaced missed a live member three times. The
# check enumerates candidates by the two things a copy cannot extract without
# -- naming the workflow, and keying on the six-space step header -- and fails
# on a candidate registered in neither of its tables. Adding a copy means adding
# a roster entry; the build says so.
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
# with the env it reads (GH_TOKEN, PR_BRANCH, GITHUB_REPOSITORY job-level per
# code-review-audit.yml's `env:` block, PR_BASE_REF step-level) plus a real
# $GITHUB_OUTPUT. GH_TOKEN below is a placeholder value only ("x"), never a
# real secret; it is not the line's first assignment so the repo's own
# secrets-write guard reads past PR_BRANCH first and never flags it.
# $2 overrides the base ref, for the case where it does not resolve.
run_push_fixes_step() {
  local body="$1" base_ref="${2:-base-branch}"
  ( cd "$SANDBOX" \
    && PATH="$GIT_STUB_BIN:$PATH" \
       PR_BRANCH="pr-branch" GH_TOKEN=x \
       PR_BASE_REF="$base_ref" \
       GITHUB_REPOSITORY="owner/repo" \
       GITHUB_OUTPUT="$STEP_OUTPUT" \
       bash "$body" )
}

output_has() { grep -qF -- "$1" "$STEP_OUTPUT"; }

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

@test "a self-heal touching .github/audit/ is refused and names the path" {
  # gate-pending-members.sh is run by code-review-audit.yml AFTER the audit
  # step to decide whether GAIA-Audit success is posted. A self-heal that
  # empties its output passes the merge gate while a co-dispatched member
  # never cleared, so the refusal covers .github whole, not .github/workflows
  # alone.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "echo # emptied" > "$SANDBOX/.github/audit/gate-pending-members.sh"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.github/audit/gate-pending-members.sh' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
  git -C "$SANDBOX" diff --cached --quiet
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
# The test surface inside app/. code-audit-frontend repairs app/**, and the
# vitest suite and the Chromatic story that would catch a bad app/ repair live
# there too, so the refusal set reaches them per shape rather than by refusing
# the tree. Each shape is driven on its own, paired with the app/ source edit
# it would ride in on, which is the shape the gate exists to catch: a repair
# and the weakening of its own check in one self-heal commit.
# -----------------------------------------------------------------------------

@test "an app/ repair carrying an app/**/tests/ suite edit is refused and names the suite" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"
  echo "test('button', () => { /* weakened */ });" > "$SANDBOX/app/components/Button/tests/index.test.tsx"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF 'app/components/Button/tests/index.test.tsx' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  # Refused BEFORE commit/push: the app/ half never reaches origin either.
  [ ! -s "$PUSH_LOG" ]
  git -C "$SANDBOX" diff --cached --quiet
}

@test "an app/ repair carrying a story edit is refused and names the story" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"
  echo "export default {title: 'Button', parameters: {chromatic: {disable: true}}};" \
    > "$SANDBOX/app/components/Button/tests/index.stories.tsx"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF 'app/components/Button/tests/index.stories.tsx' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

@test "an app/ suite outside a tests/ folder is refused too (vitest collects on the suffix)" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"
  echo "test('format', () => { /* weakened */ });" > "$SANDBOX/app/utils/format.test.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF 'app/utils/format.test.ts' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

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
  # The count itself, not only the reason token. Every wrong value above the
  # threshold yields the same token, so a reason-only assertion cannot tell a
  # correct count from an over-count, and over-counting is the direction that
  # refuses compliant self-heals.
  output_has "refused_count=11"
  output_has "refused_reason=governance-surface" && return 1
  return 0
}

# The other side of the same boundary. Without it the count could read high by
# any amount and every assertion above would still pass, because the reason and
# the count would both simply be larger.
@test "an exactly-10-file app/-only self-heal is not refused on file-count" {
  local body i
  body="$(extract_step_body 'Commit and push self-heal')"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "export const v$i = $((i + 100));" > "$SANDBOX/app/f$i.ts"
  done

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused_reason=file-count" && return 1
  output_has "pushed=true"
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

@test "the untrusted-PR restore reset covers .claude" {
  # claude-code-action replaces a fixed set of sensitive paths with the base
  # branch's copies before the reviewer runs, and the reset loop puts them
  # back before the scope gate above reads the working tree. .claude leads the
  # action's own restore set and is the one entry the refusal set matches, so
  # dropping it from this loop leaves the action's revert in the tree and the
  # gate reads it as a governance-surface edit, discarding every self-heal on
  # any pull request that touches .claude/** alongside source.
  local list
  list="$(sed -n '/for restored_path in/,/; do/p' "$WORKFLOW")"
  [ -n "$list" ]
  # A standalone word: .claude.json carries its own entry and must not vouch
  # for this one, and neither may a .claude/... path inside a comment. The
  # trailing class admits the `;` that closes the list, so reordering the
  # entries and leaving .claude last does not red a loop that still resets it.
  printf '%s\n' "$list" | grep -qE '(^|[[:space:]])\.claude([[:space:];]|$)'
}

# -----------------------------------------------------------------------------
# The reset above must not erase the evidence the gate reads. .claude is the
# only entry in the reset list the refusal set matches, so an uncommitted agent
# edit under .claude/ would otherwise be reverted and the rest of the self-heal
# staged and pushed, when the run owes a governance-surface refusal.
# -----------------------------------------------------------------------------

@test "an uncommitted .claude/ agent edit is refused, not silently reverted by the restore reset" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  # Neither HEAD's copy nor the base branch's: the agent's own edit.
  echo '{"settings":"agent edited this"}' > "$SANDBOX/.claude/settings.json"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.claude/settings.json' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  # Refused BEFORE commit/push: the app/ half never reaches origin either.
  [ ! -s "$PUSH_LOG" ]
  git -C "$SANDBOX" diff --cached --quiet
}

@test "the action's own .claude/ restore still resets clean and does not refuse" {
  # The false positive the reset was added for. claude-code-action replaces
  # .claude/** with the base branch's copies, which on a PR that legitimately
  # changes them looks exactly like a revert; reading that as an agent edit
  # discards every self-heal on any PR touching .claude/** alongside source.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  git -C "$SANDBOX" show base-branch:.claude/settings.json > "$SANDBOX/.claude/settings.json"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "pushed=true"
  [ -s "$PUSH_LOG" ]
  # The restore was reset away rather than committed.
  git -C "$SANDBOX" diff --quiet -- .claude/settings.json
  grep -qF 'refused=true' "$STEP_OUTPUT" && return 1
  true
}

@test "a committed .claude/ edit is still refused through the origin..HEAD half" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo '{"settings":"agent edited this"}' > "$SANDBOX/.claude/settings.json"
  git -C "$SANDBOX" commit --quiet -am "agent commits a governance-surface edit"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.claude/settings.json' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

@test "an unresolvable base ref refuses the uncommitted .claude/ edit and says why" {
  # Nothing to compare against, so the safe direction is to treat every dirty
  # .claude/ path as an agent edit: refusing surfaces the run for human review,
  # where the alternative pushes an unreviewed governance-surface edit.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  git -C "$SANDBOX" show base-branch:.claude/settings.json > "$SANDBOX/.claude/settings.json"

  run run_push_fixes_step "$body" "no-such-base-branch"
  [ "$status" -eq 0 ]
  grep -qF 'cannot resolve origin/no-such-base-branch' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
}

@test "an unresolvable base ref refuses a .claude/ DELETION too, as its message promises" {
  # The arm's own stderr line claims every uncommitted .claude/ edit is treated
  # as an agent edit. The missing-from-worktree arm is what keeps that promise
  # for a deletion; this case pins the promise rather than the mechanism, so it
  # survives a later refactor of how the loop reaches the same answer.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  rm -f "$SANDBOX/.claude/settings.json"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body" "no-such-base-branch"
  [ "$status" -eq 0 ]
  grep -qF '.claude/settings.json' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

@test "deleting a .claude/ file the base branch lacks is refused, not read as the restore" {
  # Both blobs are empty here -- the working tree because the agent deleted the
  # file, the base because this PR is what added it -- so a bare blob compare
  # calls them equal and the run pushes the rest of a self-heal that removed a
  # governance surface. The reset does restore the file, so nothing forbidden
  # reaches origin; what is lost is the refusal.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  rm -f "$SANDBOX/.claude/hooks/pr-added.sh"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.claude/hooks/pr-added.sh' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

# -----------------------------------------------------------------------------
# The gate judges what the commit can carry, which includes the index. A bare
# `git diff` is worktree-vs-index and the committed half reads origin..HEAD, so
# a path the agent STAGED and never committed was invisible to both while
# `git add -u` and the commit swept it to origin regardless.
# -----------------------------------------------------------------------------

@test "a STAGED refused-surface edit is refused, not swept in by git add -u" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "test('x', () => { /* agent weakened this */ });" > "$SANDBOX/test/x.test.ts"
  git -C "$SANDBOX" add test/x.test.ts
  # One ordinary unstaged edit, which is what makes `git add -u` and the commit
  # run at all and sweep the staged path in with it.
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF 'test/x.test.ts' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

@test "a STAGED .claude/ agent edit is refused rather than erased by the reset" {
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo '{"settings":"agent edited this"}' > "$SANDBOX/.claude/settings.json"
  git -C "$SANDBOX" add .claude/settings.json
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.claude/settings.json' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

@test "a .claude/ edit staged and then reverted in the worktree is still refused" {
  # The index-only spelling of dirty, and the one state `git diff HEAD -- .claude`
  # cannot see: the agent stages an edit and then restores the working-tree copy
  # to HEAD's content, so worktree-vs-HEAD reports nothing and the capture's
  # `--cached` half is the only line that preserves the path for the gate. With
  # that line deleted the run proceeds to commit and push instead of refusing,
  # which is what this test reds on.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo '{"settings":"agent edited this"}' > "$SANDBOX/.claude/settings.json"
  git -C "$SANDBOX" add .claude/settings.json
  git -C "$SANDBOX" show HEAD:.claude/settings.json > "$SANDBOX/.claude/settings.json"
  # Precondition: the worktree matches HEAD under .claude/, so the first
  # spelling of the capture contributes nothing and only the index differs.
  git -C "$SANDBOX" diff --quiet HEAD -- .claude
  # One ordinary unstaged edit, so the unrefused run has something to push and
  # refuse-versus-proceed is observable.
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF '.claude/settings.json' <<<"$output"
  output_has "refused=true"
  output_has "refused_reason=governance-surface"
  [ ! -s "$PUSH_LOG" ]
}

@test "staging the action's own .claude/ restore still resets clean and does not refuse" {
  # The false-positive guard, carried into the staged state: reading the index
  # must not resurrect the restore-is-a-revert misread the reset exists to fix.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  git -C "$SANDBOX" show base-branch:.claude/settings.json > "$SANDBOX/.claude/settings.json"
  git -C "$SANDBOX" add .claude/settings.json
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "pushed=true"
  [ -s "$PUSH_LOG" ]
  grep -qF 'refused=true' "$STEP_OUTPUT" && return 1
  true
}

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
