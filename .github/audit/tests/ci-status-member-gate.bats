#!/usr/bin/env bats

# Guards the member-aware gate on every GAIA-Audit success-status POST in
# .github/workflows/code-review-audit.yml, and the shared gate script
# .github/audit/gate-pending-members.sh that all three consult.
#
# THREE steps can POST `state=success`, and each is a way to clear the required
# GAIA-Audit check and open the github.com merge button:
#
#   1. "Write GAIA-Audit commit status"                  (self-heal push path)
#   2. "Write GAIA-Audit commit status (clean, no push)" (clean-no-commit path)
#   3. "Write GAIA-Audit commit status (out-of-scope skip)" (has_source == false)
#
# FOUR steps can POST `state=pending`, which is the other half of the gate and a
# different set: the three above, PLUS
#
#   4. "Stand down (local-mode, no override)"            (should_run == false)
#
# The pending writers are tested as their own group at the bottom of this file,
# because a `pending` POST clobbers a live `success` (a commit status has no
# compare-and-set) and every one of the four must consult the non-clobber guard
# before writing. Naming all four here is load-bearing: the local-mode stand-down
# shipped unguarded precisely because this suite tested only the steps it names,
# and a suite that never names a step cannot notice it is broken.
#
# What they guard against: stamping success on the FRONTEND member's clearance
# alone. CI runs exactly ONE auditor (the audit step's prompt dispatches
# code-audit-frontend), so every OTHER member the resolver dispatches is
# local-only in CI: CI cannot run it, and its marker lives under gitignored
# .gaia/local/, so CI never sees a clearance for it. Success on the frontend's
# clearance alone defeats the Code Audit Team AND-aggregator and unblocks the
# merge button for a diff a required auditor never read.
#
# Path 3 is the subtle one: "out of scope" there means out of scope for the
# FRONTEND member (has_source mirrors that member's auditable-base set exactly).
# A specialized member's globs sit OUTSIDE that set, so a diff touching only
# framework CLI source or framework bash yields has_source == 'false' while the
# resolver still dispatches a member owning every changed file.
#
# Two invariants the gate script pins, each of which silently re-opens the bypass
# if broken:
#   - Membership is resolved over the FULL PR diff, never the review increment.
#     The incremental audit base advances to the newest ancestor carrying a clean
#     GAIA-Audit trailer, and that trailer is stamped by the frontend agent alone
#     (it is not member-aware), so an increment measured from it can exclude a
#     maintainer-owned file a co-dispatched member never cleared.
#   - Fail-open is LOUD. An unusable resolver yields no pending members (a broken
#     resolver must not brick the merge path), but it says so on stderr, so a
#     disarmed gate is distinguishable from a genuinely clean one.
#
# The step tests EXECUTE the real `run:` body extracted from the workflow YAML
# against a sandbox repo with the real resolver and a mocked `gh`, so they
# exercise shipped code rather than grepping for a string.
#
# Assertion style per .claude/rules/bats-assertions.md: POSIX `[ ]` and `grep -qF`
# for presence; a positive match plus an explicit `return 1` for absence (a
# `!`-negated non-final line never fails a test under `set -e`).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  GATE="$REPO_ROOT/.github/audit/gate-pending-members.sh"
  PRESENT="$REPO_ROOT/.github/audit/audit-success-present.sh"

  # Every spelling `gh` accepts for the pending-state field: the long `--field`
  # and the `-f` / `-F` short forms, whole-pair quoting (`-f 'state=pending'`),
  # and value-quoting (`--field state="pending"`). Match the VALUE, tolerating an
  # optional opening quote, rather than anchoring on any one spelling.
  #
  # This is load-bearing, not pedantry. A pending writer this pattern cannot see
  # is invisible to the lock below, and a writer the lock cannot see is precisely
  # the fourth-writer failure this suite exists to prevent -- arriving again, just
  # under a different spelling. Value-quoting is the likely slip, because the very
  # next argument in each of these `gh api` calls is a quoted `--field
  # description="..."`, so quoting `state` by analogy is a natural mistake.
  #
  # The lock's BOUNDARY, stated so the next author knows what it does and does not
  # promise. The pattern matches exactly one thing: the literal token `state=`, an
  # optional opening quote, then `pending` -- anywhere on the line. It is flag- and
  # tool-agnostic, so a bare `state=pending`, and even a `curl -d state=pending`,
  # match just as the `--field`/`-f`/`-F`/`--raw-field` forms do. What evades it is
  # a writer that never spells that whole token literally: a JSON body (`gh api
  # --input -` carries `"state":"pending"`, no `state=` at all), or a value built
  # indirectly (`--field state="$st"` -- note this DOES carry a literal `state=`
  # and still evades, because the pattern needs the VALUE too, so "does my line
  # contain `state=`?" is the wrong question to ask of it). Such a writer ships
  # unseen. That is a deliberate frontier, not an oversight: closing it fully is a
  # losing arms race against every way a string can be spelled, and all four real
  # writers use the `--field` form, so a fifth would be copied from an adjacent
  # one. Trust the lock exactly this far.
  PENDING_WRITER_RE="state=[\"']?pending"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"
  [ -f "$GATE" ] || skip "gate-pending-members.sh not found"
  [ -f "$PRESENT" ] || skip "audit-success-present.sh not found"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  printf '1.2.3\n' > "$SANDBOX/.gaia/VERSION"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add .gaia/VERSION README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  # The real resolver, the real gate, and the real non-clobber read, so every
  # decision under test is shipped code rather than a fixture of it.
  mkdir -p "$SANDBOX/.gaia/scripts" "$SANDBOX/.github/audit"
  cp "$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh" "$SANDBOX/.gaia/scripts/"
  cp "$GATE" "$SANDBOX/.github/audit/"
  cp "$PRESENT" "$SANDBOX/.github/audit/"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh" \
           "$SANDBOX/.github/audit/gate-pending-members.sh" \
           "$SANDBOX/.github/audit/audit-success-present.sh"

  POST_LOG="$BATS_TEST_TMPDIR/gh-post.log"
  rm -f "$POST_LOG"
  # A real $GITHUB_OUTPUT file, as in CI, so a step that publishes an output can
  # be asserted on. Declared here, not in run_step: bats' `run` executes in a
  # subshell, so an assignment made inside run_step would not survive back here.
  STEP_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  : > "$STEP_OUTPUT"
  # Same subshell caveat: the comment-step stub's log and its $RUNNER_TEMP are
  # declared here so assertions back in the test body can read them.
  COMMENT_LOG="$BATS_TEST_TMPDIR/comment.log"
  rm -f "$COMMENT_LOG"
  RUNNER_TEMP_DIR="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP_DIR"
  install_gh_mock
  install_upsert_stub
}

