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

  # Advance main past the branch point with a MODIFICATION to a file the branch
  # does not touch. Without this the fixture is a linear chain, where two-dot
  # and three-dot diffs are identical by construction and the hook's three-dot
  # comparison, which its own comments call load-bearing for parity with
  # distribution-audit-pr.yml, cannot be observed by any test. A modification
  # rather than an addition is what makes it visible: under two-dot it reports
  # as `M` and passes the ACMR filter, whereas a main-only addition would report
  # as `D` and be filtered out.
  git -C "$FIXTURE" checkout --quiet main
  printf 'base changed on main\n' > "$FIXTURE/base.txt"
  git -C "$FIXTURE" add base.txt
  git -C "$FIXTURE" commit --quiet -m "main-side change to base.txt"
  git -C "$FIXTURE" checkout --quiet feature
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

@test "resolves the base through a separator branch too" {
  # The separator branch reads different capture groups than the command-start
  # branch, and every other separator test asserts DENY, which is also what a
  # junk tail produces. Only a positive ALLOW through a separator can tell a
  # correct capture from an off-by-one one.
  install_maintainer_mock
  run_hook "echo hi && gh pr create --base develop --title x"
  assert_allow
}

@test "accepts a quoted base ref" {
  install_maintainer_mock
  run_hook 'gh pr create --base "develop" --title x'
  assert_allow
}

@test "strips quotes from a base ref, both quote styles" {
  # Deliberately picks a base whose CORRECT resolution denies. Asserting ALLOW
  # on a quoted ref proves nothing: a broken strip leaves `main"`, which
  # resolves to nothing and fails open to ALLOW, so the passing and failing
  # paths are indistinguishable. Asserting DENY is what makes the strip
  # observable, because only a correctly stripped ref resolves far enough to
  # produce a denial.
  install_maintainer_mock
  run_hook 'gh pr create --base "main" --title x'
  assert_deny
  run_hook "gh pr create --base 'main' --title x"
  assert_deny
}

@test "a separator directly abutting the command still gates" {
  # The character after `create` is a separator, so it is neither whitespace
  # nor end-of-string. Without the separator in the boundary group these match
  # nothing and skip the gate entirely.
  #
  # The last three forms carry a resolvable base ref in the swept-up text, so
  # they exercise the other half of the fix: the boundary group widening lets
  # them match, and the null-out is what keeps the following command's `--base`
  # out of the tail. Forms whose tails hold no resolvable ref (the first four)
  # deny either way and cannot tell the two halves apart.
  install_maintainer_mock
  local form
  for form in 'gh pr create;' 'gh pr create; echo done' 'gh pr create&&echo hi' 'gh pr create|cat' \
              'gh pr create; echo --base develop' 'gh pr create& echo --base develop' \
              'gh pr create|grep --base develop'; do
    run_hook "$form"
    [ "$status" -eq 0 ]
    grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  done
}

@test "KNOWN RESIDUAL: a --base inside this invocation's own --body is parsed" {
  # Documented in the hook header. Within the tail this is a regex, not an
  # argument parse, so body prose that reads like a flag is taken as one. The
  # third of the three accepted trades, pinned like the other two so it cannot
  # drift into looking like a bug.
  install_maintainer_mock
  run_hook 'gh pr create --body "use --base develop next time"'
  assert_allow
}

@test "KNOWN RESIDUAL: a quoted separator can rebind the match to a mention" {
  # Documented in the hook header. The `;` inside the quoted string is the
  # leftmost separator, so sep_re binds to the quoted mention instead of the
  # real invocation and adopts its --base, narrowing the changed set enough to
  # allow. Pinned so the accepted trade cannot drift into looking like a bug,
  # the same way the heredoc trade is pinned above.
  install_maintainer_mock
  run_hook 'echo "x; gh pr create --base develop" && gh pr create --fill'
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

@test "an earlier command's -B survives a tab-spelled invocation" {
  # The tail is captured by the same regex that matched the invocation, which
  # accepts any whitespace run. A glob strip would match only single ASCII
  # spaces, find nothing here, return the whole command, and capture `2`.
  install_maintainer_mock
  run_hook "$(printf 'grep -B2 foo base.txt && gh\tpr\tcreate --fill')"
  assert_deny
}

@test "a --base inside an earlier command's quoted text is not donated" {
  # The tail begins at the matched invocation, so the base flag buried in the
  # preceding commit message never reaches the base parser.
  install_maintainer_mock
  run_hook 'git commit -m "gh pr create --base develop" && gh pr create --fill'
  assert_deny
}

@test "a trailing command's -B flag is not read as this invocation's base" {
  # The tail stops at the separator, so the chained grep's context-lines flag
  # stays out of it. Unbounded, this captures `2`, which resolves to nothing
  # and silently no-ops the gate instead of denying.
  install_maintainer_mock
  run_hook "gh pr create --fill && grep -B2 foo base.txt"
  assert_deny
}

@test "a trailing command cannot donate a resolvable base ref" {
  # The dangerous direction: an unbounded tail would capture `develop` here,
  # which DOES resolve, silently narrowing the changed set and allowing a real
  # offender through rather than failing open.
  install_maintainer_mock
  run_hook "gh pr create --fill; echo --base develop"
  assert_deny
}

@test "a trailing command on the next line cannot donate a base ref" {
  # Newline is both a separator and whitespace, so the boundary group can eat
  # the newline that ends the invocation and let the next line into the tail.
  # Unbounded that captures `develop`, which resolves and narrows the changed
  # set, letting shipped.txt through.
  install_maintainer_mock
  run_hook "$(printf 'gh pr create\necho --base develop')"
  assert_deny
}

@test "backslash continuation keeps the base flag on the next line" {
  # The standard multi-line invocation. The shell strips backslash-newline
  # before parsing and so must this hook, otherwise the tail truncates at the
  # backslash, the base falls back to main, and the gate denies over a file
  # develop already ships.
  install_maintainer_mock
  run_hook "$(printf 'gh pr create \\\n  --base develop \\\n  --title x')"
  assert_allow
}

@test "a bare gh pr create with no arguments still gates" {
  # Pins the empty-tail path. The match decision keys on the regex matching,
  # never on the tail being non-empty, so a bare invocation must still resolve
  # the default base and deny. A future `[ -n "$cmd_tail" ] || exit 0` would
  # exempt it from the gate entirely and pass every other test in this file.
  install_maintainer_mock
  run_hook "gh pr create"
  assert_deny
}

@test "an unresolvable base ref fails open" {
  install_maintainer_mock
  run_hook "gh pr create --base no-such-branch --title x"
  assert_allow
}

# ---- intersection logic ------------------------------------------------

@test "allows when the unanswered file is not this branch's own change" {
  # base.txt is modified on main AFTER the branch point and untouched by the
  # branch, so it is not in the three-dot changed set; an inherited manifest
  # backlog must never block this branch's PR.
  #
  # This also pins the three-dot comparison itself. Under a two-dot diff the
  # main-side modification reports as `M`, passes the ACMR filter, lands in the
  # changed set, intersects, and denies, silently breaking the parity with
  # distribution-audit-pr.yml the hook's comments call load-bearing.
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
