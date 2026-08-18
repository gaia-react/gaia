#!/usr/bin/env bats
# Tests for the disposition backstop: the shared lib
# (.claude/hooks/lib/audit-dispositions.sh: disposition_offenders,
# disposition_seed_forward) and the standalone deterministic gate hook
# (.claude/hooks/audit-disposition-check.sh) that re-keys the sidecar to the
# frontend content digest.
#
# The lib-level tests source the lib directly and call its functions in
# isolation. The hook-level tests drive the REAL hook by absolute path
# ($HOOK_ABS) with cwd set to a fixture git repo, exactly as the harness runs
# it: a PreToolUse JSON payload on stdin, allow vs deny carried in stdout (the
# hook always exits 0; a deny emits `"permissionDecision": "deny"`). Because
# the hook resolves its own libs relative to `${BASH_SOURCE[0]}`, it always
# loads the REAL classifier/digest/clearance libs against the FIXTURE repo's
# tree, never a stale copy.
#
# `gh` is mocked on a prepended PATH per test. Assertion style
# (.claude/rules/bats-assertions.md): `grep -q` / `[ ]` / explicit `return 1`.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  LIB="$REPO_ROOT/.claude/hooks/lib/audit-dispositions.sh"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/audit-disposition-check.sh"
  DIGEST_CLI="$REPO_ROOT/.gaia/scripts/audit-member-digest.sh"
  [ -f "$LIB" ] || skip "audit-dispositions.sh not present"
  [ -f "$HOOK_ABS" ] || skip "audit-disposition-check.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    skip "no sha256 tool"
  fi
  # shellcheck source=/dev/null
  . "$LIB"
  SIDECAR="$BATS_TEST_TMPDIR/head.dispositions.json"
}

# install_gh_mock MODE [ISSUES_JSON]:
#   ok <json>   -> `gh issue list ...` prints ISSUES_JSON, exit 0
#   fail        -> `gh issue list ...` exits non-zero (backend unreachable)
install_gh_mock() {
  local mode="$1" issues="${2:-[]}"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  printf '%s' "$issues" > "$BATS_TEST_TMPDIR/issues.json"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
mode="$mode"
issues_file="$BATS_TEST_TMPDIR/issues.json"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  issue)
    [ "$mode" = "fail" ] && exit 1
    cat "$issues_file"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

write_sidecar() { printf '%s\n' "$1" > "$SIDECAR"; }

# ---------------------------------------------------------------------------
# disposition_offenders: the two deny conditions (unchanged signature/behavior)
# ---------------------------------------------------------------------------

@test "offenders: a pending(definitive) entry is an offender (no backend needed)" {
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=a line=1","disposition":"pending","pending_reason":"definitive"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "pending(definitive): v1 class=x path=a line=1" <<<"$output" || return 1
}

@test "offenders: keys on pending_reason definitive, never on a severity" {
  # A pending entry with a transient reason is NOT an offender even at high severity.
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=a line=1","severity":"critical","disposition":"pending","pending_reason":"transient"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: a filed key with no matching issue on a reachable backend is an offender" {
  install_gh_mock ok '[]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "filed-but-missing: v1 class=y path=b line=2" <<<"$output" || return 1
}

@test "offenders: a CLOSED matching issue is a satisfied disposition, not an offender" {
  install_gh_mock ok '[{"number":9,"body":"title\n\n<!-- gaia-debt-key: v1 class=y path=b line=2 -->"}]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: a filed line=4 key is NOT satisfied by a sibling line=42 issue (the -->boundary guard)" {
  install_gh_mock ok '[{"number":9,"body":"title\n\n<!-- gaia-debt-key: v1 class=y path=b line=42 -->"}]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=4","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "filed-but-missing: v1 class=y path=b line=4" <<<"$output" || return 1
}

@test "offenders: a filed line=4 key IS satisfied by an exact line=4 issue" {
  install_gh_mock ok '[{"number":9,"body":"title\n\n<!-- gaia-debt-key: v1 class=y path=b line=4 -->"}]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=4","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# disposition_offenders: the machinery_waived abuse-check
#
# audit_path_is_machinery is resolved lazily by the lib from its own on-disk
# dir (setup() sources only audit-dispositions.sh), so these call the function
# in isolation and it self-loads the real machinery set. No backend query.
# ---------------------------------------------------------------------------

@test "offenders: a machinery_waived entry whose path IS machinery is NOT an offender" {
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=.claude/hooks/lib/audit-machinery.sh line=5","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: a machinery_waived entry whose path is NOT machinery IS an offender" {
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=app/x.ts line=5","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "machinery-waived-not-eligible: v1 class=holistic/x path=app/x.ts line=5" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# disposition_offenders: fail-open everywhere else
# ---------------------------------------------------------------------------

@test "fail-open: no sidecar -> clean" {
  run disposition_offenders "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: unparseable sidecar -> clean" {
  write_sidecar 'not json {'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: backend absent -> clean (even with a filed entry)" {
  write_sidecar '{"schema":1,"backend":"absent","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: gh absent -> filed checks skipped (no offender)" {
  # No gh on PATH (mock not installed); filed check fails open.
  PATH="$BATS_TEST_TMPDIR/empty-bin:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  # Only assert the filed arm is fail-open by removing gh: run in a shell whose
  # PATH lacks gh. If gh is genuinely present system-wide this still returns
  # clean because the issue list is queried and, absent a match, would flag; so
  # instead force the unreachable path with a failing mock.
  install_gh_mock fail
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: gh returns non-zero (unreachable backend) -> no filed offender" {
  install_gh_mock fail
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# disposition_seed_forward: deterministic still-open union (replaces the
# deleted disposition_merge; no anchor selection, no ancestry, no backend
# precedence).
# ---------------------------------------------------------------------------

@test "seed-forward: a filed entry from prev is written through into a missing new sidecar" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed"}]}' > "$PREV"
  rm -f "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  [ -f "$SIDECAR" ]
  [ "$(jq -r '.findings[] | select(.key=="K1") | .disposition' "$SIDECAR")" = "filed" ]
}

@test "seed-forward: a pending(definitive) entry is still-open and is seeded" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K2","disposition":"pending","pending_reason":"definitive"}]}' > "$PREV"
  rm -f "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  [ "$(jq -r '.findings[] | select(.key=="K2") | .disposition' "$SIDECAR")" = "pending" ]
}

@test "seed-forward: waived / diverted / machinery_waived / pending(transient) are NOT still-open and are not seeded" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[
    {"key":"W1","disposition":"waived"},
    {"key":"D1","disposition":"diverted"},
    {"key":"M1","disposition":"machinery_waived"},
    {"key":"P1","disposition":"pending","pending_reason":"transient"}
  ]}' > "$PREV"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[]}' > "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  n="$(jq -r '.findings | length' "$SIDECAR")"
  [ "$n" -eq 0 ]
}

@test "seed-forward: HEAD's fresh entry wins on a key collision; a seeded entry only ADDS keys" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed"},{"key":"K2","disposition":"filed"}]}' > "$PREV"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"waived"}]}' > "$SIDECAR"

  disposition_seed_forward "$PREV" "$SIDECAR"

  # K1 keeps HEAD's fresh value (waived), never the seeded one (filed).
  k1="$(jq -r '.findings[] | select(.key=="K1") | .disposition' "$SIDECAR")"
  [ "$k1" = "waived" ]
  # Exactly one K1 entry (no duplicate).
  n_k1="$(jq -r '[.findings[] | select(.key=="K1")] | length' "$SIDECAR")"
  [ "$n_k1" -eq 1 ]
  # K2 (prev-only, still-open) was ADDED.
  k2="$(jq -r '.findings[] | select(.key=="K2") | .disposition' "$SIDECAR")"
  [ "$k2" = "filed" ]
}