# Fake `gh` on a prepended PATH: records every `gh api` WRITE argv.
#
# The combined-status READ that each stamp step's non-clobber guard performs
# (`gh api repos/<slug>/commits/<sha>/status`) is served, NOT recorded: $POST_LOG
# is asserted throughout as "what this step WROTE", and several tests assert the
# log does not exist at all. Recording a read there would turn every read into a
# phantom write.
#
# $GH_CANNED_SUCCESS_DESC (exported by a test) is the GAIA-Audit description the
# read returns, standing in for a `success` status the local member-aware
# producer already posted. Unset => the read returns nothing, i.e. no live
# success, which is the pre-existing behavior every older test relies on.
install_gh_mock() {
  # No live success unless a test asks for one. Defensive: a leaked value would
  # silently stand the gate down in an unrelated test.
  unset GH_CANNED_SUCCESS_DESC
  unset GH_STATUS_READ_FAILS
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
record="$POST_LOG"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  api)
    # Reads end in /status (combined status). Writes are POSTs to /statuses/<sha>,
    # which end in the sha, so the two never collide.
    case "$2" in
      */status)
        # Simulate an unreadable status (auth blip, rate limit, network): gh
        # exits non-zero. The guard must treat this as "could not ask", NOT as
        # "no success live".
        if [ -n "${GH_STATUS_READ_FAILS:-}" ]; then
          echo "gh: could not read status" >&2
          exit 1
        fi
        if [ -n "${GH_CANNED_SUCCESS_DESC:-}" ]; then
          printf '%s\n' "$GH_CANNED_SUCCESS_DESC"
        fi
        exit 0
        ;;
    esac
    printf '%s\n' "$*" >> "$record"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# Stand in for a `success` GAIA-Audit status the local producer already posted
# for a given tree. post-audit-status.sh's description shape is "<version> <tree>".
canned_success_for_tree() {
  export GH_CANNED_SUCCESS_DESC="1.2.3 $1"
}

# Make the combined-status READ fail, standing in for a transient API/auth error.
status_read_fails() {
  export GH_STATUS_READ_FAILS=1
}

# Delete the non-clobber guard from the sandbox, so a caller's
# `bash .github/audit/audit-success-present.sh ...` exits 127 rather than
# returning one of the script's own 0/1/2 codes.
#
# This is not a contrived fixture. It stands in for a partial checkout, a botched
# merge, an adopter whose install predates the script -- and, more generally, for
# the fact that the exit space is OPEN: the invocation can fail outside the
# script's contract even when the script itself is correct. A caller that
# enumerates the stand-down codes (`-eq 0`, `-eq 2`) lets every unenumerated one
# fall straight through to the `pending` POST, which is the clobber the guard
# exists to prevent -- restored on exactly the runs where the guard is missing.
remove_guard_script() {
  rm -f "$SANDBOX/.github/audit/audit-success-present.sh"
}

# How many steps in the workflow POST a `pending` GAIA-Audit status. CODE lines
# only: the workflow is dense with prose about this very mechanism, so a comment
# that happened to write the literal string would inflate the count and fail the
# lock on a change that added no writer at all. The tempting repair for that red
# is to bump the expected count -- which would permanently blind the lock to a
# real fifth writer, the same silent blinding this test exists to prevent,
# arriving through the front door. Strip the comments; keep the match loose.
count_pending_writers() {
  grep -v '^[[:space:]]*#' "$WORKFLOW" | grep -cE -- "$PENDING_WRITER_RE"
}

# Stub the PR-comment upsert the terminal status steps shell out to, recording
# the comment text ($2) so a test asserts what the AUTHOR is actually told
# rather than grepping the step's YAML for a phrase.
install_upsert_stub() {
  cat > "$RUNNER_TEMP_DIR/cra-status-upsert.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$COMMENT_LOG"
EOF
  chmod +x "$RUNNER_TEMP_DIR/cra-status-upsert.sh"
}

# Extract one step's `run:` shell body from the workflow YAML and dedent it.
# Matches the `- name:` line EXACTLY, so "Write GAIA-Audit commit status" does
# not also match its "(clean, no push)" / "(out-of-scope skip)" siblings.
extract_step_body() {
  local step_name="$1" out="$BATS_TEST_TMPDIR/step.sh"
  awk -v want="      - name: ${step_name}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$WORKFLOW" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

base_sha() { git -C "$SANDBOX" rev-parse main; }

# app/ + .gaia/cli/src/** -> dispatches code-audit-frontend AND
# code-audit-maintainer-node against the built-in roster.
commit_mixed_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/app" "$SANDBOX/.gaia/cli/src"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  echo "export const y = 2;" > "$SANDBOX/.gaia/cli/src/y.ts"
  git -C "$SANDBOX" add app/x.ts .gaia/cli/src/y.ts
  git -C "$SANDBOX" commit --quiet -m "mixed change"
}

