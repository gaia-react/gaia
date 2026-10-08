#!/usr/bin/env bats
#
# Suite for .gaia/scripts/file-tech-debt.sh: the security-first screen, the
# backend probe, the visibility re-read, dedup, filing, verify-after-file and
# the retry file. Every fixture lives under $BATS_TEST_TMPDIR; gh is a stub on
# PATH that logs each call and answers from files in $STUB.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/file-tech-debt.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# fixture_secret <kind>: a secret-shaped string assembled at run time, so no
# literal secret sits in this file.
fixture_secret() {
  case "$1" in
    token) printf '%s_%s' ghp "$(printf '%036d' 0)" ;;
    pat) printf '%s_%s_%s' github pat "$(printf '%030d' 0)" ;;
    access) printf '%s%s' AKIA "$(printf '%016d' 0)" ;;
    pem) printf -- '-----BEGIN %s %s-----' RSA 'PRIVATE KEY' ;;
  esac
}

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REAL_ROOT/.gaia/scripts/file-tech-debt.sh"
  WORK_REPO="$BATS_TEST_TMPDIR/repo"
  STUB="$BATS_TEST_TMPDIR/stub"
  OUTCOMES="$BATS_TEST_TMPDIR/run/outcomes.jsonl"
  FINDING="$BATS_TEST_TMPDIR/finding.json"
  SHAPED_TOKEN="$(fixture_secret token)"
  SHAPED_PAT="$(fixture_secret pat)"
  SHAPED_ACCESS="$(fixture_secret access)"
  SHAPED_PEM="$(fixture_secret pem)"
  mkdir -p "$WORK_REPO" "$STUB" "$BATS_TEST_TMPDIR/bin"
  git -C "$WORK_REPO" init -q
  write_gh_stub
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cd "$WORK_REPO" || return 1
  printf 'PRIVATE\n' >"$STUB/visibility"
  make_finding '.'
}

# write_gh_stub: a gh that logs "$*" and answers per subcommand from $STUB.
write_gh_stub() {
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
stub="$STUB_DIR"
printf '%s\n' "$*" >>"$stub/log"
# pop <name>: first line of a sequence file; the last line repeats.
pop() {
  [ -f "$stub/$1" ] || return 1
  head -n1 "$stub/$1"
  if [ "$(wc -l <"$stub/$1")" -gt 1 ]; then
    tail -n +2 "$stub/$1" >"$stub/$1.next"
    mv "$stub/$1.next" "$stub/$1"
  fi
}
args="$*"
case "$args" in
  *"--json nameWithOwner"*)
    cat "$stub/name" 2>/dev/null || echo owner/name
    ;;
  *"--json visibility"*)
    value="$(pop visibility)" || exit 1
    case "$value" in
      FAIL) exit 1 ;;
      EMPTY) exit 0 ;;
    esac
    echo "$value"
    ;;
  *"--json hasIssuesEnabled"*)
    if [ -f "$stub/probe-fail" ]; then
      cat "$stub/probe-fail" >&2
      exit 1
    fi
    cat "$stub/probe-view" 2>/dev/null || echo '{"hasIssuesEnabled":true,"viewerPermission":"ADMIN"}'
    ;;
  "issue list"*"--limit 1 "*)
    if [ -f "$stub/list-probe-fail" ]; then
      cat "$stub/list-probe-fail" >&2
      exit 1
    fi
    echo '[]'
    ;;
  "issue list"*"--state open"*)
    [ -f "$stub/list-fail" ] && exit 1
    cat "$stub/open.json" 2>/dev/null || echo '[]'
    ;;
  "issue list"*"--state closed"*)
    cat "$stub/closed.json" 2>/dev/null || echo '[]'
    ;;
  "issue create"*)
    [ -f "$stub/create-fail" ] && exit 1
    body_file="$(printf '%s\n' "$@" | sed -n '/^--body-file$/{n;p;}')"
    count=0
    [ -f "$stub/open.json" ] && count="$(jq 'length' "$stub/open.json")"
    if [ ! -f "$stub/create-invisible" ]; then
      [ -f "$stub/open.json" ] || echo '[]' >"$stub/open.json"
      jq -c --rawfile body "$body_file" --argjson number "$((101 + count))" '. + [{number: $number, body: $body}]' \
        "$stub/open.json" >"$stub/open.next"
      mv "$stub/open.next" "$stub/open.json"
    fi
    echo "https://github.com/owner/name/issues/$((101 + count))"
    ;;
  "label list"*)
    cat "$stub/labels" 2>/dev/null || printf 'tech-debt\nseverity:important\nseverity:suggestion\nseverity:critical\naudience:adopter\n'
    ;;
  *) ;;