@test "seed-forward: fail-safe no-op on a missing prev sidecar" {
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K9","disposition":"filed"}]}' > "$SIDECAR"
  before="$(snapshot_file "$SIDECAR")"
  disposition_seed_forward "$BATS_TEST_TMPDIR/does-not-exist.json" "$SIDECAR"
  after="$(snapshot_file "$SIDECAR")"
  assert_files_identical "$before" "$after"
}

@test "seed-forward: fail-safe no-op on an unparseable prev sidecar" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf 'not json {' > "$PREV"
  rm -f "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  [ ! -f "$SIDECAR" ]
}

@test "seed-forward: fail-safe no-op when jq is unavailable" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed"}]}' > "$PREV"
  rm -f "$SIDECAR"
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  # PATH is scoped to the child bash -c subshell only: replacing it in the
  # test's own process would also strip PATH from bats-core's own post-test
  # cleanup step, which runs coreutils in this same process.
  run bash -c '
    PATH="$1"
    . "$2"
    disposition_seed_forward "$3" "$4"
  ' _ "$BATS_TEST_TMPDIR/empty-bin" "$LIB" "$PREV" "$SIDECAR"
  [ ! -f "$SIDECAR" ]
}

# ---------------------------------------------------------------------------
# Hook-level fixtures: a real git repo the digest engine's builtin classifier
# recognizes (app/ = frontend auditable base), no .gaia/audit-ci.yml (so the
# builtin roster applies, mirroring audit-digest-lib.bats).
# ---------------------------------------------------------------------------

git_init() {
  local d="$1"
  git -C "$d" init --quiet --initial-branch=main
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false
}

seed_repo() {
  local d="$1"
  mkdir -p "$d/app" "$d/.gaia"
  git_init "$d"
  echo "export const x = 1;" > "$d/app/x.ts"
  printf '1.6.1\n' > "$d/.gaia/VERSION"
  git -C "$d" add -A
  git -C "$d" commit --quiet -m "seed"
}

frontend_digest_of() {
  local root="$1" ref="${2:-HEAD}"
  bash "$DIGEST_CLI" --root "$root" --member code-audit-frontend --ref "$ref"
}

# Write a schema-3 frontend earned clearance marker (C2) for <root> keyed to
# <digest>, dated from <root>'s current HEAD.
write_frontend_marker() {
  local root="$1" digest="$2" tree sha
  tree=$(git -C "$root" rev-parse "HEAD^{tree}")
  sha=$(git -C "$root" rev-parse HEAD)
  mkdir -p "$root/.gaia/local/audit"
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-frontend","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$digest" "$tree" "$sha" \
    > "$root/.gaia/local/audit/${digest}.ok"
}

# Run the REAL hook (by absolute path, so it resolves its own libs) with a
# `gh pr merge` command, cwd = <root>.
run_disposition_hook() {
  local root="$1" cmd="${2:-gh pr merge 30 --squash --delete-branch}" json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$root" "$json" "$HOOK_ABS"
}