# app/ only -> code-audit-frontend alone: CI can clear it by itself.
commit_app_only_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/app"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" add app/x.ts
  git -C "$SANDBOX" commit --quiet -m "app-only change"
}

# .gaia/cli/src/** only -> has_source == 'false' (the frontend member owns
# nothing here) yet the resolver dispatches code-audit-maintainer-node. This is
# the shape the out-of-scope skip path must NOT wave through.
commit_maintainer_only_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/.gaia/cli/src"
  echo "export const y = 2;" > "$SANDBOX/.gaia/cli/src/y.ts"
  git -C "$SANDBOX" add .gaia/cli/src/y.ts
  git -C "$SANDBOX" commit --quiet -m "maintainer-only change"
}

# docs-only -> no member owns it AND has_source == 'false', so the out-of-scope
# skip step runs past the members-pending branch and reaches the version guard.
commit_docs_only_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/docs"
  echo "# notes" > "$SANDBOX/docs/notes.md"
  git -C "$SANDBOX" add docs/notes.md
  git -C "$SANDBOX" commit --quiet -m "docs only"
}

# The frontend's clean marker is keyed to the TREE it audited, not the commit,
# so pass a tree sha. Keying it to the commit would leave the step's lookup
# empty-handed.
write_frontend_marker() {
  mkdir -p "$SANDBOX/.gaia/local/audit"
  printf '{}' > "$SANDBOX/.gaia/local/audit/$1.ok"
}

sandbox_tree() { git -C "$SANDBOX" rev-parse "HEAD^{tree}"; }

run_gate() { ( cd "$SANDBOX" && bash .github/audit/gate-pending-members.sh "$@" ); }

# Run an extracted step body in the sandbox with the CI env it reads, including a
# real $GITHUB_OUTPUT (declared in setup, asserted on via $STEP_OUTPUT).
run_step() {
  local body="$1" sha="$2"
  ( cd "$SANDBOX" \
    && GITHUB_REPOSITORY="gaia-react/gaia" \
       GITHUB_OUTPUT="$STEP_OUTPUT" \
       HEAD_SHA="$sha" \
       AUDIT_SHA="$sha" \
       PR_BASE_SHA="$(base_sha)" \
       bash "$body" )
}

# Run the terminal comment step's body against the stubbed upsert, with the
# outputs it consumes from the out-of-scope status step bound explicitly.
run_comment_step() {
  local body="$1" members_pending="$2" success_stamped="$3" success_live="${4:-}" read_failed="${5:-}"
  ( cd "$SANDBOX" \
    && RUNNER_TEMP="$RUNNER_TEMP_DIR" \
       PR_NUMBER="1" \
       MEMBERS_PENDING="$members_pending" \
       SUCCESS_STAMPED="$success_stamped" \
       SUCCESS_LIVE="$success_live" \
       READ_FAILED="$read_failed" \
       bash "$body" )
}

# -----------------------------------------------------------------------------
# gate-pending-members.sh, the shared gate
# -----------------------------------------------------------------------------

@test "gate: mixed diff reports the co-dispatched maintainer member as pending" {
  commit_mixed_diff
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-node" <<<"$output"
  # CI runs the frontend member itself, so it is never "pending".
  grep -qF "code-audit-frontend" <<<"$output" && return 1
  return 0
}

@test "gate: app-only diff reports nothing pending (CI can clear it alone)" {
  commit_app_only_diff
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "gate: maintainer-only diff reports the member pending even though has_source is false" {
  commit_maintainer_only_diff
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-node" <<<"$output"
}

@test "gate: an unusable resolver fails open, but says so on stderr" {
  commit_mixed_diff
  rm -f "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"

  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  # Fails open: no members pending, so a broken resolver cannot brick the merge.
  grep -qF "code-audit-maintainer" <<<"$output" && return 1
  # But never silently: the operator can tell a disarmed gate from a clean one.
  grep -qF "failing open" <<<"$output"
}

@test "gate: an unresolvable base fails open loudly, never silently" {
  # The resolver exits 0 on every path by contract, so an unreachable base makes
  # it emit an empty diff -- indistinguishable from a genuinely clean pass unless
  # the gate says so. A shallow clone or a GC'd base must not silently disarm it.
  commit_mixed_diff
  run run_gate --base "0000000000000000000000000000000000000000"
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer" <<<"$output" && return 1
  grep -qF "does not resolve" <<<"$output"
  grep -qF "failing open" <<<"$output"
}

@test "gate: an empty --base fails open loudly instead of silently swapping the base" {
  # An empty value must not alias to "no base given", which would let the
  # resolver self-resolve a DIFFERENT base than the caller pinned.
  commit_mixed_diff
  run run_gate --base ""
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer" <<<"$output" && return 1
  grep -qF "failing open" <<<"$output"
}

@test "gate: an unrecognized argument stops rather than resolving a different base" {
  # The `--base=<sha>` equals form is NOT supported; parsing on would drop the
  # base and silently resolve membership over the resolver's own merge-base.
  commit_mixed_diff
  run run_gate --base="$(base_sha)"
  [ "$status" -eq 0 ]
  # The absence assertion is what pins the "stops" half of this test's name, and
  # it is not redundant with the stderr grep below: `run` merges stdout+stderr,
  # so a gate that warned "failing open" and then parsed on anyway -- emitting a
  # member resolved over the WRONG base -- would satisfy the stderr grep alone.
  # Mirrors the two sibling fail-open tests above.
  grep -qF "code-audit-maintainer" <<<"$output" && return 1
  grep -qF "failing open" <<<"$output"
}

@test "gate: an incremental base that skips the maintainer file shrinks the member set" {
  # Pins WHY the workflow must pass the full-PR base. A base advanced past the
  # maintainer-owned file (what a frontend-only GAIA-Audit trailer would do to
  # the incremental base) yields an empty member set -- the bypass this gate
  # exists to close. The workflow binds PR_BASE_SHA to the PR base for exactly
  # this reason; the binding is asserted in the step tests below.
  commit_mixed_diff
  maintainer_commit="$(git -C "$SANDBOX" rev-parse HEAD)"
  # A later app-only commit; measuring from $maintainer_commit sees only app/.
  echo "export const z = 3;" > "$SANDBOX/app/z.ts"
  git -C "$SANDBOX" add app/z.ts
  git -C "$SANDBOX" commit --quiet -m "app-only follow-up"

  run run_gate --base "$maintainer_commit"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]

  # The full-PR base still sees the maintainer file and holds the gate shut.
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-node" <<<"$output"
}