esac
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export STUB_DIR="$STUB"
}

# make_finding <jq-filter>: the default non-security finding, then the filter.
make_finding() {
  jq -n -c "{member: \"code-audit-frontend\", finding_class: \"holistic/swallowed-error\", path: \"app/a.ts\", line: 10,
    severity: \"warning\", security: false, title: \"TITLE-SENTINEL\", failure_mode: \"FAILURE-SENTINEL\",
    suggested_fix: \"FIX-SENTINEL\", audience: \"adopter\"} | $1" >"$FINDING"
}

# reset_state: a clean stub log and record directory between loop iterations.
reset_state() {
  rm -f "$STUB/log" "$OUTCOMES" "$STUB/open.json" "$STUB/closed.json"
  rm -rf "$WORK_REPO/.gaia/local" "$BATS_TEST_TMPDIR/run"
}

run_file() {
  run bash "$SCRIPT" file --finding "$FINDING" --outcome-file "$OUTCOMES" --repo owner/name "$@"
}

# has_write_call: true when the stub log shows any gh write verb.
has_write_call() {
  [ -f "$STUB/log" ] || return 1
  grep -Eq '^(issue create|issue edit|label create)|^api .*(-X|--method)[ =]?(POST|PATCH|PUT)' "$STUB/log"
}

record_count() {
  find "$WORK_REPO/.gaia/local/audit/security" -type f 2>/dev/null | wc -l | tr -d ' '
}

retry_count() {
  find "$BATS_TEST_TMPDIR/run/filing-retry" -type f 2>/dev/null | wc -l | tr -d ' '
}

# security_cases: one jq filter per trigger, paired with the trigger it names.
security_cases() {
  cat <<CASES
.security = true|flag-true
del(.security)|flag-absent
.security = "yes"|flag-non-boolean
.severity = "error"|severity-error
.issue_severity = "Critical"|issue-severity-critical
.failure_mode = "token $SHAPED_TOKEN"|secret-shaped
.failure_mode = "token $SHAPED_PAT"|secret-shaped
.failure_mode = "key $SHAPED_ACCESS here"|secret-shaped
.failure_mode = "$SHAPED_PEM"|secret-shaped
del(.finding_class)|class-absent
.finding_class = "not a class!"|class-malformed
CASES
}

# --- screen --------------------------------------------------------------------

@test "screen names the trigger for each security case and exits 1" {
  local seen=0 filter trigger
  while IFS='|' read -r filter trigger; do
    make_finding "$filter"
    run bash "$SCRIPT" screen --finding "$FINDING"
    [ "$status" -eq 1 ] || { echo "no divert for: $filter ($output)"; return 1; }
    [ "$output" = "security $trigger" ] || { echo "wrong trigger for: $filter ($output)"; return 1; }
    seen=$((seen + 1))
  done < <(security_cases)
  [ "$seen" -eq 11 ]
}

@test "screen is clear for a documented non-security finding and for holistic/unclassified" {
  run bash "$SCRIPT" screen --finding "$FINDING"
  [ "$status" -eq 0 ]
  [ "$output" = clear ]
  make_finding '.finding_class = "holistic/unclassified"'
  run bash "$SCRIPT" screen --finding "$FINDING"
  [ "$status" -eq 0 ]
  [ "$output" = clear ]
}