# ---------------------------------------------------------------------------
# SPEC-064 fixtures: a pull-request-shaped repository (a base commit on
# `main`, a `feature` branch with real divergence) for exercising the
# eligibility union's TRUE branch, which neither seed_repo (single commit,
# permanently empty diff) nor a bare $SIDECAR-only call (acting_root omitted)
# can reach.
# ---------------------------------------------------------------------------

# make_pr_repo <name> [--advance-main <path>] [<committed-path>...]
#
# Builds a repo under $BATS_TEST_TMPDIR/<name>: git init on `main`, a base
# commit, then `git checkout -b feature` and one commit per <committed-path>.
# --advance-main <path> additionally commits <path> ON MAIN after the fork
# point and returns to `feature`, giving a fixture a path the default branch
# changed after the fork that the branch itself did not.
#
# ASSERTS the derived changed-file set is non-empty before returning stdout,
# and fails (returns 1, prints nothing) when it is not: a fixture that
# silently degrades to the unresolvable-base path would green every positive
# case while proving nothing. Callers must check:
# `repo="$(make_pr_repo ...)" || return 1` (a `local` declaration on the same
# line swallows the command substitution's own exit status).
make_pr_repo() {
  local name="$1"; shift
  local dir="$BATS_TEST_TMPDIR/$name"
  local advance_main="" p changed_file
  local paths=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --advance-main) advance_main="$2"; shift 2 ;;
      *) paths[${#paths[@]}]="$1"; shift ;;
    esac
  done

  mkdir -p "$dir/app" "$dir/.gaia"
  git_init "$dir"
  echo "export const base = 1;" > "$dir/app/base.ts"
  printf '1.6.1\n' > "$dir/.gaia/VERSION"
  git -C "$dir" add -A
  git -C "$dir" commit --quiet -m "base"

  git -C "$dir" checkout --quiet -b feature

  for p in "${paths[@]}"; do
    mkdir -p "$dir/$(dirname "$p")"
    printf 'touched\n' > "$dir/$p"
    git -C "$dir" add "$p"
    git -C "$dir" commit --quiet -m "add $p"
  done

  if [ -n "$advance_main" ]; then
    git -C "$dir" checkout --quiet main
    mkdir -p "$dir/$(dirname "$advance_main")"
    printf 'main-only\n' > "$dir/$advance_main"
    git -C "$dir" add "$advance_main"
    git -C "$dir" commit --quiet -m "advance main"
    git -C "$dir" checkout --quiet feature
  fi

  changed_file="$BATS_TEST_TMPDIR/.${name}.changed-check"
  _disposition_changed_set "$dir" "$changed_file" || {
    echo "make_pr_repo($name): the changed-file set's base did not resolve" >&2
    return 1
  }
  [ -s "$changed_file" ] || {
    echo "make_pr_repo($name): the changed-file set resolved empty; fixture is degraded" >&2
    rm -f "$changed_file"
    return 1
  }
  rm -f "$changed_file"

  printf '%s' "$dir"
}

# make_no_base_repo <name>
#
# A repo on `master` (never `main`), no origin remote: the default-branch
# probe finds no refs/remotes/origin/HEAD, falls back to the literal `main`,
# and neither `origin/main` nor `main` exists, so FULL_BASE cannot resolve.
# Mirrors .gaia/scripts/tests/audit-base-agreement.bats's make_no_base_repo
# shape (a reachable adopter shape, not a contrivance), extended with app/ +
# .gaia/VERSION so the hook tier's digest engine recognizes the fixture.
make_no_base_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/app" "$dir/.gaia"
  git -C "$dir" init --quiet --initial-branch=master
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
  echo "export const x = 1;" > "$dir/app/x.ts"
  printf '1.6.1\n' > "$dir/.gaia/VERSION"
  git -C "$dir" add -A
  git -C "$dir" commit --quiet -m "seed"
  printf '%s' "$dir"
}

# commit_on_second_branch <repo> <path>
#
# Branches off <repo>'s CURRENT branch, commits <path> on the new branch, and
# returns to the original branch, leaving the new branch LIVE (a real ref).
# Prints the new commit's sha. For the not-attributable case: a sha reachable
# from another live ref, never from the branch under judgment.
commit_on_second_branch() {
  local repo="$1" path="$2" cur sha
  cur="$(git -C "$repo" symbolic-ref --short HEAD)"
  git -C "$repo" checkout --quiet -b "${cur}-other-pr" "$cur"
  mkdir -p "$repo/$(dirname "$path")"
  printf 'other pr content\n' > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit --quiet -m "other pr commit"
  sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout --quiet "$cur"
  printf '%s' "$sha"
}

# orphan_commit_on_current_branch <repo> <path>
#
# Commits <path> on <repo>'s CURRENT branch, then rewinds the branch
# (`reset --hard HEAD~1`), leaving the commit orphaned: reachable from no ref.
# Prints the orphaned sha. Simulates an amend/rebase/force-push on the same
# branch, the case the orphan probe exists to still deny.
orphan_commit_on_current_branch() {
  local repo="$1" path="$2" sha
  mkdir -p "$repo/$(dirname "$path")"
  printf 'to be orphaned\n' > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit --quiet -m "will be orphaned"
  sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" reset --quiet --hard HEAD~1
  printf '%s' "$sha"
}