# -----------------------------------------------------------------------------
# All three status steps bind the FULL-PR base, never the incremental one
# -----------------------------------------------------------------------------

@test "every status step resolves members over the full-PR base" {
  for step in \
    "Write GAIA-Audit commit status" \
    "Write GAIA-Audit commit status (clean, no push)" \
    "Write GAIA-Audit commit status (out-of-scope skip)"
  do
    body="$(extract_step_body "$step")"
    grep -qF 'gate-pending-members.sh --base "${PR_BASE_SHA}"' "$body" || return 1
    # The incremental audit base must never decide membership.
    grep -qF 'gate-pending-members.sh --base "${AUDIT_BASE}"' "$body" && return 1
  done

  # PR_BASE_SHA is the PR's base sha from the event payload, for all three steps.
  run grep -cF 'PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}' "$WORKFLOW"
  [ "$output" -eq 3 ]
}

@test "the local-mode stand-down and the out-of-scope skip take their sha from the event payload, not git rev-parse HEAD" {
  # A bare `git rev-parse HEAD` in the runner can point at a local,
  # never-pushed commit (an empty trailer marker, a refused self-heal), and
  # POSTing a status to a sha GitHub does not have returns HTTP 422. The
  # clean-no-push stamp step already reads HEAD_SHA from the event payload
  # directly, and the self-heal push stamp reads AUDIT_SHA from push-fixes'
  # own event-anchored resolution; these two steps are the last of the four
  # writers to anchor the same way.
  for step in \
    "Stand down (local-mode, no override)" \
    "Write GAIA-Audit commit status (out-of-scope skip)"
  do
    body="$(extract_step_body "$step")"
    grep -qF 'head_sha="${HEAD_SHA}"' "$body" || return 1
    grep -qF 'git rev-parse HEAD)"' "$body" && return 1
  done

  # One HEAD_SHA event-payload binding for each of these two steps, the
  # unrelated source-changes step, the pre-existing clean-no-push stamp, and
  # the progress-breadcrumb print step (resolves the tree the agent keyed its
  # breadcrumb file to, for the same reason: a self-heal commit can move the
  # runner's local HEAD before this step runs).
  run grep -cF 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$WORKFLOW"
  [ "$output" -eq 5 ]
}

# -----------------------------------------------------------------------------
# clean-no-push path
# -----------------------------------------------------------------------------

@test "clean-no-push: mixed diff with only the frontend marker never posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (clean, no push)')"
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  write_frontend_marker "$(sandbox_tree)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "context=GAIA-Audit" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"

  grep -qF "state=success" "$POST_LOG" && return 1

  # The pending description must not carry the cleared "<version> <tree-sha>"
  # shape, so a state-blind reader cannot mistake it for cleared.
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG" && return 1
  return 0
}

@test "clean-no-push: app-only diff with the frontend marker still posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (clean, no push)')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  write_frontend_marker "$(sandbox_tree)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "statuses/${sha}" "$POST_LOG"
  grep -qF "state=success" "$POST_LOG"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG"
}

@test "clean-no-push: mixed diff without the frontend marker posts nothing at all" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (clean, no push)')"
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]
  [ ! -f "$POST_LOG" ]
}

# -----------------------------------------------------------------------------
# self-heal push path
# -----------------------------------------------------------------------------

@test "push path: mixed diff never posts success while a co-dispatched member is pending" {
  body="$(extract_step_body 'Write GAIA-Audit commit status')"
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"

  grep -qF "state=success" "$POST_LOG" && return 1
  return 0
}

@test "push path: app-only diff posts success as before" {
  body="$(extract_step_body 'Write GAIA-Audit commit status')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "statuses/${sha}" "$POST_LOG"
  grep -qF "state=success" "$POST_LOG"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG"
}

# -----------------------------------------------------------------------------
# out-of-scope skip path: "out of scope" is frontend-relative, not team-relative
# -----------------------------------------------------------------------------

@test "out-of-scope skip: maintainer-only diff never posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  commit_maintainer_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"

  # A success here clears the required check for a diff whose only auditor never
  # ran: the merge button opens on wholly un-reviewed framework source.
  grep -qF "state=success" "$POST_LOG" && return 1
  return 0
}