@test "screen-text exits 1 on each secret fixture and 0 on clean text" {
  local fixture
  for fixture in "$SHAPED_TOKEN" "$SHAPED_PAT" "$SHAPED_ACCESS" "$SHAPED_PEM"; do
    printf 'text %s more\n' "$fixture" >"$BATS_TEST_TMPDIR/text.txt"
    run bash "$SCRIPT" screen-text --text-file "$BATS_TEST_TMPDIR/text.txt"
    [ "$status" -eq 1 ] || { echo "missed: $fixture"; return 1; }
  done
  printf 'a plain sentence about ghp prefixes and AKIA keys\n' >"$BATS_TEST_TMPDIR/text.txt"
  run bash "$SCRIPT" screen-text --text-file "$BATS_TEST_TMPDIR/text.txt"
  [ "$status" -eq 0 ]
  [ "$output" = clear ]
}

# --- divert --------------------------------------------------------------------

@test "every security trigger diverts on every non-private visibility answer with no gh write" {
  local filter trigger visibility record combinations=0
  while IFS='|' read -r filter trigger; do
    for visibility in PUBLIC INTERNAL FAIL EMPTY; do
      reset_state
      printf '%s\n' "$visibility" >"$STUB/visibility"
      make_finding "$filter"
      run_file
      [ "$status" -eq 0 ] || { echo "$trigger/$visibility: status $status ($output)"; return 1; }
      has_write_call && { echo "$trigger/$visibility: a gh write ran"; return 1; }
      [ "$(record_count)" -eq 1 ] || { echo "$trigger/$visibility: record count $(record_count)"; return 1; }
      record="$(find "$WORK_REPO/.gaia/local/audit/security" -type f | head -n1)"
      # The script prints the physically resolved root, so compare by suffix.
      case "$output" in
        "diverted 1 "*"/.gaia/local/audit/security/$(basename "$record")") ;;
        *) echo "$trigger/$visibility: stdout $output"; return 1 ;;
      esac
      [ "$(jq -r '.outcome' "$OUTCOMES")" = diverted ] || return 1
      [ "$(wc -l <"$OUTCOMES" | tr -d ' ')" -eq 1 ] || return 1
      grep -q 'SENTINEL' "$OUTCOMES" && { echo "$trigger/$visibility: finding text in the outcome line"; return 1; }
      grep -q -e "$trigger" "$OUTCOMES" && { echo "$trigger/$visibility: trigger in the outcome line"; return 1; }
      grep -q 'SENTINEL' <<<"$output" && return 1
      grep -q 'FAILURE-SENTINEL' "$record" || grep -q 'Trigger: ' "$record" || { echo "$trigger/$visibility: record lacks content"; return 1; }
      combinations=$((combinations + 1))
    done
  done < <(security_cases)
  [ "$combinations" -eq 44 ]
}

@test "a security finding diverts under each probe outcome even on a private repository" {
  local scenario
  for scenario in absent transient; do
    reset_state
    rm -f "$STUB/probe-fail"
    case "$scenario" in
      absent) printf '{"hasIssuesEnabled":false,"viewerPermission":"ADMIN"}\n' >"$STUB/probe-view" ;;
      transient) printf 'HTTP 502: bad gateway\n' >"$STUB/probe-fail" ;;
    esac
    make_finding '.security = true'
    run_file
    [ "$status" -eq 0 ]
    [ "$(jq -r '.outcome' "$OUTCOMES")" = diverted ] || return 1
    [ "$(record_count)" -eq 1 ] || return 1
    has_write_call && return 1
    [ "$(retry_count)" -eq 0 ] || return 1
  done
  true
}

@test "a visibility flip between the two reads diverts, and the re-read is the last gh call" {
  printf 'PRIVATE\nPUBLIC\n' >"$STUB/visibility"
  make_finding '.security = true'
  run_file
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$OUTCOMES")" = diverted ]
  has_write_call && return 1
  [ "$(tail -n1 "$STUB/log")" = "repo view owner/name --json visibility --jq .visibility" ]
  [ "$(grep -c -e '--json visibility' "$STUB/log")" -eq 2 ]
}

