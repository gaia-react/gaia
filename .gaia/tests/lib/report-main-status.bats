#!/usr/bin/env bats

# Hermetic suite for .gaia/tests/report-main-status.sh, the reporter the
# push-to-main job runs to keep one `ci-red-main` issue open while main is red.
# Push behavior cannot run before merge, so every transition is driven here
# through a PATH-stubbed `gh` that records its argv and answers from fixture
# files. Nothing reads the real tree, the network or a real repository.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../report-main-status.sh"
  STUB_DIRECTORY="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIRECTORY/bin"
  GH_LOG="${STUB_DIRECTORY}/argv.log"
  BODY_LOG="${STUB_DIRECTORY}/body.log"
  : > "$GH_LOG"
  : > "$BODY_LOG"
  : > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" ""
  printf '%s\n' 'shard-alpha' 'shard-beta' > "$STUB_DIRECTORY/jobs-failed.txt"
  printf 'ahead\n' > "$STUB_DIRECTORY/compare.txt"
  cat > "$STUB_DIRECTORY/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
previous=""
for argument in "$@"; do
  if [ "$previous" = "--body-file" ]; then
    { printf '=== %s %s\n' "$1" "$2"; cat "$argument"; } >> "$BODY_LOG"
  fi
  previous="$argument"
done
if [ -n "${GH_FAIL_ON:-}" ] && [ "$1 $2" = "$GH_FAIL_ON" ]; then
  exit 1
