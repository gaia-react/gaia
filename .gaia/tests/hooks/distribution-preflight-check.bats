#!/usr/bin/env bats
# Tests for the distribution pre-flight gate
# (.claude/hooks/distribution-preflight-check.sh), the PreToolUse hook that
# denies `gh pr create` when a file this branch newly ships has no answer in
# the committed .gaia/manifest.json.
#
# The tests drive the REAL hook by absolute path ($HOOK_ABS) with cwd set to a
# fixture git repo, exactly as the harness runs it: a PreToolUse JSON payload
# on stdin, allow vs deny carried in stdout (the hook always exits 0; a deny
# emits `"permissionDecision": "deny"`).
#
# The maintainer binary is mocked as a fixture script that prints a
# `release manifest --check --json` report. The hook resolves it as the
# repo-relative path .gaia/cli/gaia-maintainer, so the mock lands inside the
# fixture repo and the real binary is never invoked.
#
# Fixture shape, three branches in a chain so the resolved base actually
# changes the answer:
#
#   main     base.txt
#   develop  + shipped.txt   (branched from main)
#   feature  + feature.txt   (branched from develop)
#
# The mock reports shipped.txt as `missing`. Against the default base (main)
# the three-dot changed set is {shipped.txt, feature.txt}, which intersects and
# DENIES. Against an explicit `--base develop` it is {feature.txt}, which does
# not intersect and ALLOWS.
#
# That asymmetry is deliberate and load-bearing: it is what gives the base-ref
# tests teeth. If develop and main pointed at the same commit, a hook that
# parsed `--base=develop` correctly and one that ignored the flag entirely
# would produce identical output, and the tests would pass against the bug
# they exist to catch.
#
# Assertion style (.claude/rules/bats-assertions.md): `grep -q` / `[ ]` /
# explicit `return 1`; absence assertions written as
# `<positive-bad-case> && return 1`, never `! grep -q`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/distribution-preflight-check.sh"
  [ -f "$HOOK_ABS" ] || skip "distribution-preflight-check.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  command -v git >/dev/null 2>&1 || skip "git not available"

  FIXTURE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init --quiet --initial-branch=main
  git -C "$FIXTURE" config user.email "test@example.com"
  git -C "$FIXTURE" config user.name "Test"

  printf 'base\n' > "$FIXTURE/base.txt"
  git -C "$FIXTURE" add base.txt
  git -C "$FIXTURE" commit --quiet -m "base"

  # develop carries shipped.txt, so it is this branch's own change against main
  # but NOT against develop.
  git -C "$FIXTURE" checkout --quiet -b develop
  printf 'ship\n' > "$FIXTURE/shipped.txt"
  git -C "$FIXTURE" add shipped.txt
  git -C "$FIXTURE" commit --quiet -m "add shipped.txt"

  git -C "$FIXTURE" checkout --quiet -b feature
  printf 'feat\n' > "$FIXTURE/feature.txt"
  git -C "$FIXTURE" add feature.txt
  git -C "$FIXTURE" commit --quiet -m "add feature.txt"
}

# install_maintainer_mock [MISSING_JSON]:
#   Writes an executable .gaia/cli/gaia-maintainer inside the fixture that
#   prints a --check report. Defaults to reporting shipped.txt as unanswered.
install_maintainer_mock() {
  # Assigned in two steps on purpose: a `}` inside a `${1:-default}` closes the
  # expansion early, so a JSON default inlined there silently truncates.
  local missing="$1"
  [ -n "$missing" ] || missing='[{"file":"shipped.txt"}]'
  mkdir -p "$FIXTURE/.gaia/cli"
  printf '%s' "$missing" > "$FIXTURE/.gaia/missing.json"
  cat > "$FIXTURE/.gaia/cli/gaia-maintainer" <<'EOF'
#!/usr/bin/env bash
# `release manifest --check --json` exits 1 on any drift; that is data, not
# failure, and the hook treats exit < 2 as a usable report.
printf '{"missing":%s}' "$(cat "$(dirname "$0")/../missing.json")"
exit 1
EOF
  chmod +x "$FIXTURE/.gaia/cli/gaia-maintainer"
}