@test "a security finding files normally when both visibility reads answer PRIVATE" {
  make_finding '.security = true'
  run_file
  [ "$status" -eq 0 ]
  [ "$output" = "filed 101" ]
  [ "$(grep -c '^issue create' "$STUB/log")" -eq 1 ]
  grep -q '^issue create --repo owner/name ' "$STUB/log"
  grep -q -e ' --body-file ' "$STUB/log"
  grep -q -e ' --body ' "$STUB/log" && return 1
  local create_line
  create_line="$(grep -n '^issue create' "$STUB/log" | cut -d: -f1)"
  [ "$(sed -n "$((create_line - 1))p" "$STUB/log")" = "repo view owner/name --json visibility --jq .visibility" ]
  [ "$(record_count)" -eq 0 ]
}

@test "a caller-requested divert diverts a clear finding without any gh call" {
  run_file --disposition divert
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$OUTCOMES")" = diverted ]
  [ "$(jq -r '.disposition' "$OUTCOMES")" = divert ]
  [ "$(record_count)" -eq 1 ]
  [ ! -f "$STUB/log" ]
}

@test "a holistic/unclassified warning on a public repository proceeds to filing" {
  printf 'PUBLIC\n' >"$STUB/visibility"
  make_finding '.finding_class = "holistic/unclassified"'
  run_file
  [ "$status" -eq 0 ]
  [ "$output" = "filed 101" ]
  [ "$(record_count)" -eq 0 ]
  grep -q -e '--json visibility' "$STUB/log" && return 1
  true
}

# --- probe ---------------------------------------------------------------------

@test "probe classifies each backend answer" {
  local entry expected_status expected_word view_json message
  for entry in \
    'absent|10|{"hasIssuesEnabled":false,"viewerPermission":"ADMIN"}' \
    'absent|10|{"hasIssuesEnabled":true,"viewerPermission":"READ"}' \
    'present|0|{"hasIssuesEnabled":true,"viewerPermission":"WRITE"}'; do
    rm -f "$STUB/probe-fail"
    IFS='|' read -r expected_word expected_status view_json <<<"$entry"
    printf '%s\n' "$view_json" >"$STUB/probe-view"
    run bash "$SCRIPT" probe --repo owner/name
    [ "$status" -eq "$expected_status" ] || { echo "$entry: status $status"; return 1; }
    [ "$output" = "$expected_word" ] || { echo "$entry: $output"; return 1; }
  done
  rm -f "$STUB/probe-view"
  for entry in 'To get started with GitHub CLI, please run:  gh auth login|absent|10' \
    'Could not resolve to a Repository with the name x|absent|10' \
    'HTTP 502: bad gateway|transient|11' \
    'API rate limit exceeded|transient|11' \
    'context deadline exceeded (timeout)|transient|11' \
    'something nobody classified|transient|11'; do
    IFS='|' read -r message expected_word expected_status <<<"$entry"
    printf '%s\n' "$message" >"$STUB/probe-fail"
    run bash "$SCRIPT" probe --repo owner/name
    [ "$status" -eq "$expected_status" ] || { echo "$message: status $status"; return 1; }
    [ "$output" = "$expected_word" ] || { echo "$message: $output"; return 1; }
  done
  rm -f "$STUB/probe-fail"
  printf 'GraphQL: the repository has disabled issues\n' >"$STUB/list-probe-fail"
  run bash "$SCRIPT" probe --repo owner/name
  [ "$status" -eq 10 ]
  printf 'HTTP 503\n' >"$STUB/list-probe-fail"
  run bash "$SCRIPT" probe --repo owner/name
  [ "$status" -eq 11 ]
}

@test "probe without --repo is a usage error" {
  run bash "$SCRIPT" probe
  [ "$status" -eq 2 ]
}

