#!/usr/bin/env bats
# Every test exports its own FAKE_GH_PR_BODY into the subshell bats creates
# for it, which is the point: the fixture must not leak to the next test, and
# the hook runs as a child of that same subshell, so it does see the value.
# shellcheck disable=SC2030,SC2031
#
# Tests for `.claude/hooks/issue-claim-release.sh`, the PostToolUse Bash hook
# that strips the `in-progress` claim label from every issue a merged pull
# request closes.
#
# Each test runs the hook against a throwaway git repo, with a fake `gh` on
# PATH that answers `pr view` from FAKE_GH_PR_STATE / FAKE_GH_PR_BODY and
# records every `pr view` ref and `issue edit` call under $FAKE_GH_STATE for
# assertions. Nothing is staged for `repo-scope.sh`: the hook resolves that
# lib from its OWN location rather than from cwd, so it reaches the real one
# beside it and a sandbox copy would never be read.
#
# The sandbox repo's toplevel directory is named exactly `gaia`, matching the
# repo-NAME half of the home slug the fake gh reports (`gaia-react/gaia`). The
# hook compares the whole [HOST/]OWNER/REPO against that slug rather than the
# directory basename, so the name decides nothing on its own. It is kept
# because it is what makes the same-named-sibling fixtures adversarial:
# `--repo other-org/gaia` is precisely the value a repo-NAME comparison calls
# home, so those cases red the moment the boundary regresses to one.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/issue-claim-release.sh
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
HOME_HOST="${FAKE_GH_HOME_HOST:-github.com}"
case "$1" in
  repo)
    shift
    case "$1" in
      # gh identifies a repo as [HOST/]OWNER/REPO, so the hook reads the slug
      # and the URL's authority from one call; the stub answers both.
      view)
        jq -n --arg n "$HOME_REPO" --arg u "https://$HOME_HOST/$HOME_REPO" \
          '{nameWithOwner: $n, url: $u}'
        exit 0
        ;;
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