@test "out-of-scope skip: publishes members_pending so the PR comment can tell the truth" {
  # Without this output the terminal comment step tells the author "the merge
  # gate is satisfied with no local audit run" while the status is `pending` and
  # the button is shut -- a green-sounding message over a closed gate.
  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  commit_maintainer_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  grep -qF "members_pending=code-audit-maintainer-node" "$STEP_OUTPUT"

  # The comment step must consume it and drop the free-skip claim.
  comment="$(extract_step_body 'Status - skipped (no source changes)')"
  grep -qF 'MEMBERS_PENDING' "$comment"
  grep -qF "GAIA-Audit is pending, not green" "$comment"
}

@test "out-of-scope skip: a genuinely unowned diff still posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  # docs-only: no member owns it, so the skip is a real skip.
  commit_docs_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "state=success" "$POST_LOG"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG"

  # The stamp really happened, so the comment step is entitled to say the gate is
  # satisfied. This is the true half that the version-guard tests below pin false.
  grep -qF "success_stamped=true" "$STEP_OUTPUT"
}

# -----------------------------------------------------------------------------
# out-of-scope skip: the .gaia/VERSION guard exits WITHOUT posting a status, so
# the terminal comment must not claim a stamp that never landed.
#
# The guard fails CLOSED (no status posted -> the required GAIA-Audit check is
# absent -> the merge button is shut), so this is author confusion, not a bypass.
# But the free-skip comment says "GAIA-Audit commit status stamped on HEAD so the
# merge gate is satisfied with no local audit run", which is the exact opposite
# of what happened, and the only truthful signal is buried in the step log.
#
# Both triggers land on the same `exit 0`: `tr -d '\r' < .gaia/VERSION | awk` is
# a PIPELINE, so a MISSING file leaves awk with no input -- it prints nothing and
# exits 0 -- and the substitution yields "" exactly as an EMPTY file does. Under
# `set -e` neither shape fails the step.
# -----------------------------------------------------------------------------

@test "out-of-scope skip: an empty .gaia/VERSION posts no status and publishes success_stamped=false" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  commit_docs_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  # A botched merge, a partial checkout, an adopter who emptied it.
  : > "$SANDBOX/.gaia/VERSION"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  # Nothing was stamped: the required check is ABSENT, not green.
  [ ! -f "$POST_LOG" ]

  # ...and the step says so, so the comment step can tell this apart from a stamp.
  grep -qF "success_stamped=false" "$STEP_OUTPUT"
}

@test "out-of-scope skip: a missing .gaia/VERSION posts no status and publishes success_stamped=false" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  commit_docs_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  rm -f "$SANDBOX/.gaia/VERSION"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ ! -f "$POST_LOG" ]
  grep -qF "success_stamped=false" "$STEP_OUTPUT"
}

@test "comment: no status stamped means the comment never claims the merge gate is satisfied" {
  body="$(extract_step_body 'Status - skipped (no source changes)')"

  run run_comment_step "$body" "" "false"
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  # The free-skip claim is what #711 is about: it must not survive a no-stamp run.
  grep -qF "the merge gate is satisfied" "$COMMENT_LOG" && return 1
  grep -qF "merge gate is NOT satisfied" "$COMMENT_LOG"
}

@test "comment: an unset success_stamped is read as no-stamp, never as a stamp" {
  # Fail-safe default. If the status step is ever reshaped so the output goes
  # missing, the comment must degrade to the cautious message, not the green one.
  body="$(extract_step_body 'Status - skipped (no source changes)')"

  run run_comment_step "$body" "" ""
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  grep -qF "the merge gate is satisfied" "$COMMENT_LOG" && return 1
  return 0
}

@test "comment: a real stamp still gets the free-skip message" {
  body="$(extract_step_body 'Status - skipped (no source changes)')"

  run run_comment_step "$body" "" "true"
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  grep -qF "the merge gate is satisfied" "$COMMENT_LOG"
  grep -qF "merge gate is NOT satisfied" "$COMMENT_LOG" && return 1
  return 0
}

@test "comment: a pending member still outranks the version guard in the message" {
  # MEMBERS_PENDING is checked first: when a member is pending the status step
  # posted `pending` and never reached the version guard, so that message wins.
  body="$(extract_step_body 'Status - skipped (no source changes)')"

  run run_comment_step "$body" "code-audit-maintainer-node" ""
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  grep -qF "GAIA-Audit is pending, not green" "$COMMENT_LOG"
  grep -qF "the merge gate is satisfied" "$COMMENT_LOG" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# Non-clobbering pending POST
#
# A GitHub commit status has no compare-and-set: for a given context the newest
# write wins outright. CI cannot run a maintainer-only member, so it declines to
# post success and posts `pending`. The LOCAL member-aware producer
# (.claude/hooks/post-audit-status.sh) posts `success` once EVERY dispatched
# member has cleared. Nothing sequences the two writers, so an unconditional
# `pending` here overwrites a legitimate `success`: the required check reverts to
# pending, `gh pr merge` is rejected by branch protection, and nothing re-posts.
# On a PR whose dispatched set is entirely maintainer-only -- the shape of most
# framework-maintenance PRs -- that is the common path, not an edge case.
#
# The guard: skip the pending POST when a GAIA-Audit `success` is already the
# LIVE status on the sha AND carries THIS EXACT TREE. It must still fail CLOSED
# for a stale-tree success and for no success at all.
# -----------------------------------------------------------------------------

@test "non-clobber: out-of-scope skip does NOT overwrite a live success for the current tree" {
  # The #734 headline shape: dispatched set is maintainer-only, so has_source is
  # false and this is the step that fires. The local producer has already cleared
  # every member and posted success.
  commit_maintainer_only_diff
  local sha tree body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  canned_success_for_tree "$tree"

  body="$(extract_step_body "Write GAIA-Audit commit status (out-of-scope skip)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  # The whole point: nothing was written, so the live success survives.
  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "not clobbering" <<<"$output"
}

@test "non-clobber: out-of-scope skip still publishes success_stamped=false when it stands down" {
  # This step stamped nothing on the stand-down path, so it must not claim it did.
  commit_maintainer_only_diff
  local sha tree body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  canned_success_for_tree "$tree"

  body="$(extract_step_body "Write GAIA-Audit commit status (out-of-scope skip)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]
  grep -qF "success_stamped=false" "$STEP_OUTPUT"
}