@test "the screen runs before the probe: a divert on a public repository never probes" {
  printf 'PUBLIC\n' >"$STUB/visibility"
  make_finding '.security = true'
  run_file
  grep -q -e 'hasIssuesEnabled' "$STUB/log" && return 1
  grep -q -e '^issue list' "$STUB/log" && return 1
  make_finding '.'
  reset_state
  run_file
  [ "$(head -n1 "$STUB/log")" = "repo view owner/name --json hasIssuesEnabled,viewerPermission" ]
}

# --- per-outcome filing --------------------------------------------------------

@test "a non-security finding under an absent backend files nothing and writes outcome absent" {
  printf '{"hasIssuesEnabled":false,"viewerPermission":"ADMIN"}\n' >"$STUB/probe-view"
  run_file
  [ "$status" -eq 0 ]
  [ "$output" = absent ]
  [ "$(jq -r '.outcome' "$OUTCOMES")" = absent ]
  has_write_call && return 1
  true
}

@test "a transient backend writes outcome transient, exits 0 and retains the finding" {
  printf 'HTTP 502\n' >"$STUB/probe-fail"
  run_file
  [ "$status" -eq 0 ]
  [ "$output" = transient ]
  [ "$(jq -r '.outcome' "$OUTCOMES")" = transient ]
  has_write_call && return 1
  local key_hash
  key_hash="$(printf '%s' '<!-- gaia-debt-key: v1 class=holistic/swallowed-error path=app/a.ts line=10 -->' | shasum -a 256 | cut -d' ' -f1)"
  [ "$(retry_count)" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/run/filing-retry/$key_hash.json" "$FINDING"
}

@test "the retry file is removed by a later filed, absent or failed run and kept by another transient" {
  printf 'HTTP 502\n' >"$STUB/probe-fail"
  run_file
  [ "$(retry_count)" -eq 1 ]
  run_file
  [ "$(retry_count)" -eq 1 ]
  rm -f "$STUB/probe-fail"
  run_file
  [ "$output" = "filed 101" ]
  [ "$(retry_count)" -eq 0 ]
  rm -f "$STUB/open.json"
  printf 'HTTP 502\n' >"$STUB/probe-fail"
  run_file
  [ "$(retry_count)" -eq 1 ]
  rm -f "$STUB/probe-fail"
  printf '{"hasIssuesEnabled":false,"viewerPermission":"ADMIN"}\n' >"$STUB/probe-view"
  run_file
  [ "$output" = absent ]
  [ "$(retry_count)" -eq 0 ]
  rm -f "$STUB/probe-view"
  printf 'HTTP 502\n' >"$STUB/probe-fail"
  run_file
  [ "$(retry_count)" -eq 1 ]
  rm -f "$STUB/probe-fail"
  touch "$STUB/create-fail"
  run_file
  [ "$status" -eq 1 ]
  [ "$(retry_count)" -eq 0 ]
}

@test "two runs into one outcome file append two schema-valid lines" {
  printf '{"hasIssuesEnabled":false,"viewerPermission":"ADMIN"}\n' >"$STUB/probe-view"
  run_file
  rm -f "$STUB/probe-view"
  printf 'HTTP 502\n' >"$STUB/probe-fail"
  make_finding '.line = 11'
  run_file
  [ "$(wc -l <"$OUTCOMES" | tr -d ' ')" -eq 2 ]
  [ "$(jq -r '.outcome' "$OUTCOMES" | paste -sd, -)" = "absent,transient" ]
  jq -e -s 'all(.[]; (keys | sort) == ["disposition","issue","key","outcome","record"]
    and (.key | keys | sort) == ["finding_class","line","member","path"])' "$OUTCOMES" >/dev/null
}

# --- filing, dedup and verify --------------------------------------------------

@test "filing creates one issue with --body-file and verifies it" {
  run_file
  [ "$status" -eq 0 ]
  [ "$output" = "filed 101" ]
  [ "$(jq -r '.issue' "$OUTCOMES")" = 101 ]
  grep -q -e '--label tech-debt --label severity:important' "$STUB/log"
  grep -q -e ' --body ' "$STUB/log" && return 1
  jq -e '.[0].body | contains("<!-- gaia-debt-key: v1 class=holistic/swallowed-error path=app/a.ts line=10 -->")' "$STUB/open.json" >/dev/null
}

