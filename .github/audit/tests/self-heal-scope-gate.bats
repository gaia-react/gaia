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
# config. AUDIT_SELFHEAL_REFUSE_ERE is the boundary; read it rather than this
# summary of it. The SAME refusal set is sourced by the local producer's
# PreToolUse hook (.claude/hooks/block-selfheal-paths.sh,
# .gaia/tests/hooks/block-selfheal-paths.bats), so criteria 1-4 must hold on
# both producers; this suite covers the CI half.
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

# -----------------------------------------------------------------------------
# Criterion 12: the path enumeration feeding the gate fails CLOSED.
# -----------------------------------------------------------------------------

# Re-stub `git` so exactly ONE enumeration call fails, the way a corrupt object
# store, a ref deleted mid-run, or a leftover index.lock makes it fail. The
# caller passes the exact argv the derivation uses, because the surrounding step
# spells neighbouring calls almost identically -- the .claude/ evidence capture
# uses the same subcommand with a `-- .claude` pathspec, and the ref-existence
# probe guarding the third call is a `rev-parse` -- and every one of those has to
# keep working, or these tests would be exercising a neighbour instead of the
# gate. `push` keeps the setup stub's behaviour, so an unrefused run still
# reaches PUSH_LOG and refuse-versus-push stays observable.
#
# That deconfliction is NOT exhaustive, and the difference matters. The staging
# block further down spells `git diff --cached --name-only -z` and
# `tr '\0' '\n'` byte-identically, so these stubs would break those too; what
# keeps them unreached is only that the refusal `exit 0` sits ahead of that
# block. Move the gate after the staging block, or add a test that expects to
# reach the push path with a stub armed, and a neighbour breaks with no
# assertion naming the drift.
break_enumeration_call() {
  local argv="$1"
  cat > "$GIT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then
  printf '%s\n' "\$*" >> "$PUSH_LOG"
  exit 0
fi
if [ "\$*" = "$argv" ]; then
  echo "fatal: unable to read tree (simulated)" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$GIT_STUB_BIN/git"
}

# The same idea for the enumeration producers that are not git. `$2`, when
# given, is the exact argv that must fail and every other invocation reaches the
# real binary; omitted, every invocation fails. Stubs land in the same directory
# the git stub does, which is what run_push_fixes_step puts on PATH.
# For a command the step calls several times, where only a later call belongs to
# the enumeration. Succeeds for the first $2 invocations, then fails. `mktemp` is
# the case: the .claude/ evidence capture takes the first two, and the
# enumeration's own three follow.
break_command_after() {
  local name="$1" after="$2" real counter
  real="$(command -v "$name")"
  counter="$BATS_TEST_TMPDIR/${name}.calls"
  : > "$counter"
  cat > "$GIT_STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
printf 'x' >> "$counter"
if [ "\$(wc -c < "$counter" | tr -d ' ')" -gt "$after" ]; then
  echo "$name: simulated failure" >&2
  exit 3
fi
exec "$real" "\$@"
EOF
  chmod +x "$GIT_STUB_BIN/$name"
}

# Re-stub `git` so exactly ONE call fails, `push` INCLUDED. break_enumeration_call
# above deliberately keeps `push` succeeding, so refuse-versus-push stays
# observable on every enumeration fixture; the step-abort fixtures below need
# the opposite, because `git push` is one of the commands that abort this step
# and a stub that always succeeds it cannot drive that site at all. The
# failing arm is tested FIRST here for the same reason: a `push` argv has to
# reach it rather than the logging arm.
break_git_call() {
  local argv="$1"
  cat > "$GIT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$*" = "$argv" ]; then
  echo "fatal: simulated failure" >&2
  exit 128
fi
if [ "\$1" = "push" ]; then
  printf '%s\n' "\$*" >> "$PUSH_LOG"
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$GIT_STUB_BIN/git"
}

break_command() {
  local name="$1" argv="${2:-}" real
  real="$(command -v "$name")"
  cat > "$GIT_STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
if [ -z '$argv' ] || [ "\$*" = '$argv' ]; then
  echo "$name: simulated failure" >&2
  exit 3
fi
exec "$real" "\$@"
EOF
  chmod +x "$GIT_STUB_BIN/$name"
}