# GitHub requires a closing keyword to stand as its own word, so a keyword
# that is only the tail of a longer one closes nothing and must release
# nothing. This is the one direction in which the hook can strip a claim off
# work still in flight.
@test "5b: a keyword inside a longer word releases nothing" {
  export FAKE_GH_PR_BODY="This leaves the design unresolved #91 for now"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "5c: a keyword opening the body still releases" {
  export FAKE_GH_PR_BODY="resolved #4"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_released_once "4"
}

# 5d-5f cover the two spellings GitHub documents beside the bare one. The
# first two are merges that DID close an issue, so failing to match them
# leaves a claim live on finished work; the third is the reason the qualifier
# is compared rather than merely allowed.
@test "5d: the colon spelling releases" {
  export FAKE_GH_PR_BODY="Closes: #5"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_released_once "5"
}

@test "5e: a reference qualified with the home repo releases" {
  export FAKE_GH_PR_BODY="Closes gaia-react/gaia#12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_released_once "12"
}

@test "5f: a reference qualified with another repo releases nothing" {
  export FAKE_GH_PR_BODY="Closes other-org/other-repo#13"
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

# Test 6 pins a mention with no real invocation after it. 6b and 6c pin the
# other half: a mention FOLLOWED by one. Both assert the selector rather than
# the release, because that is where the defect shows, the hook reads some
# other pull request's state and body and releases whatever THAT one closed.
# 6b-6g are one contract, not six: the merge has to BE the first command in
# the tool call. The arming match only proves the phrase appears somewhere a
# command could start, and a comment, another command's quoted value, a
# heredoc body line, a directory change and a subshell all satisfy that while
# meaning something else. Each one previously resolved a pull request this
# merge never touched and stripped labels off its issues.
@test "6b: a merge behind a comment line releases nothing" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook $'# gh pr merge 5 (old, already done)\ngh pr merge 9'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "6c: a merge behind another gh command releases nothing" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr comment 9 --body "ready; gh pr merge 5 landed" && gh pr merge 9'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "6d: a merge behind a heredoc releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'cat <<\'EOF\' > notes.md\ngh pr merge 5\nEOF\ngh pr merge 9'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "6e: a merge behind a directory change releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'git fetch && cd ../other && gh pr merge 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# The subshell form is the one the shell-cwd rule pushes toward, and it is
# glued to its `cd`, so any guard matching the word `cd` misses it. Under the
# first-command contract the spelling stops mattering.
@test "6g: a merge inside a subshell that changes directory releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook '(cd ../other && gh pr merge 5 --squash)'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# 6f and 6h are the controls that keep the contract from collapsing into
# "release nothing". A command AFTER the merge cannot change which pull
# request merged, so it is still read; and an empty leading piece, from a
# newline or from the second character of `&&`, is not a command at all.
@test "6f: a command after the merge does not stand it down" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 1508 && git checkout main'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "77"
}

@test "6h: a leading blank line does not count as a command" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'\n  gh pr merge 1508'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "77"
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

# The sandbox toplevel is named `gaia`, so `--repo other-org/gaia` is exactly
# the value a repo-NAME comparison calls "home". repo-scope.sh's blocking
# guard does compare that way, and for a consumer that ENFORCES the
# over-classification is safe; this hook ACTS, so it compares the whole slug
# and this case has to stay foreign.
@test "7i: a same-named sibling repo releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo other-org/gaia 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# gh accepts flags in any position, so the boundary check has to survive a
# --repo written after the reference. 7k and 7l are 7i with the argument order
# reversed, which is the spelling a leading-flag-only guard leaves open.
@test "7k: a trailing --repo naming a same-named sibling releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --repo other-org/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7l: a trailing -R naming a same-named sibling releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --squash -R other-org/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# 7p-7r pin the separator handling in both directions. A separator inside a
# quoted subject or body is ordinary text and must not end the scan, or every
# token after it, a trailing --repo included, drops out of the set the guard
# reads. A real separator must still end it, or a later command's own --repo
# decides this one.
@test "7p: a semicolon inside a quoted body does not end the scan" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --body "fix; ship it" --repo other-org/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7q: a pipe inside a quoted body does not end the scan" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --body "a | b" -R other-org/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7r: a semicolon inside a quoted subject does not end the scan" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --squash -t "labels: rename; recolor" --repo other-org/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7s: a later command's --repo does not decide this one" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --repo other-org/gaia && gh issue list --repo gaia-react/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# 7t-7w pin the boundary between the two, which is where a pattern over the
# raw text keeps getting it wrong: a separator glued to a CLOSING quote is a
# real separator, a separator inside an open quote or behind a backslash is
# text. Each spelling below is ordinary shell, not a crafted string.
@test "7t: a separator glued to a closing quote ends the scan" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --repo other-org/gaia -t "subj"; gh issue list --repo gaia-react/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# A newline separates two commands exactly as `&&` does, and the matcher that
# arms this hook already treats it that way, so the scan has to agree.
@test "7x: a newline ends the command as a separator does" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge --repo other-org/gaia 5 --squash\ngh issue list --repo gaia-react/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7y: a multi-line no-reference merge still resolves the current branch" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge --squash\necho done'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "" ]
  assert_released_once "77"
}

@test "7u: a later command does not stand a home merge down" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 -t "subj"; gh issue list --repo other-org/gaia'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

@test "7v: an attached --body= value keeps its separator as text" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --squash --body="fix; ship it" --repo other-org/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7w: a backslash-escaped separator is text, not an end of command" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --body fix\;ship --repo other-org/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# 7z and 7aa are the other half of 7w: a backslash before a newline is a line
# CONTINUATION rather than an escape, so both characters go away instead of
# the newline becoming a word. Treated as an escape it becomes the first
# non-flag word, which is the reference, so a merge written across two lines
# resolves a newline and releases nothing. 7aa pins that the bogus word takes
# the slot even when the real number comes later.
@test "7z: a line continuation before the reference resolves it" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge \\\n  1508 --squash'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "77"
}

@test "7aa: a line continuation before a flag leaves a later reference intact" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge \\\n  --squash 1508'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "77"
}