@test "an open issue carrying the key is recorded as filed with its number and nothing is created" {
  printf '[{"number":7,"body":"<!-- gaia-debt-key: v1 class=holistic/other path=app/a.ts line=10 -->"}]\n' >"$STUB/open.json"
  run_file
  [ "$output" = "filed 7" ]
  grep -q '^issue create' "$STUB/log" && return 1
  true
}

@test "a declined-closed match is not filed again and records the matched number" {
  printf '[{"number":9,"body":"<!-- gaia-debt-key: v1 class=holistic/swallowed-error path=app/a.ts line=10 -->","labels":[{"name":"wontfix"}],"stateReason":"NOT_PLANNED"}]\n' >"$STUB/closed.json"
  run_file
  [ "$output" = "filed 9" ]
  grep -q '^issue create' "$STUB/log" && return 1
  true
}

@test "a create whose key the re-query cannot find is failed with exit 1" {
  touch "$STUB/create-invisible"
  run_file
  [ "$status" -eq 1 ]
  [ "$output" = "failed verify-after-file" ]
  [ "$(jq -r '.outcome' "$OUTCOMES")" = failed ]
}

@test "a create that itself fails on a present backend writes failed" {
  touch "$STUB/create-fail"
  run_file
  [ "$status" -eq 1 ]
  [ "$(jq -r '.outcome' "$OUTCOMES")" = failed ]
}

@test "a metadata check failure files nothing and writes failed" {
  jq -c '.grade = "trivial"' "$FINDING" >"$FINDING.next" && mv "$FINDING.next" "$FINDING"
  run_file
  [ "$status" -eq 1 ]
  case "$output" in
    *"failed metadata-check") ;;
    *) echo "$output"; return 1 ;;
  esac
  grep -q '^issue create' "$STUB/log" && return 1
  true
}

# --- repo pinning, tools, usage ------------------------------------------------

@test "every gh call carries the same --repo" {
  run_file
  local unpinned
  unpinned="$(grep -v -e '--repo owner/name' -e '^repo view owner/name ' "$STUB/log" | wc -l | tr -d ' ')"
  [ "$unpinned" -eq 0 ]
  [ "$(wc -l <"$STUB/log" | tr -d ' ')" -gt 5 ]
}

@test "a run without --repo resolves it once and pins it" {
  run bash "$SCRIPT" file --finding "$FINDING" --outcome-file "$OUTCOMES"
  [ "$status" -eq 0 ]
  [ "$(grep -c -e '--json nameWithOwner' "$STUB/log")" -eq 1 ]
  [ "$(grep -v -e '--json nameWithOwner' "$STUB/log" | grep -v -e '--repo owner/name' | grep -vc '^repo view owner/name ')" -eq 0 ]
}

@test "a missing jq exits 3 with a message" {
  local lean="$BATS_TEST_TMPDIR/lean" tool
  mkdir -p "$lean"
  for tool in bash dirname cat mktemp rm; do
    ln -s "$(command -v "$tool")" "$lean/$tool"
  done
  run env PATH="$lean" bash "$SCRIPT" screen --finding "$FINDING"
  [ "$status" -eq 3 ]
  grep -q 'jq' <<<"$output"
}

@test "an unreadable finding exits 3 and an unknown subcommand exits 2" {
  run bash "$SCRIPT" screen --finding "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 3 ]
  printf 'not json' >"$BATS_TEST_TMPDIR/bad.json"
  run bash "$SCRIPT" file --finding "$BATS_TEST_TMPDIR/bad.json" --outcome-file "$OUTCOMES" --repo owner/name
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" nonsense
  [ "$status" -eq 2 ]
}

@test "the full filing path runs under the system bash (3.2 on macOS) with set -u" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash "$SCRIPT" file --finding "$FINDING" --outcome-file "$OUTCOMES" --repo owner/name
  [ "$status" -eq 0 ]
  [ "$output" = "filed 101" ]
}