@test "a failed path enumeration refuses in-band rather than judging a partial list" {
  # The derivation used to end in `| sort -u` inside a command substitution.
  # `shopt inherit_errexit` is off under the step's `bash -e` plus `set -eu`, so
  # a git call failing in there neither aborted the group nor reached the
  # substitution's status: the list came back partial at status 0 and the step
  # fell through to `git add -u` and the push with the refusal never consulted.
  # Refusal is in-band (status 0, outputs written) on purpose: no terminal
  # GAIA-Audit status writer downstream carries `always()`, so a hard failure
  # here would strand the pull request on a required check.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_enumeration_call "diff --name-only -z HEAD"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused=true"
  output_has "refused_reason=path-enumeration-failed"
  [ ! -s "$PUSH_LOG" ]
  git -C "$SANDBOX" diff --cached --quiet
}

@test "a refused-surface edit visible only to the failed enumeration call is never pushed" {
  # The consequence the refusal exists to prevent, rather than the refusal
  # itself. test/x.test.ts is edited in the WORKTREE only, so worktree-vs-HEAD
  # is the one call of the three that can report it; with that call failing, the
  # pre-fix derivation handed the refusal ERE a list the refused path had
  # silently dropped out of, and the self-heal pushed an edit to the tests that
  # would catch its own bad repair.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_enumeration_call "diff --name-only -z HEAD"
  echo "test('x', () => { /* agent edit */ });" > "$SANDBOX/test/x.test.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  # PUSH_LOG first: the harm this fixture exists to catch is the push, and
  # asserting it ahead of the outputs makes the pre-fix failure name it.
  [ ! -s "$PUSH_LOG" ]
  output_has "refused=true"
  git -C "$SANDBOX" diff --cached --quiet
}

@test "a failed origin..HEAD enumeration refuses, not just the worktree spelling" {
  # The committed half. Worktree-vs-HEAD and index-vs-HEAD cannot see a path the
  # self-heal already COMMITTED, so this call is that path's only producer, and
  # a `|| true` on it is the same fail-open the other two just closed: the
  # committed refused-surface path drops out of the list, the ERE matches
  # nothing, and the commit is pushed with the gate silent.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_enumeration_call "diff --name-only -z origin/pr-branch..HEAD"
  echo "test('x', () => { /* agent edit */ });" > "$SANDBOX/test/x.test.ts"
  git -C "$SANDBOX" commit --quiet -am "agent commits a refused-surface edit"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  [ ! -s "$PUSH_LOG" ]
  output_has "refused=true"
  output_has "refused_reason=path-enumeration-failed"
}

@test "an absent origin/<branch> is not an enumeration failure and does not refuse" {
  # The one case the retired `|| true` existed to tolerate, now carried by a
  # ref-existence probe instead. Before the branch's first push there is nothing
  # to diff against, which is an answer rather than a failure, so the step must
  # run past the gate. Drop the probe and let the bare call report its own
  # status, and this refuses every first-push run instead. It does not reach the
  # push: with no origin ref the later `ahead` count is 0 and the step stands
  # down there, which is pre-existing behaviour this gate does not change.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  git -C "$SANDBOX" push --quiet origin --delete pr-branch
  git -C "$SANDBOX" update-ref -d refs/remotes/origin/pr-branch
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  grep -qF 'refused=true' "$STEP_OUTPUT" && return 1
  # Reached the post-gate arm rather than the refusal arm.
  output_has "pushed=false"
}

@test "a failed index-vs-HEAD enumeration refuses, the staged-only producer" {
  # The third git producer. It is the only spelling that sees a path the agent
  # STAGED and never committed, which the suite already treats as load-bearing
  # above; a status discarded here drops exactly that path from the list.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_enumeration_call "diff --cached --name-only -z"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  [ ! -s "$PUSH_LOG" ]
  output_has "refused=true"
  output_has "refused_reason=path-enumeration-failed"
}