# merged_and_deleted_head <repo> <path> <branch>
#
# Commits <path> on a new <branch>, returns to the original branch, then deletes
# <branch> unmerged, leaving its head reachable from no ref. Prints that sha.
# This is the shape `gh pr merge --squash --delete-branch` leaves behind: the
# squash writes a NEW commit, so the pull request's own head survives on no ref
# and is indistinguishable by reachability alone from a rewritten-away commit of
# the branch under judgment.
merged_and_deleted_head() {
  local repo="$1" path="$2" branch="$3" cur sha
  cur="$(git -C "$repo" symbolic-ref --short HEAD)"
  git -C "$repo" checkout --quiet -b "$branch" "$cur"
  mkdir -p "$repo/$(dirname "$path")"
  printf 'merged pr content\n' > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit --quiet -m "merged pr commit"
  sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout --quiet "$cur"
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1

  # Both callers title themselves around an ORPHANED sha, so a helper that
  # yielded a reachable one would green them while exercising a different arm
  # of the probe entirely. Same rationale as make_pr_repo's own degradation
  # guard: assert the fixture is the shape the test names.
  if git -C "$repo" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
    echo "merged_and_deleted_head($branch): sha is an ancestor of HEAD; fixture degraded" >&2
    return 1
  fi
  if [ -n "$(git -C "$repo" for-each-ref --contains "$sha" --count=1 refs/heads refs/remotes 2>/dev/null)" ]; then
    echo "merged_and_deleted_head($branch): sha is still reachable from a ref; fixture degraded" >&2
    return 1
  fi
  printf '%s' "$sha"
}

# ---------------------------------------------------------------------------
# disposition_offenders / disposition_notes: the widened union eligibility
# (SPEC-064) -- gate-machinery paths UNION this pull request's own
# changed-file set. Frozen contracts B, C, D, E in README.md.
# ---------------------------------------------------------------------------

@test "offenders: union -- a non-machinery path the branch changes clears; the same shape absent from the diff denies (one repo, one run)" {
  local repo
  repo="$(make_pr_repo case-union app/in-diff.ts)" || return 1
  write_sidecar '{"schema":1,"backend":"github","findings":[
    {"key":"v1 class=x path=app/in-diff.ts line=1","disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/other.ts line=1","disposition":"machinery_waived"}
  ]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "app/in-diff.ts" <<<"$output" && return 1
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/other.ts line=1" <<<"$output" || return 1
}

@test "offenders/notes: the union is a union, not a replacement -- a machinery path absent from the diff still clears, with no note" {
  local repo
  repo="$(make_pr_repo case-union2 app/in-diff.ts)" || return 1
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=.claude/hooks/lib/audit-machinery.sh line=1","disposition":"machinery_waived"}]}'

  local changed_file="$BATS_TEST_TMPDIR/case-union2-changed"
  _disposition_changed_set "$repo" "$changed_file" || return 1
  _disposition_set_contains "$changed_file" ".claude/hooks/lib/audit-machinery.sh" && return 1

  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run disposition_notes "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: near-miss library-tier cases prove exact whole-string equality, never prefix/suffix/basename/substring in either direction" {
  local repo
  repo="$(make_pr_repo case-nearmiss --advance-main app/main-advance.ts app/x.ts docs/readme.md)" || return 1
  write_sidecar '{"schema":1,"backend":"github","findings":[
    {"key":"v1 class=x path=app/y.ts line=1","disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/x.tsx line=1","disposition":"machinery_waived"},
    {"key":"v1 class=x path=x.ts line=1","disposition":"machinery_waived"},
    {"key":"v1 class=x path=vendor/app/x.ts line=1","disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/main-advance.ts line=1","disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/x line=1","disposition":"machinery_waived"}
  ]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/y.ts line=1" <<<"$output" || return 1
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/x.tsx line=1" <<<"$output" || return 1
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=x.ts line=1" <<<"$output" || return 1
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=vendor/app/x.ts line=1" <<<"$output" || return 1
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/main-advance.ts line=1" <<<"$output" || return 1
  # The PREFIX-direction near-miss: `app/x` is a proper prefix of the changed
  # `app/x.ts`, not an equal string. A `case "$_p" in "$want"*)` mutation of
  # _disposition_set_contains's equality test clears this one (the changed
  # path starts with the waived path) while the shipped exact-match code
  # correctly keeps it an offender.
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/x line=1" <<<"$output" || return 1
}

@test "offenders: a malformed key on a machinery path still fails closed as an offender (the key-shape check precedes the machinery term)" {
  # No acting root: the key-shape check runs before any git call, so this
  # holds regardless of whether a root is passed.
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=.claude/rules/foo","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=.claude/rules/foo" <<<"$output" || return 1
}

@test "offenders: unresolvable base, non-machinery path -- the offender is grounded in the machinery term, not the git failure" {
  local repo
  repo="$(make_no_base_repo case-nobase-offender)"
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=app/y.ts line=1","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/y.ts line=1" <<<"$output" || return 1
}

@test "offenders/notes: unresolvable base, machinery path -- not an offender, and disposition_notes says changed-files-unverified" {
  local repo
  repo="$(make_no_base_repo case-nobase-clean)"
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=.claude/hooks/lib/audit-machinery.sh line=1","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run disposition_notes "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "changed-files-unverified: v1 class=x path=.claude/hooks/lib/audit-machinery.sh line=1" <<<"$output" || return 1
}