@test "non-clobber: a STALE success (different tree) does NOT suppress the pending POST" {
  # Fail-closed. A success naming an older tree vouches for content that is no
  # longer what would merge, so it must not stand the gate down.
  commit_maintainer_only_diff
  local sha body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  canned_success_for_tree "0000000000000000000000000000000000000000"

  body="$(extract_step_body "Write GAIA-Audit commit status (out-of-scope skip)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"
  grep -qF "state=success" "$POST_LOG" && return 1
  return 0
}

@test "non-clobber: no live success at all still posts pending (unchanged behavior)" {
  # Regression lock on the pre-existing path: with nothing to protect, the guard
  # is inert and the gate behaves exactly as before.
  commit_maintainer_only_diff
  local sha body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  body="$(extract_step_body "Write GAIA-Audit commit status (out-of-scope skip)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"
}

@test "non-clobber: the self-heal stamp step does NOT overwrite a live success for the current tree" {
  # Mixed diff: has_source is true, so CI runs the frontend member and this is
  # the step that fires, but a maintainer member is co-dispatched and still
  # pending from CI's point of view.
  commit_mixed_diff
  local sha tree body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  canned_success_for_tree "$tree"

  body="$(extract_step_body "Write GAIA-Audit commit status")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "not clobbering" <<<"$output"
}

@test "non-clobber: the clean-no-push stamp step does NOT overwrite a live success for the current tree" {
  commit_mixed_diff
  local sha tree body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  write_frontend_marker "$tree"
  canned_success_for_tree "$tree"

  body="$(extract_step_body "Write GAIA-Audit commit status (clean, no push)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "not clobbering" <<<"$output"
}

@test "non-clobber: the guard never suppresses a legitimate SUCCESS post" {
  # The guard lives only on the members-pending branch. An app-only diff has
  # nothing pending, so the step must still post success even with a live status.
  commit_app_only_diff
  local sha tree body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  canned_success_for_tree "$tree"

  body="$(extract_step_body "Write GAIA-Audit commit status")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=success" "$POST_LOG"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG"
}

@test "non-clobber: an UNREADABLE status stands down instead of posting pending" {
  # The subtle half of the fix. `gh api | grep -q` returns non-zero identically
  # for "no success is live" and "I could not reach the API", so collapsing the
  # two would re-post pending on a transient auth/rate-limit blip and clobber a
  # success it simply failed to see -- reintroducing the bug on exactly the flaky
  # runs where it is hardest to diagnose. Standing down still fails CLOSED: an
  # absent required check blocks the merge just as a pending one does.
  commit_maintainer_only_diff
  local sha body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  status_read_fails

  body="$(extract_step_body "Write GAIA-Audit commit status (out-of-scope skip)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "could not be read" <<<"$output"

  # The step stamped nothing AND could not tell whether a success is already
  # live: publish that so the terminal comment step does not assert "pending,
  # not green", a claim this exit never verified.
  grep -qF "read_failed=true" "$STEP_OUTPUT"
}

@test "non-clobber: an unreadable status stands down on the self-heal stamp step too" {
  commit_mixed_diff
  local sha body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  status_read_fails

  body="$(extract_step_body "Write GAIA-Audit commit status")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "could not be read" <<<"$output"
}

@test "non-clobber: an unreadable status stands down on the clean-no-push stamp step too" {
  commit_mixed_diff
  local sha tree body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  write_frontend_marker "$tree"
  status_read_fails

  body="$(extract_step_body "Write GAIA-Audit commit status (clean, no push)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "could not be read" <<<"$output"
}

@test "non-clobber: the out-of-scope skip publishes success_live=true when it stands down on a live success" {
  commit_maintainer_only_diff
  local sha tree body
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  canned_success_for_tree "$tree"

  body="$(extract_step_body "Write GAIA-Audit commit status (out-of-scope skip)")"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]
  grep -qF "success_live=true" "$STEP_OUTPUT"
}

@test "non-clobber: the PR comment says ALREADY GREEN, not 'run the members locally', when the gate is live" {
  # Asserts what the AUTHOR actually reads, not just the step output. On this
  # path members_pending is still non-empty (CI cannot see a local marker), and
  # the comment step branches on members_pending FIRST -- so without the
  # success_live branch the author is told to clear a merge gate that is already
  # green. Under-claiming is as much a lie as over-claiming.
  local body
  body="$(extract_step_body "Status - skipped (no source changes)")"
  run run_comment_step "$body" "code-audit-maintainer-shell" "false" "true"
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  grep -qF "already green" "$COMMENT_LOG"
  grep -qF "No action needed" "$COMMENT_LOG"
  # The misleading instruction must NOT appear.
  grep -qF "run the dispatched member(s) locally" "$COMMENT_LOG" && return 1
  return 0
}

@test "non-clobber: the PR comment STILL says 'pending' when no success is live (regression)" {
  # The success_live branch must not swallow the genuinely-pending case.
  local body
  body="$(extract_step_body "Status - skipped (no source changes)")"
  run run_comment_step "$body" "code-audit-maintainer-shell" "false" ""
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  grep -qF "pending, not green" "$COMMENT_LOG"
  grep -qF "run the dispatched member(s) locally" "$COMMENT_LOG"
}