# The scan reads the command one fixed-size block at a time, so word, quote and
# escape state has to survive a block boundary. Every other case here is short
# enough to fit in one block, which would leave the chaining unexercised. These
# two straddle several boundaries: 7ab carries a word across them, 7ac holds a
# quoted span open across them so a separator inside it stays text and the flag
# after it is still scanned.
@test "7ab: a value spanning several blocks does not become the reference" {
  export FAKE_GH_PR_BODY="Closes #77"
  local pad
  pad=$(printf 'x%.0s' $(seq 1 600))
  run_hook "gh pr merge --body \"$pad\" 1508"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "77"
}

# 7ab and 7ac pin quote state across a boundary but not the WORD itself: in
# both, a word truncated at the boundary is a flag value nothing reads back,
# so the reference still resolves. This sweeps the reference across a whole
# block's worth of offsets so at least one run has it straddling, whatever
# the scan's block constant is; a truncated word there resolves the wrong
# pull request outright.
@test "7ad: the reference resolves wherever it straddles a block boundary" {
  export FAKE_GH_PR_BODY="Closes #77"
  local n pad
  for n in $(seq 230 262); do
    pad=$(printf 'x%.0s' $(seq 1 "$n"))
    run_hook "gh pr merge --body \"$pad\" 1508"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  done
}

@test "7ac: a quoted span held open across blocks keeps its separator as text" {
  export FAKE_GH_PR_BODY="Closes #77"
  local half body
  half=$(printf 'x%.0s' $(seq 1 300))
  body="$half;$half"
  run_hook "gh pr merge 5 --body \"$body\" --repo other-org/gaia"
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# 7n and 7o pin the spellings that carry a quote into the parser. Each one
# fails closed when mishandled, releasing nothing on a merge that closed
# issues, which the rule promises needs no manual step.
@test "7n: a multi-word --body= value does not become the reference" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge --squash --body="release notes here" 1508'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "12"
}

@test "7o: a quoted reference resolves without its quotes" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge "1508" --squash'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "12"
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
# gh's flag library accepts a shorthand with its value attached, so this is
# the same invocation as the spaced form two cases up. Read as a bare boolean
# flag it sets no repository at all, and the whole-slug boundary check below
# never arms: the hook then reads THIS repository's pull request 5.
@test "7ae: an attached -R naming another repo releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -Rother-org/other-repo 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7af: an attached -R naming the home repo still resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -Rgaia-react/gaia 5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

# 7ak-7an: gh identifies a repository as [HOST/]OWNER/REPO, so the slug alone
# does not name one. An adopter mirroring a repository between github.com and
# an enterprise host carries the SAME owner/repo on both, and the shared guard
# compares only the repo-name half, so nothing upstream separates them. Read
# on the slug alone, a merge on the other host resolves this host's pull
# request of that number and strips labels off issues it never closed. The
# home-host controls are what keep the check from degrading into "reject every
# qualifier".
@test "7ak: a --repo qualified with another host releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo ghe.example.com/gaia-react/gaia 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7al: a --repo qualified with the home host still resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo github.com/gaia-react/gaia 5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

@test "7am: a URL on another host releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge https://ghe.example.com/gaia-react/gaia/pull/5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# The mirror direction: when the enterprise host IS home, its own URL has to
# resolve and github.com's must not. Without this the check could pass by
# hardcoding github.com rather than by reading the home repository.
@test "7an: on an enterprise home host, a github.com URL releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  export FAKE_GH_HOME_HOST="ghe.example.com"
  run_hook 'gh pr merge https://github.com/gaia-react/gaia/pull/5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7ao: on an enterprise home host, its own URL resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  export FAKE_GH_HOME_HOST="ghe.example.com"
  run_hook 'gh pr merge https://ghe.example.com/gaia-react/gaia/pull/5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