@test "offenders/notes: a resolved base with a genuinely empty diff is still an offender, with no note (not the same state as an unresolved base)" {
  local repo="$BATS_TEST_TMPDIR/case-empty-diff"
  mkdir -p "$repo"
  seed_repo "$repo"
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=app/y.ts line=1","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/y.ts line=1" <<<"$output" || return 1

  run disposition_notes "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: a linked worktree resolves the changed-file set from its OWN root, never an ambient cwd or the sidecar's directory" {
  local main_repo wt_dir
  main_repo="$BATS_TEST_TMPDIR/case-worktree-main"
  mkdir -p "$main_repo/app" "$main_repo/.gaia"
  git_init "$main_repo"
  echo "export const base = 1;" > "$main_repo/app/base.ts"
  printf '1.6.1\n' > "$main_repo/.gaia/VERSION"
  git -C "$main_repo" add -A
  git -C "$main_repo" commit --quiet -m "base"

  wt_dir="$BATS_TEST_TMPDIR/case-worktree-wt"
  git -C "$main_repo" worktree add --quiet -b case-worktree-feature "$wt_dir" main
  mkdir -p "$wt_dir/app"
  printf 'export const wt = 1;\n' > "$wt_dir/app/wt-only.ts"
  git -C "$wt_dir" add "app/wt-only.ts"
  git -C "$wt_dir" commit --quiet -m "worktree commit"

  # The sidecar lives in the MAIN checkout; the acting root passed to
  # disposition_offenders below is the WORKTREE. Resolving from the
  # sidecar's own directory ($main_repo) or an ambient cwd would never see
  # app/wt-only.ts, so either mistake reds this.
  local sidecar="$main_repo/head.dispositions.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=app/wt-only.ts line=1","disposition":"machinery_waived"}]}' \
    > "$sidecar"

  run disposition_offenders "$sidecar" "$wt_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders/notes: a sidecar attributed to another live branch's commit is set aside, not silently granted a waive; sha-absent is the control" {
  local repo other_sha
  repo="$(make_pr_repo case-attrib app/in-diff.ts)" || return 1
  other_sha="$(commit_on_second_branch "$repo" app/other-pr-only.ts)"

  write_sidecar "$(printf '{"schema":1,"backend":"github","sha":"%s","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}' "$other_sha")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run disposition_notes "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "changed-files-not-attributable: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1

  # Control: the same key with sha absent DOES produce the offender, proving
  # this test measures attribution rather than an unconditional pass.
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders: a history-rewrite-orphaned sha on the SAME branch still denies (the force-push case the orphan probe exists for)" {
  local repo orphaned_sha
  repo="$(make_pr_repo case-orphan app/in-diff.ts)" || return 1
  orphaned_sha="$(orphan_commit_on_current_branch "$repo" app/will-be-orphaned.ts)"

  write_sidecar "$(printf '{"schema":1,"backend":"github","sha":"%s","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}' "$orphaned_sha")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders: a sha naming no commit is inconclusive and reads as attributable, never set aside on a guess" {
  local repo
  repo="$(make_pr_repo case-unknown-sha app/in-diff.ts)" || return 1
  write_sidecar '{"schema":1,"backend":"github","sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders/notes: a sidecar recording a DIFFERENT branch is set aside even when its sha is orphaned (the squash-merged, branch-deleted head)" {
  local repo merged_sha
  repo="$(make_pr_repo case-branch-other app/in-diff.ts)" || return 1
  merged_sha="$(merged_and_deleted_head "$repo" app/other-pr-only.ts other-pr)" || return 1

  write_sidecar "$(printf '{"schema":1,"backend":"github","branch":"other-pr","sha":"%s","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}' "$merged_sha")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run disposition_notes "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "changed-files-not-attributable: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1

  # Control: the SAME sidecar without the branch field reaches the orphan
  # probe's attributable arm and denies. This is the false deny the branch term
  # answers, and it proves the test measures the branch term rather than
  # anything the orphaned sha does on its own.
  write_sidecar "$(printf '{"schema":1,"backend":"github","sha":"%s","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}' "$merged_sha")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders: a sidecar recording the branch under judgment still denies on an orphaned sha, so the branch term never undoes the force-push case" {
  local repo orphaned_sha
  repo="$(make_pr_repo case-branch-same app/in-diff.ts)" || return 1
  orphaned_sha="$(orphan_commit_on_current_branch "$repo" app/will-be-orphaned.ts)"

  write_sidecar "$(printf '{"schema":1,"backend":"github","branch":"feature","sha":"%s","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}' "$orphaned_sha")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders/notes: a MATCHING branch decides nothing, so the sha chain's live-ref arm still sets the sidecar aside" {
  local repo other_sha
  repo="$(make_pr_repo case-branch-match-liveref app/in-diff.ts)" || return 1
  other_sha="$(commit_on_second_branch "$repo" app/other-pr-only.ts)"

  # branch matches the branch under judgment, so the branch term declines to
  # answer; the sha is reachable from another LIVE ref, which only the sha
  # chain can see. A match that short-circuited to attributable would flip this
  # arm from set-aside to judged-and-denied, which is what this pins.
  write_sidecar "$(printf '{"schema":1,"backend":"github","branch":"feature","sha":"%s","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}' "$other_sha")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run disposition_notes "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "changed-files-not-attributable: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders: a detached-HEAD acting root resolves no branch to compare, so a recorded branch decides nothing and the sha chain answers alone" {
  local repo merged_sha
  repo="$(make_pr_repo case-branch-detached app/in-diff.ts)" || return 1
  merged_sha="$(merged_and_deleted_head "$repo" app/other-pr-only.ts other-pr)" || return 1
  git -C "$repo" checkout --quiet --detach HEAD

  write_sidecar "$(printf '{"schema":1,"backend":"github","branch":"other-pr","sha":"%s","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}' "$merged_sha")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders/notes: the machinery classifier being unresolvable fails the WHOLE arm open, never stricter than today" {
  local repo lib_copy_dir
  repo="$(make_pr_repo case-noclassifier app/in-diff.ts)" || return 1

  lib_copy_dir="$BATS_TEST_TMPDIR/case-noclassifier-lib"
  mkdir -p "$lib_copy_dir"
  cp "$LIB" "$lib_copy_dir/audit-dispositions.sh"
  # Deliberately no audit-machinery.sh alongside: the lib's lazy BASH_SOURCE-
  # relative self-source then has nothing to load, and a fresh `bash -c`
  # subshell never sourced the real one either.

  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=app/not-changed.ts line=1","disposition":"machinery_waived"}]}'

  run bash -c '. "$1"; disposition_offenders "$2" "$3"' \
    _ "$lib_copy_dir/audit-dispositions.sh" "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c '. "$1"; disposition_notes "$2" "$3"' \
    _ "$lib_copy_dir/audit-dispositions.sh" "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-classifier-unavailable: v1 class=x path=app/not-changed.ts line=1" <<<"$output" || return 1
}