@test "a failed NUL-to-newline conversion refuses too, not only the git producers" {
  # `tr` carries every git-produced path into the list the refusal ERE reads, so
  # its failure loses the same paths a failed git call would. Argv-scoped: the
  # untracked-file reporting earlier in the step spells `tr` three other ways,
  # one of them identically, and it is reached only when untracked files exist.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  # -z, though the assertion is emptiness: the path-quoting guard arms on the
  # spelling rather than on what the consumer does with it, and a bare listing
  # here would red it. Emptiness reads the same either way.
  [ -z "$(git -C "$SANDBOX" ls-files --others --exclude-standard -z)" ]
  break_command tr '\0 \n'
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  [ ! -s "$PUSH_LOG" ]
  output_has "refused=true"
  output_has "refused_reason=path-enumeration-failed"
}

@test "a failed read of the preserved .claude/ evidence refuses too" {
  # The fifth producer carries the .claude/ agent edits captured before the
  # untrusted-PR restore erased them from view. Losing it silently is the exact
  # false positive that capture exists to prevent, inverted.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_command cat
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  [ ! -s "$PUSH_LOG" ]
  output_has "refused=true"
  output_has "refused_reason=path-enumeration-failed"
}

@test "a failed sort refuses too: the reduce step, not only the producers" {
  # `sort -u` consumes the list the five producers just built. As a plain
  # assignment from a command substitution it took the substitution's status
  # under `set -eu` and killed the step, which is the stranded-required-check
  # outcome the in-band refusal exists to avoid. It sorts into a file now.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_command sort '-u'
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  [ ! -s "$PUSH_LOG" ]
  output_has "refused=true"
  output_has "refused_reason=path-enumeration-failed"
}

@test "a failed scratch-file allocation refuses too, rather than killing the step" {
  # The enumeration's own three `mktemp` calls, the same plain-assignment shape.
  # Scoped past the first two, which belong to the .claude/ evidence capture
  # earlier in the step. Those two are the step's EXIT trap's problem, not this
  # arm's (criterion 13 below drives them), and the scoping is what keeps the
  # two fixtures distinguishable: reaching them from here would report the
  # generic `step-aborted` where this arm's whole claim is the specific reason.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_command_after mktemp 2
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  [ ! -s "$PUSH_LOG" ]
  output_has "refused=true"
  output_has "refused_reason=path-enumeration-failed"
}

# -----------------------------------------------------------------------------
# Criterion 13: this step cannot end the run with no GAIA-Audit status at all.
#
# Every terminal status writer downstream carries an implicit `success()`, and
# `Status - audit aborted` selects on `steps.audit.outcome != 'success'`, which
# a clean audit followed by a dying self-heal step does not satisfy. So a hard
# abort anywhere in this body left the pull request on a required check that
# never posts, with a re-run diagnosing nothing. The step's EXIT trap converts
# any non-zero exit into the same in-band refusal the named refusals use, under
# `refused_reason=step-aborted`.
#
# Each fixture drives a DIFFERENT call site, chosen to span the three regions
# the named refusals cannot reach: ahead of the enumeration's own status
# capture, outside git entirely, and past the gate's verdict. One site says
# nothing about the others -- the per-call-site arm this trap replaced named a
# hand-kept subset of the step's aborting commands, and left `git add -u`,
# `git commit` and `git push` out of it, the three likeliest to fail for real.
# -----------------------------------------------------------------------------

@test "an abort AHEAD of the enumeration's capture refuses in-band rather than stranding the PR" {
  # `git config user.name`, the first command after the trap is armed and far
  # ahead of any refusal machinery. Nothing captured its status before the trap
  # existed: the step died at 128 with an empty $GITHUB_OUTPUT, and the five
  # terminal status writers were all skipped behind their implicit success().
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_git_call "config user.name gaia-code-review-audit[bot]"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused=true"
  output_has "refused_reason=step-aborted"
  [ ! -s "$PUSH_LOG" ]
  git -C "$SANDBOX" diff --cached --quiet
}