# 7ag-7aj: gh clusters single-dash shorthands, and this parser does not model
# that. The first value-taking letter in a cluster swallows the rest of the
# token or the next word, so `-sR<slug>` leaves the repository check unarmed
# and `-st 1234 5` hands `1234` to the subject. Read as one unknown flag both
# resolve a pull request in THIS repository that the merge never touched, so
# a cluster is refused outright rather than decoded. 7aj is the control: a
# lone shorthand is not a cluster and still works.
@test "7ag: an attached cluster naming another repo releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -sRother-org/other-repo 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7ah: a spaced cluster naming another repo releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -sR other-org/other-repo 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# Refused even when it names the home repo, and even when every letter in it
# is a boolean. The parser cannot tell those apart from the dangerous shape
# without modelling the cluster grammar, and this is the direction to be
# wrong in: `-sd 1508` costs a release that is done by hand.
@test "7ai: a cluster releases nothing even when it is harmless" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -sd 1508'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7aj: a lone shorthand is not a cluster and still resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -s 1508'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ]
  assert_released_once "77"
}

# 7ap-7as: a word-initial unquoted `#` opens a shell COMMENT, so gh receives
# none of it. Read as ordinary text those words reach the flag parser, and a
# `--repo` among them wins over the one the merge carried, because the parser
# keeps the last one it sees and the shared guard captures greedily. 7ap is the
# harm that reaches: a merge landing in the SIBLING repository, stripping claims
# here. 7aq and 7ar are the controls that the arm cuts a comment rather than
# every `#`. 7as pins the stop rather than a skip to the newline: a comment
# hiding a leading command must not promote the words after it into the first
# command, which is the one shape a skip would get wrong.
@test "7ap: a trailing comment's --repo does not turn a foreign merge into a home release" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo other-org/other-repo 5 # was --repo gaia-react/gaia'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7aq: a trailing comment does not cost a home merge its release" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --squash # ship it'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

@test "7ar: a mid-word # is ordinary text, not a comment" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --body fix#77 5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

@test "7as: a comment hiding a leading command releases nothing" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'# merge it now\ngh pr merge 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

# 7at, 7au: GitHub resolves OWNER/REPO case-insensitively, so a merge spelled
# in another case lands on the home repository and a case-sensitive comparison
# would read it as a different one and cost the release. Every half of the
# value is compared case-blind, and the three cases below cover them: the
# owner half here, both halves of a URL in 7au, and the repo-NAME half in 7av.
# 7aw and 7ay pin the direction that keeps case-blindness honest.
@test "7at: a --repo differing only in owner case still resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo GAIA-React/gaia 5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

@test "7au: a home URL differing in case still resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge https://github.com/GAIA-React/GAIA/pull/5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

# The merge has to be the first command in the tool call, so an ordinary
# benign prefix costs the release. That is the deliberate price of the
# first-command contract, and it is what the rule's own bullet tells a reader
# to expect, so it is pinned rather than left to drift.
@test "9: a merge behind an ordinary earlier command releases nothing" {
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'git fetch && gh pr merge 42'
  [ "$status" -eq 0 ]
  assert_nothing_released
}
@test "the hook file is executable" {
  [ -x "$HOOK_ABS" ]
}

# 7av-7ay: the boundary is read from the SCANNED value rather than from a
# regex over the raw command, which is what makes these four spellings behave.
# The repo-NAME half of a `--repo` value used to be compared case-sensitively
# against the checkout's directory basename by a pre-filter that ran first, so
# 7av's spelling was called foreign and cost the release; and a quoted value
# kept its quotes through that capture, so 7ax's was too. The scan strips the
# quotes and knows which command in the tool call owns the flag.
@test "7av: a --repo differing only in repo-name case still resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo gaia-react/GAIA 5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

@test "7aw: a same-named sibling differing in case still releases nothing" {
  # 7av's safety direction: case-blindness must not turn a different
  # repository into the home one.
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo OTHER-ORG/GAIA 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}

@test "7ax: a quoted home --repo value resolves the ref" {
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo="gaia-react/gaia" 5'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ]
  assert_released_once "77"
}

@test "7ay: a quoted foreign --repo value releases nothing" {
  # 7ax's safety direction, and the one that matters: reading a quoted value
  # at all is only correct if reading it foreign still declines.
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo="other-org/gaia" 5'
  [ "$status" -eq 0 ]
  assert_nothing_released
}