@test "offenders: an unparseable dedup key fails closed as an offender, never cleared by a changed-files match it does not name" {
  local repo
  repo="$(make_pr_repo case-badkey app/in-diff.ts)" || return 1
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"not a valid key shape","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: not a valid key shape" <<<"$output" || return 1
}

@test "offenders: a non-ASCII path round-trips through the NUL-delimited changed-file set" {
  local repo real_path
  # A real UTF-8-encoded filename ("café.ts"), matching what a real
  # `git diff -z` emits and what a real finding key carries.
  real_path=$(printf 'app/caf\xc3\xa9.ts')
  repo="$(make_pr_repo case-nonascii "$real_path")" || return 1
  write_sidecar "$(printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=%s line=1","disposition":"machinery_waived"}]}' "$real_path")"
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: a cross-member orchestrator waive on a .gaia/cli/src/ path the branch changes clears the gate, with no filing side effect" {
  local repo head_sha committed_path=".gaia/cli/src/fixture.ts"
  repo="$(make_pr_repo case-crossmember "$committed_path")" || return 1
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  write_sidecar "$(printf '{"schema":1,"sha":"%s","backend":"github","findings":[{"key":"v1 class=x path=%s line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}]}' "$head_sha" "$committed_path")"

  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ "$(jq -r '.findings[0].issue_number // "null"' "$SIDECAR")" = "null" ]
  [ ! -f "$repo/.gaia/local/debt/refresh-requested" ]
}

@test "offenders: the same contract-shaped sidecar denies when the .gaia/cli/src/ path is NOT one the branch changes" {
  local repo head_sha committed_path=".gaia/cli/src/fixture.ts" other_path=".gaia/cli/src/untouched.ts"
  repo="$(make_pr_repo case-crossmember-neg "$committed_path")" || return 1
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  write_sidecar "$(printf '{"schema":1,"sha":"%s","backend":"github","findings":[{"key":"v1 class=x path=%s line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}]}' "$head_sha" "$other_path")"

  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=${other_path} line=1" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# disposition_notes: silence under its four preconditions. The frozen table
# (README.md contract B) has exactly three line shapes; none fits "the arm
# did not run for a reason unrelated to eligibility", so the correct
# assertion for each of these is silence, not a fourth line shape.
# ---------------------------------------------------------------------------