@test "an abort in a NON-git command refuses in-band too" {
  # The .claude/ evidence capture's own `mktemp`, the site this issue named
  # first. Unscoped, so the FIRST invocation fails -- break_command_after's
  # enumeration fixture skips past exactly these two -- which proves the trap
  # is not a git-shaped guard wearing a general name.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_command mktemp
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused=true"
  output_has "refused_reason=step-aborted"
  # The specific reason must NOT be claimed: the enumeration never ran, so
  # reporting path-enumeration-failed here would name a gate that was never
  # reached.
  output_has "refused_reason=path-enumeration-failed" && return 1
  [ ! -s "$PUSH_LOG" ]
}

@test "an abort PAST the gate's verdict refuses in-band and reports pushed=false" {
  # `git push`, the last command in the step and the one most likely to fail for
  # real (auth blip, protected branch, a rejected non-fast-forward). It sits
  # after the scope gate has passed and after the self-heal commit exists, so it
  # is the one site where an abort could plausibly have half-succeeded. The
  # refusal must still say pushed=false, because nothing reached origin.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_git_call "push origin HEAD:pr-branch"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused=true"
  output_has "refused_reason=step-aborted"
  output_has "pushed=true" && return 1
  [ ! -s "$PUSH_LOG" ]
}

@test "a step-abort refusal writes the pair the clean-no-push stamp step selects on" {
  # The composition, rather than either half. `Write GAIA-Audit commit status
  # (clean, no push)` is the only writer an aborted step can reach, and it
  # selects on `pushed != 'true' && marker_only != 'true'`. A refusal that wrote
  # neither output would satisfy that condition by absence and still reach the
  # writer, but a LATER edit setting one of them -- marker_only=true is the
  # tempting one, since a dying step did leave local commits -- would route the
  # abort to the self-heal stamp step instead, which stamps the sha the step
  # never pushed. Pin the pair explicitly for that reason.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  break_git_call "push origin HEAD:pr-branch"
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused_reason=step-aborted"
  output_has "pushed=false"
  output_has "marker_only=false"

  # And the step it therefore reaches still selects on exactly that pair. This
  # half is source text because no suite in this repo can execute a step `if:`
  # condition: extract_step_body reads the `run:` body alone.
  local cond
  cond="$(awk '
    index($0, "- name: Write GAIA-Audit commit status (clean, no push)") { grab=1; next }
    grab && /^      - name: / { exit }
    grab { print }
  ' "$WORKFLOW")"
  grep -qF "steps.push-fixes.outputs.pushed != 'true'" <<<"$cond"
  grep -qF "steps.push-fixes.outputs.marker_only != 'true'" <<<"$cond"
}

@test "the trap stays silent on a named refusal that exits 0" {
  # The other half of "writes only on a non-zero status", on the governance-surface
  # arm; the sibling below drives the push arm. The trap runs on EVERY exit, and
  # each of the step's exit-0 arms writes its outputs immediately before its own
  # `exit` -- the push arm excepted, which writes its outputs and falls off the
  # end of the body, reaching status 0 through the trap rather than through an
  # `exit` statement of its own. A trap that wrote unconditionally would append a second,
  # contradictory refused_reason after the real one and the comment ladder would
  # report whichever GitHub read last. The four arms neither fixture drives are
  # deliberately unpinned: the trap's silence is one `[ "$abort_status" -ne 0 ]`
  # test that does not vary per arm, so a third fixture would re-drive the same
  # branch through a different caller.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "test('x', () => { /* changed */ });" > "$SANDBOX/test/x.test.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "refused_reason=governance-surface"
  output_has "refused_reason=step-aborted" && return 1
  return 0
}

@test "the trap stays silent on a clean self-heal that really pushes" {
  # The success path, which is where an unconditional trap would do the most
  # damage: a `pushed=false` appended after `pushed=true` turns a pushed
  # self-heal into a refusal in the PR comment and sends the stamp to the wrong
  # writer.
  local body
  body="$(extract_step_body 'Commit and push self-heal')"
  echo "export const x = 4;" > "$SANDBOX/app/x.ts"

  run run_push_fixes_step "$body"
  [ "$status" -eq 0 ]
  output_has "pushed=true"
  output_has "refused=true" && return 1
  [ -s "$PUSH_LOG" ]
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