# run_hook COMMAND [TOOL_NAME]: drive the hook with a PreToolUse payload.
# The payload goes through a file rather than a here-string so command bodies
# carrying quotes and newlines survive verbatim. cwd is the fixture repo
# because the hook resolves .gaia/cli/gaia-maintainer repo-relative.
run_hook() {
  local cmd="$1" tool="${2:-Bash}" payload_file="$BATS_TEST_TMPDIR/payload.json"
  jq -n --arg t "$tool" --arg c "$cmd" \
    '{tool_name: $t, tool_input: {command: $c}}' > "$payload_file"
  run bash -c "cd \"\$1\" && bash \"\$2\" < \"\$3\"" _ \
    "$FIXTURE" "$HOOK_ABS" "$payload_file"
}

assert_deny() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
}

assert_allow() {
  [ "$status" -eq 0 ]
  grep -qF -- 'deny' <<<"$output" && return 1
  [ -z "$output" ]
}

# ---- adopter inertness -------------------------------------------------

@test "exits 0 with empty stdout when the maintainer binary is absent" {
  # No install_maintainer_mock: this is the adopter-clone path the hook's
  # ADOPTER POSTURE header depends on.
  run_hook "gh pr create --title x"
  assert_allow
}

@test "exits 0 when the maintainer binary exists but is not executable" {
  install_maintainer_mock
  chmod -x "$FIXTURE/.gaia/cli/gaia-maintainer"
  run_hook "gh pr create --title x"
  assert_allow
}

# ---- tool gating -------------------------------------------------------

@test "ignores a non-Bash tool" {
  install_maintainer_mock
  run_hook "gh pr create --title x" "Read"
  assert_allow
}

# ---- command-position matching -----------------------------------------

@test "denies gh pr create at command start" {
  install_maintainer_mock
  run_hook "gh pr create --title x"
  assert_deny
}

@test "denies gh pr create with leading whitespace" {
  install_maintainer_mock
  run_hook "   gh pr create --title x"
  assert_deny
}

@test "denies gh pr create after each shell separator" {
  install_maintainer_mock
  local sep
  for sep in '&&' ';' '||' '|'; do
    run_hook "echo hi ${sep} gh pr create --title x"
    [ "$status" -eq 0 ]
    grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  done
}

@test "denies gh pr create after a newline separator" {
  install_maintainer_mock
  run_hook "$(printf 'git add -A\ngh pr create --fill')"
  assert_deny
}

@test "allows a mid-line mention inside a quoted string" {
  install_maintainer_mock
  run_hook 'echo "run gh pr create later"'
  assert_allow
}

@test "allows a mid-line mention inside a commit message" {
  install_maintainer_mock
  run_hook 'git commit -m "gh pr create"'
  assert_allow
}

@test "allows a command that merely names the gh binary" {
  install_maintainer_mock
  run_hook "gh pr view 916"
  assert_allow
}

@test "KNOWN RESIDUAL: a heredoc line beginning with gh pr create matches" {
  # Documented in the hook header: newline is in the separator set because the
  # multi-line `git add -A` / `gh pr create` shape is a real invocation, and
  # telling that apart from heredoc body text needs shell parsing. Pinned here
  # so the trade stays deliberate rather than drifting silently.
  install_maintainer_mock
  run_hook "$(printf 'cat <<EOF\ngh pr create\nEOF')"
  assert_deny
}

# ---- base-ref resolution -----------------------------------------------

@test "with no base flag, falls back to the default branch and denies" {
  # The contrast case for the tests below: against main, shipped.txt is this
  # branch's own change, so the gate denies.
  install_maintainer_mock
  run_hook "gh pr create --title x"
  assert_deny
}