fi
case "$1 $2" in
  "issue list") cat "$STUB_DIRECTORY/issues.txt" ;;
  "issue view")
    expression=""
    previous=""
    for argument in "$@"; do
      [ "$previous" = "--jq" ] && expression="$argument"
      previous="$argument"
    done
    jq -r "$expression" "$STUB_DIRECTORY/issue-view.json"
    ;;
  "issue create") printf 'https://example.test/issues/9\n' ;;
  "api --paginate") cat "$STUB_DIRECTORY/jobs-failed.txt" ;;
  api\ repos/*/compare/*)
    [ -f "$STUB_DIRECTORY/compare-fails" ] && exit 1
    cat "$STUB_DIRECTORY/compare.txt"
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIRECTORY/bin/gh"
  export GH_LOG BODY_LOG STUB_DIRECTORY
  export PATH="$STUB_DIRECTORY/bin:$PATH"
  export GH_TOKEN="$BATS_TEST_NAME"
  export REPOSITORY="example/repo"
  export RUN_ID="777"
  export RUN_ATTEMPT="1"
  export RUN_URL="https://example.test/example/repo/actions/runs/777"
  export BEFORE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  export SHARDS_RESULT="failure"
}

# write_issue_view <body author login> <body text> [<comment author login> <comment text>]...
write_issue_view() {
  local body_login="$1" body_text="$2"
  shift 2
  local comments='[]'
  while [ "$#" -ge 2 ]; do
    comments=$(jq -c --arg login "$1" --arg text "$2" '. + [{author: {login: $login}, body: $text}]' <<<"$comments")
    shift 2
  done
  jq -n --arg login "$body_login" --arg text "$body_text" --argjson comments "$comments" \
    '{author: {login: $login}, body: $text, comments: $comments}' > "$STUB_DIRECTORY/issue-view.json"
}

calls_matching() {
  grep -c -- "$1" "$GH_LOG" || true
}

@test "red with no open issue creates the label then exactly one issue" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue create ')" -eq 1 ]
  [ "$(calls_matching '^label create ci-red-main --force')" -eq 1 ]
  label_line=$(grep -n '^label create' "$GH_LOG" | head -1 | cut -d: -f1)
  create_line=$(grep -n '^issue create' "$GH_LOG" | head -1 | cut -d: -f1)
  [ "$label_line" -lt "$create_line" ]
  grep -q -- '--label ci-red-main' "$GH_LOG"
  grep -qF -- '--title Main is red: GAIA: Audit CI Tests' "$GH_LOG"
  grep -qF -- "$RUN_URL" "$BODY_LOG"
  grep -qF -- "${BEFORE_SHA}..${HEAD_SHA}" "$BODY_LOG"
  grep -qF -- 'shard-alpha' "$BODY_LOG"
  grep -qF -- 'shard-beta' "$BODY_LOG"
  grep -qF -- "<!-- red-main-sha: ${HEAD_SHA} -->" "$BODY_LOG"
  grep -qF -- 'passing-shard' "$BODY_LOG" && return 1
  [ "$(calls_matching '^issue comment ')" -eq 0 ]
}

@test "the failing-leg listing reads only this run attempt's jobs" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "api --paginate repos/${REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs" "$GH_LOG"
}

@test "a zero before-commit names the head commit alone" {
  export BEFORE_SHA="0000000000000000000000000000000000000000"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "$HEAD_SHA" "$BODY_LOG"
  grep -qF -- '0000000' "$BODY_LOG" && return 1
  grep -qF -- '..' "$BODY_LOG" && return 1
  true
}

@test "an empty before-commit names the head commit alone" {
  export BEFORE_SHA=""
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "$HEAD_SHA" "$BODY_LOG"
  grep -qF -- '..' "$BODY_LOG" && return 1
  true
}

@test "red with an open issue comments on it and creates nothing" {
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue comment 42 ')" -eq 1 ]
  [ "$(calls_matching '^issue create ')" -eq 0 ]
  grep -qF -- "$RUN_URL" "$BODY_LOG"
  grep -qF -- 'shard-alpha' "$BODY_LOG"
  grep -qF -- "<!-- red-main-sha: ${HEAD_SHA} -->" "$BODY_LOG"
}

@test "two open issues: acts on the lowest number and creates nothing" {
  printf '51\n42\n' > "$STUB_DIRECTORY/issues.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue comment 42 ')" -eq 1 ]
  [ "$(calls_matching '^issue comment 51 ')" -eq 0 ]
  [ "$(calls_matching '^issue create ')" -eq 0 ]
}

@test "green on a descendant of the red commit closes with a link to the run" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" $'body\n<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->'
  printf 'ahead\n' > "$STUB_DIRECTORY/compare.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue close 42')" -eq 1 ]
  grep -qF -- "repos/${REPOSITORY}/compare/cccccccccccccccccccccccccccccccccccccccc...${HEAD_SHA}" "$GH_LOG"
  grep -qF -- "$RUN_URL" "$BODY_LOG"
}

@test "green on the identical commit also closes" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" "<!-- red-main-sha: ${HEAD_SHA} -->"
  printf 'identical\n' > "$STUB_DIRECTORY/compare.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue close 42')" -eq 1 ]
}

@test "the newest marker across body and comments decides the compare" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" "<!-- red-main-sha: 1111111111111111111111111111111111111111 -->" \
    "github-actions" "<!-- red-main-sha: 2222222222222222222222222222222222222222 -->"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "compare/2222222222222222222222222222222222222222...${HEAD_SHA}" "$GH_LOG"
  grep -qF -- "compare/1111111111111111111111111111111111111111" "$GH_LOG" && return 1
  true
}

@test "a marker in a comment from another author is ignored" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->" \
    "some-stranger" "<!-- red-main-sha: dddddddddddddddddddddddddddddddddddddddd -->"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "compare/cccccccccccccccccccccccccccccccccccccccc...${HEAD_SHA}" "$GH_LOG"
  grep -qF -- "compare/dddddddddddddddddddddddddddddddddddddddd" "$GH_LOG" && return 1
  true
}

@test "a marker only from another author counts as no marker" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "some-stranger" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue close ')" -eq 0 ]
  [ "$(calls_matching '^api repos/')" -eq 0 ]
}

@test "an unresolvable marker sha does not fail the reporter or close the issue" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->"
  : > "$STUB_DIRECTORY/compare-fails"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue close ')" -eq 0 ]
  [ "$(calls_matching '^issue comment 42 ')" -eq 1 ]
}

@test "green on an older or diverged commit does not close, and says so" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->"
  for compare_status in behind diverged; do
    : > "$GH_LOG"
    : > "$BODY_LOG"
    printf '%s\n' "$compare_status" > "$STUB_DIRECTORY/compare.txt"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(calls_matching '^issue close ')" -eq 0 ]
    [ "$(calls_matching '^issue comment 42 ')" -eq 1 ]
    grep -qF -- 'did not close' "$BODY_LOG"
  done
}

@test "green with an open issue that carries no marker does not close" {
  export SHARDS_RESULT="success"
  printf '42\n' > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" "hand-written issue"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue close ')" -eq 0 ]
  [ "$(calls_matching '^issue comment 42 ')" -eq 1 ]
}

@test "green with no open issue makes no write" {
  export SHARDS_RESULT="success"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qE '^(issue (create|comment|close)|label)' "$GH_LOG" && return 1
  true
}

@test "cancelled and skipped make no gh call at all" {
  for result in cancelled skipped; do
    : > "$GH_LOG"
    SHARDS_RESULT="$result" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$GH_LOG" ]
  done
}

@test "untrusted event text never reaches the issue" {
  export GITHUB_HEAD_REF='evil-branch $(touch pwned)'
  export GITHUB_REF_NAME='hostile-ref-name'
  export COMMIT_MESSAGE='fix: hostile commit message'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- 'evil-branch' "$BODY_LOG" "$GH_LOG" && return 1
  grep -qF -- 'hostile' "$BODY_LOG" "$GH_LOG" && return 1
  true
}

@test "the script never reads free-text event variables" {
  grep -qE 'head_commit|GITHUB_REF_NAME|GITHUB_HEAD_REF|github\.event\.' "$SCRIPT" && return 1
  true
}

@test "a failing gh call exits non-zero with a report-main-status line" {
  export GH_FAIL_ON="issue create"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"report-main-status:"* ]]
}

@test "a missing variable exits 2 before any gh call" {
  for variable in GH_TOKEN REPOSITORY RUN_ID RUN_ATTEMPT RUN_URL HEAD_SHA SHARDS_RESULT; do
    : > "$GH_LOG"
    run env -u "$variable" bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"report-main-status:"* ]]
    [[ "$output" == *"$variable"* ]]
    [ ! -s "$GH_LOG" ]
  done
}
