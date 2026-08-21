#!/usr/bin/env bats
# Tests for `.claude/hooks/issue-claim-release.sh`, the PostToolUse Bash hook
# that strips the `in-progress` claim label from every issue a merged pull
# request closes.
#
# Each test runs the hook against a throwaway git repo (the hook sources
# `.claude/hooks/lib/repo-scope.sh` relative to CWD, so a real copy is placed
# there) with a fake `gh` on PATH that answers `pr view` from
# FAKE_GH_PR_STATE / FAKE_GH_PR_BODY and records every `pr view` ref and
# `issue edit` call under $FAKE_GH_STATE for assertions.
#
# The sandbox repo's toplevel directory is named exactly `gaia`, because
# repo-scope.sh's `-R`/`--repo` arm compares only the REPO-NAME half of the
# flag value against the home repo's own directory basename; without that
# match, a same-repo `--repo gaia-react/gaia` command would misclassify as
# foreign and case 7b could never distinguish a correct ref parse from a
# broken one.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/issue-claim-release.sh
  REPO_SCOPE_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh
  command -v jq >/dev/null 2>&1 || skip "jq required"

  PARENT=$(mktemp -d -t issue-claim-release-test-XXXXXX)
  REPO="$PARENT/gaia"
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$REPO_SCOPE_ABS" "$REPO/.claude/hooks/lib/repo-scope.sh"

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  FAKE_GH_STATE="$BATS_TEST_TMPDIR/gh-state"
  mkdir -p "$FAKE_GH_STATE"
  : > "$FAKE_GH_STATE/issue_edits"
  : > "$FAKE_GH_STATE/issue_edit_repos"
  write_gh_stub
  export FAKE_GH_STATE
  export FAKE_GH_PR_STATE="${FAKE_GH_PR_STATE:-MERGED}"
  export PATH="$GH_BIN:$PATH"
}

teardown() {
  [ -n "${PARENT:-}" ] && rm -rf "$PARENT"
  return 0
}

# Fake `gh` answering exactly the three calls this hook makes: `repo view`
# (the home repo), `pr view` (once, with both fields) and
# `issue edit ... --remove-label ...`. State lives under $FAKE_GH_STATE so a
# test can assert on it after run_hook.
#
# `pr view` reproduces real gh's precedence, verified against gh 2.96: a URL
# selector resolves the repository from the URL and OVERRIDES --repo. Without
# that, a stub would answer every URL out of the home repo and the URL cases
# below would pass on a hook that never guards the boundary at all.
write_gh_stub() {
  cat > "$GH_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
STATE="$FAKE_GH_STATE"
HOME_REPO="${FAKE_GH_HOME_REPO:-gaia-react/gaia}"
case "$1" in
  repo)
    shift
    case "$1" in
      view) printf '%s\n' "$HOME_REPO"; exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view)
        shift
        ref=""
        repo=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --json|-q|--jq) shift 2 ;;
            -R|--repo) repo="$2"; shift 2 ;;
            -*) shift ;;
            *) ref="$1"; shift ;;
          esac
        done
        case "$ref" in
          *://*)
            stripped="${ref#*://}"
            stripped="${stripped#*/}"
            repo="${stripped%%/pull/*}"
            ;;
        esac
        [ -n "$repo" ] || repo="$HOME_REPO"
        printf '%s' "$ref" > "$STATE/pr_view_ref"
        printf '%s' "$repo" > "$STATE/pr_view_repo"
        jq -n --arg s "${FAKE_GH_PR_STATE:-MERGED}" --arg b "${FAKE_GH_PR_BODY:-}" \
          '{state: $s, body: $b}'
        exit "${FAKE_GH_PR_VIEW_EXIT:-0}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  issue)
    shift
    case "$1" in
      edit)
        shift
        n=""
        repo=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -R|--repo) repo="$2"; shift 2 ;;
            --remove-label|--add-label) shift 2 ;;
            -*) shift ;;
            *) n="$1"; shift ;;
          esac
        done
        echo "$n" >> "$STATE/issue_edits"
        echo "$repo" >> "$STATE/issue_edit_repos"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "$GH_BIN/gh"
}

run_hook() {
  local input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1")
  invoke_hook_in "$REPO" "$input" "$HOOK_ABS"
}

released_issues() { cat "$FAKE_GH_STATE/issue_edits" 2>/dev/null; }
assert_released_once() { [ "$(grep -cxF -- "$1" <<<"$(released_issues)")" -eq 1 ]; }
assert_nothing_released() { [ ! -s "$FAKE_GH_STATE/issue_edits" ]; }

@test "1: MERGED pr with Closes #<n> strips in-progress from that issue" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_released_once "12"
}