@test "read-failed: the PR comment says the gate's state is unknown, not 'pending, not green'" {
  # The status step could not tell whether a success is already live (the
  # non-clobber guard's read failed) and stamped nothing. Asserting "pending,
  # not green" here would be a claim that exit never verified.
  local body
  body="$(extract_step_body "Status - skipped (no source changes)")"
  run run_comment_step "$body" "code-audit-maintainer-shell" "false" "" "true"
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  grep -qF "could not be read, so its state is unknown" "$COMMENT_LOG"
  grep -qF "pending, not green" "$COMMENT_LOG" && return 1
  return 0
}

@test "read-failed: outranks members_pending, exactly as success_live does" {
  # READ_FAILED and SUCCESS_LIVE are both checked before MEMBERS_PENDING, which
  # stays non-empty on this path (CI cannot see a local marker). Without this
  # ordering the members_pending branch would fire first and assert a state
  # this step's own read never established.
  local body
  body="$(extract_step_body "Status - skipped (no source changes)")"
  run run_comment_step "$body" "code-audit-maintainer-shell" "false" "" "true"
  [ "$status" -eq 0 ]

  [ -f "$COMMENT_LOG" ]
  grep -qF "GAIA-Audit is pending, not green" "$COMMENT_LOG" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# The local-mode stand-down: the FOURTH pending writer
#
# The non-clobber guard shipped on three of the four steps that POST `pending`.
# This one -- the step that fires on the most common maintainer path, local audit
# mode with no override label -- POSTed unconditionally, so the clobber it was
# meant to close was still live.
#
# Its `if:` depends only on the label gate, chore-deps, has_source, self_modified
# and should_run. NONE of those change once a `success` is live. The workflow
# triggers on `labeled` and `unlabeled`, which re-run it on the SAME head sha with
# no new push. So:
#
#   1. The author pushes sha S; this step POSTs `pending`.
#   2. The author audits locally; every dispatched member clears and
#      post-audit-status.sh POSTs `success` on S.
#   3. Any label is added or removed. The workflow re-runs on S.
#   4. should_run is still false, this step fires again, and POSTs `pending`
#      straight over the success.
#   5. Branch protection rejects the merge. Nothing re-posts. The gate is stuck
#      shut until a human re-runs the producer by hand.
#
# It fails CLOSED, so it is a stuck gate rather than an unaudited merge -- but it
# is the #734 clobber on the path most maintainers actually take.
# -----------------------------------------------------------------------------

@test "local-mode stand-down: posts pending when no success is live (unchanged behavior)" {
  # Regression lock on the pre-existing behavior: with nothing to protect, the
  # guard is inert and the step blocks the merge exactly as it always has.
  local sha tree body
  body="$(extract_step_body 'Stand down (local-mode, no override)')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "statuses/${sha}" "$POST_LOG"
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "context=GAIA-Audit" "$POST_LOG"

  # The description must not carry the cleared "<version> <tree-sha>" shape, so a
  # state-blind reader cannot mistake this pending for cleared.
  tree="$(sandbox_tree)"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG" && return 1
  return 0
}

@test "local-mode stand-down: does NOT overwrite a live success for the current tree" {
  # The headline shape. The local producer has already cleared every dispatched
  # member and posted success on this exact tree; a re-run of this step (a label
  # touched, no new push) must not write over it.
  local sha body
  body="$(extract_step_body 'Stand down (local-mode, no override)')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  canned_success_for_tree "$(sandbox_tree)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  # The whole point: nothing was written, so the live success survives and the
  # merge button stays open.
  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "not clobbering" <<<"$output"
}

@test "local-mode stand-down: a STALE success (different tree) still posts pending" {
  # Fail-closed, and the reason the guard is keyed to the TREE and not the sha: a
  # success naming an older tree vouches for content that is no longer what would
  # merge, so it must NOT stand this step down. Without this the guard would wave
  # through every push after the first cleared one.
  local sha body
  body="$(extract_step_body 'Stand down (local-mode, no override)')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  canned_success_for_tree "0000000000000000000000000000000000000000"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "context=GAIA-Audit" "$POST_LOG"
}

@test "local-mode stand-down: an UNREADABLE status stands down instead of posting pending" {
  # A transient auth/rate-limit blip must not be read as "no success live". The
  # step has no way to tell those apart from the read alone, so it stands down.
  local sha body
  body="$(extract_step_body 'Stand down (local-mode, no override)')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  status_read_fails

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  grep -qF "could not be read" <<<"$output"
}

# -----------------------------------------------------------------------------
# An unexpected guard exit is unanswerable, never "no success live"
#
# audit-success-present.sh returns 0/1/2 by contract, but the INVOCATION can fail
# outside that contract -- above all with 127 when the script is absent or
# unreadable. A caller that enumerates the stand-down codes (`-eq 0`, `-eq 2`)
# lets 127 fall through and POST `pending` over a live success: the clobber comes
# back, and it comes back precisely on the runs where the guard is broken, which
# is where it is hardest to diagnose.
#
# So every caller tests for a DEFINITIVE 1 and stands down on everything else.
# Each case below cans a live success AND removes the guard: a caller that
# collapses 127 into "no success live" clobbers it, and the test fails.
# -----------------------------------------------------------------------------

@test "missing guard: the local-mode stand-down stands down rather than posting pending" {
  local sha body
  body="$(extract_step_body 'Stand down (local-mode, no override)')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  canned_success_for_tree "$(sandbox_tree)"
  remove_guard_script

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  return 0
}

@test "missing guard: the self-heal stamp step stands down rather than posting pending" {
  local sha body
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  canned_success_for_tree "$(sandbox_tree)"
  remove_guard_script

  body="$(extract_step_body 'Write GAIA-Audit commit status')"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  return 0
}

@test "missing guard: the clean-no-push stamp step stands down rather than posting pending" {
  local sha tree body
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  tree="$(sandbox_tree)"
  write_frontend_marker "$tree"
  canned_success_for_tree "$tree"
  remove_guard_script

  body="$(extract_step_body 'Write GAIA-Audit commit status (clean, no push)')"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  return 0
}

@test "missing guard: the out-of-scope skip stands down rather than posting pending" {
  local sha body
  commit_maintainer_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  canned_success_for_tree "$(sandbox_tree)"
  remove_guard_script

  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ] && grep -qF "state=pending" "$POST_LOG" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# audit-success-present.sh's own exit contract
#
# Every lock above pins the CALLERS. They are only as sound as the exit codes the
# guard hands them, and the guard's contract has exactly one rule: an unanswerable
# question returns 2, NEVER 1. A 1 means "definitively no success live", which is
# the caller's signal to POST `pending` over whatever is currently there. Collapse
# any "could not ask" path into a 1 and the #734 clobber returns at the SOURCE,
# below every call-site lock in this file -- all four callers would be dutifully
# testing `-ne 1` against an answer that is already a lie.
#
# The read-failure path was the only one pinned. Collapsing the usage-error path
# or the gh-absent path to `exit 1` left the whole suite green: a guard that
# cannot ask, reporting "definitively not live", with nothing to catch it. That is
# the same "a suite that never names a path cannot notice it is broken" shape that
# let the fourth pending writer ship unguarded in the first place, pointed this
# time at the guard rather than at its callers.
# -----------------------------------------------------------------------------

@test "guard: no arguments at all is unanswerable (exit 2), never 'no success live'" {
  run bash "$PRESENT"
  [ "$status" -eq 2 ]
}

@test "guard: a missing tree argument is unanswerable (exit 2), never 'no success live'" {
  # An empty tree would make the guard's fixed-string match succeed against ANY
  # description, standing the gate down on a success that vouches for nothing.
  run bash "$PRESENT" "deadbeef"
  [ "$status" -eq 2 ]
}

@test "guard: an absent gh is unanswerable (exit 2), never 'no success live'" {
  # No `gh` on PATH: the guard cannot read the status at all. That is the purest
  # "could not ask" there is, and it must never be reported as "not live".
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$empty_bin"
  run env PATH="$empty_bin" /bin/bash "$PRESENT" "deadbeef" "cafe"
  [ "$status" -eq 2 ]
}

@test "guard: an unresolvable repo slug is unanswerable (exit 2), never 'no success live'" {
  # The THIRD "could not ask" door. With $GITHUB_REPOSITORY unset the
  # guard falls back to `gh repo view` to name the repo; when that yields nothing
  # it has no repo to query and cannot ask. Unset, not empty-string: the script
  # reads `${GITHUB_REPOSITORY:-}`, so an empty value takes the same branch, but
  # unsetting it is the honest shape of "running outside Actions".
  #
  # Pinned because the other three doors are, and a door nobody names is a door
  # nobody notices closing. There is no live failure mode today (every caller is
  # an Actions step, where $GITHUB_REPOSITORY is always set, so this path is
  # unreachable in CI); it goes live the moment anything outside Actions calls the
  # guard -- a hook, a local script, the by-hand debugging its own header invites
  # -- which is exactly the future the other pins were written for.
  run env -u GITHUB_REPOSITORY PATH="$GH_BIN:$PATH" bash "$PRESENT" "deadbeef" "cafe"
  [ "$status" -eq 2 ]
}

@test "guard: an unreadable status is unanswerable (exit 2), never 'no success live'" {
  # The FOURTH door, and the one exit 2 exists for: the status read itself fails
  # (auth blip, rate limit, network). $GITHUB_REPOSITORY is set so this exercises
  # the read failure in isolation, never the unresolved-slug door pinned above.
  status_read_fails
  run env GITHUB_REPOSITORY="gaia-react/gaia" PATH="$GH_BIN:$PATH" bash "$PRESENT" "deadbeef" "cafe"
  [ "$status" -eq 2 ]
}

@test "every step that POSTs pending consults the guard and posts only on a definitive 1" {
  # The structural lock, and the one assertion that would have caught the gap the
  # behavioral tests above missed for a release: a guard is only as good as the
  # set of callers that use it, and a suite that tests three of four writers says
  # nothing about the fourth. Pin the whole set.
  local step body
  for step in \
    "Write GAIA-Audit commit status" \
    "Write GAIA-Audit commit status (clean, no push)" \
    "Write GAIA-Audit commit status (out-of-scope skip)" \
    "Stand down (local-mode, no override)"
  do
    body="$(extract_step_body "$step")"
    # Enumerating the stand-down codes is the bug: `-eq 2` alone lets 127 (and
    # every other unexpected exit) fall through to the POST.
    if grep -qF -- '"$_live" -eq 2' "$body"; then return 1; fi
    grep -qE -- "$PENDING_WRITER_RE" "$body" || return 1
    grep -qF -- "audit-success-present.sh" "$body" || return 1
    grep -qF -- '"$_live" -ne 1' "$body" || return 1
  done

  # ...and these four are the WHOLE set, so the loop above covers every pending
  # writer there is. A fifth added without a guard trips this count.
  run count_pending_writers
  [ "$output" -eq 4 ]
}