@test "notes: absent jq -> silence, not a fourth line shape" {
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=app/x.ts line=1","disposition":"machinery_waived"}]}'
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  # PATH is scoped to the child bash -c subshell only, mirroring the
  # seed-forward jq-unavailable test: replacing PATH in this process would
  # also strip it from bats-core's own post-test cleanup.
  run bash -c '
    PATH="$1"
    . "$2"
    disposition_notes "$3"
  ' _ "$BATS_TEST_TMPDIR/empty-bin" "$LIB" "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notes: no sidecar -> silence" {
  run disposition_notes "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notes: unparseable sidecar -> silence" {
  write_sidecar 'not json {'
  run disposition_notes "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notes: backend absent -> silence (even with a machinery_waived entry)" {
  write_sidecar '{"schema":1,"backend":"absent","findings":[{"key":"v1 class=x path=app/x.ts line=1","disposition":"machinery_waived"}]}'
  run disposition_notes "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Hook: fail-open cases preserved under digest keying
# ---------------------------------------------------------------------------

@test "hook: no frontend marker and no sidecar -> fail open (allow)" {
  ROOT="$BATS_TEST_TMPDIR/nomarker"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
}

@test "hook: no marker at all, but sidecar has a confirmed offender -> DENY (offender check is independent of marker state)" {
  ROOT="$BATS_TEST_TMPDIR/nomarkeroffender"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  install_gh_mock ok '[]'
  run_disposition_hook "$ROOT"
  assert_denied_by_json
  grep -qF -- "filed-but-missing: v1 class=y path=b line=2" <<<"$output" || return 1
}

@test "hook: a machinery_waived entry whose path IS machinery -> allow (no offender)" {
  ROOT="$BATS_TEST_TMPDIR/mwmachinery"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=.claude/hooks/lib/audit-machinery.sh line=1","disposition":"machinery_waived"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
}

@test "hook: a machinery_waived entry whose path is NOT machinery -> DENY (abuse-check offender)" {
  ROOT="$BATS_TEST_TMPDIR/mwnotmachinery"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=app/x.ts line=1","disposition":"machinery_waived"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_denied_by_json
  grep -qF -- "machinery-waived-not-eligible: v1 class=holistic/x path=app/x.ts line=1" <<<"$output" || return 1
}

@test "hook: sidecar present but unparseable -> fail open (allow)" {
  ROOT="$BATS_TEST_TMPDIR/badsidecar"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf 'not json {' > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
}

@test "hook: sidecar backend absent -> fail open (allow) even with a filed entry" {
  ROOT="$BATS_TEST_TMPDIR/backendabsent"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"absent","findings":[{"key":"K","disposition":"filed"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
}

@test "hook: gh unreachable -> fail open (allow), no filed offender" {
  ROOT="$BATS_TEST_TMPDIR/ghfail"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"K","disposition":"filed"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  install_gh_mock fail
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
}

@test "hook: a marker valid for a rotated-away (stale) digest does not trigger the absent-sidecar arm -> allow" {
  ROOT="$BATS_TEST_TMPDIR/stalemarker"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  old_digest="$(frontend_digest_of "$ROOT")"
  [ -n "$old_digest" ] || skip "could not derive digest"
  write_frontend_marker "$ROOT" "$old_digest"
  # Rotate frontend-owned content: the marker above no longer matches HEAD's
  # current frontend digest, and no sidecar exists for either digest.
  printf 'export const y = 2;\n' >> "$ROOT/app/x.ts"
  git -C "$ROOT" commit -aqm "rotate"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
}

# ---------------------------------------------------------------------------
# Hook: SPEC-064 widened-eligibility mirrors (cases 4, 5, 14). Case 6's hook
# mirror is the existing "a machinery_waived entry whose path is NOT
# machinery -> DENY" test above: seed_repo's single-commit fixture already
# resolves a base equal to HEAD, a genuinely empty diff, not an unresolved
# one.
# ---------------------------------------------------------------------------

@test "hook: unresolvable base, non-machinery path -> DENY, grounded in the machinery term" {
  ROOT="$(make_no_base_repo hooknobase-offender)"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=app/y.ts line=1","disposition":"machinery_waived"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_denied_by_json
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/y.ts line=1" <<<"$output" || return 1
}

@test "hook: unresolvable base, machinery path -> allow (positive absence check on the deny string), notes says changed-files-unverified" {
  ROOT="$(make_no_base_repo hooknobase-clean)"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=.claude/hooks/lib/audit-machinery.sh line=1","disposition":"machinery_waived"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
  grep -qF -- "changed-files-unverified: v1 class=x path=.claude/hooks/lib/audit-machinery.sh line=1" <<<"$output" || return 1
}

@test "hook: a cross-member orchestrator waive on a .gaia/cli/src/ path the branch changes -> allow, no filing side effect" {
  ROOT="$(make_pr_repo hookcrossmember .gaia/cli/src/fixture.ts)" || return 1
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  head_sha="$(git -C "$ROOT" rev-parse HEAD)"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"sha":"%s","backend":"github","findings":[{"key":"v1 class=x path=.gaia/cli/src/fixture.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}]}\n' \
    "$head_sha" > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
  [ "$(jq -r '.findings[0].issue_number // "null"' "$ROOT/.gaia/local/audit/${digest}.dispositions.json")" = "null" ]
  [ ! -f "$ROOT/.gaia/local/debt/refresh-requested" ]
}

# ---------------------------------------------------------------------------
# Hook: the new fail-closed arms (C4)
# ---------------------------------------------------------------------------

@test "hook: valid frontend marker, sidecar absent -> DENY (new fail-closed arm)" {
  ROOT="$BATS_TEST_TMPDIR/markernosidecar"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  write_frontend_marker "$ROOT" "$digest"
  run_disposition_hook "$ROOT"
  assert_denied_by_json
  grep -qF -- "sidecar" <<<"$output" || return 1
}

@test "hook: valid frontend marker, sidecar present and clean -> allow" {
  ROOT="$BATS_TEST_TMPDIR/markerclean"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  write_frontend_marker "$ROOT" "$digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed_by_json
}

@test "hook: digest cannot be derived (non-git root) -> DENY (fail closed)" {
  ROOT="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$ROOT"
  run_disposition_hook "$ROOT"
  assert_denied_by_json
  grep -qF -- "could not be derived" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# COV-003 (own it here): the FULL production path -- rotate -> seed-forward ->
# gate-deny -- deriving both digests the SAME way the frontend agent does (the
# CLI entrypoint, not an isolated lib call). A wrong BASE_SHA or a wrong
# prev-digest derivation leaves the receipt un-seeded, so the gate would clear
# instead of deny; this test fails on that mistake rather than only in
# production. gh is stubbed per directive TST-007 to report the filed issue
# closed-as-declined: no OPEN-or-CLOSED tech-debt issue on the reachable
# backend still carries the key, exactly how a declined-and-delabeled issue
# reads to the substring dedup check.
#
# COV-002 (cross-reference, not proved here): this test proves seed-forward
# correctly propagates the open entry from a predecessor sidecar into the new
# one, and that the standalone gate then denies. The complementary half of the
# durability invariant -- that the janitor does NOT reap the predecessor
# sidecar once it is past the retention window because it still holds an open
# receipt -- is a time-controlled janitor test owned by task-janitor-noop.
# ---------------------------------------------------------------------------

@test "COV-003/COV-002: a still-open receipt survives a frontend-digest rotation through the full production path" {
  ROOT="$BATS_TEST_TMPDIR/cov003"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  BASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"

  # 1. At BASE_SHA the frontend files a still-open (filed) receipt into the
  #    sidecar keyed to the digest AT BASE_SHA, derived exactly the way the
  #    agent derives it: the CLI entrypoint, --ref BASE_SHA.
  prev_digest="$(bash "$DIGEST_CLI" --root "$ROOT" --member code-audit-frontend --ref "$BASE_SHA")"
  [ -n "$prev_digest" ] || return 1
  mkdir -p "$ROOT/.gaia/local/audit"
  prev_sidecar="$ROOT/.gaia/local/audit/${prev_digest}.dispositions.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=app/x.ts line=1","disposition":"filed"}]}' \
    > "$prev_sidecar"

  # 2. Rotate frontend-owned content to a new HEAD: a fresh incremental audit
  #    at this HEAD would not re-encounter the original finding.
  printf 'export const rotated = true;\n' >> "$ROOT/app/x.ts"
  git -C "$ROOT" commit -aqm "rotate frontend content"

  # 3. Derive the new frontend digest the same way, then seed-forward.
  new_digest="$(bash "$DIGEST_CLI" --root "$ROOT" --member code-audit-frontend --ref HEAD)"
  [ -n "$new_digest" ] || return 1
  [ "$new_digest" != "$prev_digest" ] || return 1
  new_sidecar="$ROOT/.gaia/local/audit/${new_digest}.dispositions.json"
  disposition_seed_forward "$prev_sidecar" "$new_sidecar"
  [ -f "$new_sidecar" ]
  grep -qF -- "v1 class=y path=app/x.ts line=1" "$new_sidecar" || return 1

  # A valid marker for the NEW digest, so the sidecar-absent arm cannot itself
  # explain the deny below: the sidecar is present, the deny must come from
  # the seeded-forward offender.
  write_frontend_marker "$ROOT" "$new_digest"

  # 4. Run the standalone gate at the new HEAD with gh stubbed per TST-007.
  install_gh_mock ok '[]'
  run_disposition_hook "$ROOT"
  assert_denied_by_json
  grep -qF -- "filed-but-missing: v1 class=y path=app/x.ts line=1" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# The eligibility set is scoped to the branch the pull request MERGES INTO.
# A set taken against the repository's advertised default hands the waive
# every file the BASE branch changed, and each of those is a finding that can
# be recorded in the pull-request body instead of filed as durable tech debt.
# ---------------------------------------------------------------------------

# make_stacked_pr_repo <name>: `release` forks from the default branch and
# owns app/base-only.ts; `feature` forks from `release` and owns app/feat.ts.
# Remote-tracking refs are written directly, since they only ever need to
# resolve, never to fetch.
make_stacked_pr_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"

  mkdir -p "$dir/app" "$dir/.gaia"
  git_init "$dir"
  echo "export const base = 1;" > "$dir/app/base.ts"
  printf '1.6.1\n' > "$dir/.gaia/VERSION"
  git -C "$dir" add -A
  git -C "$dir" commit --quiet -m "base"

  git -C "$dir" checkout --quiet -b release
  printf 'the base branch own change\n' > "$dir/app/base-only.ts"
  git -C "$dir" add app/base-only.ts
  git -C "$dir" commit --quiet -m "release-only"

  git -C "$dir" checkout --quiet -b feature
  printf 'the pull request own change\n' > "$dir/app/feat.ts"
  git -C "$dir" add app/feat.ts
  git -C "$dir" commit --quiet -m "feature-only"

  git -C "$dir" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$dir" update-ref refs/remotes/origin/release refs/heads/release
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '%s' "$dir"
}

@test "offenders: a waive on a file only the base branch changed is an offender, while the pull request's own file clears" {
  local repo
  repo="$(make_stacked_pr_repo case-stacked)"
  export GITHUB_ACTIONS=true
  export GITHUB_BASE_REF=release

  write_sidecar '{"schema":1,"backend":"github","findings":[
    {"key":"v1 class=x path=app/feat.ts line=1","disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/base-only.ts line=1","disposition":"machinery_waived"}
  ]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "app/feat.ts" <<<"$output" && return 1
  grep -qF -- "machinery-waived-not-eligible: v1 class=x path=app/base-only.ts line=1" <<<"$output" || return 1
}

@test "offenders: with no declared base the same waive clears, which is the wide fallback rather than a second rule" {
  local repo
  repo="$(make_stacked_pr_repo case-stacked-fallback)"
  # The gh mock's catch-all arm answers `gh pr view` with nothing, so no base
  # branch is declared by either source and the advertised default stands.
  install_gh_mock ok '[]'

  write_sidecar '{"schema":1,"backend":"github","findings":[
    {"key":"v1 class=x path=app/base-only.ts line=1","disposition":"machinery_waived"}
  ]}'
  run disposition_offenders "$SIDECAR" "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