@test "2: multiple mixed-case closing keywords release every issue" {
  export FAKE_GH_PR_BODY=$'Fixes #3\nresolved #4\nCLOSES #5'
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_released_once "3"
  assert_released_once "4"
  assert_released_once "5"
}

@test "3: a duplicated reference releases the issue exactly once" {
  export FAKE_GH_PR_BODY=$'Closes #7\nCloses #7'
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_released_once "7"
}

@test "4: a pull request that is not MERGED releases nothing" {
  export FAKE_GH_PR_STATE="OPEN"
  export FAKE_GH_PR_BODY="Closes #9"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "5: a body with no closing reference releases nothing" {
  export FAKE_GH_PR_BODY="See discussion, no keyword here"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "6: gh pr merge mentioned inside a string is not a real invocation" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'echo "gh pr merge 42"'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7: a foreign-repo command releases nothing" {
  export FAKE_GH_PR_BODY="Closes #99"
  run_hook 'gh pr merge --repo other-org/other-repo 1'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7b: a same-repo --repo command resolves the ref, not the flag value" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge --repo gaia-react/gaia 12'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "12" ]
  assert_released_once "12"
}

# 7f-7h cover the reference form the `--repo` guard cannot reach. gh takes
# `<number> | <url> | <branch>`, and a URL names its own repository, so a
# merged sibling-repo pull request read by URL would otherwise have its
# closing references applied to THIS repository's issues of the same number.
@test "7f: a foreign-repo URL reference releases nothing" {
  export FAKE_GH_PR_BODY="Closes #99"
  run_hook 'gh pr merge https://github.com/other-org/other-repo/pull/1'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7g: a home-repo URL reference resolves to its number" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge https://github.com/gaia-react/gaia/pull/1508'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_repo")" = "gaia-react/gaia" ]
  assert_released_once "12"
}

# The sandbox toplevel is named `gaia`, so `--repo other-org/gaia` is the case
# where the shared guard's repo-NAME comparison says "home". For the blocking
# guards that share that lib, home means enforce and the over-classification is
# safe; here home means act, so the whole slug has to be compared.
@test "7i: a same-named sibling repo releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo other-org/gaia 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7j: a quoted multi-word flag value does not become the reference" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge --squash --body "release notes here" 1508'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "12"
}

@test "7h: both the read and the write name the home repo" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_repo")" = "gaia-react/gaia" ]
  [ "$(grep -cxF -- "gaia-react/gaia" "$FAKE_GH_STATE/issue_edit_repos")" -eq 1 ]
}

@test "8a: gh absent from PATH releases nothing and exits 0" {
  export FAKE_GH_PR_BODY="Closes #12"
  nogh_bin="$BATS_TEST_TMPDIR/nogh-bin"
  mkdir -p "$nogh_bin"
  ln -sf "$(command -v bash)" "$nogh_bin/bash"
  ln -sf "$(command -v jq)" "$nogh_bin/jq"
  ln -sf "$(command -v git)" "$nogh_bin/git"
  ln -sf "$(command -v grep)" "$nogh_bin/grep"
  ln -sf "$(command -v sort)" "$nogh_bin/sort"
  ln -sf "$(command -v cat)" "$nogh_bin/cat"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'gh pr merge 42')
  PATH="$nogh_bin" invoke_hook_in "$REPO" "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "8b: jq absent from PATH releases nothing and exits 0" {
  export FAKE_GH_PR_BODY="Closes #12"
  nojq_bin="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$nojq_bin"
  ln -sf "$(command -v bash)" "$nojq_bin/bash"
  ln -sf "$(command -v cat)" "$nojq_bin/cat"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'gh pr merge 42')
  PATH="$nojq_bin" invoke_hook_in "$REPO" "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# 7c-7e pin the value-taking flag table against gh's real flag set. Each one
# fails if the table gains or loses the flag it names: a boolean listed as
# value-taking swallows the reference, and a value-taking flag left out makes
# its own value the reference. Both end the same way, a merged pull request
# whose issues keep a live claim forever.
@test "7c: -m is boolean --merge, so the reference after it still resolves" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge -m 1498'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1498" ]
  assert_released_once "12"
}

@test "7d: -F takes a value, so the filename is not read as the reference" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge -F notes.txt 1498'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1498" ]
  assert_released_once "12"
}

@test "7e: -A takes a value, so the email is not read as the reference" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge -A me@example.com 1498'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1498" ]
  assert_released_once "12"
}

# Test 6 proves the matcher rejects a mention inside a string. This proves the
# other half: a real invocation after a shell separator DOES arm. Without it,
# sep_re could silently stop matching and every compound-command merge would
# release nothing with the suite still green.
@test "9: a real invocation after a shell separator arms the hook" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'git fetch && gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_released_once "12"
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABS" ]
}