@test "resolves every pflag base form identically" {
  # Each form must resolve develop, whose changed set excludes shipped.txt and
  # therefore ALLOWS. A hook that fails to parse the form falls back to main
  # and denies, so this fails against the space-only pattern. `-Bdevelop` is
  # pflag's no-separator shorthand and is only legal on the single-letter alias.
  install_maintainer_mock
  local form
  for form in '--base develop' '-B develop' '--base=develop' '-B=develop' '-Bdevelop'; do
    run_hook "gh pr create ${form} --title x"
    [ "$status" -eq 0 ]
    grep -qF -- 'deny' <<<"$output" && return 1
    [ -z "$output" ] || return 1
  done
}

@test "accepts a quoted base ref" {
  install_maintainer_mock
  run_hook 'gh pr create --base "develop" --title x'
  assert_allow
}

@test "does not treat --base-ref as the base flag" {
  # --base-ref must not resolve as --base: the value never reaches git, so the
  # hook falls back to main and denies on shipped.txt.
  install_maintainer_mock
  run_hook "gh pr create --base-ref develop --title x"
  assert_deny
}

@test "an earlier command's -B flag is not read as this invocation's base" {
  # `grep -B2` is context-lines, not a base ref. Parsing the whole command
  # string would capture `2`, which resolves to nothing and silently no-ops the
  # gate; scoping to the text after `gh pr create` keeps the real default base,
  # so shipped.txt is still caught.
  install_maintainer_mock
  run_hook "grep -B2 foo base.txt && gh pr create --fill"
  assert_deny
}

@test "an unresolvable base ref fails open" {
  install_maintainer_mock
  run_hook "gh pr create --base no-such-branch --title x"
  assert_allow
}

# ---- intersection logic ------------------------------------------------

@test "allows when the unanswered file is not this branch's own change" {
  # base.txt exists on main, so it is not in the three-dot changed set; an
  # inherited manifest backlog must never block this branch's PR.
  install_maintainer_mock '[{"file":"base.txt"}]'
  run_hook "gh pr create --title x"
  assert_allow
}

@test "allows when the report lists nothing missing" {
  install_maintainer_mock '[]'
  run_hook "gh pr create --title x"
  assert_allow
}

@test "names every offending file in the deny reason" {
  git -C "$FIXTURE" checkout --quiet feature
  printf 'two\n' > "$FIXTURE/second.txt"
  git -C "$FIXTURE" add second.txt
  git -C "$FIXTURE" commit --quiet -m "add second.txt"
  install_maintainer_mock '[{"file":"shipped.txt"},{"file":"second.txt"}]'
  run_hook "gh pr create --title x"
  assert_deny
  grep -qF -- 'shipped.txt' <<<"$output" || return 1
  grep -qF -- 'second.txt' <<<"$output" || return 1
  grep -qF -- '2 newly-shipping file(s)' <<<"$output" || return 1
}

# ---- fail-open on a broken checker -------------------------------------

@test "fails open when the checker emits non-JSON" {
  install_maintainer_mock
  cat > "$FIXTURE/.gaia/cli/gaia-maintainer" <<'EOF'
#!/usr/bin/env bash
printf 'not json at all'
exit 1
EOF
  chmod +x "$FIXTURE/.gaia/cli/gaia-maintainer"
  run_hook "gh pr create --title x"
  assert_allow
}

@test "fails open when the checker exits 2 or higher" {
  install_maintainer_mock
  cat > "$FIXTURE/.gaia/cli/gaia-maintainer" <<'EOF'
#!/usr/bin/env bash
printf '{"missing":[{"file":"shipped.txt"}]}'
exit 2
EOF
  chmod +x "$FIXTURE/.gaia/cli/gaia-maintainer"
  run_hook "gh pr create --title x"
  assert_allow
}

# ---- deny payload shape ------------------------------------------------

@test "deny payload is well-formed PreToolUse JSON" {
  install_maintainer_mock
  run_hook "gh pr create --title x"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null || return 1
  local event decision reason
  event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
  decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [ "$event" = "PreToolUse" ]
  [ "$decision" = "deny" ]
  grep -qF -- '/distribution-audit' <<<"$reason" || return 1
}
